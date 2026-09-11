#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
export DEBIAN_FRONTEND=noninteractive
if ! dpkg-query -W -f='${Status}' dnclient 2>/dev/null | grep -q 'install ok installed'; then
  install -d -m 0755 /etc/apt/keyrings
  curl --proto '=https' --tlsv1.2 -fsSL https://dl.defined.net/gpg.asc -o /etc/apt/keyrings/defined-net.asc
  chmod 0644 /etc/apt/keyrings/defined-net.asc
  printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/defined-net.asc] https://dl.defined.net/stable/apt stable main' > /etc/apt/sources.list.d/defined-net.list
  apt-get update
  apt-get install -y dnclient
fi
systemctl enable --now dnclient
dpkg-query -W -f='${Package} ${Version}\n' dnclient
systemctl is-enabled dnclient
systemctl is-active dnclient
