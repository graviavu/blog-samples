#!/usr/bin/env bash
# lib.sh - shared helpers for test-disable-enable.sh and flood.sh. Sourced, not run.
# Only needs: aws CLI, jq, curl, date. Works with bash 3.2 or newer.

umask 077   # results files and temp files are readable by the owner only

REGION="${REGION:-us-east-1}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"     # seconds between polls
TIMEOUT="${TIMEOUT:-900}"               # seconds to wait for the distribution to change (CloudFront often needs 5-15 minutes to reach Deployed)
ALERT_WAIT="${ALERT_WAIT:-120}"         # alert-only scenario: seconds to watch that nothing changes
LOG_TRIES="${LOG_TRIES:-12}"            # tries (POLL_INTERVAL apart) to find evidence in alarm history and Lambda logs
EMAIL_PROMPT_TIMEOUT="${EMAIL_PROMPT_TIMEOUT:-120}"
EXPECT_CODE="${EXPECT_CODE:-200}"       # HTTP status your site answers when healthy (after following redirects)
ATTEMPTS="${ATTEMPTS:-3}"               # forced-alarm attempts when the Lambda says "not confirmed" (1 try + 2 retries), at most 5
RETRY_PAUSE="${RETRY_PAUSE:-10}"        # seconds between such attempts
LOG_CHECK_EVERY="${LOG_CHECK_EVERY:-30}" # while polling the distribution, look for "not confirmed" in the Lambda log at most this often
TTY_FALLBACK="${CBT_TTY:-/dev/tty}"     # where the exit messages go if stdout and stderr are both dead pipes (CBT_TTY: for the tests)
RESULTS_DIR="${RESULTS_DIR:-.}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_FILE="$RESULTS_DIR/results-$STAMP.txt"

FAILS=0 INCONCS=0 INCONC_EXIT=0 NEED_RESTORE=0 ALARM_FIRED=0 NO_AUTO=0 FORCE=0 LAST_LOG_CHECK=0 ALARM_VERDICT=unknown
ALARM_ALL=()
DIST_ID="" SITE_HOST="" ACTION="" FUNCTION_NAME="" ALARM_REQ="" THRESHOLD=""
W_SEC_FLAG="" W_SEC_DEPLOYED="" LOG_GROUP="" WAIT_CHECK="" CHK_T0="" CHK_PAT=""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cost-brake.XXXXXX")"
export CBT_MAIN_PID=$$   # pid of the running script; the test stubs use it to send Ctrl-C/TERM at a chosen moment

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# redact: account ids (12 digits), ARNs, *.cloudfront.net domains, the distribution id and the site host never reach the screen summary or the results file.
redact() {
  local s="$1"
  if [ -n "$DIST_ID" ]; then s="${s//"$DIST_ID"/<distribution>}"; fi
  if [ -n "$SITE_HOST" ]; then s="${s//"$SITE_HOST"/<site-host>}"; fi
  printf '%s\n' "$s" | sed -E \
    -e 's#arn:aws[a-z-]*:[^[:space:]"]*#<arn>#g' \
    -e 's/[A-Za-z0-9-]+\.cloudfront\.net/<cloudfront-domain>/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<account-id>\2/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<account-id>\2/g'
}
redact_stream() { local l; while IFS= read -r l; do redact "$l"; done; }
say() { redact "$*"; }
err() { redact "$*" >&2; }
die() { err "ERROR: $*"; exit 1; }

# rec TEST RESULT [SECONDS] [DETAIL]  -> one machine-readable line, printed and appended to the results file
rec() {
  local line="TEST=$1 RESULT=$2 SECONDS=${3:--}" detail="${4:-}"
  if [ -n "$detail" ]; then line="$line DETAIL=\"${detail//\"/\'}\""; fi
  redact "$line" | tee -a "$RESULTS_FILE"
  if [ "$2" = FAIL ]; then FAILS=$((FAILS + 1)); fi
  if [ "$2" = INCONCLUSIVE ]; then INCONCS=$((INCONCS + 1)); fi
}

