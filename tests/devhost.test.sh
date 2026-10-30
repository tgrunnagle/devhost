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

# Polls (up to $1 seconds) until the command succeeds; fails otherwise.
# Timing-sensitive tests wait for a condition rather than sleeping.
wait_for() {
    local secs="$1" what="$2" ticks=0
    shift 2
    until "$@"; do
        [[ $ticks -lt $((secs * 10)) ]] || fail "timed out after ${secs}s waiting for $what"
        sleep 0.1
        ticks=$((ticks + 1))
    done
}

# Fresh fake state + devhost state + project dir for each test. The physical
# path: devhost resolves symlinks (macOS /var/folders -> /private/var/...),
# and tests that hash $PWD themselves must see the same path.
setup() {
    TMP="$(cd "$(mktemp -d)" && pwd -P)"
    export FAKE_DIR="$TMP/fake"
    export DEVHOST_STATE_DIR="$TMP/state"
    PROJECT="$TMP/project"
    mkdir -p "$FAKE_DIR" "$PROJECT"
    touch "$FAKE_DIR/ssh.log" "$FAKE_DIR/docker.log" "$FAKE_DIR/mutagen.log"
    export PATH="$FAKES:$PATH"
    # No real sockets: the laptop's own listeners must not leak into the tests.
    export DEVHOST_PORT_PROBE=false
    unset DEVHOST_SSH DEVHOST_NO_SYNC DEVHOST_CONTEXT DEVHOST_CONFLICTS FAKE_ENDPOINT
    cd "$PROJECT" || exit 1
}

# Kills a forwarder a failed test left behind (its whole process group).
# Only a real pid: unit tests put a token in the pid file, never a pid.
kill_leftover_forwarder() {
    local pid
    pid="$(cat "$DEVHOST_STATE_DIR/forwarder.pid" 2>/dev/null)" || return 0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
}

teardown() {
    kill_leftover_forwarder
    cd "$ROOT" || exit 1
    rm -rf "$TMP"
}

# The Mutagen label devhost puts on this state directory's sessions.
state_label() { echo "devhost-state=$(printf '%s' "$DEVHOST_STATE_DIR" | cksum | cut -d' ' -f1)"; }

# Sources the script's functions (main is not run) with a resolved target,
# under the shell options main sets, so pipelines fail as they would in use.
load() {
    set -o pipefail
    # shellcheck disable=SC1090,SC1091
    source "$DEVHOST"
    init_state
    resolve_target
}

# Lets follow_events run in the harness: the loop keeps going while the pid
# file names "us"; the token is removed afterwards so nothing is signalled.
own_forwarder_pid_file() {
    FORWARDER_PID=harness-forwarder
    echo "$FORWARDER_PID" > "$FWD_PID_FILE"
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
8080/tcp -> 192.168.1.5:8080
EOF
)"
    assert_eq "$out" "$(printf '6379 127.0.0.1\n8080 192.168.1.5\n8443 127.0.0.1\n49153 127.0.0.1')" \
        "tcp host ports with the VM-side address, deduped, udp skipped"
    out="$(parse_published_ports <<'EOF'
8080/tcp -> [::1]:8080
9090/tcp -> [::]:9090
7070/tcp -> [::1]:7070
7070/tcp -> 127.0.0.1:7070
EOF
)"
    assert_eq "$out" "$(printf '7070 127.0.0.1\n8080 ::1\n9090 ::1')" \
        "IPv6-only loopback/wildcard bindings are reached at ::1, dual-stack at 127.0.0.1"
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
    echo 4242 > "$FAKE_DIR/master"
    printf 'abc123def456 redis\n789abc012def web\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    printf '80/tcp -> 0.0.0.0:48080\n80/tcp -> [::]:48080\n' > "$FAKE_DIR/port.789abc012def"
    reconcile 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:6379:127.0.0.1:6379 alice@devhost" "redis forward"
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:48080:127.0.0.1:48080 alice@devhost" "web forward"
    assert_eq "$(grep -c -- '-O forward' "$FAKE_DIR/ssh.log")" "2" "one forward per port"
    assert_file_has "$FAKE_DIR/ssh.log" "ssh-remote docker ps --no-trunc --format" "containers listed through the master"
    assert_file_has "$FAKE_DIR/ssh.log" "ssh-remote docker port abc123def456" "ports asked through the master"
    assert_file_has "$FORWARDS_FILE" "6379 127.0.0.1 abc123def456 redis" "redis recorded"
    assert_file_has "$FORWARDS_FILE" "48080 127.0.0.1 789abc012def web" "web recorded"
    assert_eq "$(cat "$CONFLICTS_FILE" 2>/dev/null)" "" "no conflicts"
}

test_reconcile_cancels_stale_forwards() {
    load
    echo 4242 > "$FAKE_DIR/master"
    echo 4242 > "$MASTER_PID_FILE"
    printf '6379 127.0.0.1 deadbeef0000 oldredis\n' > "$FORWARDS_FILE"
    echo "127.0.0.1:6379:127.0.0.1:6379" > "$FAKE_DIR/open-forwards"
    : > "$FAKE_DIR/ps"
    reconcile 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:6379:127.0.0.1:6379" "stale forward cancelled"
    assert_eq "$(cat "$FORWARDS_FILE")" "" "forward forgotten"
}

test_reconcile_forgets_forwards_of_a_dead_master() {
    load
    echo 4242 > "$MASTER_PID_FILE"              # forwards were opened on master 4242 ...
    echo 5151 > "$FAKE_DIR/master"              # ... but a new master answers now
    printf '6379 127.0.0.1 abc123def456 redis\n' > "$FORWARDS_FILE"
    printf '6380|abc123def456|redis|port already in use\n' > "$CONFLICTS_FILE"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    reconcile 2>/dev/null
    assert_file_lacks "$FAKE_DIR/ssh.log" "-O cancel" "nothing to cancel: the old forwards died with their master"
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:6379:127.0.0.1:6379" "forward opened again on the new master"
    assert_eq "$(cat "$MASTER_PID_FILE")" "5151" "new master remembered"
    assert_eq "$(cat "$CONFLICTS_FILE")" "" "old conflicts dropped and re-evaluated"
}

