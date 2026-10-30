#!/usr/bin/env bash
# Points a dev laptop's Docker CLI at devhost over SSH (macOS / Linux).
#
# Usage:  ./add-devhost-context.sh <host> <ssh-user> [context-name]
#
# Requires the Docker CLI and an SSH key the host already trusts (see
# guest/add-dev-user.sh). The key must load without a prompt (ssh-agent or no
# passphrase), because Docker can't answer SSH prompts.
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
    echo "and that $user was set up with guest/add-dev-user.sh on the host." >&2
    exit 1
fi

if docker context inspect "$name" >/dev/null 2>&1; then
    echo "==> Updating existing context '$name'"
    docker context update "$name" --docker "host=ssh://$user@$host"
else
    echo "==> Creating context '$name'"
    docker context create "$name" --description "Shared LAN Docker host" --docker "host=ssh://$user@$host"
fi

echo
echo "Use it for one command:   docker --context $name ps"
echo "Or make it the default:   docker context use $name"
