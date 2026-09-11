#!/usr/bin/env bash
set -euo pipefail
test "$(id -u)" = 0
. /etc/os-release
test "$ID" = ubuntu
test "$(uname -m)" = x86_64
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends podman uidmap slirp4netns fuse-overlayfs dbus-user-session
if ! id kota-private-test >/dev/null 2>&1; then
  useradd --create-home --user-group --shell /usr/sbin/nologin kota-private-test
fi
runtime_uid=$(id -u kota-private-test)
test "$runtime_uid" -ne 0
loginctl enable-linger kota-private-test
systemctl start "user@${runtime_uid}.service"
install -d -m 0700 -o kota-private-test -g kota-private-test /var/lib/kota-private-test
for path in config besu paladin evidence; do
  install -d -m 0700 -o kota-private-test -g kota-private-test "/var/lib/kota-private-test/$path"
done
install -d -m 0755 /opt/kota-private-test
runuser -u kota-private-test -- env "XDG_RUNTIME_DIR=/run/user/${runtime_uid}" podman info --format '{{.Host.Security.Rootless}}'
printf 'Runtime user ready: uid=%s\n' "$runtime_uid"
