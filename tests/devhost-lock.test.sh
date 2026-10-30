#!/usr/bin/env bash
# Tests for `client/devhost lock`. Needs Linux with flock(1) (util-linux).
#
# Usage:  tests/devhost-lock.test.sh
#
# A fake `ssh` on PATH runs the remote command locally, and DEVHOST_LOCK_DIR points
# the remote side at a temporary directory, so no VM is needed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
devhost="$root/client/devhost"

work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/locks"
cat >"$work/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Fake ssh: ignore options and the destination, run the remote command locally.
for arg; do cmd="$arg"; done
exec bash -c "$cmd"
EOF
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH"
export DEVHOST_SSH="tester@devhost" DEVHOST_LOCK_DIR="$work/locks"

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; failures=$((failures + 1)); }
check() {
    local desc="$1"
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# Waits until a lock appears in `devhost lock --list`.
wait_held() {
    local _
    for _ in $(seq 50); do
        "$devhost" lock --list | grep -q "^$1 " && return 0
        sleep 0.1
    done
    return 1
}

# --- exit code passthrough --------------------------------------------------------
rc=0
"$devhost" lock pass -- sh -c 'exit 7' || rc=$?
check "passes through the command's exit code" test "$rc" -eq 7

rc=0
"$devhost" lock pass -- true || rc=$?
check "exits 0 when the command succeeds" test "$rc" -eq 0

# --- serialization ----------------------------------------------------------------
log="$work/serial.log"
"$devhost" lock e2e -- sh -c "echo start-a >>'$log'; sleep 2; echo end-a >>'$log'" &
a=$!
wait_held e2e
"$devhost" lock e2e -- sh -c "echo start-b >>'$log'; echo end-b >>'$log'" 2>"$work/b.err" &
b=$!
wait "$a" "$b"
check "second holder runs after the first finishes" \
    test "$(tr '\n' ' ' <"$log")" = "start-a end-a start-b end-b "
check "waiter reports who holds the lock" grep -q "waiting for 'e2e' (held by $(id -un)@$(hostname)" "$work/b.err"

# --- --no-wait, --timeout, --list -------------------------------------------------
"$devhost" lock e2e -- sleep 3 &
a=$!
wait_held e2e

start=$SECONDS
rc=0
"$devhost" lock e2e --no-wait -- true 2>"$work/nowait.err" || rc=$?
check "--no-wait exits 75 while the lock is held" test "$rc" -eq 75
check "--no-wait returns right away" test $((SECONDS - start)) -le 1
check "--no-wait reports the holder" grep -q "is held by $(id -un)@$(hostname)" "$work/nowait.err"

rc=0
"$devhost" lock e2e --timeout 1 -- true 2>/dev/null || rc=$?
check "--timeout exits 75 when it expires" test "$rc" -eq 75

list="$("$devhost" lock --list)"
check "--list shows the holder's user and hostname" \
    grep -Eq "^e2e +$(id -un) +$(hostname) +[0-9]{4}-[0-9]{2}-[0-9]{2}T" <<<"$list"
wait "$a"
check "--list shows nothing once the lock is released" test -z "$("$devhost" lock --list)"

# --- holder killed -----------------------------------------------------------------
"$devhost" lock e2e -- sleep 30 &
a=$!
wait_held e2e
start=$SECONDS
"$devhost" lock e2e -- true 2>/dev/null &
b=$!
sleep 1
kill -9 "$a"
rc=0
wait "$b" || rc=$?
check "killing the holder with -9 lets the waiter proceed" test "$rc" -eq 0
check "...promptly" test $((SECONDS - start)) -le 5
pkill -f 'sleep 30' 2>/dev/null || true

# --- TERM / HUP to devhost -------------------------------------------------------
for sig in TERM HUP; do
    marker="$work/term-$sig"
    "$devhost" lock e2e -- sh -c "trap 'echo got >\"$marker\"; sleep 1; exit 3' $sig; sleep 30 & wait" &
    a=$!
    wait_held e2e
    kill -"$sig" "$a"
    sleep 0.3
    rc=0
    "$devhost" lock e2e --no-wait -- true 2>/dev/null || rc=$?
    check "$sig to devhost keeps the lock until the command exits" test "$rc" -eq 75
    rc=0
    wait "$a" || rc=$?
    check "...forwards $sig to the command" test -s "$marker"
    check "...and exits with the command's code" test "$rc" -eq 3
    pkill -f 'sleep 30' 2>/dev/null || true
done

# --- connection lost while the command runs ---------------------------------------
"$devhost" lock e2e -- sleep 3 2>"$work/lost.err" &
a=$!
wait_held e2e
pkill -f 'DEVHOST_LOCK_DIR' # the fake ssh session
sleep 0.5
check "warns right away when the lock's connection is lost" grep -q "lost the connection holding lock 'e2e'" "$work/lost.err"
wait "$a" || true

# --- waiter killed -----------------------------------------------------------------
"$devhost" lock e2e -- sleep 2 &
a=$!
wait_held e2e
"$devhost" lock e2e -- true 2>/dev/null &
b=$!
sleep 0.5
kill -9 "$b"
wait "$a"
sleep 1.5
rc=0
"$devhost" lock e2e --no-wait -- true 2>/dev/null || rc=$?
check "a waiter whose client died gives up instead of taking the lock" test "$rc" -eq 0
check "...and leaves no holder record" test -z "$("$devhost" lock --list)"

# --- errors -----------------------------------------------------------------------
rc=0
"$devhost" lock 'bad/name' -- true 2>/dev/null || rc=$?
check "rejects lock names with '/'" test "$rc" -eq 1

rc=0
"$devhost" lock e2e 2>/dev/null || rc=$?
check "usage error without a command" test "$rc" -eq 2

rc=0
"$devhost" lock e2e --no-wait --timeout 3 -- true 2>/dev/null || rc=$?
check "rejects --no-wait with --timeout" test "$rc" -eq 1

rc=0
DEVHOST_LOCK_DIR="$work/missing" "$devhost" lock e2e -- true 2>"$work/missing.err" || rc=$?
check "fails when the lock directory is missing" test "$rc" -eq 1
check "...and says why" grep -q "missing or not writable" "$work/missing.err"

# What a user outside the devhost group hits. Root can write anywhere, so skip there.
if [[ $EUID -ne 0 ]]; then
    mkdir -m 0555 "$work/readonly"
    rc=0
    DEVHOST_LOCK_DIR="$work/readonly" "$devhost" lock e2e -- true 2>"$work/ro.err" || rc=$?
    check "fails when the lock directory isn't writable" test "$rc" -eq 1
    check "...and points at the devhost group" grep -q "in the devhost group" "$work/ro.err"
else
    echo "skip - unwritable lock directory (running as root)"
fi

echo
if [[ $failures -gt 0 ]]; then
    echo "$failures test(s) failed" >&2
    exit 1
fi
echo "All tests passed"