# aws_call: every AWS CLI call. stdout untouched; stderr is redacted before it reaches the screen
# and the last error text stays in $WORK/aws.err (so callers can look for e.g. PreconditionFailed).
aws_call() {
  local rc=0
  : > "$WORK/aws.err"
  aws --region "$REGION" "$@" 2>"$WORK/aws.err" || rc=$?
  if [ -s "$WORK/aws.err" ]; then redact "$(cat "$WORK/aws.err")" >&2; fi
  return "$rc"
}

require_tools() {
  local t
  for t in aws jq curl date; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done
}

check_region() {
  if [ "$REGION" != "us-east-1" ]; then echo "REGION must be us-east-1 (CloudFront metrics and this stack live there), got: $REGION" >&2; exit 2; fi
}

check_site_url() {
  case "$SITE_URL" in https://*) ;; *) echo "SITE_URL must start with https://" >&2; exit 2 ;; esac
  case "$SITE_URL" in *@*) echo "SITE_URL must not contain '@' (user info can hide the real host)" >&2; exit 2 ;; esac
  case "$SITE_URL" in *[[:space:]]*|*\\*) echo "SITE_URL must not contain spaces or backslashes" >&2; exit 2 ;; esac
  local h="${SITE_URL#*://}"; h="${h%%[/?#]*}"; SITE_HOST="$(lower "${h%%:*}")"
  if [ -z "$SITE_HOST" ]; then echo "SITE_URL has no host" >&2; exit 2; fi
}
check_expect_code() {
  check_number EXPECT_CODE "$EXPECT_CODE"; check_number ATTEMPTS "$ATTEMPTS"; check_number RETRY_PAUSE "$RETRY_PAUSE"
  check_number LOG_TRIES "$LOG_TRIES"; check_number LOG_CHECK_EVERY "$LOG_CHECK_EVERY"
  if [ "$ATTEMPTS" -lt 1 ] || [ "$ATTEMPTS" -gt 5 ]; then echo "ATTEMPTS must be between 1 and 5, got: $ATTEMPTS" >&2; exit 2; fi
}

check_number() { case "$2" in ''|*[!0-9]*) echo "$1 must be a whole number, got: $2" >&2; exit 2 ;; esac; }

init_results() {
  mkdir -p "$RESULTS_DIR"
  {
    echo "# cost-brake-test results, UTC $STAMP"
    echo "# $1"
    echo "# region=$REGION action_on_trip=$ACTION poll_interval=${POLL_INTERVAL}s timeout=${TIMEOUT}s"
    echo "# ids, ARNs, account numbers and the site host are redacted"
  } | while IFS= read -r l; do redact "$l"; done > "$RESULTS_FILE"
}

# load_stack [warn]: read the cost-protection stack parameters and outputs. Nothing is hardcoded.
# With "warn" (--restore-only) a SITE_URL that does not match the distribution is only a warning: the restore targets
# the stack's DistributionId, not SITE_URL.
load_stack() {
  local j alarms
  j="$(aws_call cloudformation describe-stacks --stack-name "$STACK_NAME" --output json)" || die "cannot read stack $STACK_NAME"
  DIST_ID="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="DistributionId") | .ParameterValue' <<<"$j")"
  ACTION="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="ActionOnTrip") | .ParameterValue' <<<"$j")"
  THRESHOLD="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="RequestsPer5Min") | .ParameterValue' <<<"$j")"
  alarms="$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="AlarmNames") | .OutputValue' <<<"$j")"
  FUNCTION_NAME="$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="FunctionName") | .OutputValue' <<<"$j")"
  ALARM_REQ="${alarms%%,*}"    # first name in AlarmNames is the requests alarm
  IFS=, read -r -a ALARM_ALL <<<"$alarms"   # all alarms of the stack (requests and bytes): any of them can trip the brake
  case "$DIST_ID" in E[A-Z0-9]*) ;; *) DIST_ID=""; die "stack has no DistributionId parameter (is this the cost-protection stack?)" ;; esac
  case "$ACTION" in Disable|AlertOnly) ;; *) die "ActionOnTrip is '$ACTION', expected Disable or AlertOnly" ;; esac
  if [ -z "$ALARM_REQ" ] || [ -z "$FUNCTION_NAME" ]; then die "stack outputs AlarmNames or FunctionName are missing"; fi
  check_site_matches_distribution "${1:-}"
}

