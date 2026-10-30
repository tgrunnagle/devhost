#!/usr/bin/env bash
# Exits 0 if devhost's Docker daemon answers within a few seconds, 1 otherwise.
# Never blocks longer than the timeout, even when SSH would hang, so shell rc
# files, direnv and agent hooks can opt into devhost only when it's reachable:
#
#   devhost-probe.sh && export DOCKER_CONTEXT=devhost
#
# Usage:  ./devhost-probe.sh [context-name]
# Set DEVHOST_PROBE_TIMEOUT to change the timeout (whole seconds, default 5).
set -uo pipefail

name="${1:-devhost}"
limit="${DEVHOST_PROBE_TIMEOUT:-5}"

# Output goes to /dev/null so a docker or ssh process left behind after the
# timeout can't hold the caller's pipe open.
docker --context "$name" version --format '{{.Server.Version}}' >/dev/null 2>&1 </dev/null &
pid=$!

# macOS has no timeout(1), so poll in 0.1s steps.
ticks=$((limit * 10))
while kill -0 "$pid" 2>/dev/null; do
    if ((ticks-- <= 0)); then
        kill -KILL "$pid" 2>/dev/null
        exit 1
    fi
    sleep 0.1
done

wait "$pid" || exit 1
