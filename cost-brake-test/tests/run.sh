#!/usr/bin/env bash
# run.sh - drives test-disable-enable.sh and flood.sh against a fake aws and curl (tests/bin). No AWS, no network.
# Usage: tests/run.sh      Exit 0 only if every check passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
export PATH="$here/bin:$PATH"
export POLL_INTERVAL=0 ALERT_WAIT=1 TIMEOUT=3 LOG_TRIES=2 EMAIL_PROMPT_TIMEOUT=1
export STACK_NAME=fake-stack SITE_URL=https://blog.fake-host.example
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cbt.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0

check() { # description, then a command; passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "  ok   $d"; else FAIL=$((FAIL + 1)); echo "  FAIL $d"; fi
}
has()    { grep -q -- "$2" "$1"; }
hasnot() { ! grep -q -- "$2" "$1"; }
state()  { cat "$STUB_DIR/$1" 2>/dev/null || { [ "$1" = enabled ] && echo true; }; }

# run NAME "stdin text" script args...   -> sets RC, OUT (stdout+stderr file), RES (results file), STUB_DIR
run() {
  local name="$1" input="$2"; shift 2
  STUB_DIR="$TMP/$name/state"; RESDIR="$TMP/$name/res"; mkdir -p "$STUB_DIR" "$RESDIR"
  export STUB_DIR RESULTS_DIR="$RESDIR"
  OUT="$TMP/$name/out.txt"
  printf '%b' "$input" | "$@" > "$OUT" 2>&1; RC=$?
  RES="$(ls "$RESDIR"/results-*.txt 2>/dev/null | head -n 1)"; [ -n "$RES" ] || RES=/dev/null
}
reset_env() { unset STUB_ACTION STUB_LAMBDA STUB_BREAK STUB_INIT_ENABLED STUB_FAIL_NTH STUB_INT STUB_FLOOD_AT STUB_THRESHOLD; }
T="$root/test-disable-enable.sh"; F="$root/flood.sh"

echo "disable path"
reset_env; export STUB_ACTION=Disable
run disable 'DISABLE 1234\n14:05\n' "$T"
check "exit 0" test "$RC" = 0
check "enabled_false PASS" has "$RES" 'TEST=enabled_false RESULT=PASS'
check "disable_deployed PASS" has "$RES" 'TEST=disable_deployed RESULT=PASS'
check "lambda_log PASS" has "$RES" 'TEST=lambda_log RESULT=PASS'
check "alarm_history PASS" has "$RES" 'TEST=alarm_history RESULT=PASS'
check "email_minute measured" has "$RES" 'TEST=email_minute RESULT=MEASURED'
check "restore enabled and deployed" has "$RES" 'TEST=restore_deployed RESULT=PASS'
check "site 200 after restore" has "$RES" 'TEST=site_http_200 RESULT=PASS'
check "alarm reset PASS" has "$RES" 'TEST=alarm_reset RESULT=PASS'
check "distribution ends enabled" test "$(state enabled)" = true
check "alarm ends OK" test "$(state alarm)" = OK
check "restore used If-Match" has "$STUB_DIR/calls.log" 'update-distribution.*--if-match ETAG1'
check "no distribution id in results" hasnot "$RES" EFAKETEST1234
check "no site host in results" hasnot "$OUT" fake-host.example

echo "disable path, wrong confirmation phrase"
run phrase 'yes\n' "$T"
check "exit 3" test "$RC" = 3
check "alarm never touched" hasnot "$STUB_DIR/calls.log" set-alarm-state
check "distribution untouched" hasnot "$STUB_DIR/calls.log" update-distribution

echo "disable path, Lambda does nothing (timeout)"
export STUB_LAMBDA=off
run timeout 'DISABLE 1234\n\n' "$T"
check "exit 1" test "$RC" = 1
check "enabled_false FAIL" has "$RES" 'TEST=enabled_false RESULT=FAIL'
check "still enabled at the end" test "$(state enabled)" = true
reset_env

echo "alert-only path"
export STUB_ACTION=AlertOnly
run alert '\n' "$T"
check "exit 0" test "$RC" = 0
check "stays enabled PASS" has "$RES" 'TEST=alertonly_stays_enabled RESULT=PASS'
check "lambda_log PASS" has "$RES" 'TEST=lambda_log RESULT=PASS'
check "email skipped" has "$RES" 'TEST=email_minute RESULT=SKIPPED'
check "no phrase prompt" hasnot "$OUT" 'Type exactly'
check "no update-distribution call" hasnot "$STUB_DIR/calls.log" update-distribution
echo "alert-only path, brake wrongly disables"
export STUB_BREAK=1
run alertbad '\n' "$T"
check "exit 1" test "$RC" = 1
check "FAIL recorded" has "$RES" 'TEST=alertonly_stays_enabled RESULT=FAIL'
check "restored anyway" test "$(state enabled)" = true
reset_env

