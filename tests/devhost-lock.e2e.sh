#!/usr/bin/env bash
# End-to-end test of `devhost lock` against a real sshd, with several SSH users.
#
# It creates users, starts sshd and changes iptables, so run it ONLY in a disposable
# container, from the repository root:
#
#   docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" ubuntu:24.04 bash /src/tests/devhost-lock.e2e.sh
#
# Covers what the fake-ssh tests in devhost-lock.test.sh can't: the tmpfiles.d entry
# from install-docker.sh, users outside the devhost group, and the VM's sshd dropping
# a holder whose network is cut.
# shellcheck disable=SC2015  # `test && ok || bad`: ok only echoes, so it can't fail
set -u

if [[ ! -f /.dockerenv ]]; then
    echo "Run this only inside a disposable container (see the header)." >&2
    exit 1
fi

echo "==> Installing packages"
apt-get update -qq >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    openssh-server openssh-client systemd iptables iproute2 procps >/dev/null 2>&1
cp -r /src /w && cd /w || exit 1
D=/w/client/devhost

failures=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1" >&2; failures=$((failures + 1)); }

# --- guest setup, as install-docker.sh and add-dev-user.sh do it ------------------
groupadd -f devhost
sed -n "/^cat > \/etc\/tmpfiles.d\/devhost.conf <<'EOF'$/,/^EOF$/{/^cat\|^EOF/!p}" \
    guest/install-docker.sh >/etc/tmpfiles.d/devhost.conf
systemd-tmpfiles --create /etc/tmpfiles.d/devhost.conf
perm="$(stat -c '%a %U:%G' /run/lock/devhost 2>/dev/null)"
[[ "$perm" == "2770 root:devhost" ]] && ok "tmpfiles.d creates /run/lock/devhost 2770 root:devhost" \
    || bad "tmpfiles.d: got '$perm'"

mkdir -p /root/.ssh /run/sshd
ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
for u in alice bob carol; do
    useradd -m -s /bin/bash "$u"
    install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
    install -m 600 -o "$u" -g "$u" /root/.ssh/id_ed25519.pub "/home/$u/.ssh/authorized_keys"
done
usermod -aG devhost alice
usermod -aG devhost bob
# Shorter than install-docker.sh's 10s x 3 to keep the test quick.
printf 'ClientAliveInterval 5\nClientAliveCountMax 2\n' >/etc/ssh/sshd_config.d/50-devhost.conf
ssh-keygen -A >/dev/null
/usr/sbin/sshd
printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n' \
    >/root/.ssh/config
# A second address for alice, so her network can be cut without cutting bob's.
ip addr add 10.99.0.1/32 dev lo

as() { local u="$1"; shift; DEVHOST_SSH="$u" "$D" "$@"; }

echo "==> Unit tests as a non-root user"
cp -r /w /home/alice/w && chown -R alice /home/alice/w
su alice -c 'bash /home/alice/w/tests/devhost-lock.test.sh' >/tmp/unit.log 2>&1 \
    && ok "devhost-lock.test.sh passes as alice" || { cat /tmp/unit.log; bad "devhost-lock.test.sh as alice"; }

echo "==> Two users take turns"
as alice@localhost lock e2e -- sleep 3 &
a=$!
sleep 1.5
as bob@localhost lock --list | grep -q '^e2e  *alice ' && ok "--list shows alice" || bad "--list"
s=$SECONDS
rc=0; as bob@localhost lock e2e --no-wait -- true 2>/dev/null || rc=$?
[[ $rc -eq 75 && $((SECONDS - s)) -le 2 ]] && ok "bob --no-wait exits 75 right away" || bad "bob --no-wait rc=$rc"
rc=0; as bob@localhost lock e2e -- sh -c 'exit 42' 2>/dev/null || rc=$?
[[ $rc -eq 42 ]] && ok "bob waits, then gets the command's exit code" || bad "bob rc=$rc"
wait "$a"
[[ -z "$(as bob@localhost lock --list)" ]] && ok "--list is empty once released" || bad "--list not empty"

echo "==> Users outside the devhost group"
as carol@localhost lock e2e -- true 2>/dev/null && bad "carol took a lock" || ok "carol can't take a lock"
as carol@localhost lock --list 2>/dev/null && bad "carol listed locks" || ok "carol can't list locks"

echo "==> kill -9 of the holder's ssh"
as alice@localhost lock e2e -- sleep 60 2>/dev/null &
a=$!
sleep 1.5
s=$SECONDS
as bob@localhost lock e2e -- true 2>/dev/null &
b=$!
sleep 1
pkill -9 -f 'ssh .*alice@localhost'
wait "$b" && [[ $((SECONDS - s)) -le 5 ]] && ok "bob proceeds right away" || bad "bob stuck"
kill "$a" 2>/dev/null; pkill -f 'sleep 60'; wait "$a" 2>/dev/null

echo "==> A waiter that goes away leaves nothing on the VM"
as alice@localhost lock e2e -- sleep 4 &
a=$!
sleep 1.5
as bob@localhost lock e2e -- true 2>/dev/null &
b=$!
sleep 1.5
pkill -9 -f 'ssh .*bob@localhost'
wait "$b" 2>/dev/null
sleep 2.5
[[ "$(pgrep -u bob -c bash)" -eq 0 ]] && ok "no waiting process left for bob" || bad "bob's waiter lingers"
wait "$a"

echo "==> Cutting the holder's network releases the lock"
as alice@10.99.0.1 lock e2e -- sleep 120 2>/dev/null &
a=$!
sleep 1.5
as bob@localhost lock --list | grep -q '^e2e  *alice ' || bad "alice isn't holding the lock"
for chain in INPUT OUTPUT; do
    iptables -I "$chain" -s 10.99.0.1 -j DROP
    iptables -I "$chain" -d 10.99.0.1 -j DROP
done
s=$SECONDS
as bob@localhost lock e2e -- true 2>/dev/null && [[ $((SECONDS - s)) -le 20 ]] \
    && ok "bob gets the lock $((SECONDS - s))s after the cut" || bad "bob didn't get the lock"
kill "$a" 2>/dev/null; pkill -f 'sleep 120'; wait "$a" 2>/dev/null

echo
if [[ $failures -gt 0 ]]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "All checks passed"