# host_matches NAME HOST: exact match, or NAME is a wildcard alias (*.example.com) and HOST adds exactly one label to it.
host_matches() {
  local n="$1" h="$2" rest pre
  if [ "$n" = "$h" ]; then return 0; fi
  case "$n" in '*.'?*) ;; *) return 1 ;; esac
  rest="${n#\*}"                      # ".example.com"
  case "$h" in *"$rest") ;; *) return 1 ;; esac
  pre="${h%"$rest"}"
  case "$pre" in ''|*.*) return 1 ;; esac
  return 0
}

# The test hits SITE_URL and judges the distribution from the stack: they must be the same site.
# check_site_matches_distribution [warn]: with "warn" a mismatch (or an unreadable distribution) is reported, not fatal.
check_site_matches_distribution() {
  local mode="${1:-}" d names n ok=0
  if ! d="$(aws_call cloudfront get-distribution --id "$DIST_ID" --output json)"; then
    if [ "$mode" = warn ]; then err "WARNING: cannot read the distribution to compare it with SITE_URL; restoring the stack's distribution anyway."; return 0; fi
    die "cannot read the distribution from the stack"
  fi
  names="$(jq -r '([.Distribution.DomainName // empty] + (.Distribution.DistributionConfig.Aliases.Items // []))[] | ascii_downcase' <<<"$d")" || die "cannot parse the distribution"
  while IFS= read -r n; do if [ -n "$n" ] && host_matches "$n" "$SITE_HOST"; then ok=1; fi; done <<<"$names"
  if [ "$ok" = 1 ]; then return 0; fi
  if [ "$mode" = warn ]; then
    err "WARNING: SITE_URL host is not the domain name or an alias of the stack's distribution. --restore-only re-enables the stack's distribution (DistributionId) anyway; the final site check uses SITE_URL and may fail."
    return 0
  fi
  die "SITE_URL host is neither the domain name nor an alias of the distribution in the stack. Nothing was changed."
}

dist_enabled() { aws_call cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.Enabled' --output text; }
dist_status()  { aws_call cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text; }
alarm_json()   { aws_call cloudwatch describe-alarms --alarm-names "$ALARM_REQ" --output json; }

http_code() { curl -s -L --globoff -o /dev/null -w '%{http_code}' --max-time 15 "$1" || true; }

# show_alarm_state: print the state of every stack alarm before anything is changed, and set ALARM_VERDICT:
#   ok (none in ALARM), ours (in ALARM, forced by this test), real (in ALARM, NOT set by this test), unknown (could not read).
show_alarm_state() {
  local a lines n s w
  ALARM_VERDICT=unknown
  if ! a="$(aws_call cloudwatch describe-alarms --alarm-names "${ALARM_ALL[@]}" --output json)"; then err "WARNING: could not read the alarm state."; return 0; fi
  lines="$(jq -r '.MetricAlarms[]? | [.AlarmName, .StateValue, (if ((.StateReason // "") | test("cost-brake-test")) then "set by this test" else "not set by this test" end)] | @tsv' <<<"$a" 2>/dev/null)" || lines=""
  if [ -z "$lines" ]; then err "WARNING: could not read the alarm state."; return 0; fi
  ALARM_VERDICT=ok
  say "Alarm state now (before anything is changed):"
  while IFS=$'\t' read -r n s w; do
    if [ "$s" = ALARM ]; then
      say "  $n: ALARM ($w)"
      if [ "$w" = "set by this test" ]; then if [ "$ALARM_VERDICT" != real ]; then ALARM_VERDICT=ours; fi; else ALARM_VERDICT=real; fi
    else
      say "  $n: $s"
    fi
  done <<<"$lines"
  if [ "$ALARM_VERDICT" = real ]; then say "WARNING: an alarm is in ALARM and this test did not set it: the cost brake may have tripped for REAL."; fi
}

# guard_restore (--restore-only): do not undo a real brake trip by accident. If an alarm is in ALARM without our marker
# (or the state cannot be read), refuse unless --force was given or the user types RESTORE <last 4 of the distribution id>.
guard_restore() {
  local phrase="RESTORE ${DIST_ID: -4}" reply=""
  case "$ALARM_VERDICT" in ok|ours) return 0 ;; esac
  if [ "$ALARM_VERDICT" = real ]; then
    err "An alarm is in ALARM and this test did not set it. The brake may have tripped for REAL: re-enabling now undoes it and the traffic (and cost) continues."
  else
    err "The alarm state could not be read, so a real brake trip cannot be ruled out."
  fi
  if [ "$FORCE" = 1 ]; then rec restore_guard OVERRIDDEN - "--force given, restoring although alarm state is $ALARM_VERDICT"; return 0; fi
  err "Check the alarm (CloudWatch console) and your traffic first."
  printf 'To restore anyway, type exactly  %s  : ' "$phrase"
  IFS= read -r reply || true
  if [ "$reply" != "$phrase" ]; then echo; echo "Phrase did not match. Nothing was changed."; exit 3; fi
  rec restore_guard OVERRIDDEN - "phrase typed, restoring although alarm state is $ALARM_VERDICT"
}

