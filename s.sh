cat > /home/user/hive-setup.sh <<'HIVE_SETUP_EOF'
# ==================================================================
#  Hive OS first-time setup - MSI Cyborg 15 (RTX 4050 Laptop GPU)
#  Fill in CONFIG (keep the single quotes), or leave it empty
#  and the script asks you.
#  Safe to re-run: each step checks first and skips what is done.
#  Re-run later with:  sudo bash /home/user/hive-setup.sh
# ==================================================================

# ----------------------------- CONFIG -----------------------------
# Connection - ignored if this rig is already connected.
# Easiest: the.hiveos.farm -> your farm -> Settings -> FARM_HASH
FARM_HASH=''
WORKER_NAME='cyborg15'      # dashboard name (FARM_HASH mode only)
# ...or the pair shown after "Add Worker" in the dashboard:
RIG_ID=''
RIG_PASSWD=''

# Wi-Fi: leave empty if the Ethernet cable is plugged in (best).
# Open network without password: WIFI_PASS='NONE'
WIFI_SSID=''
WIFI_PASS=''

# New SSH/VNC password for user "user" (Hive default is 1).
# 6+ letters/numbers, . _ - allowed. Empty = keep current.
NEW_SYS_PASS=''

DO_SELFUPGRADE=1        # 1 = update Hive OS packages first
MIN_NVIDIA=550          # install Hive's newest NVIDIA driver if older
LAPTOP_TWEAKS=1         # 1 = lid close ignored + screen/battery tweaks
SCREEN_BRIGHTNESS=15    # backlight % while mining (0 = leave as is)
BATTERY_LIMIT=80        # stop charging at this % if supported (0 = off)
AUTO_REBOOT=0           # 1 = reboot by itself at the end if needed
# ------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then exec sudo bash "$0" "$@"; fi

# Hive environment (RIG_CONF, VNC_PASSWD, API_HOST_FILE...)
set -a; [[ -f /etc/environment ]] && . /etc/environment; set +a
export PATH="/hive/bin:/hive/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export RIG_CONF="${RIG_CONF:-/hive-config/rig.conf}"

LOG=/home/user/hive-setup.log; [[ -d /home/user ]] || LOG=/tmp/hive-setup.log
exec > >(tee -a "$LOG") 2>&1

