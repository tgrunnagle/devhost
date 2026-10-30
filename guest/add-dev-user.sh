#!/usr/bin/env bash
# Gives a developer SSH access to devhost and their own Docker daemon.
#
# Usage (inside the VM):  sudo ./add-dev-user.sh [--shared] <username> <public-key-file>
#
# Creates the user if needed (no password; key-only login) and appends the public key to
# their authorized_keys. Then, by default, sets up rootless Docker for them: a daemon
# that runs as the user, with its own containers, volumes, networks, images and build
# cache. DOCKER_HOST in ~/.ssh/environment points their SSH sessions (and so their
# laptop's Docker context) at it.
#
# --shared  Use the VM's shared, rootful daemon instead: adds the user to the docker
#           group. Everyone in shared mode sees and can remove each other's resources,
#           and membership in the docker group is equivalent to root on this VM.
#
# Safe to re-run, including to switch a user between modes.
set -euo pipefail

usage="Usage: sudo $0 [--shared] <username> <public-key-file>"

shared=false
if [[ "${1:-}" == --shared ]]; then
    shared=true
    shift
fi
if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: $usage" >&2
    exit 1
fi
if [[ $# -ne 2 ]]; then
    echo "$usage" >&2
    exit 1
fi

user="$1"
keyfile="$2"

if [[ ! -f "$keyfile" ]]; then
    echo "Public key file not found: $keyfile" >&2
    exit 1
fi
if ! ssh-keygen -l -f "$keyfile" >/dev/null 2>&1; then
    echo "$keyfile does not look like an SSH public key." >&2
    exit 1
fi
if ! $shared && ! sshd -T 2>/dev/null | grep -qi '^permituserenvironment .*DOCKER_HOST'; then
    echo "sshd doesn't accept DOCKER_HOST from ~/.ssh/environment. Re-run install-docker.sh first." >&2
    exit 1
fi

if id "$user" >/dev/null 2>&1; then
    echo "==> User $user already exists"
else
    echo "==> Creating user $user"
    adduser --disabled-password --gecos "" "$user"
fi

uid="$(id -u "$user")"
home="$(getent passwd "$user" | cut -d: -f6)"
install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
touch "$home/.ssh/authorized_keys"

key="$(cat "$keyfile")"
if grep -qxF "$key" "$home/.ssh/authorized_keys"; then
    echo "==> Key already authorized"
else
    echo "$key" >> "$home/.ssh/authorized_keys"
    echo "==> Key added"
fi
chown "$user:$user" "$home/.ssh/authorized_keys"
chmod 0600 "$home/.ssh/authorized_keys"

# Rewrites ~/.ssh/environment without any DOCKER_HOST line, then appends $1 if given.
set_ssh_docker_host() {
    local envfile="$home/.ssh/environment"
    touch "$envfile"
    grep -v '^DOCKER_HOST=' "$envfile" > "$envfile.tmp" || true
    if [[ -n "${1:-}" ]]; then
        echo "DOCKER_HOST=$1" >> "$envfile.tmp"
    fi
    mv "$envfile.tmp" "$envfile"
    chown "$user:$user" "$envfile"
    chmod 0600 "$envfile"
}

# Gives the user subordinate UID/GID ranges (65536 IDs) if they don't have them yet.
ensure_subids() {
    local file next
    for file in /etc/subuid /etc/subgid; do
        if grep -q "^$user:" "$file"; then
            continue
        fi
        next="$(awk -F: 'BEGIN { m = 100000 } { e = $2 + $3; if (e > m) m = e } END { print m }' "$file")"
        if [[ "$file" == /etc/subuid ]]; then
            usermod --add-subuids "$next-$((next + 65535))" "$user"
        else
            usermod --add-subgids "$next-$((next + 65535))" "$user"
        fi
    done
}

# Runs a command as the user with their systemd user session in reach.
as_user() {
    (cd "$home" && runuser -u "$user" -- env -i \
        HOME="$home" USER="$user" LOGNAME="$user" PATH=/usr/local/bin:/usr/bin:/bin \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        "$@")
}

if $shared; then
    usermod -aG docker "$user"
    set_ssh_docker_host ""
    echo "==> $user uses the shared daemon (docker group)"
    if [[ -f "$home/.config/systemd/user/docker.service" ]]; then
        echo "    Their rootless daemon is still installed but no longer used over SSH."
    fi
else
    if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
        gpasswd -d "$user" docker >/dev/null
        echo "==> Removed $user from the docker group"
    fi

    echo "==> Setting up rootless Docker for $user"
    ensure_subids
    # Linger keeps the user's service manager (and so their daemon) running without a login.
    loginctl enable-linger "$user"
    systemctl start "user@$uid.service"
    for _ in $(seq 1 30); do
        [[ -S "/run/user/$uid/bus" ]] && break
        sleep 1
    done
    if [[ ! -S "/run/user/$uid/bus" ]]; then
        echo "The systemd user session for $user didn't start (no /run/user/$uid/bus)." >&2
        exit 1
    fi

    # --force: the rootful daemon is running too; that's expected here.
    as_user dockerd-rootless-setuptool.sh install --force
    as_user systemctl --user enable --now docker.service

    socket="unix:///run/user/$uid/docker.sock"
    set_ssh_docker_host "$socket"

    for _ in $(seq 1 30); do
        as_user env DOCKER_HOST="$socket" docker info >/dev/null 2>&1 && break
        sleep 1
    done
    if ! as_user env DOCKER_HOST="$socket" docker info --format '{{.SecurityOptions}}' | grep -q rootless; then
        echo "$user's rootless daemon isn't answering on $socket." >&2
        echo "Check its log: sudo journalctl _UID=$uid _SYSTEMD_USER_UNIT=docker.service" >&2
        exit 1
    fi
    echo "==> $user has their own rootless daemon at $socket"
fi

echo
echo "On their laptop: client/add-devhost-context.sh $(hostname) $user"