echo "restore-only"
export STUB_INIT_ENABLED=false
run restore '' "$T" --restore-only
check "exit 0" test "$RC" = 0
check "restore PASS" has "$RES" 'TEST=restore_deployed RESULT=PASS'
check "distribution enabled" test "$(state enabled)" = true
check "alarm not forced" hasnot "$STUB_DIR/calls.log" 'set-alarm-state --alarm-name.*ALARM'
reset_env

echo "dry-run"
run dry '' "$T" --dry-run
check "exit 0" test "$RC" = 0
check "prints update-distribution" has "$OUT" 'update-distribution'
check "calls nothing" test ! -s "$STUB_DIR/calls.log"
check "writes no results file" test "$RES" = /dev/null
run dryflood '' "$F" --dry-run
check "flood dry-run exit 0 and no calls" test "$RC" = 0 -a ! -s "$STUB_DIR/calls.log"

echo "error path: AWS call fails mid-poll, trap restores"
export STUB_ACTION=Disable STUB_FAIL_NTH=get-distribution:2
run err 'DISABLE 1234\n' "$T"
check "non-zero exit" test "$RC" -ne 0
check "trap restored the distribution" test "$(state enabled)" = true
check "says it is restoring" has "$OUT" 'restoring the distribution'
reset_env

echo "Ctrl-C path"
export STUB_ACTION=Disable STUB_INT=1
run intr 'DISABLE 1234\n' "$T"
check "exit 130" test "$RC" = 130
check "trap restored the distribution" test "$(state enabled)" = true
reset_env

echo "--no-auto-restore"
export STUB_ACTION=Disable STUB_FAIL_NTH=get-distribution:2
run noauto 'DISABLE 1234\n' "$T" --no-auto-restore
check "non-zero exit" test "$RC" -ne 0
check "left disabled" test "$(state enabled)" = false
check "prints restore-only command" has "$OUT" -e '--restore-only'
reset_env

echo "refusals"
REGION=eu-west-1 run region '' "$T"; check "other region exit 2" test "$RC" = 2
STACK_NAME='' run nostack '' "$T" ; check "missing STACK_NAME exit 2" test "$RC" -ne 0
SITE_URL=http://x.example run http '' "$T"; check "http SITE_URL exit 2" test "$RC" = 2

echo "flood"
export STUB_ACTION=Disable STUB_THRESHOLD=10 STUB_FLOOD_AT=10 N=20 BATCH=5
run flood 'DISABLE 1234\n\n' "$F"
check "exit 0" test "$RC" = 0
check "sent N requests" has "$RES" 'TEST=flood_sent RESULT=PASS.*20 requests sent'
check "alarm_in_alarm PASS" has "$RES" 'TEST=alarm_in_alarm RESULT=PASS'
check "enabled_false PASS" has "$RES" 'TEST=enabled_false RESULT=PASS'
check "waited for alarm OK" has "$RES" 'TEST=alarm_back_to_ok RESULT=PASS'
check "site 200 after restore" has "$RES" 'TEST=site_http_200 RESULT=PASS'
check "ends enabled" test "$(state enabled)" = true
check "real alarm never forced to OK by the script" hasnot "$STUB_DIR/calls.log" 'state-value OK'
export STUB_THRESHOLD=10 STUB_ACTION=AlertOnly STUB_FLOOD_AT=10 N=20
run floodalert '\n' "$F"
check "alert-only flood stays enabled" has "$RES" 'TEST=alertonly_stays_enabled RESULT=PASS'
export STUB_THRESHOLD=500 N=20
run floodrefuse '' "$F"
check "refuses when threshold >= N" test "$RC" -ne 0
check "no request sent" hasnot "$STUB_DIR/calls.log" 'cbt='
unset N BATCH; reset_env

echo "redaction"
d="$(printf '%s%s%s' 1234 5678 9012)"
out="$(DIST_ID=EXYZ99 SITE_HOST=my.host.example bash -c ". '$root/lib.sh'; DIST_ID=EXYZ99 SITE_HOST=my.host.example; redact 'acct $d arn:aws:iam::$d:role/r id EXYZ99 host my.host.example ts 1789000000000'")"
check "account id removed" test "${out#*"$d"}" = "$out"
check "arn removed" test "${out#*arn:aws}" = "$out"
check "distribution id removed" test "${out#*EXYZ99}" = "$out"
check "host removed" test "${out#*my.host.example}" = "$out"
check "13-digit timestamp kept" has <(echo "$out") 1789000000000

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
