#!/usr/bin/env bash
# Tests for client/devhost using fake docker/ssh/mutagen/lsof on PATH.
# Run with: tests/run.sh (or make test). Plain bash, no test framework needed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVHOST="$ROOT/client/devhost"
FAKES="$ROOT/tests/fakes"
chmod +x "$FAKES"/* "$DEVHOST"

PASS=0
FAIL=0
CURRENT=""

fail() { echo "  FAIL [$CURRENT]: $*" >&2; return 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
assert_file_has() { grep -qF -- "$2" "$1" || fail "$3: '$2' not found in $1"; }
assert_file_lacks() { ! grep -qF -- "$2" "$1" || fail "$3: '$2' unexpectedly found in $1"; }
assert_exists() { [[ -e "$1" ]] || fail "$2: $1 does not exist"; }
assert_missing() { [[ ! -e "$1" ]] || fail "$2: $1 still exists"; }

# Fresh fake state + devhost state + project dir for each test.
setup() {
    TMP="$(mktemp -d)"
    export FAKE_DIR="$TMP/fake"
    export DEVHOST_STATE_DIR="$TMP/state"
    PROJECT="$TMP/project"
    mkdir -p "$FAKE_DIR" "$PROJECT"
    touch "$FAKE_DIR/ssh.log" "$FAKE_DIR/docker.log" "$FAKE_DIR/mutagen.log"
    export PATH="$FAKES:$PATH"
    unset DEVHOST_SSH DEVHOST_NO_SYNC DEVHOST_CONTEXT FAKE_ENDPOINT
    cd "$PROJECT" || exit 1
}

teardown() {
    cd "$ROOT" || exit 1
    rm -rf "$TMP"
}

# Sources the script's functions (main is not run) with a resolved target.
load() {
    # shellcheck disable=SC1090,SC1091
    source "$DEVHOST"
    init_state
    resolve_target
}

# ---------------------------------------------------------------- unit tests

test_parse_published_ports() {
    load
    local out
    out="$(parse_published_ports <<'EOF'
6379/tcp -> 127.0.0.1:6379
80/tcp -> 0.0.0.0:49153
80/tcp -> [::]:49153
53/udp -> 0.0.0.0:5353
443/tcp -> 127.0.0.1:8443
EOF
)"
    assert_eq "$out" "$(printf '6379\n8443\n49153')" "tcp host ports, deduped, udp skipped"
    out="$(parse_published_ports <<< "")"
    assert_eq "$out" "" "no ports"
}

test_parse_ssh_endpoint() {
    load
    parse_ssh_endpoint "ssh://alice@devhost"
    assert_eq "$TARGET" "alice@devhost" "target without port"
    assert_eq "$SSH_PORT" "" "no port"
    parse_ssh_endpoint "ssh://alice@devhost.lan:2222"
    assert_eq "$TARGET" "alice@devhost.lan" "target with port"
    assert_eq "$SSH_PORT" "2222" "port"
    assert_eq "$(ssh_port_opts | tr '\n' ' ')" "-p 2222 " "port opts"
    DEVHOST_SSH="bob@10.0.0.5" resolve_target
    assert_eq "$TARGET" "bob@10.0.0.5" "DEVHOST_SSH override"
}

test_reconcile_adds_forwards() {
    load
    printf 'abc123def456 redis\n789abc012def web\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    printf '80/tcp -> 0.0.0.0:48080\n80/tcp -> [::]:48080\n' > "$FAKE_DIR/port.789abc012def"
    reconcile 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:6379:127.0.0.1:6379 alice@devhost" "redis forward"
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:48080:127.0.0.1:48080 alice@devhost" "web forward"
    assert_eq "$(grep -c '^' "$FAKE_DIR/ssh.log")" "2" "one forward per port"
    assert_file_has "$FORWARDS_FILE" "6379 abc123def456 redis" "redis recorded"
    assert_file_has "$FORWARDS_FILE" "48080 789abc012def web" "web recorded"
    assert_eq "$(cat "$CONFLICTS_FILE" 2>/dev/null)" "" "no conflicts"
}

test_reconcile_cancels_stale_forwards() {
    load
    printf '6379 deadbeef0000 oldredis\n' > "$FORWARDS_FILE"
    : > "$FAKE_DIR/ps"
    reconcile 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:6379:127.0.0.1:6379" "stale forward cancelled"
    assert_eq "$(cat "$FORWARDS_FILE")" "" "forward forgotten"
}

test_events_add_and_remove() {
    load
    echo "3000/tcp -> 127.0.0.1:3000" > "$FAKE_DIR/port.c0ffee000001"
    handle_event start c0ffee000001 api 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:3000:127.0.0.1:3000" "start adds forward"
    assert_file_has "$FORWARDS_FILE" "3000 c0ffee000001 api" "recorded"
    handle_event die c0ffee000001 api 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:3000:127.0.0.1:3000" "die cancels forward"
    assert_eq "$(cat "$FORWARDS_FILE")" "" "forward forgotten after die"
}

test_follow_events_pipeline() {
    load
    echo "80/tcp -> 127.0.0.1:48081" > "$FAKE_DIR/port.aaaa00000001"
    printf 'start aaaa00000001 nginx\ndie aaaa00000001 nginx\n' > "$FAKE_DIR/events"
    echo 0 > "$FAKE_DIR/events-hold"
    follow_events 2>/dev/null
    assert_file_has "$FAKE_DIR/docker.log" "events --filter type=container --filter event=start --filter event=die" "events filters"
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:48081:127.0.0.1:48081" "forward from event"
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:48081:127.0.0.1:48081" "cancel from event"
}

test_port_conflict_is_reported_not_moved() {
    load
    echo "6379 redis-server 4242" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    reconcile 2>/dev/null
    assert_file_lacks "$FAKE_DIR/ssh.log" "-O forward" "no forward attempted"
    assert_file_has "$CONFLICTS_FILE" "6379|abc123def456|redis|port already in use on this laptop by redis-server (pid 4242)" "conflict names port, container and holder"
    assert_eq "$(cat "$FORWARDS_FILE" 2>/dev/null)" "" "nothing recorded as forwarded"
    local out rc=0
    out="$(report_conflicts 2>&1)" || rc=$?
    assert_eq "$rc" "1" "report_conflicts returns 1"
    [[ "$out" == *"127.0.0.1:6379"*"redis"*"redis-server (pid 4242)"* ]] || fail "report mentions port, container, holder: $out"
}

test_ssh_bind_failure_is_a_conflict() {
    load
    echo 5000 > "$FAKE_DIR/ssh-fail-ports"
    echo "5000/tcp -> 127.0.0.1:5000" > "$FAKE_DIR/port.bbbb00000001"
    handle_event start bbbb00000001 registry 2>/dev/null
    assert_file_has "$CONFLICTS_FILE" "5000|bbbb00000001|registry|ssh could not bind 127.0.0.1:5000" "bind failure recorded"
    assert_eq "$(cat "$FORWARDS_FILE" 2>/dev/null)" "" "not recorded as forwarded"
}

test_forward_binds_loopback_only() {
    load
    echo "8080/tcp -> 0.0.0.0:8080" > "$FAKE_DIR/port.cccc00000001"
    handle_event start cccc00000001 web 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-L 127.0.0.1:8080:127.0.0.1:8080" "laptop side bound to 127.0.0.1"
    assert_file_lacks "$FAKE_DIR/ssh.log" "-L 8080:" "never an unbound -L"
    assert_file_lacks "$FAKE_DIR/ssh.log" "0.0.0.0:8080:" "never bound to all interfaces"
}

test_ignore_patterns() {
    load
    assert_eq "$(sync_ignore_patterns | tr '\n' ' ')" "node_modules .git .venv target dist " "defaults"
    printf '# comment\n\n  build/  # trailing comment\n*.log\n' > .devhostignore
    assert_eq "$(sync_ignore_patterns | tr '\n' ' ')" "build/ *.log " ".devhostignore overrides defaults"
}

test_sync_create_uses_same_absolute_path() {
    load
    start_sync 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "ssh-remote mkdir -p $PWD" "remote dir created"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync create --name $(sync_name) --label devhost=1 --sync-mode two-way-resolved --ignore node_modules --ignore .git --ignore .venv --ignore target --ignore dist $PWD alice@devhost:$PWD" "mutagen session"
    FAKE_ENDPOINT="alice@devhost:2222" resolve_target
    assert_eq "$(sync_beta_url)" "alice@devhost:2222:$PWD" "beta url with port"
}

test_flush_warns_on_permission_problems() {
    load
    start_sync 2>/dev/null
    echo "Problems: scan error: permission denied: /out/root-file" > "$FAKE_DIR/mutagen-status"
    local out
    out="$(flush_sync 2>&1)"
    [[ "$out" == *"root-owned files"* ]] || fail "permission warning printed: $out"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync flush $(sync_name)" "flushed"
}

# -------------------------------------------------------- end-to-end tests

run_devhost() { "$DEVHOST" "$@"; }

test_run_passes_exit_code_and_sets_context() {
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    local rc=0
    # shellcheck disable=SC2016  # expanded by the child shell on purpose
    run_devhost run -- sh -c 'echo "$DOCKER_CONTEXT" > ctx; exit 3' 2>/dev/null || rc=$?
    assert_eq "$rc" "3" "child exit code passed through"
    assert_eq "$(cat ctx)" "devhost" "DOCKER_CONTEXT set for the child"
    assert_eq "$(grep -c 'sync flush' "$FAKE_DIR/mutagen.log")" "2" "flushed before and after, even on failure"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync terminate" "sync removed"
    assert_file_has "$FAKE_DIR/ssh.log" "-M -N -f -S $DEVHOST_STATE_DIR/ssh.sock alice@devhost" "master opened"
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:6379:127.0.0.1:6379" "existing container forwarded before the command"
    assert_file_has "$FAKE_DIR/ssh.log" "-O exit alice@devhost" "master closed"
    assert_missing "$FAKE_DIR/master" "no ssh master left behind"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "no forwarder left behind"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "no mutagen session left behind"
    local status
    status="$(run_devhost status 2>/dev/null)"
    [[ "$status" == *"forwarder:  not running"* ]] || fail "status shows forwarder stopped: $status"
    [[ "$status" == *"forwards:   none"* ]] || fail "status shows no forwards: $status"
}

test_run_fails_on_startup_conflict() {
    echo "6379 redis-server 4242" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    local out rc=0
    out="$(run_devhost run -- sh -c 'echo ran > ran' 2>&1)" || rc=$?
    assert_eq "$rc" "1" "run exits 1 on conflict"
    assert_missing ran "command not run"
    [[ "$out" == *"6379"*"redis"*"redis-server (pid 4242)"* ]] || fail "conflict reported: $out"
    assert_file_lacks "$FAKE_DIR/ssh.log" "-O forward" "no forward to another port"
    assert_missing "$FAKE_DIR/master" "cleaned up"
}

test_run_fails_on_conflict_during_command() {
    : > "$FAKE_DIR/ps"
    echo "6380 redis-server 4242" > "$FAKE_DIR/busy-ports"
    echo "6379/tcp -> 127.0.0.1:6380" > "$FAKE_DIR/port.dddd00000001"
    printf 'start dddd00000001 redis\n' > "$FAKE_DIR/events"
    local out rc=0
    out="$(run_devhost run -- sleep 1 2>&1)" || rc=$?
    assert_eq "$rc" "1" "successful command still exits 1 when a port could not be mirrored"
    [[ "$out" == *"6380"*"redis-server (pid 4242)"* ]] || fail "conflict reported after the command: $out"
}

test_run_with_sync_disabled() {
    : > "$FAKE_DIR/ps"
    DEVHOST_NO_SYNC=1 run_devhost run -- true 2>/dev/null || fail "exit 0"
    assert_eq "$(cat "$FAKE_DIR/mutagen.log")" "" "mutagen never called"
}

test_up_down_lifecycle() {
    : > "$FAKE_DIR/ps"
    run_devhost up 2>/dev/null || fail "up"
    assert_exists "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder running"
    assert_exists "$FAKE_DIR/master" "master running"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "devhost-$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)" "sync session for this dir"
    local status
    status="$(run_devhost status 2>/dev/null)"
    [[ "$status" == *"forwarder:  running"* ]] || fail "status shows forwarder: $status"
    [[ "$status" == *"$PWD"* ]] || fail "status lists this dir: $status"
    # A run inside an active session reuses it and leaves it up.
    run_devhost run -- true 2>/dev/null || fail "nested run"
    assert_exists "$FAKE_DIR/master" "nested run keeps master"
    assert_file_lacks "$FAKE_DIR/mutagen.log" "sync terminate" "nested run keeps sync"
    run_devhost flush 2>/dev/null || fail "flush"
    run_devhost down 2>/dev/null || fail "down"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder stopped"
    assert_missing "$FAKE_DIR/master" "master stopped"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "sync terminated"
    run_devhost down 2>/dev/null || fail "down is idempotent"
}

test_up_in_two_dirs_shares_forwarder() {
    : > "$FAKE_DIR/ps"
    mkdir -p "$TMP/other"
    run_devhost up 2>/dev/null || fail "up 1"
    (cd "$TMP/other" && run_devhost up 2>/dev/null) || fail "up 2"
    assert_eq "$(grep -c -- '-M -N -f' "$FAKE_DIR/ssh.log")" "1" "one master for both"
    run_devhost down 2>/dev/null || fail "down 1"
    assert_exists "$FAKE_DIR/master" "master kept while another dir is up"
    (cd "$TMP/other" && run_devhost down 2>/dev/null) || fail "down 2"
    assert_missing "$FAKE_DIR/master" "master stopped after last down"
}

test_up_refuses_when_unreachable() {
    local rc=0
    touch "$FAKE_DIR/unreachable"
    run_devhost up 2>/dev/null || rc=$?
    assert_eq "$rc" "1" "up fails"
    assert_missing "$FAKE_DIR/master" "nothing started"
}

test_probe() {
    local start end rc=0
    run_devhost probe >/dev/null 2>&1 || fail "probe exits 0 when up"
    assert_file_has "$FAKE_DIR/ssh.log" "-o ConnectTimeout=3 -o ControlPath=none alice@devhost docker version" "probe uses a short timeout and no shared master"
    touch "$FAKE_DIR/ssh-down"
    start=$(date +%s)
    run_devhost probe >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "1" "probe exits 1 when down"
    end=$(date +%s)
    [[ $((end - start)) -le 5 ]] || fail "probe took $((end - start))s, expected <= 5s"
}

test_probe_deadline() {
    local rc=0
    load
    with_deadline 1 sleep 5 || rc=$?
    assert_eq "$rc" "124" "deadline kills a hung command"
}

# ------------------------------------------------------------------ runner

run_test() {
    local rc
    CURRENT="$1"
    setup
    # Not inside `if (...)`: bash disables set -e in an if condition.
    ( set -e; "$1" )
    rc=$?
    if [[ $rc -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo "  ok   $1"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL $1"
    fi
    teardown
}

main() {
    local t
    echo "devhost tests"
    for t in $(declare -F | awk '{ print $3 }' | grep '^test_' | sort); do
        run_test "$t"
    done
    echo "$PASS passed, $FAIL failed"
    [[ $FAIL -eq 0 ]]
}

main "$@"
