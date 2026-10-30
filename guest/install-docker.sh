#!/usr/bin/env bash
# Installs Docker Engine on the devhost Ubuntu VM and tunes it for shared use.
#
# Usage (inside the VM):  sudo ./install-docker.sh
#
# - Installs Docker Engine, Buildx and Compose from Docker's apt repository.
# - Rotates container logs so a chatty container can't fill the disk.
# - Installs what per-user rootless Docker needs (see add-dev-user.sh): rootless extras,
#   uidmap, an AppArmor profile for rootlesskit, cgroup v2 controller delegation to user
#   services, and the iptables modules kind needs.
# - Raises sshd session limits; Docker over SSH (and Compose especially) opens many
#   sessions at once and hits the default limit of 10. Lets users set DOCKER_HOST in
#   ~/.ssh/environment so SSH sessions reach their own rootless daemon.
# - Adds the invoking user to the docker group (the shared, rootful daemon).
#
# Safe to re-run.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

. /etc/os-release
codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

echo "==> Removing conflicting distro packages (if any)"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        apt-get remove -y "$pkg"
    fi
done

echo "==> Adding Docker's apt repository for Ubuntu $VERSION_ID ($codename)"
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

if ! apt-get update; then
    echo "apt-get update failed. If the error mentions download.docker.com, Docker may not" >&2
    echo "publish packages for '$codename' yet; see https://docs.docker.com/engine/install/ubuntu/" >&2
    exit 1
fi

echo "==> Installing Docker Engine"
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    docker-ce-rootless-extras uidmap dbus-user-session slirp4netns

echo "==> Configuring log rotation"
if [[ -f /etc/docker/daemon.json ]]; then
    echo "    /etc/docker/daemon.json already exists; leaving it unchanged."
else
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
fi

systemctl enable --now docker containerd
systemctl restart docker

echo "==> Preparing for per-user rootless Docker"
# Ubuntu 24.04+ blocks unprivileged user namespaces unless an AppArmor profile allows them.
rootlesskit_profile=/etc/apparmor.d/usr.bin.rootlesskit
if [[ -d /etc/apparmor.d && ! -f "$rootlesskit_profile" ]]; then
    cat > "$rootlesskit_profile" <<'EOF'
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,

  include if exists <local/usr.bin.rootlesskit>
}
EOF
    apparmor_parser -r "$rootlesskit_profile"
fi

# Rootless containers can only limit resources (and kind can only run) if systemd
# delegates the cgroup v2 controllers to each user's service manager.
install -d /etc/systemd/system/user@.service.d
cat > /etc/systemd/system/user@.service.d/delegate.conf <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
systemctl daemon-reload

# kind's nodes need these; a rootless daemon can't load kernel modules itself.
cat > /etc/modules-load.d/devhost-kind.conf <<'EOF'
ip6_tables
ip6table_nat
ip_tables
iptable_nat
EOF
systemctl restart systemd-modules-load

echo "==> Configuring sshd for Docker over SSH"
cat > /etc/ssh/sshd_config.d/50-devhost.conf <<'EOF'
# Docker contexts over SSH open a session per API call; Compose opens many at once.
MaxSessions 64
MaxStartups 64:30:128
# add-dev-user.sh sets DOCKER_HOST in ~/.ssh/environment so `docker system dial-stdio`
# reaches the user's own rootless daemon.
PermitUserEnvironment DOCKER_HOST
EOF
sshd -t
systemctl reload ssh

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    usermod -aG docker "$SUDO_USER"
    echo "==> Added $SUDO_USER to the docker group (log out and back in to use it)"
fi

echo
docker version --format 'Docker Engine {{.Server.Version}} installed.'
echo "Next: add developers with ./add-dev-user.sh [--shared] <username> <public-key-file>"
