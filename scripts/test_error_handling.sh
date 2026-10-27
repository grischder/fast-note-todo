#!/usr/bin/env bash
# Checks that only hold on the error-handling branch (fix/keyring-error-handling):
# a failed read has to be told apart from an empty value, and a failure has
# to be visible. Run from the branch's checkout:
#
#   PLUGIN_DIR=/path/to/checkout scripts/test_error_handling.sh
#
# Uses a secret-tool *shim* for the failure cases, so no keyring prompt can
# appear. The "missing entry" checks need the real tool and a running
# keyring; they are skipped where there is none.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
PLUGIN_DIR=${PLUGIN_DIR:-$PROJECT_DIR}
WORK=${WORK:-/tmp/fast-note-todo-tests}
mkdir -p "$WORK"
cd "$WORK" || exit 1

FIELD=probecompat
pass=0
fail=0
skip=0

skip() {
  printf 'SKIP  %-46s %s\n' "$1" "$2"
  skip=$((skip + 1))
}

check() {
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %-46s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-46s expected=%q actual=%q\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

extract() { python3 "$SCRIPT_DIR/extract_script.py" "$@"; }
mkload() { extract loadScript "$1" > "load_$1.sh"; }
do_load()  { bash -c "$(cat "load_$1.sh")" omanote-load; }
clearfield() { secret-tool clear omarchy-plugin b.omanote field "$1" >/dev/null 2>&1; }

# A missing value can only be told apart from an empty one against a real
# keyring. Probe for one, and skip the checks that need it otherwise.
keyring_available() {
  command -v secret-tool >/dev/null 2>&1 || return 1
  printf 'probe' | secret-tool store --label=probe omarchy-plugin b.omanote field omanote-probe >/dev/null 2>&1 || return 1
  if ! secret-tool lookup omarchy-plugin b.omanote field omanote-probe >/dev/null 2>&1; then
    secret-tool clear omarchy-plugin b.omanote field omanote-probe >/dev/null 2>&1
    return 1
  fi
  secret-tool clear omarchy-plugin b.omanote field omanote-probe >/dev/null 2>&1
  return 0
}

mkdir -p shim
cat > shim/secret-tool <<'EOF'
#!/bin/sh
echo "secret-tool: simulated failure" >&2
exit 1
EOF
chmod +x shim/secret-tool

export PLUGIN_DIR
clearfield "$FIELD"
mkload "$FIELD"

echo "== a failing lookup is an error, not an empty value =="
PATH="$WORK/shim:$PATH" bash -c "$(cat load_"$FIELD".sh)" omanote-load \
  > failed.txt 2> failed_err.txt
check "failing lookup exits non-zero" 1 $?
check "failing lookup explains itself" "yes" \
  "$(grep -q 'simulated failure' failed_err.txt && echo yes || echo no)"
check "failing lookup prints no note" "" "$(cat failed.txt)"

echo
echo "== a signal-killed secret-tool is a failure, not 'not found' =="
cat > shim/secret-tool <<'EOF'
#!/bin/sh
kill -TERM $$
EOF
chmod +x shim/secret-tool
PATH="$WORK/shim:$PATH" bash -c "$(cat load_"$FIELD".sh)" omanote-load \
  > sig.txt 2> sig_err.txt
check "signal-killed lookup exits non-zero" 143 $?
check "signal-killed lookup prints no note" "" "$(cat sig.txt)"

echo
echo "== a silent exit 0 with no value is a failure =="
cat > shim/secret-tool <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x shim/secret-tool
PATH="$WORK/shim:$PATH" bash -c "$(cat load_"$FIELD".sh)" omanote-load \
  > silent.txt 2> silent_err.txt
check "silent empty success exits non-zero" 1 $?
check "silent empty success is explained" "yes" \
  "$(grep -q 'could not be read' silent_err.txt && echo yes || echo no)"

echo
echo "== a missing value is empty, and clearing it is not an error =="
extract clearScript nosuchthing > clear_nosuchthing.sh
if keyring_available; then
  clearfield nosuchthing
  mkload nosuchthing
  do_load nosuchthing > missing.txt 2> missing_err.txt
  check "missing entry exits zero" 0 $?
  check "missing entry prints nothing" "" "$(cat missing.txt)"
  check "missing entry has no error output" "" "$(cat missing_err.txt)"
  bash -c "$(cat clear_nosuchthing.sh)" omanote-clear > clear_out.txt 2> clear_err.txt
  check "clearing a missing entry exits zero" 0 $?
  check "clearing a missing entry has no error output" "" "$(cat clear_err.txt)"
else
  for name in "missing entry exits zero" "missing entry prints nothing" \
              "missing entry has no error output" "clearing a missing entry exits zero" \
              "clearing a missing entry has no error output"; do
    skip "$name" "no usable keyring"
  done
fi

echo
echo "== a signal-killed clear is a failure =="
cat > shim/secret-tool <<'EOF'
#!/bin/sh
kill -TERM $$
EOF
chmod +x shim/secret-tool
PATH="$WORK/shim:$PATH" bash -c "$(cat clear_nosuchthing.sh)" omanote-clear \
  > clear_sig.txt 2> clear_sig_err.txt
check "signal-killed clear exits non-zero" 143 $?

echo
echo "passed=$pass failed=$fail skipped=$skip"
[[ $fail -eq 0 ]]
