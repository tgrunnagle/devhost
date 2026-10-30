#!/usr/bin/env bash
# Points a dev laptop's Docker CLI at devhost over SSH (macOS / Linux).
#
# Usage:  ./add-devhost-context.sh <host> <ssh-user> [context-name]
#
# Requires the Docker CLI and an SSH key the host already trusts (see
# guest/add-dev-user.sh). The key must load without a prompt (ssh-agent or no
# passphrase), because Docker can't answer SSH prompts.
#
# Also offers to add a Host block for <host> to ~/.ssh/config, so a VM that has
# gone away fails fast instead of stalling every docker call.
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
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$user@$host" docker version --format '{{.Server.Version}}' >/dev/null; then
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

ssh_config="$HOME/.ssh/config"
begin="# BEGIN devhost-context $name"
end="# END devhost-context $name"
# Docker passes its own ConnectTimeout=30 on the ssh command line, which wins over
# this file, so ConnectTimeout here only speeds up plain ssh. The keepalives drop
# sessions to a VM that went away, and ControlMaster lets docker calls share one
# connection.
block="$begin
Host $host
  ConnectTimeout 3
  ServerAliveInterval 15
  ServerAliveCountMax 3
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
$end"

existing=""
if [[ -f "$ssh_config" ]]; then
    existing=$(awk -v b="$begin" -v e="$end" '$0 == b { on = 1 } on { print } $0 == e { on = 0 }' "$ssh_config")
fi

print_block() {
    echo
    echo "$block"
    echo
}

if [[ "$existing" == "$block" ]]; then
    echo "==> $ssh_config already has the devhost block"
elif [[ -n "$existing" ]]; then
    echo "==> $ssh_config has a devhost block that differs from this one; leaving it alone."
    echo "    The script would write:"
    print_block
elif [[ -f "$ssh_config" ]] && awk -v h="$host" 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == h) found = 1 } END { exit !found }' "$ssh_config"; then
    echo "==> $ssh_config already has a Host entry for $host; leaving it alone."
    echo "    Consider adding these settings to it:"
    print_block
else
    answer=y
    if [[ -s "$ssh_config" ]]; then
        answer=n
        if [[ -t 0 ]]; then
            read -r -p "==> Add a devhost Host block to $ssh_config? [y/N] " answer
        fi
    fi
    if [[ "$answer" == [yY]* ]]; then
        if [[ ! -d "$HOME/.ssh" ]]; then
            mkdir "$HOME/.ssh"
            chmod 700 "$HOME/.ssh"
        fi
        # Appended, not prepended: options at the top of the file apply to every host.
        [[ -s "$ssh_config" ]] && echo >>"$ssh_config"
        echo "$block" >>"$ssh_config"
        chmod 600 "$ssh_config"
        echo "==> Added the devhost block to $ssh_config"
    else
        echo "==> Not changing $ssh_config. Add this block yourself:"
        print_block
    fi
fi

echo
echo "Use it for one command:   docker --context $name ps"
echo "Or only when reachable:   ./client/devhost-probe.sh $name && export DOCKER_CONTEXT=$name"
