#!/usr/bin/env bash
# Exercises the exact scripts Panel.qml generates (extracted from the QML).
#
#   scripts/test_plugin_scripts.sh            # test this checkout
#   PLUGIN_DIR=/path/to/checkout scripts/test_plugin_scripts.sh
#
# Uses a secret-tool *shim* on PATH for the failure cases, so no extra
# gnome-keyring daemon is started and no keyring prompt can appear.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
PLUGIN_DIR=${PLUGIN_DIR:-$PROJECT_DIR}
WORK=${WORK:-/tmp/fast-note-todo-tests}
mkdir -p "$WORK"
cd "$WORK" || exit 1

KEYRING=~/.local/share/keyrings/Default_keyring.keyring
STARTED=$(date '+%Y-%m-%d %H:%M:%S')
FIELD=probecompat
pass=0
fail=0

check() {
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %-46s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-46s expected=%q actual=%q\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

keyring_valid() {
  python3 - "$KEYRING" <<'PY'
import sys, pathlib
bad = [(i, l) for i, l in enumerate(pathlib.Path(sys.argv[1]).read_text().splitlines(), 1)
       if l.strip() and not l.strip().startswith('[') and '=' not in l]
sys.exit(1 if bad else 0)
PY
}

extract() { python3 "$SCRIPT_DIR/extract_script.py" "$@"; }
mkload() { extract loadScript "$1" > "load_$1.sh"; }
mkstore() { extract storeScript "$1" "probe" > "store_$1.sh"; }
do_store() { bash -c "$(cat "store_$1.sh")" omanote-store "$2"; }
do_load()  { bash -c "$(cat "load_$1.sh")" omanote-load; }
clearfield() { secret-tool clear omarchy-plugin b.omanote field "$1" >/dev/null 2>&1; }

# a fake secret-tool that always fails, for the failure paths
mkdir -p shim
cat > shim/secret-tool <<'EOF'
#!/bin/sh
echo "secret-tool: simulated failure" >&2
exit 1
EOF
chmod +x shim/secret-tool

export PLUGIN_DIR

# Guard: running these tests against a checkout without the fix would store a
# raw multi-line value and corrupt the real keyring all over again.
mkload "$FIELD"; mkstore "$FIELD"
if ! grep -q omanote-b64 "store_$FIELD.sh"; then
  echo "REFUSING TO RUN: $PLUGIN_DIR does not contain the single-line storage fix." >&2
  echo "Point PLUGIN_DIR at a checkout of the fixed branch." >&2
  exit 2
fi

clearfield "$FIELD"
mkload "$FIELD"; mkstore "$FIELD"

echo "== 1. multiline note round trip =="
printf 'first line\nsecond line\nthird line\n' > note.txt
cp note.txt note.orig.txt
do_store "$FIELD" note.txt
check "store exit code" 0 $?
check "multiline payload is marked" "yes" \
  "$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD" | grep -q '^omanote-b64:' && echo yes || echo no)"
check "stored value has no newline" 0 \
  "$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD" | wc -l)"
do_load "$FIELD" > loaded.txt
check "loaded text is byte-exact" "$(cat note.orig.txt)" "$(cat loaded.txt)"
keyring_valid
check "keyring file has no malformed lines" 0 $?

echo
echo "== 1b. a single-line payload is stored verbatim and keeps its size =="
printf 'a single line of text' > oneline.txt
cp oneline.txt oneline.orig.txt
do_store "$FIELD" oneline.txt
check "single-line store succeeds" 0 $?
check "single-line value is not marked" "no" \
  "$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD" | grep -q '^omanote-b64:' && echo yes || echo no)"
do_load "$FIELD" > loaded_oneline.txt
check "single-line text round-trips" "$(cat oneline.orig.txt)" "$(cat loaded_oneline.txt)"
python3 -c "open('big1.txt','w').write('A'*7000)"
do_store "$FIELD" big1.txt
check "a 7000 byte single-line payload is accepted" 0 $?
check "7000 bytes stored fully" 7000 \
  "$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD" | wc -c)"
python3 -c "open('toobig1.txt','w').write('A'*8192)"
do_store "$FIELD" toobig1.txt 2> toobig1_err.txt
check "8192 bytes are refused" 1 $?
check "the refusal names the 8191 byte limit" "yes" \
  "$(grep -q '8191' toobig1_err.txt && echo yes || echo no)"

