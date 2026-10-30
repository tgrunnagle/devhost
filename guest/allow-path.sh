#!/usr/bin/env bash
# Creates a developer's laptop path prefix on devhost, so client/devhost can
# sync a project checkout to the same absolute path on the VM.
#
# Usage (inside the VM):  sudo ./allow-path.sh <username> <absolute-path>
#
#   sudo ./allow-path.sh alice /Users/alice        # macOS laptop
#   sudo ./allow-path.sh bob   /home/bob/work      # Linux laptop
#
# Parent directories are created root-owned (0755); the final path is created
# owned by the developer. Only directories this script creates change owner: if
# the final path already exists and is root's (e.g. /home passed by mistake) or
# another developer's, the script refuses, because two developers must not
# share a directory and system directories must stay root's.
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
        if [[ "$current" == "$path" && "$owner" == root ]]; then
            echo "Refusing: $path already exists and is owned by root; not handing it to $user." >&2
            echo "Pass the developer's own prefix, e.g. /Users/<name> or /home/<name>." >&2
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

echo "==> $user can sync projects under $path"