# precheck_site: the site must answer EXPECT_CODE before we touch anything. Nothing is changed yet, so no auto-restore here:
# the distribution may be disabled by a REAL trip, so we only show how to restore, after the warning.
precheck_site() {
  local code
  code="$(http_code "$SITE_URL")"
  if [ "$code" != "$EXPECT_CODE" ]; then
    err "site answered HTTP $code before the test, expected $EXPECT_CODE (set EXPECT_CODE if your healthy site answers differently)."
    err "The cost brake may have tripped for REAL. Check the alarm state above (and in the CloudWatch console) and your traffic first."
    err "Only if you are sure an earlier test run left the distribution disabled, restore it:"
    restore_hint >&2
    exit 1
  fi
}

# require_alarm_ok: never force or flood an alarm that is not OK (a real incident, or no data yet).
require_alarm_ok() {
  local st
  st="$(alarm_json | jq -r '.MetricAlarms[0].StateValue // "MISSING"')" || die "cannot read the requests alarm"
  if [ "$st" != OK ]; then die "the requests alarm is $st, not OK, so it is not forced (again). Wait until it is OK and run again. If you did not expect this, the brake may have tripped for REAL: check the alarm before restoring anything."; fi
}

# confirm_disable: the site will go down, so the user must type an exact phrase.
confirm_disable() {
  local phrase="DISABLE ${DIST_ID: -4}" reply=""
  say "ActionOnTrip=Disable: this test WILL take the site down (a few minutes) and then bring it back."
  printf 'Type exactly  %s  to continue: ' "$phrase"
  IFS= read -r reply || true
  if [ "$reply" != "$phrase" ]; then echo; echo "Phrase did not match. Nothing was changed."; exit 3; fi
}

# wait_state true|false START_EPOCH
# Polls every POLL_INTERVAL. Sets W_SEC_FLAG (first time Enabled == wanted) and W_SEC_DEPLOYED (then Status == Deployed).
# Returns 0 both seen, 1 timeout, 2 API error, 3 WAIT_CHECK (a function) said stop (Lambda logged "not confirmed").
wait_state() {
  local want="$1" start="$2" el en st
  W_SEC_FLAG=""; W_SEC_DEPLOYED=""
  while :; do
    el=$(( $(date +%s) - start ))
    en="$(dist_enabled)" || return 2
    en="$(lower "$en")"
    if [ -z "$W_SEC_FLAG" ] && [ "$en" = "$want" ]; then W_SEC_FLAG=$el; fi
    if [ -z "$W_SEC_FLAG" ] && [ -n "$WAIT_CHECK" ] && "$WAIT_CHECK"; then return 3; fi
    if [ -n "$W_SEC_FLAG" ]; then
      st="$(dist_status)" || return 2
      if [ "$st" = "Deployed" ]; then W_SEC_DEPLOYED=$el; return 0; fi
    fi
    if [ "$el" -ge "$TIMEOUT" ]; then return 1; fi
    sleep "$POLL_INTERVAL"
  done
}