G=$'\e[1;32m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; C=$'\e[1;36m'; N=$'\e[0m'
step() { printf '\n%s== %s ==%s\n' "$C" "$*" "$N"; }
ok()   { printf '%s[ OK ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*"; }
ask()  { local v; read -r -p "$1" v; printf '%s' "${v//[[:space:]]/}"; }
online() { ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; }
NEED_REBOOT=0
echo "${C}Hive OS laptop setup - $(date)${N}"

# ------------------------------------------------------------------
step "1/6 Network"
if online; then
  :
else
  if [[ -z $WIFI_SSID && -t 0 ]]; then
    warn "Offline. Plug in the Ethernet cable, or type your Wi-Fi."
    read -r -p "Wi-Fi name (Enter = skip): " WIFI_SSID
    [[ -n $WIFI_SSID ]] && read -r -p "Wi-Fi password: " WIFI_PASS
  fi
  if [[ -n $WIFI_SSID ]]; then
    if ip link show wlan0 >/dev/null 2>&1; then
      wifi "$WIFI_SSID" "$WIFI_PASS"
      # Hive re-applies /hive-config/network/wifi.txt on every boot
      esc() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\`/\\\`}; v=${v//\$/\\\$}; printf '%s' "$v"; }
      WF=/hive-config/network/wifi.txt
      mkdir -p /hive-config/network && touch "$WF"
      sed -i '/^WIFI_/d' "$WF"
      printf 'WIFI_SSID="%s"\nWIFI_PASSWORD="%s"\n' "$(esc "$WIFI_SSID")" "$(esc "$WIFI_PASS")" >> "$WF"
      for _ in $(seq 25); do online && break; sleep 1; done
    else
      err "No wlan0 adapter - this image has no driver/firmware for the Intel Wi-Fi."
    fi
  fi
fi
if online; then
  ok "Online - IP $(hostname -I 2>/dev/null | awk '{print $1}')"
else
  err "Still offline. Plug the cable into the RJ45 port and re-run."
  exit 1
fi

# ------------------------------------------------------------------
step "2/6 Hive dashboard"
registered() { [[ -f $RIG_CONF ]] && grep -qE '^(RIG_ID|FARM_HASH)="?[0-9a-fA-F]' "$RIG_CONF"; }
HOST_URL=$(grep -m1 -oP '^HIVE_HOST_URL="?\K[^"\r]+' /hive-config/rig-config-example.txt 2>/dev/null)
HOST_URL=${HOST_URL:-http://api.hiveos.farm}
NEW_CONF=0; CONNECTED=0
if registered; then
  :
else
  if [[ -z $FARM_HASH && -z $RIG_ID && -t 0 ]]; then
    echo "Paste FARM_HASH (farm -> Settings), or press Enter to use Rig ID + password."
    FARM_HASH=$(ask "FARM_HASH: ")
    if [[ -z $FARM_HASH ]]; then
      RIG_ID=$(ask "Rig ID: ")
      RIG_PASSWD=$(ask "Rig password: ")
    fi
  fi
  FARM_HASH=${FARM_HASH//[[:space:]]/}; RIG_ID=${RIG_ID//[[:space:]]/}; RIG_PASSWD=${RIG_PASSWD//[[:space:]]/}
  [[ -f $RIG_CONF ]] && cp -f "$RIG_CONF" "$RIG_CONF.bak"
  if [[ $FARM_HASH =~ ^[0-9a-fA-F]{40}$ ]]; then
    printf 'HIVE_HOST_URL="%s"\nFARM_HASH="%s"\nWORKER_NAME="%s"\n' "$HOST_URL" "$FARM_HASH" "$WORKER_NAME" > "$RIG_CONF"
    NEW_CONF=1
  elif [[ $RIG_ID =~ ^[0-9]+$ && $RIG_PASSWD =~ ^[^\"\']+$ ]]; then
    printf 'HIVE_HOST_URL="%s"\nRIG_ID="%s"\nRIG_PASSWD="%s"\n' "$HOST_URL" "$RIG_ID" "$RIG_PASSWD" > "$RIG_CONF"
    NEW_CONF=1
  else
    err "No valid FARM_HASH (40 chars) or RIG_ID + RIG_PASSWD. Skipped - you can run: firstrun -f"
  fi
fi
if registered; then
  [[ -n ${API_HOST_FILE:-} ]] && rm -f "$API_HOST_FILE"
  if hello; then
    CONNECTED=1
    ok "Connected: $( unset WORKER_NAME RIG_ID; . "$RIG_CONF"; echo "worker ${WORKER_NAME:-?}, rig ID ${RIG_ID:-?}" )"
  else
    err "Hive server did not accept the login (or is unreachable)."
    if [[ $NEW_CONF == 1 ]]; then
      if [[ -f $RIG_CONF.bak ]]; then mv -f "$RIG_CONF.bak" "$RIG_CONF"; else rm -f "$RIG_CONF"; fi
      warn "Check the hash / ID / password and re-run."
    fi
  fi
fi

# ------------------------------------------------------------------
step "3/6 Hive OS update + disk"
if [[ $DO_SELFUPGRADE == 1 ]]; then
  if selfupgrade; then
    ok "Hive OS $(dpkg-query -W -f='${Version}' hive 2>/dev/null)"
  else
    warn "selfupgrade had a problem - try later: selfupgrade --force"
  fi
fi
disk-expand -s >/dev/null 2>&1
ok "Disk: $(df -h / | awk 'NR==2{print $2" total, "$4" free"}')"
NEWEST_K=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -n1)
[[ -n $NEWEST_K && $NEWEST_K != "$(uname -r)" ]] && NEED_REBOOT=1

# ------------------------------------------------------------------
step "4/6 NVIDIA GPU"
lspci | grep -iE 'vga|3d controller|display controller' | sed 's/^/  /'
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)
[[ $DRV =~ ^[0-9]+\. ]] || DRV=""
if [[ -z $DRV ]]; then
  err "NVIDIA driver is not talking to the RTX 4050:"
  journalctl -k -b --no-pager 2>/dev/null | grep -i nvrm | tail -n3 | sed 's/^/  /'
  warn "Installing Hive's newest NVIDIA driver (takes a few minutes)..."
  nvidia-driver-update && NEED_REBOOT=1
  warn "If it still fails after reboot: BIOS -> disable Secure Boot."
elif (( ${DRV%%.*} < MIN_NVIDIA )); then
  warn "Driver $DRV is older than $MIN_NVIDIA - updating (a few minutes)..."
  nvidia-driver-update && NEED_REBOOT=1
else
  ok "Driver $DRV"
  nvidia-smi --query-gpu=name,memory.total,temperature.gpu,clocks.max.sm,clocks.max.mem --format=csv | sed 's/^/  /'
  nvidia-smi -q -d POWER | grep -E 'Power Draw|Power Limit' | head -n6 | sed 's/^ */  /'
fi

# ------------------------------------------------------------------
step "5/6 Laptop tweaks"
if [[ $LAPTOP_TWEAKS == 1 ]]; then
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
  BAT=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1)
  if [[ $BATTERY_LIMIT -gt 0 && -r $BAT/charge_control_end_threshold ]]; then
    ok "Battery stops charging at $(cat "$BAT/charge_control_end_threshold")%"
  elif [[ $BATTERY_LIMIT -gt 0 ]]; then
    warn "This kernel can't cap battery charge - it will sit at 100% while warm."
  fi
else
  ok "Skipped (LAPTOP_TWEAKS=0)"
fi

# ------------------------------------------------------------------
step "6/6 Password + summary"
if [[ -n $NEW_SYS_PASS ]]; then
  if [[ $NEW_SYS_PASS =~ ^[A-Za-z0-9._-]{6,}$ ]]; then
    hive-passwd "$NEW_SYS_PASS" >/dev/null && ok "SSH/VNC password for 'user' changed"
  else
    warn "NEW_SYS_PASS skipped: use 6+ letters/numbers (. _ - allowed)"
  fi
else
  warn "SSH password not changed by this script (Hive default: user / 1)"
fi

GPU=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null) || GPU="not detected"
CUDA=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version: \K[0-9.]+')
TEMP=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,power.limit --format=csv,noheader 2>/dev/null) || TEMP=""
echo
echo "${C}------------- SEND ME THIS (a photo is fine) -------------${N}"
echo "Worker : $( unset WORKER_NAME RIG_ID; [[ -f $RIG_CONF ]] && . "$RIG_CONF"; echo "${WORKER_NAME:-not connected} (rig ID ${RIG_ID:-?})" )"
echo "Hive   : $(dpkg-query -W -f='${Version}' hive 2>/dev/null) | kernel $(uname -r) | $(lsb_release -ds 2>/dev/null)"
echo "GPU    : $GPU | CUDA ${CUDA:-?}"
echo "Temp/W : ${TEMP:-?}"
echo "glibc  : $(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9.]+$')"
echo "IP     : $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "${C}-----------------------------------------------------------${N}"
echo "Full log: $LOG"

if [[ $NEED_REBOOT == 1 ]]; then
  if [[ $AUTO_REBOOT == 1 ]]; then
    warn "Rebooting in 15 s (Ctrl+C to cancel)..."; sleep 15; sreboot
  else
    warn "Reboot needed to finish: type  sreboot"
  fi
elif [[ $CONNECTED == 1 ]]; then
  ok "Done. Rig is ready for the miner / flight sheet."
else
  warn "Not connected to the dashboard yet - fix step 2 and re-run."
fi
[[ -n ${STY:-} && -t 0 ]] && read -r -p "Press Enter to close this window... " _
exit 0
HIVE_SETUP_EOF
if command -v screen >/dev/null; then sudo screen -S setup bash /home/user/hive-setup.sh; else sudo bash /home/user/hive-setup.sh; fi
