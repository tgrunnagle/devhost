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
if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
    echo "DEVHOST_PROBE_TIMEOUT must be a whole number of seconds, not '$limit'" >&2
    exit 1
fi

# Output goes to /dev/null so a docker or ssh process left behind after the
# timeout can't hold the caller's pipe open.
docker --context "$name" version --format '{{.Server.Version}}' >/dev/null 2>&1 </dev/null &
pid=$!

# macOS has no timeout(1), so poll. SECONDS tracks wall-clock time, which a
# count of loop passes doesn't when starting sleep itself is slow.
SECONDS=0
while kill -0 "$pid" 2>/dev/null; do
    # SECONDS counts whole seconds, so ">" waits between limit and limit+1s.
    if ((SECONDS > limit)); then
        kill -KILL "$pid" 2>/dev/null
        exit 1
    fi
    sleep 0.1
done

wait "$pid" || exit 1