# watch_stays_enabled START_EPOCH: 0 = stayed Enabled for ALERT_WAIT seconds, 1 = it was disabled (W_SEC_FLAG), 2 = API error
watch_stays_enabled() {
  local start="$1" el en
  W_SEC_FLAG=""
  while :; do
    el=$(( $(date +%s) - start ))
    en="$(dist_enabled)" || return 2
    if [ "$(lower "$en")" = "false" ]; then W_SEC_FLAG=$el; return 1; fi
    if [ "$el" -ge "$ALERT_WAIT" ]; then return 0; fi
    sleep "$POLL_INTERVAL"
  done
}

# wait_alarm STATE START_EPOCH: sets W_SEC_FLAG. 0 reached, 1 timeout, 2 API error.
wait_alarm() {
  local want="$1" start="$2" el st
  W_SEC_FLAG=""
  while :; do
    el=$(( $(date +%s) - start ))
    st="$(alarm_json | jq -r '.MetricAlarms[0].StateValue // "MISSING"')" || return 2
    if [ "$st" = "$want" ]; then W_SEC_FLAG=$el; return 0; fi
    if [ "$el" -ge "$TIMEOUT" ]; then return 1; fi
    sleep "$POLL_INTERVAL"
  done
}

# Evidence from the stack itself. Both are best effort: they lag, so they are retried.
# jq: CloudWatch timestamps come with any offset (Z, +00:00, +05:30, -0800) and optional fractions; convert to epoch seconds.
HIST_JQ='def ep: if type == "number" then . else
    (sub("\\.[0-9]+"; "") | capture("^(?<b>.*?)(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")
     | (.b + "Z" | fromdateiso8601) - (if .z == "Z" then 0 else ((if .z[0:1] == "-" then -1 else 1 end) * ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60)) end)) end;
  [.AlarmHistoryItems[]? | select(.HistorySummary | test("to ALARM")) | .Timestamp | ep] | min // empty'
alarm_history_seconds() { # START_EPOCH START_ISO -> prints seconds from start to the "to ALARM" history entry, or nothing
  local t="$1" iso="$2" n=0 h ts
  while [ "$n" -lt 6 ]; do
    h="$(aws_call cloudwatch describe-alarm-history --alarm-name "$ALARM_REQ" --history-item-type StateUpdate --start-date "$iso" --output json)" || h='{}'
    ts="$(jq -r "$HIST_JQ" <<<"$h" 2>/dev/null)" || ts=""
    if [ -n "$ts" ]; then echo $((ts - t)); return 0; fi
    n=$((n + 1)); sleep "$POLL_INTERVAL"
  done
  return 1
}

# The Lambda log group is NOT /aws/lambda/<FunctionName> (the function name is auto-generated); ask the function.
ensure_log_group() {
  local lg=""
  if [ -n "$LOG_GROUP" ]; then return 0; fi
  lg="$(aws_call lambda get-function-configuration --function-name "$FUNCTION_NAME" --query 'LoggingConfig.LogGroup' --output text)" || lg=""
  case "$lg" in
    ''|None|null) lg="/aws/lambda/${STACK_NAME}-brake"; err "note: could not read the function's log group, trying $lg" ;;
  esac
  LOG_GROUP="$lg"
}

