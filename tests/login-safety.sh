#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SCRIPT="$PWD/secure_server_bootstrap.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Run the real preflight key check against isolated fixture files.
awk '/^# Require a usable public key/{copy=1} copy{print} copy && /^fi$/{exit}' "$SCRIPT" |
  sed "s|/root/.ssh/authorized_keys|$TEST_DIR/authorized_keys|g" >"$TEST_DIR/preflight"
for fixture in missing empty comments invalid; do
  rm -f "$TEST_DIR/authorized_keys"
  case "$fixture" in
    empty) touch "$TEST_DIR/authorized_keys" ;;
    comments) echo '# no login keys' >"$TEST_DIR/authorized_keys" ;;
    invalid) echo 'ssh-ed25519 invalid' >"$TEST_DIR/authorized_keys" ;;
  esac
  if bash "$TEST_DIR/preflight" >/dev/null 2>&1; then
    echo "FAIL: accepted $fixture key file" >&2
    exit 1
  fi
done
ssh-keygen -q -t ed25519 -N '' -f "$TEST_DIR/key"
cp "$TEST_DIR/key.pub" "$TEST_DIR/authorized_keys"
bash "$TEST_DIR/preflight"
printf 'restrict %s\n' "$(cat "$TEST_DIR/key.pub")" >"$TEST_DIR/authorized_keys"
bash "$TEST_DIR/preflight"

# Exercise the real local orchestration; never execute remote payloads.
mkdir "$TEST_DIR/bin"
cat >"$TEST_DIR/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
  *root@*)
    cat >"$PAYLOAD"
    bash -n "$PAYLOAD"
    echo root >>"$EVENTS"
    ;;
  *'sudo -n env '*)
    cat >"$PAYLOAD"
    bash -n "$PAYLOAD"
    echo harden >>"$EVENTS"
    ;;
  *'sudo -n true')
    [[ "$args" == *'ControlMaster=no'* && "$args" == *'ControlPath=none'* && "$args" == *'BatchMode=yes'* && "$args" == *'PreferredAuthentications=publickey'* ]]
    echo verify >>"$EVENTS"
    count=$(grep -c '^verify$' "$EVENTS")
    if [[ "$count" == "$FAIL_VERIFY" ]]; then exit 1; fi
    ;;
  *'sudo -n reboot') echo reboot >>"$EVENTS" ;;
  *) echo "Unexpected SSH call: $args" >&2; exit 1 ;;
esac
MOCK
printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/bin/ssh-keygen"
printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/bin/sleep"
chmod +x "$TEST_DIR/bin/"*
export EVENTS="$TEST_DIR/events" PAYLOAD="$TEST_DIR/payload"
for FAIL_VERIFY in 1 2 0; do
  export FAIL_VERIFY
  : >"$EVENTS"
  status=0
  PATH="$TEST_DIR/bin:$PATH" bash "$SCRIPT" --host=example.test --user=root --new-user=admin --hostname=test --tailscale=false >"$TEST_DIR/output" 2>&1 || status=$?
  case "$FAIL_VERIFY" in
    1) expected=$'root\nverify'; [[ "$status" != 0 ]] ;;
    2) expected=$'root\nverify\nharden\nverify'; [[ "$status" != 0 ]] ;;
    0) expected=$'root\nverify\nharden\nverify\nreboot\nverify\nroot'; [[ "$status" == 0 ]] ;;
  esac
  [[ "$(cat "$EVENTS")" == "$expected" ]] || { cat "$EVENTS"; exit 1; }
done
bash -n "$SCRIPT"
echo 'PASS: key preflight and admin login gates'