test_events_add_and_remove() {
    load
    echo 4242 > "$FAKE_DIR/master"
    echo "3000/tcp -> 127.0.0.1:3000" > "$FAKE_DIR/port.c0ffee000001"
    handle_event start c0ffee000001 api 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:3000:127.0.0.1:3000" "start adds forward"
    assert_file_has "$FORWARDS_FILE" "3000 127.0.0.1 c0ffee000001 api" "recorded"
    handle_event die c0ffee000001 api 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:3000:127.0.0.1:3000" "die cancels forward"
    assert_eq "$(cat "$FORWARDS_FILE")" "" "forward forgotten after die"
}

test_follow_events_pipeline() {
    load
    echo 4242 > "$FAKE_DIR/master"
    echo "80/tcp -> 127.0.0.1:48081" > "$FAKE_DIR/port.aaaa00000001"
    printf 'start aaaa00000001 nginx\ndie aaaa00000001 nginx\n' > "$FAKE_DIR/events"
    echo 0 > "$FAKE_DIR/events-hold"
    own_forwarder_pid_file
    follow_events "$(date +%s)" 2>/dev/null
    rm -f "$FWD_PID_FILE"
    assert_file_has "$FAKE_DIR/docker.log" "--filter type=container --filter event=start --filter event=die" "events filters"
    assert_file_has "$FAKE_DIR/ssh.log" "ssh-remote docker events" "events streamed through the master"
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:48081:127.0.0.1:48081" "forward from event"
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:48081:127.0.0.1:48081" "cancel from event"
}

test_port_conflict_is_reported_not_moved() {
    load
    echo 4242 > "$FAKE_DIR/master"
    echo "6379 redis-server 9999" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    reconcile 2>/dev/null
    assert_file_lacks "$FAKE_DIR/ssh.log" "-O forward" "no forward attempted"
    assert_file_has "$CONFLICTS_FILE" "6379|abc123def456|redis|port already in use on this laptop by redis-server (pid 9999)" "conflict names port, container and holder"
    assert_eq "$(cat "$FORWARDS_FILE" 2>/dev/null)" "" "nothing recorded as forwarded"
    local out rc=0
    out="$(report_conflicts 2>&1)" || rc=$?
    assert_eq "$rc" "1" "report_conflicts returns 1"
    [[ "$out" == *"127.0.0.1:6379"*"redis"*"redis-server (pid 9999)"* ]] || fail "report mentions port, container, holder: $out"
}

test_ssh_bind_failure_is_a_conflict() {
    load
    echo 4242 > "$FAKE_DIR/master"
    echo 5000 > "$FAKE_DIR/ssh-fail-ports"
    echo "5000/tcp -> 127.0.0.1:5000" > "$FAKE_DIR/port.bbbb00000001"
    handle_event start bbbb00000001 registry 2>/dev/null
    assert_file_has "$CONFLICTS_FILE" "5000|bbbb00000001|registry|ssh could not bind 127.0.0.1:5000" "bind failure recorded"
    assert_eq "$(cat "$FORWARDS_FILE" 2>/dev/null)" "" "not recorded as forwarded"
}

test_forward_binds_loopback_only() {
    load
    echo 4242 > "$FAKE_DIR/master"
    echo "8080/tcp -> 0.0.0.0:8080" > "$FAKE_DIR/port.cccc00000001"
    handle_event start cccc00000001 web 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-L 127.0.0.1:8080:127.0.0.1:8080" "laptop side bound to 127.0.0.1"
    assert_file_lacks "$FAKE_DIR/ssh.log" "-L 8080:" "never an unbound -L"
    assert_file_lacks "$FAKE_DIR/ssh.log" "0.0.0.0:8080:" "never bound to all interfaces"
    echo "80/tcp -> 192.168.1.5:8081" > "$FAKE_DIR/port.cccc00000002"
    handle_event start cccc00000002 lanonly 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-L 127.0.0.1:8081:192.168.1.5:8081" "a port on a specific VM interface is reached there"
    handle_event die cccc00000002 lanonly 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:8081:192.168.1.5:8081" "cancelled with the same spec"
    assert_eq "$(cat "$FAKE_DIR/open-forwards")" "127.0.0.1:8080:127.0.0.1:8080" "only the live forward stays open in the master"
    echo "80/tcp -> [fe80::1]:8082" > "$FAKE_DIR/port.cccc00000003"
    handle_event start cccc00000003 v6 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-L 127.0.0.1:8082:[fe80::1]:8082" "IPv6 connect host is bracketed"
    echo "80/tcp -> [::1]:8083" > "$FAKE_DIR/port.cccc00000004"
    handle_event start cccc00000004 v6lo 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-L 127.0.0.1:8083:[::1]:8083" "IPv6 loopback binding is reached at ::1, not 127.0.0.1"
}

test_events_replayed_since_reconcile() {
    load
    echo 4242 > "$FAKE_DIR/master"
    own_forwarder_pid_file
    echo 0 > "$FAKE_DIR/events-hold"
    follow_events 1700000000 2>/dev/null
    rm -f "$FWD_PID_FILE"
    assert_file_has "$FAKE_DIR/docker.log" "events --since 1700000000 --filter" "events replayed from the reconcile time"
}

test_conflict_retried_once_port_is_free() {
    echo "6379 redis-server 9999" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    run_devhost up 2>/dev/null || fail "up"
    assert_eq "$(grep -c '^' "$DEVHOST_STATE_DIR/conflicts")" "1" "conflict at up"
    local rc=0
    run_devhost flush >/dev/null 2>&1 || rc=$?
    assert_eq "$rc" "1" "flush fails while the port is busy"
    rm -f "$FAKE_DIR/busy-ports"                      # the local redis went away
    run_devhost run -- sh -c 'echo ran > ran' 2>/dev/null || fail "run succeeds once the port is free"
    assert_exists ran "command ran"
    assert_file_has "$FAKE_DIR/ssh.log" "-O forward -L 127.0.0.1:6379:127.0.0.1:6379" "forward established on retry"
    assert_eq "$(cat "$DEVHOST_STATE_DIR/conflicts")" "" "conflict cleared"
    run_devhost down 2>/dev/null || fail "down"
}

test_stale_locks_are_reclaimed() {
    : > "$FAKE_DIR/ps"
    local dead
    ( : ) &
    dead=$!
    wait "$dead"                                       # a pid that is certainly not alive
    mkdir -p "$DEVHOST_STATE_DIR/lock"
    echo "$dead" > "$DEVHOST_STATE_DIR/lock/pid"       # holder is long dead
    run_devhost up 2>/dev/null || fail "up past a dead holder's lock"
    run_devhost down 2>/dev/null || fail "down"
    mkdir -p "$DEVHOST_STATE_DIR/lock"                 # no pid file, old mtime
    touch -t 202001010000 "$DEVHOST_STATE_DIR/lock"
    run_devhost up 2>/dev/null || fail "up past an old pid-less lock"
    run_devhost down 2>/dev/null || fail "down"
    assert_missing "$DEVHOST_STATE_DIR/lock" "lock released"
}

