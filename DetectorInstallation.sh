#!/usr/bin/env bash
# install_detector.sh — Pi4 muon station bootstrap
# - Ensures I2C/SPI enabled (persist + immediate)
# - Fetches repo content (detector folder + bmp280.py)
# - Installs WiringPi
# - Builds ice40/max1932/dac60508 (+ slowControl with RELINK fallback)
# - Installs rc.local (backgrounds long jobs; no hang) + systemd compat
# - Installs Datatransfer.sh + 6h cron
# - Generates SSH key and prints public key with friendly message

set -euo pipefail

USER_NAME="cosmic"
USER_HOME="/home/${USER_NAME}"
REPO_ROOT="${USER_HOME}/mppcinterface-oct-2022"
BITFILE="coincidence_0raw_1raw_conincident.bin"     # change if your station needs a different bitstream
DATAXFER="${USER_HOME}/Datatransfer.sh"

log(){ printf "\n[%s] %s\n" "$(date '+%F %T')" "$*"; }
need_root(){ [[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }; }

ensure_boot_param() {
  # ensure_boot_param <file> <key>=<value>
  local f="$1" kv="$2"
  [[ -f "$f" ]] || return 0
  local key="${kv%%=*}"
  # Drop any existing dtparam=line for that key, then append "key=value"
  sed -i -E "/^\s*dtparam=${key}=/d" "$f"
  grep -qE "^\s*dtparam=${key}=" "$f" || echo "dtparam=${kv#dtparam=}" >> "$f"
}

ensure_overlay() {
  # ensure_overlay <file> <overlay>
  local f="$1" ov="$2"
  [[ -f "$f" ]] || return 0
  grep -qE "^\s*dtoverlay=${ov}\s*$" "$f" || echo "dtoverlay=${ov}" >> "$f"
}

enable_buses_persistently() {
  for f in /boot/config.txt /boot/firmware/config.txt; do
    [[ -f "$f" ]] || continue
    ensure_boot_param "$f" "dtparam=i2c_arm=on"
    ensure_boot_param "$f" "dtparam=spi=on"
    # Guarantee both /dev/spidev0.0 and /dev/spidev0.1 at boot
    ensure_overlay   "$f" "spi0-2cs"
  done
}

enable_buses_now() {
  # Remove any runtime SPI overlay then add spi0-2cs to expose spidev0.{0,1}
  command -v dtoverlay >/dev/null 2>&1 && {
    dtoverlay -l 2>/dev/null | awk -F: '/spi0-/{print $1}' | xargs -r -n1 dtoverlay -r || true
    dtoverlay spi0-2cs || true
  }
  modprobe i2c-bcm2835 i2c-dev 2>/dev/null || true
  modprobe spi_bcm2835 spidev  2>/dev/null || true
  udevadm settle || true
}

have_node() { [[ -e "$1" ]]; }

need_root

log "APT update + base packages"
apt-get update -y
apt-get install -y git build-essential curl ca-certificates pkg-config \
                   python3-pip python3-venv python3-dev i2c-tools

log "Ensure ${USER_NAME} in gpio/i2c/spi groups"
usermod -aG gpio,i2c,spi "${USER_NAME}" || true

log "Enable I2C/SPI persistently in boot config"
enable_buses_persistently

log "Enable I2C/SPI immediately (no reboot)"
enable_buses_now

SPI_OK=0
I2C_OK=0
have_node /dev/spidev0.0 && SPI_OK=1
have_node /dev/i2c-1   && I2C_OK=1
log "SPI now: $([[ $SPI_OK -eq 1 ]] && echo PRESENT || echo MISSING)  |  I2C now: $([[ $I2C_OK -eq 1 ]] && echo PRESENT || echo MISSING)"

log "Fetch repo content to ${USER_HOME} (detector folder + bmp280.py)"
sudo -u "${USER_NAME}" bash -lc '
set -e
cd ~
TAR_URL="https://github.com/tharinduudu/mppcInterface-oct-2022/archive/refs/heads/main.tar.gz"
TMP="$(mktemp /tmp/mppcInterface.XXXXXX.tar.gz)"

curl -L "$TAR_URL" -o "$TMP"

# Detect the top folder name inside the archive (e.g., mppcInterface-oct-2022-main)
TOP="$(tar -tzf "$TMP" | head -1 | cut -d/ -f1)"

# Extract exactly what we need into ~/
tar -xzf "$TMP" --strip-components=1 -C "$HOME" \
  "$TOP/mppcinterface-oct-2022" \
  "$TOP/bmp280.py"

rm -f "$TMP"
'

log "Install WiringPi from source"
sudo -u "${USER_NAME}" bash -lc 'cd ~ && rm -rf WiringPi && git clone --depth=1 https://github.com/WiringPi/WiringPi.git'
bash -lc "cd ${USER_HOME}/WiringPi && ./build"

# ---------- Build helpers ----------
build_dir(){ local d="$1"; log "Build: ${d} (make clean && make)"; bash -lc "cd ${d} && make clean || true && make -j\$(nproc)"; }

log "Build ice40 / max1932 / dac60508"
build_dir "${REPO_ROOT}/firmware/libraries/ice40"
build_dir "${REPO_ROOT}/firmware/libraries/max1932"
build_dir "${REPO_ROOT}/firmware/libraries/dac60508"

log "Build slowControl (with RELINK fallback, no Makefile edits)"
bash -lc "cd ${REPO_ROOT}/firmware/libraries/slowControl && make clean || true && make -j\$(nproc) || true"
bash -lc "cd ${REPO_ROOT}/firmware/libraries/slowControl && rm -f main.o main && g++ -c main.cpp -std=c++11 -I. && g++ main.o -lwiringPi -o main"

# ---------- One-time bring-up (only if SPI is present now) ----------
if [[ $SPI_OK -eq 1 ]]; then
  log "One-time bring-up now (FPGA, HV, DAC)"
  bash -lc "cd ${REPO_ROOT}/firmware/libraries/ice40 && ./main ${BITFILE}"
  bash -lc "cd ${REPO_ROOT}/firmware/libraries/max1932 && ./main 0xE5"
  bash -lc "cd ${REPO_ROOT}/firmware/libraries/dac60508 && ./main 0 0 && ./main 1 0 && ./main 2 0 && ./main 3 0"
else
  log "SPI device /dev/spidev0.0 still missing at runtime. Skipping bring-up now; it will run on NEXT BOOT via rc.local."
fi

# ---------- rc.local + compatibility (non-blocking) ----------
log "Install repo rc.local"
curl -fsSL https://raw.githubusercontent.com/tharinduudu/mppcInterface/main/rc.local -o /etc/rc.local \
  || curl -fsSL https://raw.githubusercontent.com/tharinduudu/mppcInterface/main/mppcinterface-oct-2022/rc.local -o /etc/rc.local

log "Sanitize rc.local (background long jobs; ensure exit 0)"
grep -q '^#!' /etc/rc.local || sed -i '1s|^|#!/bin/sh -e\n|' /etc/rc.local
sed -i -E 's#(^.*slowControl/main[^&]*)(\s*)$#\1 >>/var/log/slowcontrol.log 2>\&1 \&#' /etc/rc.local
sed -i -E 's#(^.*(python3?|/usr/bin/python3)\s+.*bmp280\.py[^&]*)(\s*)$#\1 >>/var/log/bmp280.log 2>\&1 \&#' /etc/rc.local
sed -i -E 's#(^.*/home/'"${USER_NAME}"'/bmp280\.py[^&]*)(\s*)$#\1 >>/var/log/bmp280.log 2>\&1 \&#' /etc/rc.local
grep -q '^exit 0$' /etc/rc.local || echo 'exit 0' >> /etc/rc.local
chmod 755 /etc/rc.local
chown root:root /etc/rc.local

log "Install rc-local.service (compat) and enable for next boot (do NOT start now)"
cat >/etc/systemd/system/rc-local.service <<'UNIT'
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/etc/rc.local
TimeoutSec=0
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT

systemctl stop rc-local.service 2>/dev/null || true
systemctl disable rc-local.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable rc-local.service   # next boot

# ---------- Datatransfer.sh + cron ----------
log "Fetch Datatransfer.sh → ${DATAXFER}"
curl -fL https://raw.githubusercontent.com/tharinduudu/mppcInterface/main/Datatransfer.sh -o "${DATAXFER}"
sed -i 's/\r$//' "${DATAXFER}" || true
chmod 755 "${DATAXFER}"
chown "${USER_NAME}:${USER_NAME}" "${DATAXFER}"

log "Crontab: every 6h (no output redirection)"
bash -lc '(crontab -u '"${USER_NAME}"' -l 2>/dev/null | grep -v -F "'"${DATAXFER}"'"; echo "0 */6 * * * '"${DATAXFER}"'") | crontab -u '"${USER_NAME}"' -'

# ---------- Display.sh ----------
log "Fetch Display.sh → ${USER_HOME}/Display.sh"
curl -fL https://raw.githubusercontent.com/tharinduudu/mppcInterface/main/Display.sh -o "${USER_HOME}/Display.sh"
sed -i 's/\r$//' "${USER_HOME}/Display.sh" || true
chmod 755 "${USER_HOME}/Display.sh"
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/Display.sh"

# ---------- SSH key (with friendly message) ----------
log "Generate Ed25519 SSH key (no prompts) and print public key"
sudo -u "${USER_NAME}" bash -lc '
mkdir -p ~/.ssh && chmod 700 ~/.ssh
yes y | ssh-keygen -t ed25519 -a 100 -C "$(whoami)@$(hostname)" -N "" -f ~/.ssh/id_ed25519 -q
echo
echo "Please share the public key below with GSU to enable secure data transfer access. Thank you."
echo "==== PUBLIC KEY ===="
cat ~/.ssh/id_ed25519.pub
echo "===================="
'

echo
if [[ $SPI_OK -eq 0 || $I2C_OK -eq 0 ]]; then
  echo "⚠️  A reboot is recommended to finalize SPI/I²C device nodes."
fi
echo "✅ Install complete."
echo "You can reboot now: sudo reboot"