LOG_JSON='[]'
read_logs() { # START_EPOCH [quiet]: sets LOG_JSON. AWS errors are printed, not swallowed; with "quiet" a log group that
  # does not exist yet (created on the first Lambda run) is silent.
  local rc=0
  ensure_log_group
  LOG_JSON="$(aws --region "$REGION" logs filter-log-events --log-group-name "$LOG_GROUP" --start-time $((($1 - 1) * 1000)) --no-paginate --query 'events[].[timestamp,message]' --output json 2>"$WORK/logs.err")" || rc=$?
  if [ "$rc" -ne 0 ]; then LOG_JSON='[]'; fi
  if [ -s "$WORK/logs.err" ]; then
    if [ "${2:-}" = quiet ] && grep -q ResourceNotFoundException "$WORK/logs.err"; then :; else redact "$(cat "$WORK/logs.err")" >&2; fi
  fi
  return 0
}
log_has() { jq -e --arg p "$1" 'map(select(.[1] | test($p))) | length > 0' <<<"$LOG_JSON" >/dev/null 2>&1; }

# lambda_not_confirmed: 0 when the Lambda logged "not confirmed" since CHK_T0 and no line matches CHK_PAT.
# The forced ALARM can revert within about a minute; the Lambda then refuses to act. Not a defect of the brake.
lambda_not_confirmed() {
  read_logs "$CHK_T0" quiet
  if log_has 'not confirmed' && ! log_has "$CHK_PAT"; then return 0; fi
  return 1
}
# lambda_not_confirmed_poll: the same, for WAIT_CHECK inside the 5 s poll loop, but at most every LOG_CHECK_EVERY seconds
# (counted from CHK_T0, so a new attempt waits again): CloudWatch Logs is slow and has API limits.
lambda_not_confirmed_poll() {
  local now base
  now="$(date +%s)"; base="$LAST_LOG_CHECK"
  if [ "$base" -lt "$CHK_T0" ]; then base="$CHK_T0"; fi
  if [ $((now - base)) -lt "$LOG_CHECK_EVERY" ]; then return 1; fi
  LAST_LOG_CHECK="$now"
  lambda_not_confirmed
}

# fetch_logs START_EPOCH PATTERN: sets LOG_JSON. 0 a message matches, 3 only "not confirmed" seen, 1 nothing after LOG_TRIES.
fetch_logs() {
  local t="$1" pat="$2" n=0
  while :; do
    read_logs "$t"
    if log_has "$pat"; then return 0; fi
    if log_has 'not confirmed'; then return 3; fi
    n=$((n + 1))
    if [ "$n" -ge "$LOG_TRIES" ]; then return 1; fi
    sleep "$POLL_INTERVAL"
  done
}

NOT_CONFIRMED_HINT="the Lambda logged 'not confirmed': the forced ALARM went back to OK before its check, so it correctly did nothing. Run again; see README (forced alarm can revert)"

# collect_evidence START_EPOCH START_ISO LOG_PATTERN
collect_evidence() {
  local t="$1" iso="$2" pat="$3" s first rc=0
  if s="$(alarm_history_seconds "$t" "$iso")"; then rec alarm_history PASS "$s" "history entry 'to ALARM' found"
  else rec alarm_history INCONCLUSIVE - "no history entry found yet"; fi
  fetch_logs "$t" "$pat" || rc=$?
  case "$rc" in
    0)
      first="$(jq -r --arg p "$pat" '[.[] | select(.[1] | test($p)) | .[0]] | min' <<<"$LOG_JSON")"
      rec lambda_log PASS "$(( first / 1000 - t ))" "log line matching '$pat' found"
      say "Lambda log lines since T0 (first 15):"
      # jq takes the first 15 itself: no "| head" that closes the pipe early (SIGPIPE is ignored, so jq would complain)
      jq -r '.[:15][] | "  " + (.[1] | gsub("[\\r\\n]+$"; ""))' <<<"$LOG_JSON" | while IFS= read -r l; do say "$l"; done || true ;;
    3) rec lambda_log INCONCLUSIVE - "$NOT_CONFIRMED_HINT" ;;
    *) rec lambda_log FAIL - "no log line matching '$pat' in $LOG_GROUP after $LOG_TRIES tries" ;;
  esac
}