echo
echo "== 2. legacy value without marker is returned unchanged =="
printf 'todo\n' > legacy.txt
secret-tool store --label=probe omarchy-plugin b.omanote field legacyprobe < legacy.txt
mkload legacyprobe
do_load legacyprobe > loaded_legacy.txt
check "legacy raw text preserved" "todo" "$(cat loaded_legacy.txt)"
clearfield legacyprobe

echo
echo "== 3. legacy value that looks like base64 is NOT mis-decoded =="
printf 'todo\n' > legacy2.txt
secret-tool store --label=probe omarchy-plugin b.omanote field legacy2 < legacy2.txt
mkload legacy2
do_load legacy2 > loaded_legacy2.txt
check "legacy 'todo' kept verbatim" "todo" "$(cat loaded_legacy2.txt)"
clearfield legacy2

echo
echo "== 3b. a legacy value starting with the old marker is read verbatim =="
printf 'b64:todo\n' > legacy3.txt
secret-tool store --label=probe omarchy-plugin b.omanote field legacy3 < legacy3.txt
mkload legacy3
do_load legacy3 > loaded_legacy3.txt
check "legacy 'b64:todo' kept verbatim" "b64:todo" "$(cat loaded_legacy3.txt)"
clearfield legacy3

echo
echo "== 3c. a single-line payload that starts with the marker is encoded =="
printf 'omanote-b64:notreallyencoded' > markerish.txt
do_store "$FIELD" markerish.txt
check "marker-like payload is stored marked" "yes" \
  "$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD" | grep -q '^omanote-b64:' && echo yes || echo no)"
do_load "$FIELD" > loaded_markerish.txt
check "marker-like payload round-trips" "omanote-b64:notreallyencoded" "$(cat loaded_markerish.txt)"

echo
echo "== 4. oversized payload is refused, not truncated =="
before_big=$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD")
python3 -c "open('big.txt','w').write('A'*6132 + chr(10))"
do_store "$FIELD" big.txt 2> big_err.txt
check "oversized store fails" 1 $?
check "error mentions the limit" "yes" \
  "$(grep -q 'too large' big_err.txt && echo yes || echo no)"
check "previous value left untouched" "$before_big" \
  "$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD")"

echo
echo "== 5. exact boundary =="
python3 -c "open('edge.txt','w').write('A'*6131 + chr(10))"
do_store "$FIELD" edge.txt
check "6132 bytes with a line break accepted" 0 $?
check "6132 bytes stored fully (marker + base64)" 8188 \
  "$(secret-tool lookup omarchy-plugin b.omanote field "$FIELD" | wc -c)"
do_load "$FIELD" > loaded_edge.txt
check "6132 bytes decode back exactly" 6132 "$(wc -c < loaded_edge.txt)"

echo
echo "== 6. a zero-byte stored value is a read failure =="
: > empty.txt
do_store "$FIELD" empty.txt
check "zero-byte payload accepted by the store" 0 $?
do_load "$FIELD" > loaded_empty.txt 2> empty_err.txt
empty_rc=$?
if grep -q "could not be read" load_"$FIELD".sh; then
  # error-handling branch: a zero-byte stored value is a failure
  check "a zero-byte stored value exits non-zero" 1 "$empty_rc"
  check "a zero-byte stored value is explained" "yes" \
    "$(grep -q 'could not be read' empty_err.txt && echo yes || echo no)"
else
  # core branch: upstream semantics, an empty read is not an error
  check "a zero-byte stored value exits zero (upstream semantics)" 0 "$empty_rc"
fi
check "a zero-byte stored value prints no note" "" "$(cat loaded_empty.txt)"

echo
echo "== 7. missing entry =="
clearfield nosuchthing
mkload nosuchthing
do_load nosuchthing > loaded_missing.txt 2> missing_err.txt
check "missing entry prints nothing" "" "$(cat loaded_missing.txt)"

echo
echo "== 8. a failing lookup is reported, not reported as empty =="
PATH="$WORK/shim:$PATH" bash -c "$(cat load_"$FIELD".sh)" omanote-load \
  > failed_load.txt 2> failed_load_err.txt
check "failing lookup explains itself" "yes" \
  "$(grep -q 'simulated failure' failed_load_err.txt && echo yes || echo no)"
check "failing lookup prints no note" "" "$(cat failed_load.txt)"

echo
echo "== 9. daemon saw no format errors =="
since="$STARTED"
check "no 'invalid or unrecognized format' logged" 0 \
  "$(journalctl --user -u gnome-keyring-daemon.service --since "$since" --no-pager | grep -c 'invalid or unrecognized format')"

clearfield "$FIELD"
echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
