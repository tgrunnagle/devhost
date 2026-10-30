#!/usr/bin/env bash
# Runs every tests/*.test.sh. Exit status is non-zero if any fails.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
rc=0
for t in tests/*.test.sh; do
    bash "$t" || rc=1
done
exit $rc