# ask_email_minute START_EPOCH: optional. The user types the UTC minute (HH:MM) the alert email arrived.
ask_email_minute() {
  local t="$1" reply="" h m typed sod diff
  printf 'Optional: type the UTC minute the alert email arrived (HH:MM), or press Enter to skip: '
  if ! IFS= read -r -t "$EMAIL_PROMPT_TIMEOUT" reply; then reply=""; fi
  case "$reply" in
    [0-2][0-9]:[0-5][0-9])
      h=$((10#${reply%%:*})); m=$((10#${reply##*:}))
      typed=$((h * 3600 + m * 60)); sod=$((t % 86400))
      diff=$(( (typed - sod + 86400) % 86400 ))
      rec email_minute MEASURED "$diff" "typed by hand, minute resolution (+/- 60 s)" ;;
    *) rec email_minute SKIPPED - "no minute typed" ;;
  esac
}

# Only reset an alarm that THIS test forced (state reason carries our marker). A real alarm is never touched.
reset_alarm_if_ours() {
  local a st why
  a="$(alarm_json)" || { rec alarm_reset INCONCLUSIVE - "could not read alarm"; return 0; }
  st="$(jq -r '.MetricAlarms[0].StateValue // ""' <<<"$a")"
  why="$(jq -r '.MetricAlarms[0].StateReason // ""' <<<"$a")"
  case "$why" in
    *cost-brake-test*)
      if [ "$st" = "OK" ]; then rec alarm_reset PASS - "alarm already OK"
      elif aws_call cloudwatch set-alarm-state --alarm-name "$ALARM_REQ" --state-value OK --state-reason "cost-brake-test: reset after test" >/dev/null; then rec alarm_reset PASS - "alarm set back to OK"
      else rec alarm_reset FAIL - "set-alarm-state OK failed"; fi ;;
    *) rec alarm_reset SKIPPED - "state was not forced by this test, left alone" ;;
  esac
}

# restore_phase: re-enable (read-modify-write with If-Match, like the stack's ReEnableCommand), wait, check the site.
# If CloudFront answers PreconditionFailed (someone changed the config meanwhile), re-read config and ETag and try again (3 tries).
restore_phase() {
  local t0 got etag rc=0 n=0 tries=0 code="" done_update=0
  say "Restore: enabling the distribution, then waiting until it is Enabled and Deployed."
  t0="$(date +%s)"
  while [ "$done_update" = 0 ]; do
    tries=$((tries + 1))
    if ! got="$(aws_call cloudfront get-distribution-config --id "$DIST_ID" --output json)"; then
      rec restore_enabled FAIL - "could not read the distribution config"; return 1
    fi
    etag="$(jq -r '.ETag' <<<"$got")"
    if [ "$(jq -r '.DistributionConfig.Enabled' <<<"$got")" = "true" ]; then
      say "Distribution is already Enabled, no update needed."; done_update=1
    else
      jq '.DistributionConfig | .Enabled = true' <<<"$got" > "$WORK/cf.json"
      if aws_call cloudfront update-distribution --id "$DIST_ID" --if-match "$etag" --distribution-config "file://$WORK/cf.json" >/dev/null; then
        done_update=1
      elif grep -q PreconditionFailed "$WORK/aws.err" && [ "$tries" -lt 3 ]; then
        say "Config changed meanwhile (PreconditionFailed): reading it again, try $((tries + 1)) of 3."
      else
        rec restore_enabled FAIL - "update-distribution failed; use the stack output ReEnableCommand"; return 1
      fi
    fi
  done
  wait_state true "$t0" || rc=$?
  if [ "$rc" -ne 0 ]; then rec restore_enabled FAIL - "restore did not finish (rc=$rc); run again with --restore-only"; return 1; fi
  rec restore_enabled PASS "$W_SEC_FLAG"
  rec restore_deployed PASS "$W_SEC_DEPLOYED"
  while [ "$n" -lt 12 ]; do
    code="$(http_code "$SITE_URL")"
    if [ "$code" = "$EXPECT_CODE" ]; then rec site_http PASS - "HTTP $code"; return 0; fi
    n=$((n + 1)); sleep "$POLL_INTERVAL"
  done
  rec site_http FAIL - "HTTP $code after restore (expected $EXPECT_CODE)"
  return 1
}

