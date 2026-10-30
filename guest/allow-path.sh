#!/usr/bin/env bash
# Creates a developer's laptop path prefix on devhost, so client/devhost can
# sync a project checkout to the same absolute path on the VM.
#
# Usage (inside the VM):  sudo ./guest/allow-path.sh <username> <absolute-path>
#
#   sudo ./guest/allow-path.sh alice /Users/alice        # macOS laptop
#   sudo ./guest/allow-path.sh bob   /home/bob/work      # Linux laptop
#
# Parent directories are created root-owned (0755); the final path is created
# owned by the developer. Only directories this script creates change owner: if
# the final path already exists and is root's (e.g. /home passed by mistake) or
# another developer's, the script refuses, because two developers must not
# share a directory and system directories must stay root's. Symbolic links
# anywhere in the path are refused for the same reason.
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
    echo "No such user: $user (add them first with ./guest/add-dev-user.sh)" >&2
    exit 1
fi
if [[ "$path" != /* ]]; then
    echo "Path must be absolute: $path" >&2
    exit 1
fi
if [[ "$path" == *$'\n'* ]]; then
    echo "Path must not contain newlines." >&2
    exit 1
fi

# Normalise into components: repeated and trailing slashes go, '.' and '..'
# are refused, so "final component" below means the last real one.
parts=()
IFS='/' read -r -a raw <<< "$path"
for part in "${raw[@]}"; do
    [[ -n "$part" ]] || continue
    if [[ "$part" == . || "$part" == .. ]]; then
        echo "Path must not contain '.' or '..' components: $path" >&2
        exit 1
    fi
    parts+=("$part")
done
if [[ ${#parts[@]} -eq 0 ]]; then
    echo "Refusing to hand / to a user." >&2
    exit 1
fi
path="/$(IFS='/'; echo "${parts[*]}")"

# System directories stay root's, whatever is asked for.
case "${parts[0]}" in
    bin|boot|dev|etc|lib|lib32|lib64|libx32|proc|root|run|sbin|sys|usr|var)
        echo "Refusing: $path is under the system directory /${parts[0]}." >&2
        echo "Laptop checkouts live under /Users/<name> or /home/<name>; pass one of those." >&2
        exit 1
        ;;
esac

# Walks the components from the root, checking ownership of what exists.
current=""
last=$(( ${#parts[@]} - 1 ))
for i in "${!parts[@]}"; do
    current="$current/${parts[$i]}"
    if [[ -L "$current" ]]; then
        echo "Refusing: $current is a symbolic link; pass the real path." >&2
        exit 1
    fi
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
        if [[ $i -eq $last && "$owner" == root ]]; then
            echo "Refusing: $path already exists and is owned by root; not handing it to $user." >&2
            echo "Pass the developer's own prefix, e.g. /Users/<name> or /home/<name>." >&2
            exit 1
        fi
    elif [[ $i -eq $last ]]; then
        # mkdir rather than install -d: a directory that appears between the
        # check and here makes mkdir fail instead of being handed over.
        mkdir -m 0755 "$current"
        chown -h "$user:" "$current"
        echo "==> Created $current (owner $user)"
    else
        mkdir -m 0755 "$current"
        echo "==> Created $current (owner root)"
    fi
done

echo "==> $user can sync projects under $path"
