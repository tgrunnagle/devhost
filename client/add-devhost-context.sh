#!/usr/bin/env bash
# Points a dev laptop's Docker CLI at devhost over SSH (macOS / Linux).
#
# Usage:  ./add-devhost-context.sh <host> <ssh-user> [context-name]
#
# Requires the Docker CLI and an SSH key the host already trusts (see
# guest/add-dev-user.sh). The key must load without a prompt (ssh-agent or no
# passphrase), because Docker can't answer SSH prompts.
#
# ADD_SSH_CONFIG=1 adds the recommended ~/.ssh/config block without asking
# (for scripted setups; interactively the script asks).
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <host> <ssh-user> [context-name]" >&2
    exit 1
fi

host="$1"
user="$2"
name="${3:-devhost}"

echo "==> Checking SSH access to $user@$host"
# accept-new records the host key on first connect so later Docker calls don't prompt.
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$user@$host" docker version --format '{{.Server.Version}}' >/dev/null; then
    echo "Could not run docker on $user@$host over SSH. Check that your key is authorized" >&2
    echo "and that $user is in the docker group on the host." >&2
    exit 1
fi

if docker context inspect "$name" >/dev/null 2>&1; then
    echo "==> Updating existing context '$name'"
    docker context update "$name" --docker "host=ssh://$user@$host"
else
    echo "==> Creating context '$name'"
    docker context create "$name" --description "Shared LAN Docker host" --docker "host=ssh://$user@$host"
fi

# A ControlMaster block makes every docker call reuse one SSH connection, and a
# short ConnectTimeout keeps shells from hanging while the VM is saved or off.
ssh_config="$HOME/.ssh/config"
block="Host $host
    User $user
    ConnectTimeout 3
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
    ServerAliveInterval 15"

# True if the config already has a Host line naming $host (compared as a
# literal token, so dots in the hostname aren't wildcards).
has_host_block() {
    [[ -f "$ssh_config" ]] && awk -v h="$host" '
        tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == h) found = 1 }
        END { exit !found }' "$ssh_config"
}

# ssh uses the first value it finds for each option, so the block goes in
# front of any "Host *" or "Match" block, which would otherwise override it.
add_block() {
    local tmp
    mkdir -p "$HOME/.ssh"
    chmod 0700 "$HOME/.ssh"
    touch "$ssh_config"
    tmp="$(mktemp "$ssh_config.XXXXXX")"
    # The block reaches awk through the environment: macOS (BWK) awk rejects
    # a multi-line -v value.
    BLOCK="$block" awk '
        BEGIN { block = ENVIRON["BLOCK"] }
        !done && ((tolower($1) == "host" && $2 == "*") || tolower($1) == "match") {
            print block; print ""; done = 1
        }
        { print }
        END { if (!done) { if (NR > 0) print ""; print block } }' "$ssh_config" > "$tmp"
    cat "$tmp" > "$ssh_config"     # written in place: the config may be a symlink
    rm -f "$tmp"
    chmod 0600 "$ssh_config"
}

echo
if has_host_block; then
    echo "==> $ssh_config already has a block for $host; make sure it includes:"
    printf '    %s\n' "${block//$'\n'/$'\n'    }"
else
    answer=n
    if [[ "${ADD_SSH_CONFIG:-}" == 1 ]]; then
        answer=y
    elif [[ -t 0 ]]; then
        read -r -p "==> Add the recommended block for $host to $ssh_config? [y/N] " answer
    fi
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        add_block
        echo "==> Added to $ssh_config (ahead of any 'Host *' block: ssh takes the first value it finds)"
    else
        echo "==> Recommended $ssh_config block (not added):"
        printf '    %s\n' "${block//$'\n'/$'\n'    }"
        echo "    Put it before any 'Host *' block: ssh takes the first value it finds for each option."
    fi
fi

echo
echo "Use it for one command:   docker --context $name ps"
echo "Or make it the default:   docker context use $name"
echo "Run a project unmodified: client/devhost run -- <command>   (see README)"