restore_hint() {
  echo "To restore by hand:"
  printf "  STACK_NAME=%q SITE_URL='<your site url>' ./test-disable-enable.sh --restore-only\n" "$STACK_NAME"
  echo "  or run the stack output ReEnableCommand:"
  printf "  aws cloudformation describe-stacks --region us-east-1 --stack-name %q --query \"Stacks[0].Outputs[?OutputKey=='ReEnableCommand'].OutputValue\" --output text\n" "$STACK_NAME"
}

# pick_output: after "exec >&3 2>&4", find an output that still works. With "./x.sh | tee log" a Ctrl-C kills tee too,
# so stdout is a dead pipe: then use stderr, or the terminal, or nothing (but never stop the cleanup).
pick_output() {
  local o=0 e=0
  if { printf '\n' >&3; } 2>/dev/null; then o=1; fi
  if { printf '\n' >&4; } 2>/dev/null; then e=1; fi
  if [ "$o" = 1 ] && [ "$e" = 1 ]; then return 0; fi
  if [ "$o" = 1 ]; then exec 2>&1; return 0; fi
  if [ "$e" = 1 ]; then exec 1>&2; return 0; fi
  if { printf '\n' >>"$TTY_FALLBACK"; } 2>/dev/null; then exec >>"$TTY_FALLBACK" 2>&1; return 0; fi
  exec >/dev/null 2>&1
}

# on_exit: a second Ctrl-C, SIGTERM or SIGHUP must not interrupt the cleanup, so they are ignored from here on,
# and so is SIGPIPE: a dead "| tee" must not kill the restore.
# Order: hint first (it is the lifeline), reset our forced alarm, then restore the distribution.
on_exit() {
  local rc=$?       # must be read before any other command
  trap '' PIPE
  trap '' INT TERM HUP
  trap - EXIT
  set +e
  WAIT_CHECK=""     # the restore's wait_state must not stop on a "not confirmed" log line of the test
  exec >&3 2>&4     # a signal can arrive inside "aws_call ... >/dev/null": talk to the real terminal again
  pick_output
  if [ "$NEED_RESTORE" = 1 ]; then
    NEED_RESTORE=0
    if [ "$NO_AUTO" = 1 ]; then
      echo "Stopped early and --no-auto-restore is set: the distribution may still be DISABLED."
      restore_hint
    else
      echo "Not finished (exit $rc): restoring the distribution now. Do not close this window. If it is cut off:"
      restore_hint
      if [ "$ALARM_FIRED" = 1 ]; then reset_alarm_if_ours; ALARM_FIRED=0; fi
      restore_phase || { echo "Automatic restore did not complete."; restore_hint; }
    fi
  fi
  if [ "$ALARM_FIRED" = 1 ] && [ "$NO_AUTO" != 1 ]; then reset_alarm_if_ours; fi
  if [ -f "$RESULTS_FILE" ]; then echo; echo "Summary ($RESULTS_FILE, redacted):"; grep -v '^#' "$RESULTS_FILE"; fi
  rm -rf "$WORK"
  # exit codes: 0 pass, 1 fail, 4 inconclusive (Disable mode only: the brake was not proven), others see README
  if [ "$rc" -eq 0 ] && [ "$FAILS" -gt 0 ]; then rc=1
  elif [ "$rc" -eq 0 ] && [ "$INCONC_EXIT" = 1 ] && [ "$INCONCS" -gt 0 ]; then rc=4; fi
  exit "$rc"
}
# SIGPIPE is ignored for the whole run: a write to a dead pipe then fails (and set -e ends the run through on_exit,
# which restores) instead of killing the script on the spot with the distribution still disabled.
install_traps() { exec 3>&1 4>&2; trap '' PIPE; trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP; }