test_lock_serialises_concurrent_ups() {
    : > "$FAKE_DIR/ps"
    mkdir -p "$TMP/other"
    local p1 p2
    run_devhost up 2>/dev/null &
    p1=$!
    (cd "$TMP/other" && run_devhost up 2>/dev/null) &
    p2=$!
    wait "$p1" || fail "up 1"
    wait "$p2" || fail "up 2"
    assert_eq "$(grep -c -- '-M -N -f' "$FAKE_DIR/ssh.log")" "1" "exactly one master for two simultaneous ups"
    assert_eq "$(find "$DEVHOST_STATE_DIR/sessions" -maxdepth 1 -type f | wc -l | tr -d ' ')" "2" "both directories registered"
    run_devhost down 2>/dev/null || fail "down 1"
    (cd "$TMP/other" && run_devhost down 2>/dev/null) || fail "down 2"
    assert_missing "$FAKE_DIR/master" "all stopped"
}

test_conflicts_are_cleared_and_deduped() {
    load
    echo 4242 > "$FAKE_DIR/master"
    echo "6379 redis-server 9999" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    reconcile 2>/dev/null
    reconcile 2>/dev/null
    handle_event start abc123def456 redis 2>/dev/null
    assert_eq "$(grep -c '^' "$CONFLICTS_FILE")" "1" "one line per port+container"
    handle_event die abc123def456 redis 2>/dev/null
    assert_eq "$(cat "$CONFLICTS_FILE")" "" "die clears the conflict"
    reconcile 2>/dev/null
    : > "$FAKE_DIR/ps"
    reconcile 2>/dev/null
    assert_eq "$(cat "$CONFLICTS_FILE")" "" "reconcile drops conflicts of containers no longer running"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    reconcile 2>/dev/null
    assert_eq "$(grep -c '^' "$CONFLICTS_FILE")" "1" "conflict back while the port is busy"
    rm -f "$FAKE_DIR/busy-ports"
    reconcile 2>/dev/null
    assert_eq "$(cat "$CONFLICTS_FILE")" "" "forwarded once the port is free, conflict cleared"
    assert_file_has "$FORWARDS_FILE" "6379 127.0.0.1 abc123def456 redis" "forward recorded"
}

test_nested_run_warns_about_preexisting_conflict() {
    # A real, persisting conflict on a container that was running before the
    # run (on a shared daemon, often somebody else's): reported, not fatal.
    echo "6379 redis-server 9999" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    run_devhost up 2>/dev/null || fail "up"
    local out rc=0
    out="$(run_devhost run -- sh -c 'echo ran > ran' 2>&1)" || rc=$?
    assert_eq "$rc" "0" "nested run continues past a pre-existing conflict"
    assert_exists ran "command ran"
    [[ "$out" == *"warning"*"127.0.0.1:6379"*"redis-server (pid 9999)"* ]] || fail "nested run warns and says why: $out"
    rm -f ran
    rc=0
    out="$(DEVHOST_CONFLICTS=fail run_devhost run -- sh -c 'echo ran > ran' 2>&1)" || rc=$?
    assert_eq "$rc" "1" "DEVHOST_CONFLICTS=fail refuses"
    assert_missing ran "command not run under fail"
    run_devhost down 2>/dev/null || fail "down"
}

test_concurrent_runs_share_one_session() {
    : > "$FAKE_DIR/ps"
    local rc1=0 rc2=0 pid1
    # shellcheck disable=SC2016  # expanded by the child shell on purpose
    run_devhost run -- sh -c 'touch "$FAKE_DIR/run1-started"; while [ ! -e "$FAKE_DIR/run1-go" ]; do sleep 0.1; done' 2>/dev/null &
    pid1=$!
    wait_for 30 "the first run's command to start" test -e "$FAKE_DIR/run1-started"
    run_devhost run -- true 2>/dev/null || rc2=$?
    assert_eq "$rc2" "0" "second run exits 0"
    assert_exists "$FAKE_DIR/master" "master survives the second run finishing first"
    assert_exists "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder survives"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "devhost-$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)" "sync survives"
    touch "$FAKE_DIR/run1-go"
    wait "$pid1" || rc1=$?
    assert_eq "$rc1" "0" "first run exits 0"
    assert_missing "$FAKE_DIR/master" "last run out tears down"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder stopped"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync terminate" "sync terminated by the last run"
    assert_eq "$(grep -c -- '-M -N -f' "$FAKE_DIR/ssh.log")" "1" "only one master was ever opened"
}

test_up_during_run_keeps_session_after_run() {
    : > "$FAKE_DIR/ps"
    local pid1
    # shellcheck disable=SC2016
    run_devhost run -- sh -c 'touch "$FAKE_DIR/run1-started"; while [ ! -e "$FAKE_DIR/run1-go" ]; do sleep 0.1; done' 2>/dev/null &
    pid1=$!
    wait_for 30 "the run's command to start" test -e "$FAKE_DIR/run1-started"
    run_devhost up 2>/dev/null || fail "up while a run is active"
    touch "$FAKE_DIR/run1-go"
    wait "$pid1" || fail "run"
    assert_exists "$FAKE_DIR/master" "explicit up outlives the run that started the session"
    run_devhost down 2>/dev/null || fail "down"
    assert_missing "$FAKE_DIR/master" "down stops it"
}

test_stale_run_session_elsewhere_does_not_keep_forwarder() {
    : > "$FAKE_DIR/ps"
    mkdir -p "$DEVHOST_STATE_DIR/sessions"
    printf '%s\nrun\n' "$TMP/crashed" > "$DEVHOST_STATE_DIR/sessions/123456"   # crashed run, no live pids
    run_devhost run -- true 2>/dev/null || fail "run"
    assert_missing "$FAKE_DIR/master" "stale run session elsewhere was pruned"
    assert_missing "$DEVHOST_STATE_DIR/sessions/123456" "stale file removed"
}

test_down_terminates_sync_without_session_file() {
    load
    start_sync 2>/dev/null
    run_devhost down 2>/dev/null || fail "down"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync terminate $(sync_name)" "sync terminated even though no session file existed"
}

