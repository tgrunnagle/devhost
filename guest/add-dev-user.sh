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

# Everything under $home is written as the user, never as root: the user controls that
# directory, and a symlink planted there would otherwise redirect root's writes.
as_owner() {
    (cd "$home" && runuser -u "$user" -- "$@")
}

as_owner install -d -m 0700 "$home/.ssh"
as_owner touch "$home/.ssh/authorized_keys"

key="$(cat "$keyfile")"
if as_owner grep -qxF "$key" "$home/.ssh/authorized_keys"; then
    echo "==> Key already authorized"
else
    printf '%s\n' "$key" | as_owner tee -a "$home/.ssh/authorized_keys" >/dev/null
    echo "==> Key added"
fi
as_owner chmod 0600 "$home/.ssh/authorized_keys"

# Rewrites ~/.ssh/environment without any DOCKER_HOST line, then appends $1 if given.
set_ssh_docker_host() {
    # shellcheck disable=SC2016  # expanded by the inner sh, not here
    as_owner sh -c '
        f="$1"
        touch "$f"
        { grep -v "^DOCKER_HOST=" "$f" || true; [ -z "$2" ] || echo "DOCKER_HOST=$2"; } > "$f.tmp"
        mv "$f.tmp" "$f"
        chmod 0600 "$f"
    ' sh "$home/.ssh/environment" "${1:-}"
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
        # Stop it so its containers don't keep holding ports nobody can reach any more.
        if [[ -S "/run/user/$uid/bus" ]] && as_user systemctl --user disable --now docker.service; then
            echo "    Stopped their rootless daemon. Its images and volumes are kept in"
            echo "    $home/.local/share/docker; re-run without --shared to switch back."
        else
            echo "    Warning: couldn't stop their rootless daemon. As $user, run:"
            echo "    systemctl --user disable --now docker.service"
        fi
    fi
else
    if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
        gpasswd -d "$user" docker >/dev/null
        echo "==> Removed $user from the docker group"
        echo "    Containers they started on the shared daemon keep running and holding their"
        echo "    ports, but $user can no longer see them. Remove them first with"
        echo "    'sudo docker ps -a' / 'sudo docker rm -f <id>' if they're no longer wanted."
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

    # The Delegate= drop-in from install-docker.sh only applies when the user's service
    # manager starts; one already running (a logged-in or lingering user) lacks it.
    controllers="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers"
    if ! grep -qw cpuset "$controllers" 2>/dev/null; then
        echo "    Warning: cgroup controllers aren't delegated to $user's session yet, so kind"
        echo "    and container resource limits won't work. Fix: sudo systemctl restart user@$uid.service"
        echo "    (stops $user's running containers), or reboot the VM."
    fi

    # Rootless daemons don't read /etc/docker/daemon.json; give each the same log rotation.
    config_dir="$home/.config/docker"
    restart_daemon=false
    if ! as_owner test -e "$config_dir/daemon.json"; then
        as_owner mkdir -p "$config_dir"
        as_owner tee "$config_dir/daemon.json" >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
        restart_daemon=true
    fi

    # --force: the rootful daemon is running too; that's expected here.
    as_user dockerd-rootless-setuptool.sh install --force
    as_user systemctl --user enable --now docker.service
    if $restart_daemon; then
        as_user systemctl --user restart docker.service
    fi

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
