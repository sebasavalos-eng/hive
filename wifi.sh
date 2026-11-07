#!/usr/bin/env bash
# ==================================================================
#  Wi-Fi setup for Hive OS - MSI Cyborg 15
#  Turns the radio on, fetches missing Wi-Fi driver files, connects,
#  tests the internet over Wi-Fi and makes it survive reboots.
#  Keep the Ethernet cable plugged in while it runs.
#  Run:  bash /tmp/wifi.sh
#  You type the Wi-Fi password when asked. Never put it in this file.
# ==================================================================

: "${NET_DIR:=/sys/class/net}"     ; : "${RFKILL_DIR:=/sys/class/rfkill}"
: "${HIVE_NET:=/hive-config/network}"; : "${WPA_DIR:=/etc/wpa_supplicant}"
: "${SYSD_NET:=/etc/systemd/network}"; : "${FW_DIR:=/lib/firmware}"
: "${MODPROBE_D:=/etc/modprobe.d}"
FW_URLS=('https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain'
         'https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main')

G='\e[1;32m'; Y='\e[1;33m'; R='\e[1;31m'; C='\e[1;36m'; N='\e[0m'
ok()   { echo -e "${G}[ OK ]${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
die()  { echo -e "${R}[FAIL]${N} $*"; exit 1; }
step() { echo -e "\n${C}== $* ==${N}"; }

[[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"
[[ -t 0 ]] || die "Run it from a file: bash /tmp/wifi.sh"

wifi_iface() {
  local d
  for d in "$NET_DIR"/*; do
    [[ -d $d/wireless || -e $d/phy80211 ]] && { basename "$d"; return 0; }
  done
  return 1
}

# Download one firmware file the driver asked for (0 = downloaded)
fetch_fw() {
  local f=$1 base p paths=("$1")
  [[ -s $FW_DIR/$f ]] && return 1
  [[ $f == iwlwifi-* ]] && paths=("intel/iwlwifi/$f" "$f")
  mkdir -p "$(dirname "$FW_DIR/$f")"
  for base in "${FW_URLS[@]}"; do
    for p in "${paths[@]}"; do
      if curl -fsSL --connect-timeout 15 -o "$FW_DIR/$f.part" "$base/$p" 2>/dev/null &&
         [[ $(stat -c %s "$FW_DIR/$f.part") -gt 1000 ]]; then
        mv "$FW_DIR/$f.part" "$FW_DIR/$f"; echo "       downloaded $f"; return 0
      fi
    done
  done
  rm -f "$FW_DIR/$f.part"; return 1
}

# The card has no interface: fetch the files dmesg says are missing, reload the driver
fix_driver() {
  local log hi lo base n lo_n f got=0 iwl=0 mods m
  log=$(dmesg 2>/dev/null)
  hi=$(grep -oP 'maximum version supported: \K\S+' <<<"$log" | tail -n 1)
  lo=$(grep -oP 'minimum version required: \K\S+' <<<"$log" | tail -n 1)
  [[ -z $hi ]] && hi=$(grep -oP 'iwlwifi-\S+-\d+(?= is required)' <<<"$log" | tail -n 1)
  if [[ -n $hi ]]; then
    base=${hi%-*}; n=${hi##*-}; lo_n=${lo##*-}
    [[ $lo_n =~ ^[0-9]+$ ]] || lo_n=$((n - 20))
    for ((; n >= lo_n; n--)); do fetch_fw "$base-$n.ucode" && { got=1; iwl=1; break; }; done
    fetch_fw "$base.pnvm" && got=1
  fi
  while read -r f; do
    [[ -z $f || ($iwl -eq 1 && $f == iwlwifi-*.ucode) ]] && continue
    fetch_fw "$f" && { got=1; [[ $f == iwlwifi-*.ucode ]] && iwl=1; }
  done < <(grep -oP 'Direct firmware load for \K\S+(?= failed with error -2)' <<<"$log" | awk '!s[$0]++')

  mods=$(lspci -k 2>/dev/null | grep -iA4 'network controller' | grep -oP 'Kernel modules: \K.*' | head -n 1 | tr -d ',')
  [[ -n $mods ]] || die "This Hive kernel has no driver for your Wi-Fi card. Use Ethernet."
  [[ $got -eq 1 ]] && ok "Driver files downloaded" || warn "No missing driver files found to download"
  [[ $mods == *iwlwifi* ]] && modprobe -r iwlmvm iwlwifi 2>/dev/null
  for m in $mods; do modprobe -r "$m" 2>/dev/null; modprobe "$m" 2>/dev/null; done
  for _ in {1..15}; do wifi_iface >/dev/null && return 0; sleep 1; done
  return 1
}

# Backslash-escape for /hive-config/network/wifi.txt (same as Hive's own wifi tool)
backslash() {
  local var="${1//\\/\\\\}"
  var="${var//\"/\\\"}"
  var="${var//\`/\\\`}"
  var="${var//\$/\\\$}"
  echo "$var"
}

# --- 1. Wi-Fi card -------------------------------------------------
step "1/5 Wi-Fi card"
CARD=$(lspci 2>/dev/null | grep -i 'network controller' | head -n 1 | cut -d: -f3- | xargs)
IF=$(wifi_iface)
if [[ -z $IF ]]; then
  [[ -n $CARD ]] || die "No Wi-Fi card found. Use Ethernet."
  warn "Card found ($CARD) but no Wi-Fi interface. Fixing the driver..."
  fix_driver && IF=$(wifi_iface) || {
    echo "       Last driver messages:"; dmesg 2>/dev/null | grep -iE 'iwlwifi|firmware|wlan' | tail -n 5
    die "Wi-Fi driver still not working. Send me a photo of this screen."; }
fi
DRIVER=$(basename "$(readlink -f "$NET_DIR/$IF/device/driver" 2>/dev/null)")
ok "Interface $IF  driver ${DRIVER:-?}  ${CARD}"

# --- 2. Radio ------------------------------------------------------
step "2/5 Radio"
command -v rfkill >/dev/null && rfkill unblock all 2>/dev/null
for r in "$RFKILL_DIR"/rfkill*; do [[ -w $r/soft ]] && echo 0 > "$r/soft" 2>/dev/null; done
for r in "$RFKILL_DIR"/rfkill*; do
  [[ $(cat "$r/type" 2>/dev/null) == wlan && $(cat "$r/hard" 2>/dev/null) == 1 ]] &&
    die "Wi-Fi is switched off by the airplane-mode key. Press it (airplane icon on the F-keys), then run this again."
done
ip link set "$IF" up 2>/dev/null || warn "Couldn't bring $IF up yet"
ok "Radio on"

# --- 3. Tools ------------------------------------------------------
step "3/5 Tools"
need=()
{ command -v wpa_supplicant && command -v wpa_passphrase; } >/dev/null || need+=(wpasupplicant)
command -v iwlist >/dev/null || need+=(wireless-tools)
if ((${#need[@]})); then
  { timeout 300 apt-get install -y -qq "${need[@]}" ||
    { timeout 300 apt-get update -qq && timeout 300 apt-get install -y -qq "${need[@]}"; }; } >/dev/null 2>&1 ||
    die "Couldn't install ${need[*]}. Is the Ethernet cable plugged in?"
fi
ok "wpa_supplicant ready"

# --- 4. Choose the network -----------------------------------------
step "4/5 Choose your network"
systemctl stop "wpa_supplicant@$IF" >/dev/null 2>&1
scan() {
  iwlist "$IF" scan 2>/dev/null | awk '
    /Cell [0-9]+/ { q = 0 }
    /Quality=/ { if (match($0, /Quality=[0-9]+\/[0-9]+/)) { split(substr($0, RSTART + 8, RLENGTH - 8), a, "/"); q = int(a[1] * 100 / a[2]) } }
    /ESSID:"/ { s = $0; sub(/.*ESSID:"/, "", s); sub(/"[^"]*$/, "", s); if (s != "") print q "\t" s }' |
    sort -t $'\t' -k1,1nr | awk -F '\t' '!seen[$2]++'
}
SSID=
while [[ -z $SSID ]]; do
  echo "Scanning..."
  LIST=(); for _ in 1 2 3; do mapfile -t LIST < <(scan); ((${#LIST[@]})) && break; sleep 2; done
  ((${#LIST[@]})) || echo "No networks found."
  for i in "${!LIST[@]}"; do printf '  %2d) %s  (signal %s%%)\n' $((i + 1)) "${LIST[i]#*$'\t'}" "${LIST[i]%%$'\t'*}"; done
  echo "   h) Hidden network (type its name)"
  echo "   r) Scan again"
  read -r -p "Pick one: " pick
  case $pick in
    h|H) IFS= read -r -p "Network name (SSID): " SSID ;;
    r|R|'') ;;
    *) if [[ $pick =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#LIST[@]})); then
         SSID=${LIST[pick - 1]#*$'\t'}; fi ;;
  esac
done
while true; do
  IFS= read -r -p "Password for \"$SSID\" (leave empty if it has none): " PASS
  [[ -z $PASS ]] && break
  ((${#PASS} >= 8 && ${#PASS} <= 63)) && break
  echo "Wi-Fi passwords are 8 to 63 characters. Try again."
done

# --- 5. Connect and save -------------------------------------------
step "5/5 Connect"
if [[ -z $PASS ]]; then
  NETBLOCK=$(printf 'network={\n\tssid="%s"\n\tscan_ssid=1\n\tkey_mgmt=NONE\n}' "$SSID")
else
  NETBLOCK=$(wpa_passphrase "$SSID" "$PASS" | grep -v '#psk=' | sed 's/^network={/network={\n\tscan_ssid=1/')
  [[ $NETBLOCK == *psk=* ]] || die "Couldn't create the Wi-Fi config."
fi
mkdir -p "$WPA_DIR" "$HIVE_NET" "$SYSD_NET"
for f in "$WPA_DIR/wpa_supplicant-$IF.conf" "$WPA_DIR/wpa_supplicant.conf"; do
  printf 'ctrl_interface=/run/wpa_supplicant\n%s\n' "$NETBLOCK" > "$f"; chmod 600 "$f"
done
# Hive re-applies this file at every boot
{ echo "# If you need WiFi, then give SSID and password."
  echo "WIFI_SSID=\"$(backslash "$SSID")\""
  echo "WIFI_PASSWORD=\"$(backslash "${PASS:-NONE}")\""; } > "$HIVE_NET/wifi.txt"
# DHCP on Wi-Fi; Ethernet (metric 10) stays preferred when plugged in
printf '%s\n' '[Match]' 'Name=wl*' '' '[Network]' 'DHCP=ipv4' '' '[DHCPv4]' \
  'ClientIdentifier=mac' 'RouteMetric=20' > "$HIVE_NET/15-wifi.network"
cp "$HIVE_NET/15-wifi.network" "$SYSD_NET/15-wifi.network"; chmod 644 "$SYSD_NET/15-wifi.network"
# No Wi-Fi power saving: fewer dropouts on a 24/7 rig
[[ $DRIVER == iwlwifi ]] && echo 'options iwlmvm power_scheme=1' > "$MODPROBE_D/hive-wifi.conf"
iw dev "$IF" set power_save off 2>/dev/null || iwconfig "$IF" power off 2>/dev/null

ip link set "$IF" up 2>/dev/null
systemctl enable "wpa_supplicant@$IF" >/dev/null 2>&1
systemctl restart "wpa_supplicant@$IF" || warn "wpa_supplicant didn't start"
{ networkctl reload && networkctl reconfigure "$IF"; } >/dev/null 2>&1 || systemctl restart systemd-networkd

echo -n "Connecting"
IP=; up=0
for _ in {1..45}; do
  [[ $(cat "$NET_DIR/$IF/operstate" 2>/dev/null) == up ]] && up=1
  IP=$(ip -4 -o addr show dev "$IF" 2>/dev/null | awk '{print $4}' | head -n 1)
  [[ -n $IP ]] && break
  echo -n "."; sleep 1
done
echo

if [[ -z $IP ]]; then
  if [[ $up -eq 1 ]]; then
    die "Joined \"$SSID\" but the router gave no IP address. Restart the router or run this again."
  fi
  why=$(journalctl -u "wpa_supplicant@$IF" -n 80 --no-pager 2>/dev/null)
  if grep -qE 'WRONG_KEY|4-Way Handshake failed' <<<"$why"; then
    die "Wrong password for \"$SSID\". Run this again."
  fi
  die "Couldn't join \"$SSID\". Move closer to the router or pick another network, then run this again."
fi
ok "Connected to \"$SSID\", IP ${IP%/*}"
if ping -I "$IF" -c 3 -W 3 1.1.1.1 >/dev/null 2>&1; then
  NETOK=yes; ok "Internet over Wi-Fi works"
else
  NETOK=no; warn "Connected, but no internet through Wi-Fi"
fi
SIG=$(iwconfig "$IF" 2>/dev/null | grep -oP 'Signal level=\K-?[0-9]+ dBm')

echo -e "\n${C}------------ SEND ME THIS (a photo is fine) ------------${N}"
echo "Wi-Fi    : $IF ($DRIVER) $CARD"
echo "Network  : $SSID   signal ${SIG:-?}"
echo "IP       : ${IP%/*}"
echo "Internet : $NETOK"
echo -e "${C}---------------------------------------------------------${N}"
[[ $NETOK == yes ]] &&
  ok "Done. Unplug the Ethernet cable: the rig stays online over Wi-Fi and reconnects after reboots."
exit 0
