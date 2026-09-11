#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
runtime_uid=$(id -u kota-private-test)
test "$runtime_uid" -ne 0
for service in besu-1 besu-2 besu-3 besu-4 paladin; do
  install -d -m 0700 -o kota-private-test -g kota-private-test "/var/lib/kota-private-test/$service"
  cat > "/etc/systemd/system/kota-test-${service}.service" <<EOF
[Unit]
Description=Isolated Kota ${service} compatibility test
Wants=network-online.target
After=network-online.target user@${runtime_uid}.service
Requires=user-runtime-dir@${runtime_uid}.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
User=kota-private-test
Group=kota-private-test
Environment=XDG_RUNTIME_DIR=/run/user/${runtime_uid}
ExecStart=/usr/bin/python3 /opt/kota-private-test/run-service.py ${service}
Restart=on-failure
RestartSec=5
TimeoutStopSec=45
KillMode=mixed
Delegate=yes
UMask=0077
MemoryMax=3G
CPUQuota=200%
TasksMax=2048

[Install]
WantedBy=multi-user.target
EOF
done
systemctl daemon-reload
# Starting and enabling services is a separate step after fixtures are installed.
systemd-analyze verify /etc/systemd/system/kota-test-besu-{1,2,3,4}.service /etc/systemd/system/kota-test-paladin.service
