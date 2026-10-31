#!/usr/bin/env bash
# Installs Docker Engine on the devhost Ubuntu VM and tunes it for shared use.
#
# Usage (inside the VM):  sudo ./install-docker.sh
#
# - Installs Docker Engine, Buildx and Compose from Docker's apt repository.
# - Rotates container logs so a chatty container can't fill the disk.
# - Raises sshd session limits; Docker over SSH (and Compose especially) opens many
#   sessions at once and hits the default limit of 10.
# - Adds the invoking user to the docker group.
#
# Safe to re-run.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

# shellcheck disable=SC1091
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
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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

echo "==> Raising sshd session limits for Docker over SSH"
cat > /etc/ssh/sshd_config.d/50-devhost.conf <<'EOF'
# Docker contexts over SSH open a session per API call; Compose opens many at once.
MaxSessions 64
MaxStartups 64:30:128
EOF
sshd -t
systemctl reload ssh

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    usermod -aG docker "$SUDO_USER"
    echo "==> Added $SUDO_USER to the docker group (log out and back in to use it)"
fi

echo
docker version --format 'Docker Engine {{.Server.Version}} installed.'
echo "Next: add developers with ./add-dev-user.sh <username> <public-key-file>"