test_forwarder_failing_at_start_tears_down() {
    : > "$FAKE_DIR/ps"
    touch "$FAKE_DIR/ps-fail"
    local out rc=0
    out="$(run_devhost up 2>&1)" || rc=$?
    assert_eq "$rc" "1" "up fails"
    [[ "$out" == *"forwarder failed to start"* ]] || fail "reason given: $out"
    assert_missing "$FAKE_DIR/master" "master torn down"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "no pid file"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.ready" "no ready file"
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
    assert_file_has "$FAKE_DIR/mutagen.log" "sync create --name $(sync_name) --label devhost=1 --label $(state_label) --sync-mode two-way-resolved --ignore node_modules --ignore .git --ignore .venv --ignore target --ignore dist $PWD alice@devhost:$PWD" "mutagen session"
    FAKE_ENDPOINT="alice@devhost:2222" resolve_target
    assert_eq "$(sync_beta_url)" "alice@devhost:2222:$PWD" "beta url with port"
}

test_allow_path_hint() {
    load
    local home="$TMP/home"
    mkdir -p "$home/src/proj" "$TMP/elsewhere/proj"
    cd "$home/src/proj" || exit 1
    assert_eq "$(HOME="$home" allow_path_hint)" "sudo ./guest/allow-path.sh alice $home" "checkout under HOME: the home itself"
    cd "$home" || exit 1
    assert_eq "$(HOME="$home" allow_path_hint)" "sudo ./guest/allow-path.sh alice $home" "checkout is HOME: the home itself"
    cd "$TMP/elsewhere/proj" || exit 1
    assert_eq "$(HOME="$home" allow_path_hint)" "sudo ./guest/allow-path.sh alice $TMP/elsewhere/proj" "checkout outside HOME: the checkout"
    DEVHOST_SSH="devhost.lan" resolve_target
    assert_eq "$(HOME="$home" allow_path_hint)" "sudo ./guest/allow-path.sh alice $TMP/elsewhere/proj" "user comes from ssh -G, not the target"
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

# Starts devhost in the background as a direct child, so $! is devhost itself
# (not a wrapper subshell) and signals sent to $! reach it.
start_devhost() { "$DEVHOST" "$@" 2>/dev/null & }

test_run_passes_exit_code_and_sets_context() {
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    local rc=0
    # shellcheck disable=SC2016  # expanded by the child shell on purpose
    run_devhost run -- sh -c 'echo "$DOCKER_CONTEXT" > ctx; exit 3' 2>"$TMP/stderr" || rc=$?
    assert_eq "$rc" "3" "child exit code passed through"
    assert_eq "$(cat ctx)" "devhost" "DOCKER_CONTEXT set for the child"
    local name
    name="devhost-$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
    assert_eq "$(grep -c -- "sync flush $name\$" "$FAKE_DIR/mutagen.log")" "3" "flushed at creation, before and after, even on failure"
    assert_file_lacks "$TMP/stderr" "warning:" "no warnings on the happy path"
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

test_run_keeps_stdin() {
    : > "$FAKE_DIR/ps"
    local out
    out="$(echo hello-from-stdin | run_devhost run -- cat 2>/dev/null)" || fail "run"
    assert_eq "$out" "hello-from-stdin" "the command reads devhost's stdin"
}

test_run_reports_preexisting_conflict() {
    echo "6379 redis-server 9999" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    local out rc=0
    out="$(run_devhost run -- sh -c 'echo ran > ran' 2>&1)" || rc=$?
    assert_eq "$rc" "0" "a conflict on a container that was already running is a warning by default"
    assert_exists ran "command ran"
    [[ "$out" == *"warning"*"6379"*"redis"*"redis-server (pid 9999)"* ]] || fail "conflict reported: $out"
    [[ "$out" == *"DEVHOST_CONFLICTS=fail"* ]] || fail "tells how to make it fatal: $out"
    assert_file_lacks "$FAKE_DIR/ssh.log" "-O forward" "no forward to another port"
    assert_missing "$FAKE_DIR/master" "cleaned up"
    rm -f ran
    rc=0
    out="$(DEVHOST_CONFLICTS=fail run_devhost run -- sh -c 'echo ran > ran' 2>&1)" || rc=$?
    assert_eq "$rc" "1" "run exits 1 on conflict with DEVHOST_CONFLICTS=fail"
    assert_missing ran "command not run"
    [[ "$out" == *"6379"*"redis"*"redis-server (pid 9999)"* ]] || fail "conflict reported: $out"
    assert_missing "$FAKE_DIR/master" "cleaned up"
}

# The command (via $FAKE_DIR/go) lets the container start, then waits until
# the forwarder has recorded the conflict, so the test doesn't depend on
# timing.
conflict_during_command() {
    # shellcheck disable=SC2016  # expanded by the child shell on purpose
    run_devhost run -- sh -c 'touch "$FAKE_DIR/go"; i=0; while [ ! -s "$DEVHOST_STATE_DIR/conflicts" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done' 2>&1
}

test_run_fails_on_conflict_during_command() {
    : > "$FAKE_DIR/ps"
    echo "6380 redis-server 9999" > "$FAKE_DIR/busy-ports"
    echo "6379/tcp -> 127.0.0.1:6380" > "$FAKE_DIR/port.dddd00000001"
    printf 'start dddd00000001 redis\n' > "$FAKE_DIR/events"
    echo "$FAKE_DIR/go" > "$FAKE_DIR/events-wait-for"   # the container starts once the command says so
    local out rc=0
    out="$(conflict_during_command)" || rc=$?
    assert_eq "$rc" "1" "successful command still exits 1 when a port it published could not be mirrored"
    [[ "$out" == *"while the command ran"*"6380"*"redis-server (pid 9999)"* ]] || fail "conflict reported after the command: $out"
    assert_missing "$FAKE_DIR/master" "cleaned up"
    rm -f "$FAKE_DIR/go"
    rc=0
    out="$(DEVHOST_CONFLICTS=warn conflict_during_command)" || rc=$?
    assert_eq "$rc" "0" "DEVHOST_CONFLICTS=warn never fails the run"
    [[ "$out" == *"warning"*"6380"* ]] || fail "still reported under warn: $out"
}

test_stale_session_is_restarted() {
    : > "$FAKE_DIR/ps"
    local id
    id="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
    mkdir -p "$DEVHOST_STATE_DIR/sessions"
    echo "$PWD" > "$DEVHOST_STATE_DIR/sessions/$id"     # left behind by a crash
    run_devhost run -- true 2>/dev/null || fail "run"
    assert_file_has "$FAKE_DIR/ssh.log" "-M -N -f" "master opened despite stale session file"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync create" "sync created despite stale session file"
    assert_missing "$DEVHOST_STATE_DIR/sessions/$id" "session cleaned up afterwards"
}

test_stale_up_session_restarts_as_up() {
    : > "$FAKE_DIR/ps"
    run_devhost up 2>/dev/null || fail "up"
    rm -f "$FAKE_DIR/master" "$FAKE_DIR/open-forwards"   # the master died (laptop slept)
    run_devhost run -- true 2>/dev/null || fail "run restarts the stale session"
    assert_exists "$FAKE_DIR/master" "the directory is still up after the run: it was brought up explicitly"
    local status
    status="$(run_devhost status 2>/dev/null)"
    [[ "$status" == *"$PWD (up)"* ]] || fail "status shows the session as up: $status"
    run_devhost down 2>/dev/null || fail "down"
    assert_missing "$FAKE_DIR/master" "down stops it"
}

test_forwards_readded_after_master_restart() {
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    run_devhost up 2>/dev/null || fail "up"
    assert_eq "$(grep -c -- '-O forward -L 127.0.0.1:6379:' "$FAKE_DIR/ssh.log")" "1" "forwarded once"
    rm -f "$FAKE_DIR/master" "$FAKE_DIR/open-forwards"   # the master died, and its forwards with it
    # The next command opens a new master; the forwarder must open the
    # forwards again on it rather than trust its state file.
    run_devhost run -- true 2>/dev/null || fail "run"
    assert_exists "$FAKE_DIR/master" "new master"
    [[ "$(grep -c -- '-O forward -L 127.0.0.1:6379:' "$FAKE_DIR/ssh.log")" -ge 2 ]] ||
        fail "forward opened again on the new master; forwarder log:
$(cat "$DEVHOST_STATE_DIR/forwarder.log")"
    assert_eq "$(cat "$FAKE_DIR/open-forwards")" "127.0.0.1:6379:127.0.0.1:6379" "forward open in the new master"
    assert_file_has "$DEVHOST_STATE_DIR/forwards" "6379 127.0.0.1 abc123def456 redis" "status still lists it"
    run_devhost down 2>/dev/null || fail "down"
}

test_forwarder_reopens_forwards_when_master_dies() {
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    run_devhost up 2>/dev/null || fail "up"
    rm -f "$FAKE_DIR/master" "$FAKE_DIR/open-forwards"   # the master died while nothing else ran
    # The forwarder's watchdog notices within a few seconds, opens a new
    # master and reconciles onto it.
    wait_for 30 "the forwarder to open a new master" test -e "$FAKE_DIR/master"
    wait_for 30 "the forward to be re-opened" grep -qsF "127.0.0.1:6379:127.0.0.1:6379" "$FAKE_DIR/open-forwards"
    run_devhost down 2>/dev/null || fail "down"
    assert_missing "$FAKE_DIR/master" "down stops the new master too"
}

test_interrupted_startup_leaves_nothing() {
    : > "$FAKE_DIR/ps"
    touch "$FAKE_DIR/mutagen-create-hang"              # a slow first sync create
    local pid rc=0
    start_devhost run -- true
    pid=$!
    wait_for 30 "startup to reach the sync create" grep -q 'sync create' "$FAKE_DIR/mutagen.log"
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    assert_eq "$rc" "143" "run exits on the signal"
    assert_missing "$FAKE_DIR/master" "master torn down"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder torn down"
    assert_eq "$(ls "$DEVHOST_STATE_DIR/sessions")" "" "no session registered"
}

test_run_passes_term_to_command() {
    : > "$FAKE_DIR/ps"
    local pid rc=0
    # shellcheck disable=SC2016
    start_devhost run -- sh -c 'trap "echo term > \"$FAKE_DIR/child-got-term\"; exit 7" TERM; touch "$FAKE_DIR/child-started"; while :; do sleep 0.1; done'
    pid=$!
    wait_for 30 "the command to start" test -e "$FAKE_DIR/child-started"
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    assert_exists "$FAKE_DIR/child-got-term" "TERM passed on to the command"
    assert_eq "$rc" "7" "exit code is the command's"
    assert_missing "$FAKE_DIR/master" "torn down after the signal"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder stopped"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "sync terminated"
}

test_start_forwarder_cancels_forwards_left_behind() {
    : > "$FAKE_DIR/ps"
    mkdir -p "$DEVHOST_STATE_DIR"
    echo "6379 127.0.0.1 deadbeefdead oldredis" > "$DEVHOST_STATE_DIR/forwards"  # forwarder died, master kept it
    echo 4242 > "$FAKE_DIR/master"
    echo "127.0.0.1:6379:127.0.0.1:6379" > "$FAKE_DIR/open-forwards"
    run_devhost up 2>/dev/null || fail "up"
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:6379:127.0.0.1:6379" "leftover forward cancelled"
    assert_eq "$(cat "$FAKE_DIR/open-forwards")" "" "nothing left open in the master"
    assert_eq "$(cat "$DEVHOST_STATE_DIR/conflicts")" "" "no conflicts from leftovers"
    run_devhost down 2>/dev/null || fail "down"
}

test_master_owned_listener_is_not_a_conflict() {
    load
    echo 4242 > "$FAKE_DIR/master"                 # fake -O check reports this pid
    echo "6379 ssh 4242" > "$FAKE_DIR/busy-ports"  # the master already holds the port
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    reconcile 2>/dev/null
    assert_eq "$(cat "$CONFLICTS_FILE" 2>/dev/null)" "" "no conflict"
    assert_file_has "$FORWARDS_FILE" "6379 127.0.0.1 abc123def456 redis" "adopted as a forward"
}

test_forwarder_reconnects_when_stream_ends() {
    : > "$FAKE_DIR/ps"
    echo "80/tcp -> 127.0.0.1:48082" > "$FAKE_DIR/port.eeee00000001"
    printf 'start eeee00000001 nginx\n' > "$FAKE_DIR/events"
    echo 0 > "$FAKE_DIR/events-hold"               # stream ends right after the event
    run_devhost up 2>/dev/null || fail "up"
    # Reconnect backs off 2s, then reconciles (ps is empty, so the forward goes)
    # and re-follows (the start event adds it again).
    # shellcheck disable=SC2329,SC2317  # invoked through wait_for
    forward_count() { [[ "$(grep -c -- '-O forward -L 127.0.0.1:48082:' "$FAKE_DIR/ssh.log")" -ge 2 ]]; }
    wait_for 30 "the forward to be re-established after the stream ended" forward_count
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:48082:" "forward dropped while disconnected"
    assert_exists "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder still running"
    run_devhost down 2>/dev/null || fail "down"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder stopped"
}

test_up_refuses_remote_dir_not_owned() {
    : > "$FAKE_DIR/ps"
    echo "mkdir -p" > "$FAKE_DIR/ssh-remote-fail"
    local out rc=0
    out="$(run_devhost up 2>&1)" || rc=$?
    assert_eq "$rc" "1" "up fails"
    [[ "$out" == *"allow-path.sh alice"* ]] || fail "points at allow-path.sh: $out"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions" 2>/dev/null)" "" "no sync created"
    assert_missing "$FAKE_DIR/master" "master torn down after the failed up"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder torn down after the failed up"
}

test_flush_reports_conflicts_during_up() {
    echo "6379 redis-server 9999" > "$FAKE_DIR/busy-ports"
    printf 'abc123def456 redis\n' > "$FAKE_DIR/ps"
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    run_devhost up 2>/dev/null || fail "up"
    local out rc=0
    out="$(run_devhost flush 2>&1)" || rc=$?
    assert_eq "$rc" "1" "flush fails on conflicts"
    [[ "$out" == *"127.0.0.1:6379"*"redis-server (pid 9999)"* ]] || fail "flush reports the conflict: $out"
    out="$(run_devhost status 2>/dev/null)"
    [[ "$out" == CONFLICTS* ]] || fail "status leads with conflicts: $out"
    run_devhost down 2>/dev/null || fail "down"
}

test_reconcile_then_die_with_full_length_id() {
    load
    echo 4242 > "$FAKE_DIR/master"
    local long="abc123def4560000000000000000000000000000000000000000000000000000"
    printf '%s redis\n' "$long" > "$FAKE_DIR/ps"                 # --no-trunc IDs
    echo "6379/tcp -> 127.0.0.1:6379" > "$FAKE_DIR/port.abc123def456"
    reconcile 2>/dev/null
    assert_file_has "$FORWARDS_FILE" "6379 127.0.0.1 $long redis" "recorded with the full ID"
    reconcile 2>/dev/null
    assert_file_lacks "$FAKE_DIR/ssh.log" "-O cancel" "second reconcile keeps the forward (IDs compare equal)"
    handle_event die "$long" redis 2>/dev/null
    assert_file_has "$FAKE_DIR/ssh.log" "-O cancel -L 127.0.0.1:6379:" "die with the full ID cancels"
    assert_eq "$(cat "$FORWARDS_FILE")" "" "forgotten"
}

test_empty_devhostignore_syncs_everything() {
    load
    printf '# nothing ignored\n\n' > .devhostignore
    start_sync 2>/dev/null
    assert_file_has "$FAKE_DIR/mutagen.log" "--sync-mode two-way-resolved $PWD alice@devhost:$PWD" "no --ignore arguments"
}

test_flush_has_a_deadline() {
    load
    start_sync 2>/dev/null
    touch "$FAKE_DIR/mutagen-flush-hang"
    local out start end rc=0
    start=$(date +%s)
    out="$(FLUSH_TIMEOUT=1 flush_sync 2>&1)" || rc=$?
    end=$(date +%s)
    [[ $((end - start)) -le 3 ]] || fail "flush returned after $((end - start))s"
    assert_eq "$rc" "124" "flush_sync reports the timeout"
    [[ "$out" == *"did not finish within 1s"* ]] || fail "timeout message: $out"
}

test_sync_primes_vm_from_laptop_first() {
    load
    start_sync 2>/dev/null
    local name l1 l2 l3 l4 l5
    name="$(sync_name)"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync create --name $name-prime --label devhost=1 --label $(state_label) --sync-mode one-way-replica --ignore node_modules --ignore .git --ignore .venv --ignore target --ignore dist $PWD alice@devhost:$PWD" "one-way replica from the laptop, same ignores"
    l1="$(grep -n -- "sync create --name $name-prime" "$FAKE_DIR/mutagen.log" | cut -d: -f1)"
    l2="$(grep -n -- "sync flush $name-prime" "$FAKE_DIR/mutagen.log" | cut -d: -f1)"
    l3="$(grep -n -- "sync terminate $name-prime" "$FAKE_DIR/mutagen.log" | cut -d: -f1)"
    l4="$(grep -n -- "sync create --name $name --label" "$FAKE_DIR/mutagen.log" | cut -d: -f1)"
    l5="$(grep -n -- "sync flush $name\$" "$FAKE_DIR/mutagen.log" | cut -d: -f1)"
    [[ -n "$l1" && -n "$l2" && -n "$l3" && -n "$l4" && -n "$l5" && $l1 -lt $l2 && $l2 -lt $l3 && $l3 -lt $l4 && $l4 -lt $l5 ]] ||
        fail "replica created, flushed and dropped before the two-way session is created and flushed: $(cat "$FAKE_DIR/mutagen.log")"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "$name" "only the two-way session remains"
}

test_initial_sync_timeout_fails_up() {
    : > "$FAKE_DIR/ps"
    touch "$FAKE_DIR/mutagen-flush-hang"
    local out rc=0
    out="$(DEVHOST_SYNC_TIMEOUT=1 run_devhost up 2>&1)" || rc=$?
    assert_eq "$rc" "1" "up fails when the initial sync doesn't finish"
    [[ "$out" == *"did not finish within 1s"*"DEVHOST_SYNC_TIMEOUT"* ]] || fail "says why: $out"
    assert_missing "$FAKE_DIR/master" "torn down"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "no session left behind"
}

test_flush_failure_is_fatal_for_flush_and_before_run() {
    : > "$FAKE_DIR/ps"
    run_devhost up 2>/dev/null || fail "up"
    touch "$FAKE_DIR/mutagen-flush-hang"
    local rc=0
    DEVHOST_FLUSH_TIMEOUT=1 run_devhost flush 2>/dev/null || rc=$?
    assert_eq "$rc" "1" "devhost flush exits 1 when the flush times out"
    rc=0
    DEVHOST_FLUSH_TIMEOUT=1 run_devhost run -- sh -c 'echo ran > ran' 2>/dev/null || rc=$?
    assert_eq "$rc" "1" "run refuses when the pre-command flush fails"
    assert_missing ran "command not run on a stale sync"
    rm -f "$FAKE_DIR/mutagen-flush-hang"
    run_devhost down 2>/dev/null || fail "down"
}

test_prune_terminates_crashed_runs_sync() {
    : > "$FAKE_DIR/ps"
    mkdir -p "$DEVHOST_STATE_DIR/sessions"
    printf '%s\nrun\n' "$TMP/crashed" > "$DEVHOST_STATE_DIR/sessions/123456"   # crashed run, no live pids
    local crashed_sync
    crashed_sync="devhost-$(printf '%s' "$TMP/crashed" | cksum | cut -d' ' -f1)"
    echo "$crashed_sync" > "$FAKE_DIR/mutagen-sessions"
    echo "$crashed_sync $TMP/crashed" > "$FAKE_DIR/mutagen-alphas"
    run_devhost run -- true 2>/dev/null || fail "run"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync terminate $crashed_sync" "the crashed run's sync went with its session"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "no sync left behind"
}

test_last_down_terminates_leftover_syncs() {
    : > "$FAKE_DIR/ps"
    echo "devhost-leftover" > "$FAKE_DIR/mutagen-sessions"
    echo "devhost-leftover $TMP/old-checkout" > "$FAKE_DIR/mutagen-alphas"
    run_devhost up 2>/dev/null || fail "up"
    local status
    status="$(run_devhost status 2>/dev/null)"
    [[ "$status" == *"other devhost syncs"*"$TMP/old-checkout"* ]] || fail "status lists other devhost syncs: $status"
    run_devhost down 2>/dev/null || fail "down"
    assert_file_has "$FAKE_DIR/mutagen.log" "sync terminate --label-selector $(state_label)" "leftovers of this state dir go with the last session"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "no devhost sync left"
}

test_nested_checkout_is_refused() {
    load
    echo "devhost-parent" > "$FAKE_DIR/mutagen-sessions"
    echo "devhost-parent $PWD" > "$FAKE_DIR/mutagen-alphas"    # the checkout root is up
    mkdir -p sub
    cd sub || exit 1
    local out rc=0
    out="$(start_sync 2>&1)" || rc=$?
    assert_eq "$rc" "1" "a session inside a synced checkout is refused"
    [[ "$out" == *"inside $PROJECT"* ]] || fail "names the covering session: $out"
    assert_file_lacks "$FAKE_DIR/mutagen.log" "sync create" "no second session created"
    cd "$PROJECT" || exit 1
    echo "devhost-child $PROJECT/sub" > "$FAKE_DIR/mutagen-alphas"   # or a subdirectory is
    echo "devhost-child" > "$FAKE_DIR/mutagen-sessions"
    rc=0
    out="$(start_sync 2>&1)" || rc=$?
    assert_eq "$rc" "1" "a session over a synced subdirectory is refused"
    [[ "$out" == *"$PROJECT/sub"*"inside this checkout"* ]] || fail "names the inner session: $out"
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
    assert_eq "$(grep -c -- "sync terminate $(cat "$FAKE_DIR/mutagen-sessions")\$" "$FAKE_DIR/mutagen.log")" "0" "nested run keeps sync"
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

test_ctrl_c_reaches_command() {
    : > "$FAKE_DIR/ps"
    local pid rc=0
    # Job control on: the background devhost (and so its command) keeps the
    # default INT disposition, as it would from a terminal. INT to its process
    # group is what Ctrl-C does.
    set -m
    # shellcheck disable=SC2016
    start_devhost run -- sh -c 'trap "echo int > \"$FAKE_DIR/child-got-int\"; exit 5" INT; touch "$FAKE_DIR/child-started"; while :; do sleep 0.1; done'
    pid=$!
    set +m
    wait_for 30 "the command to start" test -e "$FAKE_DIR/child-started"
    kill -INT -- "-$pid"
    wait "$pid" || rc=$?
    assert_exists "$FAKE_DIR/child-got-int" "Ctrl-C reached the command"
    assert_eq "$rc" "5" "exit code is the command's"
    assert_missing "$FAKE_DIR/master" "torn down"
    assert_missing "$DEVHOST_STATE_DIR/forwarder.pid" "forwarder stopped"
}

test_symlinked_checkout_syncs_logical_path() {
    load
    if ! ln -s "$PROJECT" "$TMP/link" 2>/dev/null || [[ ! -L "$TMP/link" ]]; then
        echo "       (no symlinks on this filesystem; skipped)"
        return 0
    fi
    cd "$TMP/link" || exit 1
    start_sync 2>/dev/null
    assert_file_has "$FAKE_DIR/mutagen.log" "--sync-mode two-way-resolved --ignore node_modules --ignore .git --ignore .venv --ignore target --ignore dist $TMP/link alice@devhost:$TMP/link" "the sync uses the path as typed: what -v \$PWD expands to"
    assert_eq "$(sync_name)" "devhost-$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)" "but is keyed by the physical path"
    cd "$PROJECT" || exit 1
    start_sync 2>/dev/null
    assert_eq "$(grep -c 'sync create --name' "$FAKE_DIR/mutagen.log")" "2" "entered directly, it is the same checkout: no new session (prime + two-way only)"
}

test_sync_alphas_keep_spaces() {
    load
    echo "devhost-x" > "$FAKE_DIR/mutagen-sessions"
    echo "devhost-x $TMP/my dir" > "$FAKE_DIR/mutagen-alphas"
    assert_eq "$(devhost_sync_alphas)" "$TMP/my dir" "paths with spaces survive"
}

test_prime_failure_is_fatal_and_leftover_prime_removed() {
    load
    local name out rc=0
    name="$(sync_name)"
    echo "$name-prime" > "$FAKE_DIR/mutagen-sessions"          # left by an interrupted start
    echo "$name-prime $PWD" > "$FAKE_DIR/mutagen-alphas"
    touch "$FAKE_DIR/mutagen-flush-fail"
    out="$(start_sync 2>&1)" || rc=$?
    assert_eq "$rc" "1" "start_sync fails when the replica could not make the VM match"
    [[ "$out" == *"could not be updated or removed"* ]] || fail "says why: $out"
    assert_eq "$(grep -c -- "sync terminate $name-prime" "$FAKE_DIR/mutagen.log")" "2" "leftover prime terminated before, the failed one after"
    assert_file_lacks "$FAKE_DIR/mutagen.log" "sync create --name $name --label" "no two-way session over a VM copy that doesn't match"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "nothing left running"
}

test_interrupted_priming_leaves_no_prime_session() {
    : > "$FAKE_DIR/ps"
    touch "$FAKE_DIR/mutagen-flush-hang"               # the priming flush never finishes
    local pid rc=0
    start_devhost run -- true
    pid=$!
    wait_for 30 "priming to start" grep -q -- '-prime' "$FAKE_DIR/mutagen.log"
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    assert_eq "$rc" "143" "run exits on the signal"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "the one-way replica is not left deleting VM files"
    assert_missing "$FAKE_DIR/master" "torn down"
}

test_failed_final_flush_keeps_sync() {
    : > "$FAKE_DIR/ps"
    local out rc=0 name
    name="devhost-$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
    # shellcheck disable=SC2016
    out="$(DEVHOST_FLUSH_TIMEOUT=1 run_devhost run -- sh -c 'touch "$FAKE_DIR/mutagen-flush-hang"' 2>&1)" || rc=$?
    assert_eq "$rc" "0" "the command's exit code wins"
    [[ "$out" == *"keeping the sync session"* ]] || fail "explains why the session stays: $out"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "$name" "sync kept so VM-side outputs are not lost"
    assert_missing "$FAKE_DIR/master" "forwarder and master stopped anyway"
    rm -f "$FAKE_DIR/mutagen-flush-hang"
    run_devhost up 2>/dev/null || fail "up"
    assert_eq "$(grep -c -- "sync create --name $name-prime" "$FAKE_DIR/mutagen.log")" "1" "the kept session is reused: no second priming"
    run_devhost down 2>/dev/null || fail "down"
    assert_eq "$(cat "$FAKE_DIR/mutagen-sessions")" "" "gone after a successful flush"
}

test_interrupt_while_waiting_for_lock_does_not_hang() {
    : > "$FAKE_DIR/ps"
    local holder pid rc=0 start end
    sleep 60 &
    holder=$!
    mkdir -p "$DEVHOST_STATE_DIR/lock"
    echo "$holder" > "$DEVHOST_STATE_DIR/lock/pid"      # a live holder
    start_devhost run -- true
    pid=$!
    sleep 1
    start=$(date +%s)
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    end=$(date +%s)
    kill "$holder" 2>/dev/null || true
    assert_eq "$rc" "143" "run exits on the signal"
    [[ $((end - start)) -le 3 ]] || fail "took $((end - start))s to exit while the lock was held"
    assert_eq "$(ls "$DEVHOST_STATE_DIR/sessions" 2>/dev/null)" "" "nothing registered"
}

test_flush_fails_without_sync_session() {
    : > "$FAKE_DIR/ps"
    run_devhost up 2>/dev/null || fail "up"
    : > "$FAKE_DIR/mutagen-sessions"                   # mutagen lost the session
    : > "$FAKE_DIR/mutagen-alphas"
    local rc=0
    run_devhost flush 2>/dev/null || rc=$?
    assert_eq "$rc" "1" "flush fails rather than claiming success"
    run_devhost down 2>/dev/null || fail "down"
}

test_initial_sync_does_not_hold_the_global_lock() {
    : > "$FAKE_DIR/ps"
    touch "$FAKE_DIR/mutagen-flush-hang"
    mkdir -p "$TMP/other"
    local pid rc=0 start end
    DEVHOST_SYNC_TIMEOUT=20 start_devhost up           # stuck in its initial sync for 20s
    pid=$!
    wait_for 30 "the first up to reach its initial flush" grep -q "sync flush" "$FAKE_DIR/mutagen.log"
    start=$(date +%s)
    (cd "$TMP/other" && DEVHOST_NO_SYNC=1 run_devhost run -- true 2>/dev/null) || fail "run elsewhere"
    end=$(date +%s)
    [[ $((end - start)) -le 10 ]] || fail "a run elsewhere waited $((end - start))s on the global lock"
    wait "$pid" || rc=$?
    assert_eq "$rc" "1" "the stuck up fails on its timeout"
    assert_missing "$FAKE_DIR/master" "everything torn down"
}

test_add_devhost_context_inserts_ssh_block() {
    local home="$TMP/home" cfg block_line star_line
    mkdir -p "$home/.ssh"
    cfg="$home/.ssh/config"
    printf 'Host *\n    ControlMaster no\n' > "$cfg"
    HOME="$home" ADD_SSH_CONFIG=1 "$ROOT/client/add-devhost-context.sh" devhost.lan alice > "$TMP/out" 2>&1 ||
        fail "script failed: $(cat "$TMP/out")"
    assert_file_has "$FAKE_DIR/docker.log" "context update devhost --docker host=ssh://alice@devhost.lan" "context pointed at the host"
    block_line="$(grep -n '^Host devhost.lan$' "$cfg" | cut -d: -f1)"
    star_line="$(grep -n '^Host \*$' "$cfg" | cut -d: -f1)"
    [[ -n "$block_line" && -n "$star_line" && $block_line -lt $star_line ]] || fail "block ahead of 'Host *': $(cat "$cfg")"
    assert_file_has "$cfg" "    ControlPath ~/.ssh/cm-%r@%h:%p" "block content intact"
    assert_file_has "$cfg" "    ControlMaster no" "existing block intact"
    HOME="$home" ADD_SSH_CONFIG=1 "$ROOT/client/add-devhost-context.sh" devhost.lan alice > "$TMP/out2" 2>&1 ||
        fail "second run failed: $(cat "$TMP/out2")"
    assert_eq "$(grep -c '^Host devhost.lan$' "$cfg")" "1" "not added twice"
    grep -q "already has a block" "$TMP/out2" || fail "second run reports the existing block: $(cat "$TMP/out2")"
    HOME="$home" ADD_SSH_CONFIG=1 "$ROOT/client/add-devhost-context.sh" devhostXlan alice > "$TMP/out3" 2>&1 ||
        fail "third run failed: $(cat "$TMP/out3")"
    assert_eq "$(grep -c '^Host devhostXlan$' "$cfg")" "1" "a dot in the existing host is not a wildcard"
}

# ------------------------------------------------------------------ runner

run_test() {
    local rc
    CURRENT="$1"
    setup
    # Not inside `if (...)`: bash disables set -e in an if condition.
    ( set -eo pipefail; "$1" )
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

# Usage: tests/devhost.test.sh [test_name...]   (default: all)
main() {
    local t tests
    tests="$*"
    [[ -n "$tests" ]] || tests="$(declare -F | awk '{ print $3 }' | grep '^test_' | sort)"
    echo "devhost tests"
    for t in $tests; do
        run_test "$t"
    done
    echo "$PASS passed, $FAIL failed"
    [[ $FAIL -eq 0 ]]
}

main "$@"
