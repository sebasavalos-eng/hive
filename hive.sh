#!/usr/bin/env bash
# ==================================================================
#  Hive OS setup for ANY PC: desktop or laptop, NVIDIA / AMD / Intel
#  - adds this PC to your farm as its own worker
#  - can install Hive on the internal drive (erases it) and set up Wi-Fi
#  - updates Hive, checks the GPUs, applies laptop tweaks on laptops
#  Safe to re-run. On the rig:
#   curl -fsSL https://raw.githubusercontent.com/sebasavalos-eng/hive/refs/heads/main/rig.sh -o /tmp/rig.sh && bash /tmp/rig.sh
#  This repo is PUBLIC: never write your farm hash or passwords here.
#  The script asks for them and keeps them only on the rig.
# ==================================================================

# ----------------------------- SETTINGS ---------------------------
REPO_RAW='https://raw.githubusercontent.com/sebasavalos-eng/hive/refs/heads/main'
HIVE_API='https://api.hiveos.farm'
DO_SELFUPGRADE=1        # 1 = update Hive OS
MIN_NVIDIA=550          # older NVIDIA drivers get updated (RTX 50 cards: 580)
SCREEN_BRIGHTNESS=15    # laptops: backlight % while mining (0 = leave as is)
BATTERY_LIMIT=80        # laptops: stop charging at this % if supported (0 = off)
# ------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then exec sudo bash "$0" "$@"; fi
set -a; [[ -f /etc/environment ]] && . /etc/environment; set +a
export PATH="/hive/bin:/hive/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export RIG_CONF="${RIG_CONF:-/hive-config/rig.conf}"
OWNER_FILE=/hive-config/network/rig-owner.txt   # which PC this drive belongs to
HASH_FILE=/hive-config/farm-hash.txt            # farm hash, kept on this drive only

LOG=/home/user/rig-setup.log; [[ -d /home/user ]] || LOG=/tmp/rig-setup.log
exec > >(tee -a "$LOG") 2>&1

