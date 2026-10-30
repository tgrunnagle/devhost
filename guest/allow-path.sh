#!/usr/bin/env bash
# Creates a developer's laptop path prefix on devhost, so client/devhost can
# sync a project checkout to the same absolute path on the VM.
#
# Usage (inside the VM):  sudo ./allow-path.sh <username> <absolute-path>
#
#   sudo ./allow-path.sh alice /Users/alice        # macOS laptop
#   sudo ./allow-path.sh bob   /home/bob/work      # Linux laptop
#
# Parent directories are created root-owned (0755); the final path is owned by
# the developer. If any component already exists and belongs to a different
# non-root user, the script refuses: two developers must not share a directory.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 <username> <absolute-path>" >&2
    exit 1
fi
if [[ $# -ne 2 ]]; then
    echo "Usage: sudo $0 <username> <absolute-path>" >&2
    exit 1
fi

user="$1"
path="$2"

if ! id "$user" >/dev/null 2>&1; then
    echo "No such user: $user (add them first with ./add-dev-user.sh)" >&2
    exit 1
fi
if [[ "$path" != /* || "$path" == */../* || "$path" == */.. ]]; then
    echo "Path must be absolute and must not contain '..': $path" >&2
    exit 1
fi
path="${path%/}"
if [[ -z "$path" ]]; then
    echo "Refusing to hand / to a user." >&2
    exit 1
fi

# Walks the components from the root, checking ownership of what exists.
current=""
IFS='/' read -r -a parts <<< "${path#/}"
for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    current="$current/$part"
    if [[ -e "$current" ]]; then
        if [[ ! -d "$current" ]]; then
            echo "$current exists and is not a directory." >&2
            exit 1
        fi
        owner="$(stat -c %U "$current")"
        if [[ "$owner" != root && "$owner" != "$user" ]]; then
            echo "Refusing: $current is owned by $owner, not $user." >&2
            echo "Two developers' laptop paths map to the same VM path; pick a different" >&2
            echo "checkout location on the laptop rather than sharing the directory." >&2
            exit 1
        fi
    elif [[ "$current" == "$path" ]]; then
        install -d -m 0755 -o "$user" -g "$user" "$current"
        echo "==> Created $current (owner $user)"
    else
        install -d -m 0755 -o root -g root "$current"
        echo "==> Created $current (owner root)"
    fi
done

owner="$(stat -c %U "$path")"
if [[ "$owner" != "$user" ]]; then
    chown "$user:$user" "$path"
    echo "==> $path now owned by $user"
fi
echo "==> $user can sync projects under $path"
