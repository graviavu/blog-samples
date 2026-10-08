#!/usr/bin/env bash
# run.sh - drives test-disable-enable.sh and flood.sh against a fake aws and curl (tests/bin). No AWS, no network.
# Usage: tests/run.sh      Exit 0 only if every check passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
export PATH="$here/bin:$PATH"
export POLL_INTERVAL=0 ALERT_WAIT=1 TIMEOUT=3 LOG_TRIES=2 EMAIL_PROMPT_TIMEOUT=1 RETRY_PAUSE=3 LOG_CHECK_EVERY=0 RESTORE_BACKOFF=0
export STACK_NAME=fake-stack SITE_URL=https://blog.fake-host.example
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cbt.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0

check() { # description, then a command; passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "  ok   $d"; else FAIL=$((FAIL + 1)); echo "  FAIL $d"; fi
}
has()    { grep -q -- "$2" "$1"; }
hasnot() { ! grep -q -- "$2" "$1"; }
state()  { cat "$STUB_DIR/$1" 2>/dev/null || { [ "$1" = enabled ] && echo "${STUB_INIT_ENABLED:-true}"; }; }

# run NAME "stdin text" script args...   -> sets RC, OUT (stdout+stderr file), RES (results file), STUB_DIR
run() {
  local name="$1" input="$2"; shift 2
  STUB_DIR="$TMP/$name/state"; RESDIR="$TMP/$name/res"; mkdir -p "$STUB_DIR" "$RESDIR"
  export STUB_DIR RESULTS_DIR="$RESDIR"
  OUT="$TMP/$name/out.txt"
  printf '%b' "$input" | "$@" > "$OUT" 2>&1; RC=$?
  RES="$(ls "$RESDIR"/results-*.txt 2>/dev/null | head -n 1)"; [ -n "$RES" ] || RES=/dev/null
}
reset_env() {
  unset STUB_ACTION STUB_LAMBDA STUB_BREAK STUB_INIT_ENABLED STUB_FAIL_NTH STUB_INT STUB_FLOOD_AT STUB_THRESHOLD \
    STUB_ALARM_INIT STUB_REVERT STUB_LG_ANSWER STUB_LOG_GROUP STUB_TS_OFFSET STUB_LOG_LINES STUB_ALIAS STUB_CURL_CODE STUB_PRECOND_ONCE EXPECT_CODE \
    STUB_HIST_AT STUB_HIST_FAIL STUB_SIG STUB_SIG_AT STUB_QUERY_LAG STUB_KILL_READER STUB_LG_LAZY STUB_REAL_AFTER_REVERT STUB_BYTES_ALARM STUB_BYTES_REASON STUB_ALARM_REASON ATTEMPTS STUB_EXTRA_PARAMS STUB_UPDATE_NOCHANGE STUB_UPDATE_FAIL_FROM STUB_WAIT_FAIL STUB_STACK_STATUS THRESHOLD N BATCH \
    STUB_PEAK STUB_PEAK_FAIL STUB_FOREIGN_UPDATE STUB_ROLLBACK_FAILED STUB_UPDATE_DELAY STUB_ALARM_HOLD_LOW STUB_ALARM_STUCK FORCE_NO_PEAK RESTORE_TRIES STACK_POLICY
  export LOG_CHECK_EVERY=0
}
# runpipe NAME "stdin" MODE script args...: like run, but stdout goes through a pipe ("| tee"-like reader whose pid the
# stub can kill). MODE out: only stdout is piped, stderr goes to $ERR. MODE both: "2>&1 |". CBT_TTY stands in for /dev/tty.
runpipe() {
  local name="$1" input="$2" mode="$3"; shift 3
  STUB_DIR="$TMP/$name/state"; RESDIR="$TMP/$name/res"; mkdir -p "$STUB_DIR" "$RESDIR"
  OUT="$TMP/$name/piped.txt"; ERR="$TMP/$name/err.txt"; TTYF="$TMP/$name/tty.txt"; : > "$ERR"; : > "$TTYF"
  export STUB_DIR RESULTS_DIR="$RESDIR" CBT_TTY="$TTYF"
  if [ "$mode" = both ]; then
    { printf '%b' "$input" | "$@" 2>&1 | sh -c 'echo $$ > "$STUB_DIR/reader.pid"; exec cat' > "$OUT"; RC=${PIPESTATUS[1]}; } 2>/dev/null
  else
    { printf '%b' "$input" | "$@" 2>"$ERR" | sh -c 'echo $$ > "$STUB_DIR/reader.pid"; exec cat' > "$OUT"; RC=${PIPESTATUS[1]}; } 2>/dev/null
  fi   # 2>/dev/null: bash's "Terminated" job notice for the killed reader
  unset CBT_TTY
  RES="$(ls "$RESDIR"/results-*.txt 2>/dev/null | head -n 1)"; [ -n "$RES" ] || RES=/dev/null
}
# between FILE A B: some line matching B lies between the first and the second line matching A
between() {
  local a1 a2
  a1=$(grep -n -- "$2" "$1" | sed -n 1p | cut -d: -f1); a2=$(grep -n -- "$2" "$1" | sed -n 2p | cut -d: -f1)
  [ -n "$a1" ] && [ -n "$a2" ] && grep -n -- "$3" "$1" | cut -d: -f1 | while read -r b; do [ "$b" -gt "$a1" ] && [ "$b" -lt "$a2" ] && echo y; done | grep -q y
}
# none_after FILE A B: no line matching B comes after the first line matching A (and A exists)
none_after() {
  local a; a=$(grep -n -- "$2" "$1" | head -n 1 | cut -d: -f1)
  [ -n "$a" ] && ! tail -n +"$((a + 1))" "$1" | grep -q -- "$3"
}
before() { # FILE PATTERN_A PATTERN_B: first line matching A comes before first line matching B
  local a b
  a=$(grep -n -- "$2" "$1" | head -n 1 | cut -d: -f1); b=$(grep -n -- "$3" "$1" | head -n 1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
secs_between() { # RESULTS TEST MIN MAX: the SECONDS= value of that TEST line lies in [MIN, MAX]
  local v; v=$(grep "TEST=$2 " "$1" | head -n 1 | sed -n 's/.*SECONDS=\(-\{0,1\}[0-9]*\).*/\1/p')
  [ -n "$v" ] && [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]
}
after_has() { sed -n "/$2/,\$p" "$1" | grep -q -- "$3"; }
count_is() { [ "$(grep -c -- "$2" "$1")" = "$3" ]; }
T="$root/test-disable-enable.sh"; F="$root/flood.sh"; FT="$root/flood-test.sh"

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
check "site 200 after restore" has "$RES" 'TEST=site_http RESULT=PASS'
check "alarm reset PASS" has "$RES" 'TEST=alarm_reset RESULT=PASS'
check "distribution ends enabled" test "$(state enabled)" = true
check "alarm ends OK" test "$(state alarm)" = OK
check "restore used If-Match" has "$STUB_DIR/calls.log" 'update-distribution.*--if-match ETAG1'
check "log group read from the function (auto-style name)" has "$STUB_DIR/calls.log" 'get-function-configuration --function-name fake-stack-BrakeFunction-AbC123xyz.*LoggingConfig.LogGroup'
check "logs read from the configured group" has "$STUB_DIR/calls.log" 'filter-log-events --log-group-name /aws/lambda/fake-stack-brake '
check "logs: the CLI paginates (no --no-paginate), no --query, capped by --max-items 2000" hasnot "$STUB_DIR/calls.log" 'filter-log-events.*\(--no-paginate\|--query\)'
check "logs: --max-items 2000 given" has "$STUB_DIR/calls.log" 'filter-log-events .*--max-items 2000'
check "alarm history: --max-records 100, no --start-date (window filtered in jq)" has "$STUB_DIR/calls.log" 'describe-alarm-history .*--max-records 100'
check "alarm history: no --start-date" hasnot "$STUB_DIR/calls.log" 'describe-alarm-history.*--start-date'
check "alarm history seconds sane" secs_between "$RES" alarm_history -2 120
check "site host checked against the distribution" has "$STUB_DIR/calls.log" 'cloudfront get-distribution --id EFAKETEST1234 --output json'
check "alarm read before it is forced" before "$STUB_DIR/calls.log" describe-alarms 'set-alarm-state.*ALARM'
check "forced alarm reset BEFORE the restore" before "$STUB_DIR/calls.log" 'state-value OK' update-distribution
check "curl follows redirects and uses --globoff" has "$STUB_DIR/calls.log" '^curl -s -L --globoff'
check "results file is private (mode 600)" test "$(ls -l "$RES" | cut -c1-10)" = "-rw-------"
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


echo "stub no longer hides: timestamp offsets"
for off in +05:30 -08:00 Z +00:00; do
  export STUB_ACTION=Disable STUB_TS_OFFSET=$off
  run "off$off" 'DISABLE 1234\n\n' "$T"
  check "history offset $off parsed, seconds sane" secs_between "$RES" alarm_history -2 120
done
reset_env

echo "stub no longer hides: log group"
export STUB_ACTION=Disable STUB_LG_ANSWER=None
run lgfallback 'DISABLE 1234\n\n' "$T"
check "falls back to /aws/lambda/<stack>-brake" has "$RES" 'TEST=lambda_log RESULT=PASS'
check "says it fell back" has "$OUT" 'could not read'
export STUB_LOG_GROUP=/aws/lambda/some-custom-group
run lgwrong 'DISABLE 1234\n\n' "$T"
check "wrong group is a FAIL" has "$RES" 'TEST=lambda_log RESULT=FAIL'
check "AWS error is printed, not swallowed" has "$OUT" 'ResourceNotFoundException'
check "FAIL: raw response goes to the results file as comment lines" has "$RES" '^# lambda_log, raw response'
check "FAIL: raw response is shown on screen" has "$OUT" '^# lambda_log, raw response'
unset STUB_LG_ANSWER
run lgcustom 'DISABLE 1234\n\n' "$T"
check "custom log group found through the function config" has "$RES" 'TEST=lambda_log RESULT=PASS'
reset_env

echo "long Lambda log (head closes the pipe)"
export STUB_ACTION=AlertOnly STUB_LOG_LINES=8000
run biglog '\n' "$T"
check "exit 0 despite SIGPIPE risk" test "$RC" = 0
check "lambda_log PASS" has "$RES" 'TEST=lambda_log RESULT=PASS'
reset_env

echo "alarm must be OK first"
export STUB_ACTION=Disable STUB_ALARM_INIT=ALARM
run alarmbad 'DISABLE 1234\n' "$T"
check "refuses" test "$RC" -ne 0
check "says the alarm is not OK" has "$OUT" 'not OK'
check "alarm never forced" hasnot "$STUB_DIR/calls.log" set-alarm-state
check "distribution untouched" hasnot "$STUB_DIR/calls.log" update-distribution
export STUB_ALARM_INIT=INSUFFICIENT_DATA
run alarmdata 'DISABLE 1234\n' "$T"
check "INSUFFICIENT_DATA refused too" test "$RC" -ne 0
reset_env

echo "site pre-check"
export STUB_ACTION=Disable STUB_INIT_ENABLED=false
run pre403 'DISABLE 1234\n' "$T"
check "refuses when site is not healthy" test "$RC" -ne 0
check "prints the restore command" has "$OUT" -e '--restore-only'
check "nothing changed" hasnot "$STUB_DIR/calls.log" 'set-alarm-state\|update-distribution'
reset_env; export STUB_ACTION=AlertOnly STUB_CURL_CODE=301
run pre301 '\n' "$T"
check "301 is refused by default" test "$RC" -ne 0
EXPECT_CODE=301 run pre301ok '\n' "$T"
check "EXPECT_CODE=301 accepted" test "$RC" = 0
check "site check uses EXPECT_CODE after restore" has "$RES" 'TEST=site_http RESULT=PASS.*HTTP 301'
reset_env

echo "forced alarm reverts (Lambda logs 'not confirmed')"
export STUB_ACTION=Disable STUB_REVERT=1
run revert1 'DISABLE 1234\n\n' "$T"
check "retried and passed" has "$RES" 'TEST=enabled_false RESULT=PASS'
check "alarm forced twice" count_is "$STUB_DIR/calls.log" 'set-alarm-state.*--state-value ALARM' 2
check "exit 0" test "$RC" = 0
export STUB_REVERT=9
run revert9 'DISABLE 1234\n\n' "$T"
check "INCONCLUSIVE, not FAIL" has "$RES" 'TEST=enabled_false RESULT=INCONCLUSIVE'
check "Disable mode INCONCLUSIVE exits 4" test "$RC" = 4
check "lambda_log INCONCLUSIVE with hint" has "$RES" "TEST=lambda_log RESULT=INCONCLUSIVE.*not confirmed"
check "no FAIL anywhere" hasnot "$RES" 'RESULT=FAIL'
check "gave up after ATTEMPTS=3" count_is "$STUB_DIR/calls.log" 'set-alarm-state.*--state-value ALARM' 3
check "distribution still enabled" test "$(state enabled)" = true
export STUB_ACTION=AlertOnly
run revertalert '\n' "$T"
check "alert-only INCONCLUSIVE" has "$RES" 'TEST=alertonly_stays_enabled RESULT=INCONCLUSIVE'
check "alert-only INCONCLUSIVE still exits 0" test "$RC" = 0
reset_env

echo "SITE_URL checks"
SITE_URL='https://blog.fake-host.example@evil.example' run at '' "$T"
check "'@' in SITE_URL exit 2" test "$RC" = 2
export STUB_ACTION=Disable STUB_ALIAS=other.example
run alias 'DISABLE 1234\n' "$T"
check "host not an alias of the distribution: refused" test "$RC" -ne 0
check "alarm never touched" hasnot "$STUB_DIR/calls.log" set-alarm-state
reset_env; export STUB_ACTION=AlertOnly
SITE_URL=https://dfaketest.cloudfront.net run cfdomain '\n' "$T"
check "distribution domain name accepted" test "$RC" = 0
check "cloudfront domain not in output" hasnot "$OUT" dfaketest
reset_env

echo "restore: PreconditionFailed is retried with a fresh ETag"
export STUB_INIT_ENABLED=false STUB_PRECOND_ONCE=1
run precond '' "$T" --restore-only
check "ends enabled" test "$(state enabled)" = true
check "second update used the new ETag" has "$STUB_DIR/calls.log" 'update-distribution.*--if-match ETAG2'
check "two update calls" count_is "$STUB_DIR/calls.log" '^cloudfront update-distribution' 2
reset_env

echo "exit trap order and hint"
export STUB_ACTION=Disable STUB_INT=1
run introrder 'DISABLE 1234\n' "$T"
check "hint printed before the restore starts" before "$OUT" 'restore-only' 'Restore: enabling'
check "forced alarm reset before the restore" before "$STUB_DIR/calls.log" 'state-value OK' update-distribution
check "on_exit ignores INT TERM HUP" grep -q "trap '' INT TERM HUP" "$root/lib.sh"
reset_env
export STUB_ACTION=Disable STUB_FAIL_NTH=get-distribution:2
STACK_NAME="fake stack" run quote 'DISABLE 1234\n' "$T" --no-auto-restore
check "restore hint is shell-quoted (printf %q)" has "$OUT" 'STACK_NAME=fake\\ stack'
reset_env

echo "redaction of AWS errors and dry-run text"
export STUB_ACTION=Disable STUB_FAIL_NTH=get-distribution:2
d="$(printf '%s%s' 1234 56789012)"
run errredact 'DISABLE 1234\n' "$T"
check "AWS stderr shown" has "$OUT" 'simulated failure'
check "account id redacted in stderr" hasnot "$OUT" "$d"
check "arn redacted in stderr" hasnot "$OUT" 'arn:aws'
check "cloudfront domain redacted in stderr" hasnot "$OUT" 'dfaketest'
reset_env
run dryredact '' "$T" --dry-run
check "dry-run text hides the site host" hasnot "$OUT" 'fake-host.example'
run dryfloodredact '' "$F" --dry-run
check "flood dry-run text hides the site host" hasnot "$OUT" 'fake-host.example'

echo ".gitignore"
check "results-*.txt ignored" grep -q '^results-\*\.txt' "$root/../.gitignore"

echo "flood"
export STUB_ACTION=Disable STUB_THRESHOLD=10 STUB_FLOOD_AT=10 N=20 BATCH=5
run flood 'DISABLE 1234\n\n' "$F"
check "exit 0" test "$RC" = 0
check "sent N requests" has "$RES" 'TEST=flood_sent RESULT=PASS.*20 requests sent'
check "alarm_in_alarm PASS" has "$RES" 'TEST=alarm_in_alarm RESULT=PASS'
check "enabled_false PASS" has "$RES" 'TEST=enabled_false RESULT=PASS'
check "waited for alarm OK" has "$RES" 'TEST=alarm_back_to_ok RESULT=PASS'
check "site 200 after restore" has "$RES" 'TEST=site_http RESULT=PASS'
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

echo "flood guards"
export STUB_ACTION=AlertOnly STUB_THRESHOLD=10 N=20 BATCH=5
STUB_THRESHOLD='' run thrempty '' "$F"
check "empty RequestsPer5Min: exit 2" test "$RC" = 2
check "no request sent" hasnot "$STUB_DIR/calls.log" 'cbt='
STUB_THRESHOLD=abc run thrabc '' "$F"
check "non-numeric RequestsPer5Min: exit 2" test "$RC" = 2
N=2001 run ncap '' "$F"
check "N above 2000: exit 2" test "$RC" = 2
BATCH=51 run bcap '' "$F"
check "BATCH above 50: exit 2" test "$RC" = 2
N=500 run nbig '' "$F"
check "N above 3 x threshold + 100: refused" test "$RC" -ne 0
check "no request sent" hasnot "$STUB_DIR/calls.log" 'cbt='
STUB_ALARM_INIT=ALARM run floodalarm '' "$F"
check "alarm not OK: refused before traffic" test "$RC" -ne 0
check "no request sent" hasnot "$STUB_DIR/calls.log" 'cbt='
STUB_ALIAS=other.example run floodalias '' "$F"
check "host not in distribution: refused" test "$RC" -ne 0
check "no request sent" hasnot "$STUB_DIR/calls.log" 'cbt='
SITE_URL='https://blog.fake-host.example@evil.example' run floodat '' "$F"
check "'@' in SITE_URL: exit 2" test "$RC" = 2
STUB_FLOOD_AT=10 SITE_URL='https://blog.fake-host.example/blog/?x=1#frag' run floodpath '\n' "$F"
check "path kept, query dropped, cbt added" has "$STUB_DIR/calls.log" 'blog.fake-host.example/blog/?cbt=r'
check "original query not in requests" hasnot "$STUB_DIR/calls.log" 'x=1/?cbt'
check "flood curls use --globoff" has "$STUB_DIR/calls.log" 'curl -s --globoff -o /dev/null'
echo "flood: first restore attempt fails, exit trap retries"
export STUB_ACTION=Disable STUB_FLOOD_AT=10 STUB_FAIL_NTH=update-distribution:1
run floodrestore 'DISABLE 1234\n\n' "$F"
check "trap restored after the failed restore" test "$(state enabled)" = true
check "says it is restoring again" has "$OUT" 'restoring the distribution'
unset N BATCH; reset_env

echo "redaction"
d="$(printf '%s%s%s' 1234 5678 9012)"
out="$(DIST_ID=EXYZ99 SITE_HOST=my.host.example bash -c ". '$root/lib.sh'; DIST_ID=EXYZ99 SITE_HOST=my.host.example; redact 'acct $d arn:aws:iam::$d:role/r id EXYZ99 host my.host.example ts 1789000000000'")"
check "account id removed" test "${out#*"$d"}" = "$out"
check "arn removed" test "${out#*arn:aws}" = "$out"
check "distribution id removed" test "${out#*EXYZ99}" = "$out"
check "host removed" test "${out#*my.host.example}" = "$out"
out2="$(DIST_ID=X SITE_HOST=y bash -c ". '$root/lib.sh'; redact 'domain d111abcdef8.cloudfront.net and www.example.com'")"
check "cloudfront domain removed" test "${out2#*cloudfront.net}" = "$out2"
check "other domains kept" has <(echo "$out2") www.example.com
check "13-digit timestamp kept" has <(echo "$out") 1789000000000

echo "round 3 (1): piped stdout, the reader dies (SIGPIPE must not kill the restore)"
export STUB_ACTION=Disable STUB_INT=INT STUB_KILL_READER=1
runpipe pipeint 'DISABLE 1234\n' out "$T"
check "Ctrl-C with '| reader': exit 130" test "$RC" = 130
check "restore still ran: distribution enabled" test "$(state enabled)" = true
check "forced alarm reset" test "$(state alarm)" = OK
check "restore recorded in the results file" has "$RES" 'TEST=restore_deployed RESULT=PASS'
check "hint printed on stderr" has "$ERR" -e '--restore-only'
check "restore messages on stderr" has "$ERR" 'Restore: enabling'
export STUB_INT=TERM
runpipe pipeterm 'DISABLE 1234\n' both "$T"
check "TERM with '2>&1 | reader': exit 143" test "$RC" = 143
check "restore still ran: distribution enabled" test "$(state enabled)" = true
check "hint printed on the terminal (both pipes dead)" has "$TTYF" -e '--restore-only'
check "summary printed on the terminal" has "$TTYF" 'TEST=restore_deployed RESULT=PASS'
export STUB_INT=READER
runpipe pipereader 'DISABLE 1234\n' out "$T"
check "reader dies alone: run stops with exit 1" test "$RC" = 1
check "restore still ran: distribution enabled" test "$(state enabled)" = true
check "hint printed on stderr" has "$ERR" -e '--restore-only'
export STUB_INT=INT STUB_FLOOD_AT=10 STUB_THRESHOLD=10 N=20 BATCH=5
unset STUB_INT; export STUB_SIG=INT STUB_SIG_AT=describe-alarms:4
runpipe pipeflood 'DISABLE 1234\n' out "$F"
check "flood: Ctrl-C with '| reader': exit 130" test "$RC" = 130
check "flood: distribution enabled" test "$(state enabled)" = true
check "flood: hint printed on stderr" has "$ERR" -e '--restore-only'
unset N BATCH; reset_env
check "on_exit ignores SIGPIPE" grep -q "trap '' PIPE" "$root/lib.sh"
check "README: do not pipe, use tmux" grep -q 'Do not pipe the output' "$root/README.md"

echo "round 3 (2): --restore-only and aliases"
export STUB_ALIAS=other.example STUB_INIT_ENABLED=false
run aliasrestore '' "$T" --restore-only
check "restore-only with a non-matching alias: exit 0" test "$RC" = 0
check "warns about the alias" has "$OUT" 'WARNING: SITE_URL host is not'
check "restored the stack's distribution" test "$(state enabled)" = true
reset_env; export STUB_INIT_ENABLED=false STUB_FAIL_NTH=get-distribution:1
run aliasread '' "$T" --restore-only
check "restore-only: unreadable distribution is only a warning" has "$OUT" 'WARNING: cannot read the distribution'
check "and the restore ran" test "$(state enabled)" = true
reset_env; export STUB_ACTION=AlertOnly STUB_ALIAS='*.fake-host.example'
run wildcard '\n' "$T"
check "wildcard alias matches one label: accepted" test "$RC" = 0
export STUB_ALIAS='*.host.example'
run wildcard2 '\n' "$T"
check "wildcard alias does not match two labels: refused" test "$RC" -ne 0
check "  and nothing was forced" hasnot "$STUB_DIR/calls.log" set-alarm-state
reset_env
hm() { bash -c ". '$root/lib.sh'; rm -rf \"\$WORK\"; host_matches '$1' '$2'"; }
check "host_matches exact" hm blog.example.com blog.example.com
check "host_matches *.example.com / blog.example.com" hm '*.example.com' blog.example.com
check "host_matches *.example.com / a.b.example.com is no" eval '! hm "*.example.com" a.b.example.com'
check "host_matches *.example.com / example.com is no" eval '! hm "*.example.com" example.com'
check "host_matches *.example.com / blogexample.com is no" eval '! hm "*.example.com" blogexample.com'

echo "round 3 (3): do not undo a real brake trip"
export STUB_ACTION=Disable STUB_INIT_ENABLED=false
run showfirst 'DISABLE 1234\n' "$T"
check "alarm state shown before the site pre-check" before "$OUT" 'Alarm state now' 'site answered HTTP'
check "all stack alarms read before the site is checked" before "$STUB_DIR/calls.log" 'describe-alarms --alarm-names fake-stack-RequestsAlarm-X fake-stack-BytesAlarm-Y' '^curl'
check "pre-check hint says the brake may have tripped for real" has "$OUT" 'tripped for REAL'
export STUB_ALARM_INIT=ALARM STUB_ALARM_REASON='Threshold Crossed: 1 datapoint'
run guardno '' "$T" --restore-only
check "real ALARM, no phrase: exit 3" test "$RC" = 3
check "  distribution left disabled" test "$(state enabled)" = false
check "  no update-distribution" hasnot "$STUB_DIR/calls.log" update-distribution
check "  says the brake may have tripped for real" has "$OUT" 'tripped for REAL'
run guardwrong 'yes\n' "$T" --restore-only
check "real ALARM, wrong phrase: exit 3, left disabled" test "$RC" = 3 -a "$(state enabled)" = false
run guardok 'RESTORE 1234\n' "$T" --restore-only
check "real ALARM, phrase typed: restored" test "$(state enabled)" = true
check "  override recorded" has "$RES" 'TEST=restore_guard RESULT=OVERRIDDEN'
check "  real alarm never touched" hasnot "$STUB_DIR/calls.log" set-alarm-state
run guardforce '' "$T" --restore-only --force
check "real ALARM, --force: restored without asking" test "$(state enabled)" = true -a "$RC" = 0
check "  no phrase prompt" hasnot "$OUT" 'type exactly'
reset_env; export STUB_INIT_ENABLED=false STUB_BYTES_ALARM=ALARM STUB_BYTES_REASON='Threshold Crossed'
run guardbytes '' "$T" --restore-only
check "bytes alarm in real ALARM also guards: exit 3" test "$RC" = 3 -a "$(state enabled)" = false
reset_env; export STUB_INIT_ENABLED=false STUB_ALARM_INIT=ALARM STUB_ALARM_REASON='cost-brake-test 2026-10-08T10:00:00Z: manual test'
run guardours '' "$T" --restore-only
check "our own forced ALARM: no question, restored" test "$(state enabled)" = true -a "$RC" = 0
check "  our alarm reset to OK" test "$(state alarm)" = OK
reset_env; export STUB_INIT_ENABLED=false STUB_FAIL_NTH=describe-alarms:1
run guardunknown '' "$T" --restore-only
check "alarm state unreadable: asks, exit 3 without phrase" test "$RC" = 3 -a "$(state enabled)" = false
reset_env
run forcealone '' "$T" --force
check "--force without --restore-only: exit 2" test "$RC" = 2

echo "round 3 (4): ATTEMPTS cap, alarm re-checked before each retry"
ATTEMPTS=6 run att6 '' "$T"; check "ATTEMPTS=6 refused (exit 2)" test "$RC" = 2
ATTEMPTS=0 run att0 '' "$T"; check "ATTEMPTS=0 refused (exit 2)" test "$RC" = 2
export STUB_ACTION=Disable STUB_REVERT=1
run retrycheck 'DISABLE 1234\n\n' "$T"
check "alarm read between the first and the second forcing" between "$STUB_DIR/calls.log" 'set-alarm-state.*--state-value ALARM' 'describe-alarms'
export STUB_REAL_AFTER_REVERT=1
run retryreal 'DISABLE 1234\n\n' "$T"
check "real ALARM before the retry: stops (non-zero)" test "$RC" -ne 0
check "  forced only once" count_is "$STUB_DIR/calls.log" 'set-alarm-state.*--state-value ALARM' 1
check "  no restore (nothing of ours to undo)" hasnot "$STUB_DIR/calls.log" update-distribution
check "  real alarm not reset" hasnot "$STUB_DIR/calls.log" 'state-value OK'
check "  says it may be a real trip" has "$OUT" 'tripped for REAL'
reset_env

echo "round 3 (5): exit code 4 is documented"
check "README documents exit code 4" grep -q '| `4` |' "$root/README.md"

echo "round 3 (6): WAIT_CHECK cleared in on_exit"
export STUB_ACTION=Disable STUB_QUERY_LAG=1 STUB_SIG=INT STUB_SIG_AT=get-distribution-config:1
run waitclr 'DISABLE 1234\n' "$T"
check "Ctrl-C during the poll: exit 130" test "$RC" = 130
check "restored" test "$(state enabled)" = true
check "restore poll does not read the Lambda log" none_after "$STUB_DIR/calls.log" update-distribution filter-log-events
check "on_exit clears WAIT_CHECK" grep -q 'WAIT_CHECK=""     # the restore' "$root/lib.sh"
reset_env

echo "round 3 (7): TIMEOUT default 900"
run dryto '' env -u TIMEOUT "$T" --dry-run
check "test-disable-enable.sh default TIMEOUT 900" has "$OUT" 'up to 900s'
run drytof '' env -u TIMEOUT "$F" --dry-run
check "flood.sh default TIMEOUT 900" has "$OUT" 'up to 900s'
check "README: TIMEOUT 900 for both" grep -q '| `TIMEOUT` | 900 |' "$root/README.md"

echo "round 3 (8): README IAM policy"
check "DescribeAlarms + DescribeAlarmHistory in their own statement on *" grep -q '"Action": \["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"\], "Resource": "\*"' "$root/README.md"
check "SetAlarmState still scoped to the alarm" grep -q '"Action": "cloudwatch:SetAlarmState"' "$root/README.md"
check "log group placeholder is the LoggingConfig.LogGroup value" grep -q 'log-group:<LoggingConfig.LogGroup value>:\*' "$root/README.md"
check "no guessed log group name in the policy" hasnot "$root/README.md" 'log-group:/aws/lambda/<stack-name>-brake'
check "WAF and Lambda@Edge note" grep -q 'Lambda@Edge' "$root/README.md"

echo "round 3 (9): Lambda log polled at most every LOG_CHECK_EVERY, missing group is quiet"
export STUB_ACTION=Disable STUB_LAMBDA=off LOG_CHECK_EVERY=30
run throttle 'DISABLE 1234\n\n' "$T"
check "many distribution polls" test "$(grep -c 'DistributionConfig.Enabled' "$STUB_DIR/calls.log")" -gt 5
check "no log reads during the poll, only LOG_TRIES=2 for the evidence" count_is "$STUB_DIR/calls.log" 'filter-log-events' 2
export LOG_CHECK_EVERY=0 STUB_LG_LAZY=1
run lazylg 'DISABLE 1234\n\n' "$T"
check "log group not there yet: polled anyway" test "$(grep -c 'filter-log-events' "$STUB_DIR/calls.log")" -gt 2
check "  but quiet while polling (only the 2 evidence tries print it)" test "$(grep -c 'ResourceNotFoundException' "$OUT")" = 2
reset_env

echo "evidence: pagination (empty first page with nextToken), AWS errors, raw response"
export STUB_ACTION=Disable
run pagedisable 'DISABLE 1234\n\n' "$T"
check "real behavior stub: lambda_log still PASS" has "$RES" 'TEST=lambda_log RESULT=PASS'
check "  alarm_history PASS with the -05:00 offset (default)" has "$RES" 'TEST=alarm_history RESULT=PASS'
check "  no raw dump on success" hasnot "$RES" 'raw response'
# the stub's old-style call must not work: --no-paginate gives an empty first page
printf '%s\t%s\n' "$(( $(date +%s) * 1000 ))" "[INFO] disabled distribution EFAKETEST1234 (alarm x)" > "$TMP/ev.events"
mkdir -p "$TMP/pg/state"; cp "$TMP/ev.events" "$TMP/pg/state/events"
pgout="$(STUB_DIR="$TMP/pg/state" aws --region us-east-1 logs filter-log-events --log-group-name /aws/lambda/fake-stack-brake --start-time 0 --no-paginate --output json)"
check "stub: --no-paginate returns an empty first page with nextToken" test "$(jq -r '(.events | length | tostring) + (.nextToken // "-")' <<<"$pgout")" = "0tok-page-2"
pgout="$(STUB_DIR="$TMP/pg/state" aws --region us-east-1 logs filter-log-events --log-group-name /aws/lambda/fake-stack-brake --start-time 0 --max-items 2000 --output json)"
check "stub: without it the pages are merged" test "$(jq -r '.events | length' <<<"$pgout")" = 1
export STUB_HIST_FAIL=1
run histfail 'DISABLE 1234\n\n' "$T"
check "AWS error text printed (redacted)" has "$OUT" 'AccessDenied'
check "  no account id on screen" hasnot "$OUT" "$(printf '%s%s' 1234 56789012)"
check "  alarm_history INCONCLUSIVE" has "$RES" 'TEST=alarm_history RESULT=INCONCLUSIVE'
check "  raw response written to the results file as comments" has "$RES" '^# alarm_history, raw response'
check "  error text in the results file, redacted" has "$RES" '^# .*AccessDenied'
check "  no account id in the results file" hasnot "$RES" "$(printf '%s%s' 1234 56789012)"
check "  Disable mode INCONCLUSIVE exits 4" test "$RC" = 4
check "  the rest of the run still restored" test "$(state enabled)" = true
reset_env

echo "--evidence-only (read-only)"
SE=$(( $(date +%s) - 600 ))
isoz() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SINCE_ISO="$(isoz "$SE")"
evsetup() { # NAME: pre-seed the fake log group (one old matching line, one unrelated line, the real line) and the alarm history
  mkdir -p "$TMP/$1/state"
  {
    printf '%s\t%s\n' "$(( (SE - 3000) * 1000 ))" "[INFO] disabled distribution EFAKETEST1234 (alarm older-run)"
    printf '%s\t%s\n' "$(( (SE + 3) * 1000 ))" "[INFO] unrelated filler line"
    printf '%s\t%s\n' "$(( (SE + 7) * 1000 + 250 ))" "[INFO] disabled distribution EFAKETEST1234 (alarm fake-stack-RequestsAlarm-X)"
  } > "$TMP/$1/state/events"
}
export STUB_ACTION=Disable STUB_HIST_AT=$((SE + 4))
evsetup ev1
run ev1 '' env -u SITE_URL "$T" --evidence-only --since "$SINCE_ISO"
check "exit 0 (SITE_URL not needed)" test "$RC" = 0
check "alarm_history PASS, 4 s after --since (not the older entry)" secs_between "$RES" alarm_history 4 4
check "lambda_log PASS, 7 s after --since (not the older run)" secs_between "$RES" lambda_log 7 7
check "TEST= lines printed" has "$OUT" 'TEST=lambda_log RESULT=PASS SECONDS=7'
check "matching log line shown" has "$OUT" 'disabled distribution'
check "  non-matching lines not shown" hasnot "$OUT" 'unrelated filler'
check "  distribution id redacted in the shown line" hasnot "$OUT" EFAKETEST1234
check "no write call: no set-alarm-state, update-distribution" hasnot "$STUB_DIR/calls.log" 'set-alarm-state\|update-distribution'
check "no cloudfront call at all, no curl" hasnot "$STUB_DIR/calls.log" 'cloudfront\|^curl'
check "only reads: stack, function config, history, logs" test "$(cut -d' ' -f1,2 "$STUB_DIR/calls.log" | sort -u | tr '\n' ',')" = "cloudformation describe-stacks,cloudwatch describe-alarm-history,lambda get-function-configuration,logs filter-log-events,"
check "alarm history: no --start-date, --max-records 100" has "$STUB_DIR/calls.log" 'describe-alarm-history .*--max-records 100'
check "logs: --start-time is exactly --since (no slack)" has "$STUB_DIR/calls.log" "filter-log-events .*--start-time $((SE * 1000)) "
check "distribution untouched" test "$(state enabled)" = true
check "no state or distribution files written by the stub" test ! -e "$STUB_DIR/alarm" -a ! -e "$STUB_DIR/pending"
check "results file records the mode" has "$RES" '^# mode=evidence-only since='
UNTIL_ISO="$(isoz $((SE + 5)))"
evsetup ev2
run ev2 '' env -u SITE_URL "$T" --evidence-only --since "$SINCE_ISO" --until "$UNTIL_ISO"
check "--until: history inside the window still found" secs_between "$RES" alarm_history 4 4
check "--until: log line after the window is excluded: FAIL" has "$RES" 'TEST=lambda_log RESULT=FAIL'
check "--until: end time passed to the log call" has "$STUB_DIR/calls.log" "filter-log-events .*--end-time $(((SE + 5) * 1000))"
check "--until: FAIL exits 1" test "$RC" = 1
check "--until: raw response in the results file" has "$RES" '^# lambda_log, raw response'
evsetup ev3
run ev3 '' env -u SITE_URL "$T" --evidence-only --since "$(isoz $((SE + 5)))"
check "history before --since is not counted (the 4 s entry is before; the hour-old one too): INCONCLUSIVE" has "$RES" 'TEST=alarm_history RESULT=INCONCLUSIVE'
check "  evidence step shows the raw history" has "$RES" '^# alarm_history, raw response'
check "  exit 4" test "$RC" = 4
export STUB_ACTION=AlertOnly
evsetup ev4; printf '%s\t%s\n' "$(( (SE + 9) * 1000 ))" "[INFO] AlertOnly: would disable EFAKETEST1234 (alarm fake)" >> "$TMP/ev4/state/events"
run ev4 '' "$T" --evidence-only --since "$SINCE_ISO"
check "AlertOnly stack: looks for the AlertOnly line" secs_between "$RES" lambda_log 9 9
run ev5 '' "$T" --evidence-only
check "--evidence-only without --since: exit 2" test "$RC" = 2
run ev6 '' "$T" --evidence-only --since yesterday
check "bad --since: exit 2" test "$RC" = 2
run ev7 '' "$T" --evidence-only --since 2026-10-08T18:43:00+05:00
check "non-UTC --since: exit 2" test "$RC" = 2
run ev8 '' "$T" --since "$SINCE_ISO"
check "--since without --evidence-only: exit 2" test "$RC" = 2
run ev9 '' "$T" --evidence-only --since "$SINCE_ISO" --until "$(isoz $((SE - 5)))"
check "--until before --since: exit 2" test "$RC" = 2
run ev10 '' "$T" --evidence-only --restore-only --since "$SINCE_ISO"
check "--evidence-only with --restore-only: exit 2" test "$RC" = 2
check "none of the refusals called AWS" test ! -s "$STUB_DIR/calls.log"
check "README documents --evidence-only" grep -q -- '--evidence-only --since' "$root/README.md"
check "README has the pagination note" grep -q 'nextToken' "$root/README.md"
reset_env

echo "flood-test.sh (lower threshold, flood, restore)"
export STUB_ACTION=AlertOnly STUB_FLOOD_AT=10 N=20 BATCH=5 THRESHOLD=10 STUB_EXTRA_PARAMS=1
tcalls() { grep -c "cloudformation update-stack" "$STUB_DIR/calls.log"; }
run ftdry '' "$FT" --dry-run
check "dry-run: exit 0" test "$RC" = 0
check "dry-run: no update-stack, wait, set-alarm-state or request" hasnot "$STUB_DIR/calls.log" 'update-stack\|cloudformation wait\|set-alarm-state\|^curl'
check "dry-run: only reads (describe-stacks, get-distribution, get-metric-statistics)" test "$(grep -vc 'describe-stacks\|cloudfront get-distribution --id\|cloudwatch get-metric-statistics' "$STUB_DIR/calls.log")" = 0
check "dry-run: shows the 24 h peak" has "$OUT" 'Busiest 5 minutes, last 24 h \. 4 requests'
check "dry-run: no curl at all" hasnot "$STUB_DIR/calls.log" '^curl'
check "dry-run: prints the lowering call with the other parameters UsePreviousValue" has "$OUT" 'ParameterKey=RequestsPer5Min,ParameterValue=10 ParameterKey=DistributionId,UsePreviousValue=true ParameterKey=ActionOnTrip,UsePreviousValue=true ParameterKey=AlertEmail,UsePreviousValue=true ParameterKey=ApiSecretToken,UsePreviousValue=true ParameterKey=MonthlyBudgetUsd,UsePreviousValue=true'
check "dry-run: prints the restore call with the original value" has "$OUT" 'ParameterKey=RequestsPer5Min,ParameterValue=10000 '
check "dry-run: --use-previous-template and CAPABILITY_IAM shown" has "$OUT" '--use-previous-template --capabilities CAPABILITY_IAM'
check "dry-run: shows current threshold, action, last 4 only" has "$OUT" 'RequestsPer5Min now \.* 10000'
check "dry-run: distribution id not shown in full" hasnot "$OUT" EFAKETEST1234
check "dry-run: no values of other parameters printed" test "$(grep -c 'alerts@example.invalid\|\*\*\*\*' "$OUT")" = 0
check "dry-run: no results file" test "$RES" = /dev/null

run ftphrase 'yes\n' "$FT"
check "wrong phrase: exit 3" test "$RC" = 3
check "wrong phrase: nothing written" test "$(tcalls)" = 0
check "wrong phrase: no flood request" hasnot "$STUB_DIR/calls.log" 'cbt='
check "wrong phrase: site and alarm were checked first (nothing changed yet)" has "$STUB_DIR/calls.log" '^curl -s -L'
check "wrong phrase: no results file, no restore" test "$RES" = /dev/null

run ftok 'FLOOD 1234\n\n' "$FT"
check "normal: exit 0" test "$RC" = 0
check "normal: threshold_lowered PASS" has "$RES" 'TEST=threshold_lowered RESULT=PASS'
check "normal: threshold_restored PASS" has "$RES" 'TEST=threshold_restored RESULT=PASS'
check "normal: flood.sh lines in the summary (flood_sent, alarm_in_alarm)" has "$RES" 'TEST=alarm_in_alarm RESULT=PASS'
check "normal: flood_sent in the summary" has "$RES" 'TEST=flood_sent RESULT=PASS'
check "normal: summary printed with the flood lines before the threshold lines" after_has "$OUT" 'Summary (' 'TEST=flood_sent'
check "normal: summary order flood_sent, threshold_lowered, threshold_restored" test "$(grep -n 'TEST=\(flood_sent\|threshold_lowered\|threshold_restored\) ' "$OUT" | tail -n 3 | sed 's/.*TEST=\([a-z_]*\) .*/\1/' | tr '\n' ' ')" = "threshold_lowered flood_sent threshold_restored "
check "normal: two update-stack calls" test "$(tcalls)" = 2
check "normal: first update-stack lowers to 10, others UsePreviousValue" has "$STUB_DIR/calls.log" 'update-stack --stack-name fake-stack --use-previous-template --capabilities CAPABILITY_IAM --parameters ParameterKey=RequestsPer5Min,ParameterValue=10 ParameterKey=DistributionId,UsePreviousValue=true'
check "normal: second update-stack restores 10000" has "$STUB_DIR/calls.log" 'ParameterKey=RequestsPer5Min,ParameterValue=10000 ParameterKey=DistributionId'
check "normal: both updates waited for" test "$(grep -c 'cloudformation wait stack-update-complete' "$STUB_DIR/calls.log")" = 2
check "normal: threshold in the stack is back" test "$(cat "$STUB_DIR/threshold")" = 10000
check "normal: lowered before the flood, restored after" before "$STUB_DIR/calls.log" 'ParameterValue=10 ' 'cbt='
check "normal: restore after the last request" none_after "$STUB_DIR/calls.log" 'ParameterValue=10000' 'cbt='
check "normal: flood.sh ran with --leave-disabled" has "$OUT" 'flood.sh --leave-disabled'
check "normal: alarm waited OK after the restore (alarm_back_to_ok PASS)" has "$RES" 'TEST=alarm_back_to_ok RESULT=PASS'
check "normal: threshold_restored says Enabled and OK" has "$RES" 'TEST=threshold_restored RESULT=PASS.*distribution Enabled, alarm OK'
check "normal: results header has the peak" has "$RES" '^# mode=flood-test.*peak_5min_24h=4'
check "normal: flood.sh results kept in a sub folder" ls "$RESDIR"/flood-*/results-*.txt
check "normal: results private" test "$(ls -l "$RES" | cut -c1-10)" = "-rw-------"
check "normal: no distribution id or site host in results" test "$(grep -c 'EFAKETEST1234\|fake-host.example' "$RES")" = 0

echo "flood-test.sh, Disable mode: two phrases, site comes back, threshold back"
export STUB_ACTION=Disable
run ftdisable 'FLOOD 1234\nDISABLE 1234\n\n' "$FT"
check "disable: exit 0" test "$RC" = 0
check "disable: site back" test "$(state enabled)" = true
check "disable: threshold back" test "$(cat "$STUB_DIR/threshold")" = 10000
check "disable: restored PASS" has "$RES" 'TEST=threshold_restored RESULT=PASS'
check "disable: warns the site goes down" has "$OUT" 'THE SITE GOES DOWN'
run ftdisable2 'FLOOD 1234\nnope\n' "$FT"
check "disable: wrong second phrase: forwards flood.sh exit 3" test "$RC" = 3
check "disable: wrong second phrase: threshold still restored" test "$(cat "$STUB_DIR/threshold")" = 10000
check "disable: wrong second phrase: no flood request sent" hasnot "$STUB_DIR/calls.log" 'cbt='
export STUB_ACTION=AlertOnly

echo "flood-test.sh, failure inside flood.sh"
STUB_FAIL_NTH=describe-alarms:4 run ftfail 'FLOOD 1234\n\n' "$FT"
check "flood.sh fails: its exit code is forwarded (1)" test "$RC" = 1
check "flood.sh fails: threshold restored" test "$(cat "$STUB_DIR/threshold")" = 10000
check "flood.sh fails: threshold_restored PASS" has "$RES" 'TEST=threshold_restored RESULT=PASS'
check "flood.sh fails: lowered then restored (2 updates)" test "$(tcalls)" = 2

echo "flood-test.sh, Ctrl-C during the flood"
STUB_FLOOD_AT=1000 STUB_SIG=INT STUB_SIG_AT=describe-alarms:6 run ftint 'FLOOD 1234\n\n' "$FT"
check "Ctrl-C: exit 130" test "$RC" = 130
check "Ctrl-C: threshold restored" test "$(cat "$STUB_DIR/threshold")" = 10000
check "Ctrl-C: the flood had started" has "$STUB_DIR/calls.log" 'cbt='
check "Ctrl-C: says it is putting everything back" has "$OUT" 'putting everything back now'
check "Ctrl-C: restore proven (PASS)" has "$RES" 'TEST=threshold_restored RESULT=PASS'
STUB_FLOOD_AT=1000 STUB_SIG=TERM STUB_SIG_AT=describe-alarms:6 run ftterm 'FLOOD 1234\n\n' "$FT"
check "SIGTERM: exit 143 and threshold restored" test "$RC" = 143 -a "$(cat "$STUB_DIR/threshold")" = 10000
STUB_FLOOD_AT=1000 STUB_SIG=INT STUB_SIG_AT=describe-alarms:6 STUB_KILL_READER=1 runpipe ftpipe 'FLOOD 1234\n\n' out "$FT"
check "Ctrl-C with a dying '| reader': threshold restored" test "$(cat "$STUB_DIR/threshold")" = 10000

echo "flood-test.sh, update-stack fails"
STUB_UPDATE_FAIL_FROM=1 run ftupfail 'FLOOD 1234\n\n' "$FT"
check "update fails: non-zero exit" test "$RC" -ne 0
check "update fails: clear message" has "$OUT" 'update-stack failed.*RequestsPer5Min was not changed'
check "update fails: flood.sh never ran" hasnot "$STUB_DIR/calls.log" 'cbt='
check "update fails: threshold_lowered FAIL" has "$RES" 'TEST=threshold_lowered RESULT=FAIL'
check "update fails: nothing to restore (SKIPPED, no second update-stack)" has "$RES" 'TEST=threshold_restored RESULT=SKIPPED'
check "update fails: only the one failed update-stack call" test "$(tcalls)" = 1
check "update fails: no wait for the stack (would hang on a stack that never updated)" hasnot "$STUB_DIR/calls.log" 'cloudformation wait'
check "update fails: no TEST=threshold_restored FAIL" hasnot "$RES" 'threshold_restored RESULT=FAIL'
STUB_UPDATE_NOCHANGE=1 run ftnochange 'FLOOD 1234\n\n' "$FT"
check "no changes: aborts cleanly, exit 1" test "$RC" = 1
check "no changes: clear message" has "$OUT" 'no changes to perform'
check "no changes: flood.sh never ran" hasnot "$STUB_DIR/calls.log" 'cbt='
STUB_WAIT_FAIL=1 run ftwaitfail 'FLOOD 1234\n\n' "$FT"
check "lowering wait fails (rollback): exit non-zero, no flood" test "$RC" -ne 0 -a "$(grep -c 'cbt=' "$STUB_DIR/calls.log")" = 0
check "lowering wait fails: threshold_lowered FAIL" has "$RES" 'TEST=threshold_lowered RESULT=FAIL'
check "lowering wait fails: rollback put back the ORIGINAL value (stub), so no restore update" test "$(cat "$STUB_DIR/threshold")" = 10000 -a "$(tcalls)" = 1
check "lowering wait fails: threshold_restored SKIPPED (never changed)" has "$RES" 'TEST=threshold_restored RESULT=SKIPPED'
check "lowering wait fails: exit 1, not 5" test "$RC" = 1
STUB_THRESHOLD=10 run ftsame 'FLOOD 1234\n\n' "$FT"
check "already at the low value: refuses before any change" test "$RC" -ne 0 -a "$(tcalls)" = 0
STUB_STACK_STATUS=UPDATE_IN_PROGRESS run ftbusy 'FLOOD 1234\n\n' "$FT"
check "stack busy: refuses before any change" test "$RC" -ne 0 -a "$(tcalls)" = 0

echo "flood-test.sh, restore fails"
STUB_UPDATE_FAIL_FROM=2 run ftrestorefail 'FLOOD 1234\n\n' "$FT"
check "restore fails: exit 5 (flood.sh itself passed)" test "$RC" = 5
check "restore fails: threshold_lowered PASS" has "$RES" 'TEST=threshold_lowered RESULT=PASS'
check "restore fails: threshold_restored FAIL" has "$RES" 'TEST=threshold_restored RESULT=FAIL'
check "restore fails: loud warning" has "$OUT" 'WARNING: RequestsPer5Min COULD NOT BE PUT BACK'
check "restore fails: exact manual command printed after the warning" after_has "$OUT" 'COULD NOT BE PUT BACK' 'update-stack --region us-east-1 --stack-name fake-stack --use-previous-template --capabilities CAPABILITY_IAM --parameters ParameterKey=RequestsPer5Min,ParameterValue=10000 ParameterKey=DistributionId,UsePreviousValue=true.*MonthlyBudgetUsd,UsePreviousValue=true'
check "restore fails: it tried RESTORE_TRIES=5 times (1 lowering + 5)" test "$(tcalls)" = 6
check "restore fails: the stack really is still lowered (what the warning says)" test "$(cat "$STUB_DIR/threshold")" = 10
STUB_FAIL_NTH=update-stack:2 run ftretry 'FLOOD 1234\n\n' "$FT"
check "restore: one transient failure, second attempt works" test "$RC" = 0 -a "$(cat "$STUB_DIR/threshold")" = 10000
check "restore: retry noted on screen with the backoff" has "$OUT" 'Restore attempt 1 of 5 failed (update-stack failed); trying again in 0s'
STUB_UPDATE_FAIL_FROM=2 STUB_FAIL_NTH=describe-alarms:4 run ftbothfail 'FLOOD 1234\n\n' "$FT"
check "flood.sh fails AND restore fails: exit 5 (not flood.sh's 1), warning shown" test "$RC" = 5 && has "$OUT" 'COULD NOT BE PUT BACK'

echo "flood-test.sh, input checks"
THRESHOLD=20 run ftthr '' "$FT"
check "THRESHOLD >= N: exit 2, no AWS call" test "$RC" = 2 -a ! -s "$STUB_DIR/calls.log"
THRESHOLD=abc run ftthr2 '' "$FT"
check "THRESHOLD not a number: exit 2" test "$RC" = 2
N=500 run ftbign '' "$FT"
check "N above 3 x THRESHOLD + 100: exit 2" test "$RC" = 2
REGION=eu-west-1 run ftreg '' "$FT"
check "other region: exit 2" test "$RC" = 2
env -u STACK_NAME bash -c "'$FT'" >/dev/null 2>&1; check "STACK_NAME required" test "$?" -ne 0
SITE_URL=http://blog.fake-host.example run ftsite '' "$FT"
check "http SITE_URL: exit 2" test "$RC" = 2
STUB_ALIAS=other.example run ftalias '' "$FT"
check "host not in distribution: refused, no update" test "$RC" -ne 0 -a "$(tcalls)" = 0
STUB_ACTION=Foo run ftact '' "$FT"
check "unknown ActionOnTrip: refused, no update" test "$RC" -ne 0 -a "$(tcalls)" = 0
run fthelp '' "$FT" --help
check "--help documents THRESHOLD" has "$OUT" 'THRESHOLD'
check "README has the All in one section" grep -q '^## All in one' "$root/README.md"
check "README IAM mentions UpdateStack and the wait" grep -q 'cloudformation:UpdateStack' "$root/README.md"
check "no secrets or values of other parameters in the script" hasnot "$FT" 'ParameterValue=\$\(' 
unset N BATCH THRESHOLD; reset_env

echo "round 6 (HIGH 1a): THRESHOLD must be at least 2 x the busiest 5 minutes of the last 24 h"
export STUB_ACTION=AlertOnly STUB_FLOOD_AT=10 N=20 BATCH=5 THRESHOLD=10 STUB_EXTRA_PARAMS=1
run pk1 'FLOOD 1234\n\n' "$FT"
check "peak 4, THRESHOLD 10: runs, exit 0" test "$RC" = 0
check "peak read with the documented call (us-east-1 stub, Requests, DistributionId + Region=Global, 300 s, Sum)" has "$STUB_DIR/calls.log" '^cloudwatch get-metric-statistics --namespace AWS/CloudFront --metric-name Requests --dimensions Name=DistributionId,Value=EFAKETEST1234 Name=Region,Value=Global --start-time .* --end-time .* --period 300 --statistics Sum'
check "peak read before any update-stack" before "$STUB_DIR/calls.log" get-metric-statistics update-stack
check "default: no stack policy in update-stack" hasnot "$STUB_DIR/calls.log" 'stack-policy'
STUB_PEAK=6 run pk6 'FLOOD 1234\n\n' "$FT"
check "peak 6 > THRESHOLD 10 / 2: refused (exit 1), no update-stack" test "$RC" = 1 -a "$(tcalls)" = 0
check "  says which THRESHOLD is needed" has "$OUT" 'Use THRESHOLD >= 12'
check "  no flood request" hasnot "$STUB_DIR/calls.log" 'cbt='
STUB_PEAK=5 run pk5 'FLOOD 1234\n\n' "$FT"
check "THRESHOLD exactly 2 x peak (5): accepted" test "$RC" = 0
STUB_PEAK=5.5 run pkfrac 'FLOOD 1234\n\n' "$FT"
check "fractional peak 5.5 is rounded up (6): refused" test "$RC" = 1 -a "$(tcalls)" = 0
STUB_PEAK=6 run pkdry '' "$FT" --dry-run
check "dry-run refuses too (exit 1) and shows the peak" test "$RC" = 1 && has "$OUT" 'Busiest 5 minutes, last 24 h \. 6 requests'
STUB_PEAK=none run pknone 'FLOOD 1234\n\n' "$FT"
check "no datapoints: refused without FORCE_NO_PEAK (exit 1, no update)" test "$RC" = 1 -a "$(tcalls)" = 0
check "  tells about FORCE_NO_PEAK=1" has "$OUT" 'FORCE_NO_PEAK=1'
STUB_PEAK_FAIL=1 run pkfail 'FLOOD 1234\n\n' "$FT"
check "peak unreadable (AccessDenied): refused (exit 1, no update)" test "$RC" = 1 -a "$(tcalls)" = 0
check "  AWS error printed" has "$OUT" 'GetMetricStatistics operation'
check "  account id redacted" hasnot "$OUT" "$(printf '%s%s' 1234 56789012)"
STUB_PEAK_FAIL=1 FORCE_NO_PEAK=1 run pkforce 'FLOOD 1234\n\n' "$FT"
check "FORCE_NO_PEAK=1 with an unreadable peak: goes on, exit 0" test "$RC" = 0
check "  warns" has "$OUT" 'FORCE_NO_PEAK=1 is set'
check "  results header says the peak is unknown" has "$RES" 'peak_5min_24h=unknown (FORCE_NO_PEAK=1)'
STUB_PEAK=6 FORCE_NO_PEAK=1 run pkforce2 'FLOOD 1234\n\n' "$FT"
check "FORCE_NO_PEAK=1 does not override a peak that was read" test "$RC" = 1 -a "$(tcalls)" = 0
FORCE_NO_PEAK=yes run pkbad '' "$FT"
check "FORCE_NO_PEAK=yes: exit 2" test "$RC" = 2
THRESHOLD=10 N=10 run pkn '' "$FT"
check "N must stay above THRESHOLD: exit 2" test "$RC" = 2
check "README: peak rule, FORCE_NO_PEAK and cloudwatch:GetMetricStatistics" grep -q 'FORCE_NO_PEAK' "$root/README.md"
check "README: GetMetricStatistics permission" grep -q 'cloudwatch:GetMetricStatistics' "$root/README.md"

echo "round 6 (HIGH 1): refuses before any change when the site is down or the alarm is not OK"
STUB_INIT_ENABLED=false run ftdown 'FLOOD 1234\n\n' "$FT"
check "distribution disabled at the start: refused, no update-stack" test "$RC" -ne 0 -a "$(tcalls)" = 0
check "  says it may be a real trip" has "$OUT" 'tripped for REAL'
STUB_ALARM_INIT=ALARM STUB_ALARM_REASON='Threshold Crossed' run ftalarm 'FLOOD 1234\n\n' "$FT"
check "alarm in ALARM at the start: refused, no update-stack" test "$RC" -ne 0 -a "$(tcalls)" = 0

echo "round 6 (HIGH 1b/1c): threshold back BEFORE the site is re-enabled; the end state is verified"
export STUB_ACTION=Disable STUB_ALARM_HOLD_LOW=1
run ord 'FLOOD 1234\nDISABLE 1234\n\n' "$FT"
check "exit 0" test "$RC" = 0
check "flood.sh left the site to flood-test.sh" has "$OUT" 'leave-disabled: the distribution is left as it is'
check "the restore update-stack comes BEFORE update-distribution" before "$STUB_DIR/calls.log" 'ParameterValue=10000' '^cloudfront update-distribution'
check "exactly one update-distribution (no early re-enable by flood.sh)" count_is "$STUB_DIR/calls.log" '^cloudfront update-distribution' 1
check "site enabled at the end" test "$(state enabled)" = true
check "threshold back" test "$(cat "$STUB_DIR/threshold")" = 10000
check "alarm_back_to_ok PASS (it only clears once the threshold is back, in this stub)" has "$RES" 'TEST=alarm_back_to_ok RESULT=PASS'
check "re-enable recorded, site 200" has "$RES" 'TEST=site_http RESULT=PASS'
check "threshold_restored PASS with Enabled and OK" has "$RES" 'TEST=threshold_restored RESULT=PASS.*distribution Enabled, alarm OK'
check "threshold_restored is the last line of the summary" test "$(grep '^TEST=' "$RES" | tail -n 1 | cut -d' ' -f1)" = TEST=threshold_restored
echo "round 6 (HIGH 2): the lifeline is printed again after the lowering"
check "printed after threshold_lowered PASS" after_has "$OUT" 'TEST=threshold_lowered RESULT=PASS' 'COPY THIS NOW'
check "  with the exact restore update-stack (unredacted)" after_has "$OUT" 'TEST=threshold_lowered RESULT=PASS' 'update-stack --region us-east-1 --stack-name fake-stack --use-previous-template --capabilities CAPABILITY_IAM --parameters ParameterKey=RequestsPer5Min,ParameterValue=10000 '
check "  and then the --restore-only command (Disable)" after_has "$OUT" 'TEST=threshold_lowered RESULT=PASS' 'test-disable-enable.sh --restore-only'
check "  mentions the CloudShell idle timeout" has "$OUT" '20-30 minutes without keyboard input'

echo "round 6 (HIGH 1b/1c): the alarm stays in ALARM after the threshold is back (a real trip?)"
export STUB_ALARM_STUCK=1
run stuck 'FLOOD 1234\nDISABLE 1234\n\n' "$FT"
check "exit 5" test "$RC" = 5
check "  NOT re-enabled while the alarm is in ALARM" test "$(state enabled)" = false && hasnot "$STUB_DIR/calls.log" 'cloudfront update-distribution'
check "  threshold back anyway" test "$(cat "$STUB_DIR/threshold")" = 10000
check "  threshold_restored is not PASS" hasnot "$RES" 'threshold_restored RESULT=PASS'
check "  threshold_restored FAIL names the disabled site and the alarm" has "$RES" 'TEST=threshold_restored RESULT=FAIL.*Enabled=false and the alarm is ALARM'
check "  loud warning: site down" has "$OUT" 'THE DISTRIBUTION IS NOT ENABLED'
check "  loud warning: may be a REAL trip" has "$OUT" 'may be a REAL trip'
check "  --restore-only printed after the warning" after_has "$OUT" 'THE DISTRIBUTION IS NOT ENABLED' 'restore-only'
unset STUB_ALARM_STUCK
echo "round 6 (HIGH 1b): restore fails in Disable mode: the site is not re-enabled with the low threshold"
STUB_UPDATE_FAIL_FROM=2 run dfail 'FLOOD 1234\nDISABLE 1234\n\n' "$FT"
check "exit 5" test "$RC" = 5
check "  no update-distribution" hasnot "$STUB_DIR/calls.log" 'cloudfront update-distribution'
check "  says why" has "$OUT" 'NOT re-enabling the distribution: RequestsPer5Min is not back'
check "  commands in order: threshold first, then --restore-only" before "$OUT" '^1\. put RequestsPer5Min back' '^2\. once the requests alarm is OK'
check "  threshold_restored FAIL" has "$RES" 'TEST=threshold_restored RESULT=FAIL'
echo "round 6 (HIGH 1b): Ctrl-C while flood.sh polls (Disable): threshold first, then the site"
STUB_SIG=INT STUB_SIG_AT=get-distribution-config:2 run ordint 'FLOOD 1234\nDISABLE 1234\n\n' "$FT"
check "exit 130" test "$RC" = 130
check "  threshold back and site enabled" test "$(cat "$STUB_DIR/threshold")" = 10000 -a "$(state enabled)" = true
check "  restore update-stack before update-distribution" before "$STUB_DIR/calls.log" 'ParameterValue=10000' '^cloudfront update-distribution'
check "  lifeline printed by the trap" has "$OUT" 'Not finished (exit 130)'
unset STUB_ALARM_HOLD_LOW
export STUB_ACTION=AlertOnly
run aostate 'FLOOD 1234\n\n' "$FT"
check "AlertOnly: end state checked too (alarm waited OK, then PASS)" has "$RES" 'TEST=alarm_back_to_ok RESULT=PASS' && has "$RES" 'TEST=threshold_restored RESULT=PASS'

echo "round 6 (flood.sh --leave-disabled)"
unset THRESHOLD; export STUB_ACTION=Disable STUB_THRESHOLD=10
run fld 'DISABLE 1234\n\n' "$F" --leave-disabled
check "exit 0" test "$RC" = 0
check "  site left disabled, no update-distribution" test "$(state enabled)" = false && hasnot "$STUB_DIR/calls.log" update-distribution
check "  no wait for the alarm in flood.sh" hasnot "$RES" alarm_back_to_ok
STUB_FAIL_NTH=get-distribution:2 run fld2 'DISABLE 1234\n' "$F" --leave-disabled
check "error after the disable: non-zero, and the trap does NOT re-enable" test "$RC" -ne 0 -a "$(state enabled)" = false
check "  no update-distribution" hasnot "$STUB_DIR/calls.log" update-distribution
check "--help documents --leave-disabled" "$F" --help
run fldhelp '' "$F" --help
check "  text" has "$OUT" 'leave-disabled'
unset STUB_THRESHOLD; export THRESHOLD=10 STUB_ACTION=AlertOnly

echo "round 6 (MEDIUM 3): restore retry"
RESTORE_TRIES=2 STUB_UPDATE_FAIL_FROM=2 run rt2 'FLOOD 1234\n\n' "$FT"
check "RESTORE_TRIES=2: 1 lowering + 2 restore calls, exit 5" test "$(tcalls)" = 3 -a "$RC" = 5
RESTORE_TRIES=0 run rt0 '' "$FT"; check "RESTORE_TRIES=0: exit 2" test "$RC" = 2
RESTORE_TRIES=11 run rt11 '' "$FT"; check "RESTORE_TRIES=11: exit 2" test "$RC" = 2
RESTORE_BACKOFF=030 run rtb '' "$FT"; check "RESTORE_BACKOFF=030: exit 2" test "$RC" = 2
check "default 5 tries, 30 s backoff" grep -q 'RESTORE_TRIES="${RESTORE_TRIES:-5}"; RESTORE_BACKOFF="${RESTORE_BACKOFF:-30}"' "$FT"
STUB_FOREIGN_UPDATE=2 run foreign 'FLOOD 1234\n\n' "$FT"
check "another update IN_PROGRESS at the restore: waited, retried, exit 0" test "$RC" = 0 -a "$(cat "$STUB_DIR/threshold")" = 10000
check "  rejected once, then a third update-stack" test "$(tcalls)" = 3
check "  says it waits for the other update" has "$OUT" 'Another update of the stack is in progress: waiting'
check "  waits: lowering, the other update, the restore" count_is "$STUB_DIR/calls.log" 'cloudformation wait stack-update-complete' 3
check "  threshold_restored PASS" has "$RES" 'TEST=threshold_restored RESULT=PASS'
STUB_FOREIGN_UPDATE=1 run foreign1 'FLOOD 1234\n\n' "$FT"
check "another update IN_PROGRESS at the lowering: stops, no flood, nothing to restore" test "$RC" = 1 -a "$(grep -c 'cbt=' "$STUB_DIR/calls.log")" = 0
check "  threshold_restored SKIPPED" has "$RES" 'TEST=threshold_restored RESULT=SKIPPED'

echo "round 6 (MEDIUM 5): the CloudFormation stub behaves like CloudFormation"
SD="$TMP/stubcf/state"; mkdir -p "$SD"   # the stub numbers EVERY update-stack call, rejected ones too
sa() { STUB_DIR="$SD" env -u STUB_EXTRA_PARAMS aws --region us-east-1 cloudformation "$@"; }
sup() { sa update-stack --stack-name fake-stack --use-previous-template --capabilities CAPABILITY_IAM --parameters "ParameterKey=RequestsPer5Min,ParameterValue=$1" ParameterKey=DistributionId,UsePreviousValue=true ParameterKey=ActionOnTrip,UsePreviousValue=true; }
sst() { sa describe-stacks --stack-name fake-stack --output json | jq -r '.Stacks[0].StackStatus + " " + (.Stacks[0].Parameters[] | select(.ParameterKey=="RequestsPer5Min") | .ParameterValue)'; }
sup 50 >/dev/null 2>&1
check "stub: right after update-stack the stack is UPDATE_IN_PROGRESS" test "$(sst)" = "UPDATE_IN_PROGRESS 50"
check "stub: a second update while IN_PROGRESS is rejected" eval '! sup 60'
check "stub: the rejection names the state" eval 'sup 60 2>&1 | grep -q "UPDATE_IN_PROGRESS state and can not be updated"'
check "stub: wait succeeds, UPDATE_COMPLETE 50" eval 'sa wait stack-update-complete --stack-name fake-stack && test "$(sst)" = "UPDATE_COMPLETE 50"'
check "stub: same value again: No updates are to be performed" eval 'sup 50 2>&1 | grep -q "No updates are to be performed"'
STUB_WAIT_FAIL=5 sup 60 >/dev/null 2>&1
check "stub: a failed update makes the wait fail" eval '! sa wait stack-update-complete --stack-name fake-stack'
check "stub: and rolls back to the ORIGINAL value (50, not 60)" test "$(sst)" = "UPDATE_ROLLBACK_COMPLETE 50"
STUB_ROLLBACK_FAILED=6 sup 70 >/dev/null 2>&1
sa wait stack-update-complete --stack-name fake-stack >/dev/null 2>&1
check "stub: UPDATE_ROLLBACK_FAILED is reached" eval 'sst | grep -q "^UPDATE_ROLLBACK_FAILED "'
check "stub: and then update-stack is rejected" eval 'sup 80 2>&1 | grep -q "UPDATE_ROLLBACK_FAILED state"'
STUB_ROLLBACK_FAILED=2 run rbf 'FLOOD 1234\n\n' "$FT"
check "restore ends in UPDATE_ROLLBACK_FAILED: exit 5" test "$RC" = 5
check "  no useless retries (2 update-stack calls)" test "$(tcalls)" = 2
check "  continue-update-rollback hint printed" has "$OUT" 'continue-update-rollback --region us-east-1 --stack-name fake-stack'
check "  threshold_restored FAIL" has "$RES" 'TEST=threshold_restored RESULT=FAIL.*UPDATE_ROLLBACK_FAILED'
STUB_STACK_STATUS=UPDATE_ROLLBACK_FAILED run rbfpre 'FLOOD 1234\n\n' "$FT"
check "stack already UPDATE_ROLLBACK_FAILED: refused before any change, with the hint" test "$RC" = 1 -a "$(tcalls)" = 0 && has "$OUT" 'continue-update-rollback'
STUB_UPDATE_DELAY=6 run delay 'FLOOD 1234\n\n' "$FT"
check "slow update (6 polls): still lowered and restored, exit 0" test "$RC" = 0 -a "$(cat "$STUB_DIR/threshold")" = 10000

echo "round 6 (LOW 6): numbers"
N=020 run lz1 '' "$FT"; check "N=020: exit 2" test "$RC" = 2
THRESHOLD=010 run lz2 '' "$FT"; check "THRESHOLD=010: exit 2" test "$RC" = 2
BATCH=05 run lz3 '' "$FT"; check "BATCH=05: exit 2" test "$RC" = 2
TIMEOUT=0900 run lz4 '' "$FT"; check "TIMEOUT=0900: exit 2" test "$RC" = 2
TIMEOUT=1000000 run lz5 '' "$FT"; check "TIMEOUT with 7 digits: exit 2" test "$RC" = 2
N=0300 run lz6 '' "$F"; check "flood.sh N=0300: exit 2" test "$RC" = 2
TIMEOUT=09 run lz7 '' "$T" --dry-run; check "test-disable-enable.sh TIMEOUT=09: exit 2" test "$RC" = 2
cn() { bash -c ". '$root/lib.sh'; rm -rf \"\$WORK\"; check_number X '$1' ${2:-}" >/dev/null 2>&1; }
check "check_number 0 ok" cn 0
check "check_number 999999 ok" cn 999999
check "check_number 1234567 refused" eval '! cn 1234567'
check "check_number 1234567 with 10 digits allowed ok" cn 1234567 10
check "check_number 007 refused" eval '! cn 007'
check "check_number empty refused" eval '! cn ""'

echo "round 6 (LOW 7): exit 5 wins; STACK_NAME must be a plain name"
SN="s$(printf '%s%s' 1234 56789012)"
STACK_NAME="$SN" run sn12 'FLOOD 1234\n\n' "$FT"
check "the lifeline is not redacted (a stack name with 12 digits stays whole)" has "$OUT" "update-stack --region us-east-1 --stack-name $SN --use-previous-template"
STACK_NAME="arn:aws:cloudformation:us-east-1:$(printf '%s%s' 1234 56789012):stack/fake-stack/x" run snarn '' "$FT"
check "STACK_NAME as an ARN: exit 2, no AWS call" test "$RC" = 2 -a ! -s "$STUB_DIR/calls.log"
check "  says to use the plain name" has "$OUT" 'plain stack name'
STACK_NAME='fake stack' run snsp '' "$FT"; check "STACK_NAME with a space: exit 2" test "$RC" = 2
STACK_NAME='1fake' run sndig '' "$FT"; check "STACK_NAME starting with a digit: exit 2" test "$RC" = 2

echo "round 6 (optional): STACK_POLICY=1"
STACK_POLICY=1 run sp 'FLOOD 1234\n\n' "$FT"
check "exit 0" test "$RC" = 0
check "both update-stack calls carry the policy for RequestsAlarm" count_is "$STUB_DIR/calls.log" 'update-stack .*--stack-policy-during-update-body .*LogicalResourceId/RequestsAlarm' 2
check "  the policy denies Update:* elsewhere and allows Update:Modify on RequestsAlarm" has "$STUB_DIR/calls.log" '"Effect":"Deny","Action":"Update:\*","Principal":"\*","NotResource":"LogicalResourceId/RequestsAlarm"},{"Effect":"Allow","Action":"Update:Modify"'
check "  the printed restore command carries it too" has "$OUT" 'ParameterValue=10000.*' && has "$OUT" 'stack-policy-during-update-body'
STACK_POLICY=2 run sp2 '' "$FT"; check "STACK_POLICY=2: exit 2" test "$RC" = 2

echo "round 6: README"
check "README: CloudShell idle timeout, tmux does not survive it" grep -q 'tmux does not survive' "$root/README.md"
check "README: keep the tab active, or a local or EC2 shell" grep -q 'local or EC2 shell' "$root/README.md"
check "README: copy the printed restore command before starting" grep -q 'copy the printed restore command' "$root/README.md"
check "README: no longer says tmux keeps the run alive" hasnot "$root/README.md" 'keeps the run alive if the browser tab drops'
check "README IAM: PutMetricAlarm on the requests alarm" grep -q 'cloudwatch:PutMetricAlarm' "$root/README.md"
check "README IAM: CAPABILITY_IAM is an acknowledgement" grep -q 'acknowledgement, not a permission' "$root/README.md"
check "README IAM: iam:PassRole only with a RoleARN" grep -q 'iam:PassRole.*RoleARN' "$root/README.md"
check "README IAM: confirm in CloudTrail" grep -q 'CloudTrail' "$root/README.md"
check "README IAM: no more 'close to admin'" hasnot "$root/README.md" 'close to admin'
check "README: exit 5 covers the end state" grep -q '| `5` |.*not Enabled' "$root/README.md"
unset N BATCH THRESHOLD; reset_env

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