G=$'\e[1;32m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; C=$'\e[1;36m'; N=$'\e[0m'
step() { printf '\n%s== %s ==%s\n' "$C" "$*" "$N"; }
ok()   { printf '%s[ OK ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*"; }
yes_no() { local a; read -r -p "$1" a; [[ ${a,,} == y* ]]; }
online() { ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; }
dmi() { [[ -r /sys/class/dmi/id/$1 ]] && tr -d '\0' < "/sys/class/dmi/id/$1" | xargs; }
# shellcheck disable=SC1090
conf_get() { ( unset RIG_ID RIG_PASSWD WORKER_NAME FARM_HASH; . "$RIG_CONF" 2>/dev/null; printf '%s' "${!1:-}" ); }
TTY=0; [[ -t 0 ]] && TTY=1
NEED_REBOOT=0; CONNECTED=0
echo "${C}Hive OS setup - $(date)${N}"

online || { err "No internet. Plug in an Ethernet cable (or run Hive's 'wifi' command) and run this again."; exit 1; }

# ------------------------------------------------------------------
step "1/7 This PC"
VENDOR=$(dmi sys_vendor); PRODUCT=$(dmi product_name)
IS_LAPTOP=0
[[ $(dmi chassis_type) =~ ^(8|9|10|14|31|32)$ ]] && IS_LAPTOP=1
[[ $IS_LAPTOP == 0 && -z $(dmi chassis_type) ]] && ls -d /sys/class/power_supply/BAT* >/dev/null 2>&1 && IS_LAPTOP=1
CPU=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -n 1)
RAM=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
GPUS=$(lspci 2>/dev/null | grep -iE 'vga|3d controller|display controller' | cut -d: -f3- | sed 's/^ *//')
WIFI_CARD=$(lspci 2>/dev/null | grep -i 'network controller' | head -n 1 | cut -d: -f3- | xargs)
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n 1)
ROOT_TRAN=$(lsblk -dno TRAN "/dev/$ROOT_DISK" 2>/dev/null | xargs)
INTERNAL=$(lsblk -dn -b -o NAME,TYPE,TRAN,SIZE 2>/dev/null | awk -v boot="$ROOT_DISK" '$2=="disk" && $1!=boot &&
  $3!="usb" && $1 !~ /^(loop|zram|sr|mmcblk)/ && $NF>=8000000000 {print $1}' | head -n 1)
MAC=$(cat /sys/class/net/eth0/address 2>/dev/null)
[[ -n $MAC ]] || MAC=$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00' | head -n 1)
FP=$(printf '%s-%s' "$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)" "$MAC" | sha1sum | cut -c1-16)

echo "  PC      : ${VENDOR:-?} ${PRODUCT:-?} ($([[ $IS_LAPTOP == 1 ]] && echo laptop || echo desktop))"
echo "  CPU/RAM : ${CPU:-?}, ${RAM:-?} RAM"
while read -r g; do [[ -n $g ]] && echo "  GPU     : $g"; done <<<"$GPUS"
echo "  Wi-Fi   : ${WIFI_CARD:-none}"
if [[ $ROOT_TRAN == usb ]]; then
  echo "  Running : from a USB stick${INTERNAL:+ (internal drive: $INTERNAL $(lsblk -dno SIZE "/dev/$INTERNAL" | xargs))}"
else
  echo "  Running : from ${ROOT_DISK:-?} (installed)"
fi

# ------------------------------------------------------------------
step "2/7 Hive farm"
SFX=$(tr -d ':' <<<"$MAC"); SFX=${SFX: -4}
BASE=$(tr '[:upper:]' '[:lower:]' <<<"$PRODUCT" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//' | cut -c1-16 | sed -E 's/-+$//')
[[ -z $BASE || $PRODUCT =~ O\.E\.M|[Ss]ystem\ [Pp]roduct|[Dd]efault\ [Ss]tring|[Tt]o\ [Bb]e\ [Ff]illed ]] && BASE=pc
DEF_NAME="$BASE-${SFX:-1}"

register() {
  local name hash id pw tries=0
  [[ $TTY == 1 ]] || { err "Run this from the rig's own keyboard to add it to the farm."; return 1; }
  read -r -p "Worker name for this PC [$DEF_NAME]: " name; name=${name:-$DEF_NAME}
  until [[ $name =~ ^[A-Za-z0-9_-]{1,30}$ ]]; do read -r -p "Letters, numbers, - and _ only: " name; done
  hash=; [[ -f $HASH_FILE ]] && hash=$(tr -d '[:space:]' < "$HASH_FILE")
  [[ -n $hash ]] || hash=$(conf_get FARM_HASH)
  if [[ $hash =~ ^[0-9a-fA-F]{40}$ ]]; then echo "Using the farm hash saved on this drive."; else hash=; fi
  while ((tries++ < 3)); do
    if [[ -z $hash ]]; then
      echo "Farm hash: the.hiveos.farm -> your farm -> Settings (40 characters)."
      read -r -p "Farm hash (Enter = use a Rig ID + password instead): " hash; hash=${hash//[[:space:]]/}
    fi
    [[ -f $RIG_CONF ]] && cp -f "$RIG_CONF" "$RIG_CONF.bak"
    if [[ $hash =~ ^[0-9a-fA-F]{40}$ ]]; then
      printf 'HIVE_HOST_URL="%s"\nFARM_HASH="%s"\nWORKER_NAME="%s"\n' "$HIVE_API" "$hash" "$name" > "$RIG_CONF"
    else
      [[ -n $hash ]] && warn "That isn't a 40-character farm hash."
      hash=
      echo "Use the Rig ID + password from Hive -> Workers -> Add Worker (it keeps the name you gave it there)."
      read -r -p "Rig ID: " id; read -r -p "Rig password: " pw
      id=${id//[[:space:]]/}; pw=${pw//[[:space:]]/}
      if [[ ! $id =~ ^[0-9]+$ || -z $pw || $pw =~ [\"\'] ]]; then err "Invalid Rig ID or password."; continue; fi
      printf 'HIVE_HOST_URL="%s"\nRIG_ID="%s"\nRIG_PASSWD="%s"\n' "$HIVE_API" "$id" "$pw" > "$RIG_CONF"
    fi
    [[ -n ${API_HOST_FILE:-} ]] && rm -f "$API_HOST_FILE"
    if hello; then
      [[ -n $hash ]] && printf '%s\n' "$hash" > "$HASH_FILE"
      mkdir -p "${OWNER_FILE%/*}"; echo "$FP" > "$OWNER_FILE"
      miner stop >/dev/null 2>&1; agent-screen restart >/dev/null 2>&1
      return 0
    fi
    err "Hive didn't accept that."
    if [[ -f $RIG_CONF.bak ]]; then mv -f "$RIG_CONF.bak" "$RIG_CONF"; else rm -f "$RIG_CONF"; fi
    hash=
  done
  return 1
}

CUR_ID=$(conf_get RIG_ID); CUR_NAME=$(conf_get WORKER_NAME); OWNER=$(cat "$OWNER_FILE" 2>/dev/null)
NEW=1
if [[ -n $CUR_ID ]]; then
  if [[ $OWNER == "$FP" ]]; then
    NEW=0
  elif [[ -n $OWNER ]]; then
    warn "This drive was set up on another PC (worker \"${CUR_NAME:-?}\"). This PC gets its own worker."
  elif [[ $TTY == 0 ]] || ! yes_no "This drive is worker \"${CUR_NAME:-?}\" (ID $CUR_ID). Is that a different PC? (y/N): "; then
    NEW=0
  fi
fi
if [[ $NEW == 0 ]]; then
  [[ -n ${API_HOST_FILE:-} ]] && rm -f "$API_HOST_FILE"
  if hello >/dev/null 2>&1; then
    CONNECTED=1; mkdir -p "${OWNER_FILE%/*}"; echo "$FP" > "$OWNER_FILE"
  else
    err "Hive didn't accept this drive's saved login."
    [[ $TTY == 1 ]] && yes_no "Add this PC to the farm again? (y/N): " && NEW=1
  fi
fi
[[ $NEW == 1 ]] && register && CONNECTED=1
if [[ $CONNECTED == 1 ]]; then
  ok "Connected as worker \"$(conf_get WORKER_NAME)\" (rig ID $(conf_get RIG_ID))"
else
  err "Not connected to Hive. Run this again, or run: firstrun -f"
fi

# ------------------------------------------------------------------
step "3/7 Install on the internal drive"
if [[ $ROOT_TRAN != usb ]]; then
  ok "Already installed on this PC"
elif [[ -z $INTERNAL ]]; then
  ok "No internal drive found: Hive keeps running from the USB stick"
elif [[ $CONNECTED == 1 && $TTY == 1 ]]; then
  echo "Hive can run from the internal drive ($INTERNAL) instead of the USB stick."
  echo "${R}That ERASES everything on that drive.${N}"
  if yes_no "Install Hive on the internal drive now? (y/N): "; then
    if curl -fsSL "$REPO_RAW/ssd.sh" -o /tmp/ssd.sh; then
      echo "${C}When it powers off: unplug the USB, turn the PC on, then run rig.sh again to finish.${N}"
      exec bash /tmp/ssd.sh
    fi
    err "Couldn't download ssd.sh from your repo. Continuing from the USB."
  else
    ok "Skipped: Hive keeps running from the USB stick"
  fi
else
  warn "Skipped: connect to the farm first"
fi

# ------------------------------------------------------------------
step "4/7 Hive OS update + disk"
if [[ $DO_SELFUPGRADE == 1 ]]; then
  if selfupgrade; then
    ok "Hive OS $(dpkg-query -W -f='${Version}' hive 2>/dev/null)"
  else
    warn "selfupgrade had a problem - try later: selfupgrade --force"
  fi
fi
disk-expand -s >/dev/null 2>&1
ok "Disk: $(df -h / | awk 'NR==2{print $2" total, "$4" free"}')"
NEWEST_K=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n 1)
[[ -n $NEWEST_K && $NEWEST_K != "$(uname -r)" ]] && NEED_REBOOT=1

# ------------------------------------------------------------------
step "5/7 GPUs"
NV=$(grep -ci nvidia <<<"$GPUS")
AMDN=$(grep -ciE 'amd|ati ' <<<"$GPUS")
ARC=$(grep -i intel <<<"$GPUS" | grep -ciE 'arc|dg2')
((NV + AMDN + ARC == 0)) && warn "No mining GPU found (only basic integrated graphics)."
if ((NV > 0)); then
  NEED=$MIN_NVIDIA
  grep -i nvidia <<<"$GPUS" | grep -qiE 'RTX 50[0-9]0|GB20[0-9]' && ((NEED < 580)) && NEED=580
  DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1)
  [[ $DRV =~ ^[0-9]+\. ]] || DRV=""
  if [[ -z $DRV ]]; then
    err "The NVIDIA driver isn't talking to the GPU:"
    journalctl -k -b --no-pager 2>/dev/null | grep -i nvrm | tail -n 3 | sed 's/^/  /'
    warn "Installing Hive's newest NVIDIA driver (a few minutes)..."
    nvidia-driver-update && NEED_REBOOT=1
    warn "If it still fails after the reboot: BIOS -> disable Secure Boot."
  elif ((${DRV%%.*} < NEED)); then
    warn "NVIDIA driver $DRV is older than $NEED - updating (a few minutes)..."
    nvidia-driver-update && NEED_REBOOT=1
  else
    ok "NVIDIA driver $DRV"
    nvidia-smi --query-gpu=name,memory.total,temperature.gpu,power.limit --format=csv,noheader 2>/dev/null | sed 's/^/  /'
  fi
fi
if ((AMDN > 0)); then
  if lspci -k 2>/dev/null | grep -A3 -iE 'vga|3d controller|display controller' | grep -q 'Kernel driver in use: amdgpu'; then
    ok "AMD driver loaded"
  else
    warn "AMD GPU found but the amdgpu driver isn't loaded. Try: amd-ocl-install, then sreboot"
  fi
fi
((ARC > 0)) && ok "Intel Arc GPU found (details: intel-info)"

# ------------------------------------------------------------------
step "6/7 Laptop tweaks"
if [[ $IS_LAPTOP == 1 ]]; then
  # Closing the lid normally suspends the laptop and stops mining
  LID=/etc/systemd/logind.conf.d/90-mining-laptop.conf
  LID_TXT=$'[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore'
  if [[ "$(cat "$LID" 2>/dev/null)" != "$LID_TXT" ]]; then
    mkdir -p "${LID%/*}" && printf '%s\n' "$LID_TXT" > "$LID"
    systemctl restart systemd-logind
  fi
  ok "Lid close ignored (no suspend)"

  # Screen dim + battery charge limit, re-applied on every boot
  TUNE=/usr/local/sbin/laptop-mining-tune
  printf 'BRIGHT=%s\nLIMIT=%s\n' "$SCREEN_BRIGHTNESS" "$BATTERY_LIMIT" > "$TUNE"
  cat >> "$TUNE" <<'EOF'
modprobe msi_ec 2>/dev/null
if [ "$BRIGHT" -gt 0 ]; then
  for b in /sys/class/backlight/*; do
    [ -w "$b/brightness" ] || continue
    v=$(( $(cat "$b/max_brightness") * BRIGHT / 100 )); [ "$v" -lt 1 ] && v=1
    echo "$v" > "$b/brightness"
  done
fi
if [ "$LIMIT" -gt 0 ]; then
  for bat in /sys/class/power_supply/BAT*; do
    [ -w "$bat/charge_control_end_threshold" ] && echo "$LIMIT" > "$bat/charge_control_end_threshold"
  done
fi
exit 0
EOF
  chmod 755 "$TUNE"
  cat > /etc/systemd/system/laptop-mining-tune.service <<'EOF'
[Unit]
Description=Laptop tweaks for 24/7 mining (screen dim, battery limit)

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/laptop-mining-tune

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable laptop-mining-tune.service >/dev/null 2>&1
  bash "$TUNE"
  if [[ $SCREEN_BRIGHTNESS -gt 0 ]] && ls /sys/class/backlight/* >/dev/null 2>&1; then
    ok "Screen backlight at ${SCREEN_BRIGHTNESS}%"
  fi
  BAT=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n 1)
  if [[ $BATTERY_LIMIT -gt 0 && -r $BAT/charge_control_end_threshold ]]; then
    ok "Battery stops charging at $(cat "$BAT/charge_control_end_threshold")%"
  elif [[ $BATTERY_LIMIT -gt 0 ]]; then
    warn "This laptop can't cap battery charge from Linux - it will sit at 100%."
  fi
else
  ok "Desktop: nothing to do"
fi

# ------------------------------------------------------------------
step "7/7 Wi-Fi + login password"
if [[ -z $WIFI_CARD ]]; then
  ok "No Wi-Fi card: use Ethernet"
elif ip -4 -o addr show 2>/dev/null | grep -qE ': wl'; then
  ok "Wi-Fi already connected"
elif [[ $TTY == 1 ]] && yes_no "Set up Wi-Fi on this PC now? (y/N): "; then
  if curl -fsSL "$REPO_RAW/wifi.sh" -o /tmp/wifi.sh; then
    bash /tmp/wifi.sh
  else
    err "Couldn't download wifi.sh from your repo."
  fi
else
  ok "Wi-Fi skipped (run rig.sh again any time to set it up)"
fi
if [[ $TTY == 1 ]]; then
  read -r -p "New login password for this rig (6+ letters/numbers, Enter = keep): " PW
  if [[ -n $PW ]]; then
    if [[ $PW =~ ^[A-Za-z0-9._-]{6,}$ ]]; then
      hive-passwd "$PW" >/dev/null && ok "Login password for 'user' changed"
    else
      warn "Password not changed: use 6+ letters/numbers (. _ - allowed)"
    fi
  fi
fi

# ------------------------------------------------------------------
GPU_LINE=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | paste -sd ';' -)
[[ -n $GPU_LINE ]] || GPU_LINE=$(paste -sd ';' - <<<"$GPUS")
echo
echo "${C}------------- SEND ME THIS (a photo is fine) -------------${N}"
echo "Worker : $( [[ $CONNECTED == 1 ]] && echo "$(conf_get WORKER_NAME) (rig ID $(conf_get RIG_ID))" || echo "not connected")"
echo "PC     : ${VENDOR:-?} ${PRODUCT:-?} ($([[ $IS_LAPTOP == 1 ]] && echo laptop || echo desktop))"
echo "Hive   : $(dpkg-query -W -f='${Version}' hive 2>/dev/null) | kernel $(uname -r)"
echo "GPU    : ${GPU_LINE:-none}"
echo "Drive  : $([[ $ROOT_TRAN == usb ]] && echo "USB stick" || echo "internal ($ROOT_DISK)")"
echo "IP     : $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "${C}-----------------------------------------------------------${N}"
echo "Full log: $LOG"

if [[ $NEED_REBOOT == 1 ]]; then
  warn "Reboot needed to finish: type  sreboot"
elif [[ $CONNECTED == 1 ]]; then
  ok "Done. In Hive, tap the rocket next to \"$(conf_get WORKER_NAME)\" and apply your QTC flight sheet."
else
  warn "Not connected to the dashboard yet - run this again."
fi
exit 0
