#!/usr/bin/env bash
# run.sh - drives test-disable-enable.sh and flood.sh against a fake aws and curl (tests/bin). No AWS, no network.
# Usage: tests/run.sh      Exit 0 only if every check passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
export PATH="$here/bin:$PATH"
export POLL_INTERVAL=0 ALERT_WAIT=1 TIMEOUT=3 LOG_TRIES=2 EMAIL_PROMPT_TIMEOUT=1 RETRY_PAUSE=3 LOG_CHECK_EVERY=0
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
    STUB_SIG STUB_SIG_AT STUB_QUERY_LAG STUB_KILL_READER STUB_LG_LAZY STUB_REAL_AFTER_REVERT STUB_BYTES_ALARM STUB_BYTES_REASON STUB_ALARM_REASON ATTEMPTS
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
count_is() { [ "$(grep -c -- "$2" "$1")" = "$3" ]; }
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
check "site 200 after restore" has "$RES" 'TEST=site_http RESULT=PASS'
check "alarm reset PASS" has "$RES" 'TEST=alarm_reset RESULT=PASS'
check "distribution ends enabled" test "$(state enabled)" = true
check "alarm ends OK" test "$(state alarm)" = OK
check "restore used If-Match" has "$STUB_DIR/calls.log" 'update-distribution.*--if-match ETAG1'
check "log group read from the function (auto-style name)" has "$STUB_DIR/calls.log" 'get-function-configuration --function-name fake-stack-BrakeFunction-AbC123xyz.*LoggingConfig.LogGroup'
check "logs read from the configured group, no pagination" has "$STUB_DIR/calls.log" 'filter-log-events --log-group-name /aws/lambda/fake-stack-brake .*--no-paginate'
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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
