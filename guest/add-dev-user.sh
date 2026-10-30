#!/usr/bin/env bash
# Gives a developer SSH access to devhost and lets them use Docker.
#
# Usage (inside the VM):  sudo ./add-dev-user.sh <username> <public-key-file>
#
# Creates the user if needed (no password; key-only login), appends the public key to
# their authorized_keys, and adds them to the docker group.
#
# Note: membership in the docker group is equivalent to root on this VM.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 <username> <public-key-file>" >&2
    exit 1
fi
if [[ $# -ne 2 ]]; then
    echo "Usage: sudo $0 <username> <public-key-file>" >&2
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

if id "$user" >/dev/null 2>&1; then
    echo "==> User $user already exists"
else
    echo "==> Creating user $user"
    adduser --disabled-password --gecos "" "$user"
fi

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

usermod -aG docker "$user"
echo "==> $user is in the docker group"
echo
echo "On their laptop: client/add-devhost-context.sh $(hostname) $user"
echo "To let client/devhost sync checkouts, create their laptop path prefix here:"
echo "  sudo ./guest/allow-path.sh $user /Users/<laptop-username>     # macOS"
echo "  sudo ./guest/allow-path.sh $user /home/<laptop-username>      # Linux"
