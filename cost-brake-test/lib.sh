#!/usr/bin/env bash
# lib.sh - shared helpers for test-disable-enable.sh and flood.sh. Sourced, not run.
# Only needs: aws CLI, jq, curl, date. Works with bash 3.2 or newer.

umask 077   # results files and temp files are readable by the owner only

REGION="${REGION:-us-east-1}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"     # seconds between polls
TIMEOUT="${TIMEOUT:-600}"               # seconds to wait for the distribution to change
ALERT_WAIT="${ALERT_WAIT:-120}"         # alert-only scenario: seconds to watch that nothing changes
LOG_TRIES="${LOG_TRIES:-12}"            # tries (POLL_INTERVAL apart) to find evidence in alarm history and Lambda logs
EMAIL_PROMPT_TIMEOUT="${EMAIL_PROMPT_TIMEOUT:-120}"
EXPECT_CODE="${EXPECT_CODE:-200}"       # HTTP status your site answers when healthy (after following redirects)
ATTEMPTS="${ATTEMPTS:-3}"               # forced-alarm attempts when the Lambda says "not confirmed" (1 try + 2 retries)
RETRY_PAUSE="${RETRY_PAUSE:-10}"        # seconds between such attempts
RESULTS_DIR="${RESULTS_DIR:-.}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_FILE="$RESULTS_DIR/results-$STAMP.txt"

FAILS=0 NEED_RESTORE=0 ALARM_FIRED=0 NO_AUTO=0
DIST_ID="" SITE_HOST="" ACTION="" FUNCTION_NAME="" ALARM_REQ="" THRESHOLD=""
W_SEC_FLAG="" W_SEC_DEPLOYED="" LOG_GROUP="" WAIT_CHECK="" CHK_T0="" CHK_PAT=""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cost-brake.XXXXXX")"

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
check_expect_code() { check_number EXPECT_CODE "$EXPECT_CODE"; check_number ATTEMPTS "$ATTEMPTS"; check_number RETRY_PAUSE "$RETRY_PAUSE"; check_number LOG_TRIES "$LOG_TRIES"; if [ "$ATTEMPTS" -lt 1 ]; then echo "ATTEMPTS must be at least 1" >&2; exit 2; fi; }

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

# load_stack: read the cost-protection stack parameters and outputs. Nothing is hardcoded.
load_stack() {
  local j alarms
  j="$(aws_call cloudformation describe-stacks --stack-name "$STACK_NAME" --output json)" || die "cannot read stack $STACK_NAME"
  DIST_ID="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="DistributionId") | .ParameterValue' <<<"$j")"
  ACTION="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="ActionOnTrip") | .ParameterValue' <<<"$j")"
  THRESHOLD="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="RequestsPer5Min") | .ParameterValue' <<<"$j")"
  alarms="$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="AlarmNames") | .OutputValue' <<<"$j")"
  FUNCTION_NAME="$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="FunctionName") | .OutputValue' <<<"$j")"
  ALARM_REQ="${alarms%%,*}"    # first name in AlarmNames is the requests alarm
  case "$DIST_ID" in E[A-Z0-9]*) ;; *) DIST_ID=""; die "stack has no DistributionId parameter (is this the cost-protection stack?)" ;; esac
  case "$ACTION" in Disable|AlertOnly) ;; *) die "ActionOnTrip is '$ACTION', expected Disable or AlertOnly" ;; esac
  if [ -z "$ALARM_REQ" ] || [ -z "$FUNCTION_NAME" ]; then die "stack outputs AlarmNames or FunctionName are missing"; fi
  check_site_matches_distribution
}

# The test hits SITE_URL and judges the distribution from the stack: they must be the same site.
check_site_matches_distribution() {
  local d names n ok=0
  d="$(aws_call cloudfront get-distribution --id "$DIST_ID" --output json)" || die "cannot read the distribution from the stack"
  names="$(jq -r '([.Distribution.DomainName // empty] + (.Distribution.DistributionConfig.Aliases.Items // []))[] | ascii_downcase' <<<"$d")" || die "cannot parse the distribution"
  while IFS= read -r n; do if [ -n "$n" ] && [ "$n" = "$SITE_HOST" ]; then ok=1; fi; done <<<"$names"
  if [ "$ok" != 1 ]; then die "SITE_URL host is neither the domain name nor an alias of the distribution in the stack. Nothing was changed."; fi
}

dist_enabled() { aws_call cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.Enabled' --output text; }
dist_status()  { aws_call cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text; }
alarm_json()   { aws_call cloudwatch describe-alarms --alarm-names "$ALARM_REQ" --output json; }

http_code() { curl -s -L --globoff -o /dev/null -w '%{http_code}' --max-time 15 "$1" || true; }

# precheck_site: the site must answer EXPECT_CODE before we touch anything. Nothing is changed yet, so no auto-restore here;
# but the distribution may be disabled from an earlier run (or a real trip), so the restore command is shown.
precheck_site() {
  local code
  code="$(http_code "$SITE_URL")"
  if [ "$code" != "$EXPECT_CODE" ]; then
    err "site answered HTTP $code before the test, expected $EXPECT_CODE (set EXPECT_CODE if your healthy site answers differently)."
    err "If the distribution was left disabled by an earlier run, restore it first:"
    restore_hint >&2
    exit 1
  fi
}

# require_alarm_ok: never force or flood an alarm that is not OK (a real incident, or no data yet).
require_alarm_ok() {
  local st
  st="$(alarm_json | jq -r '.MetricAlarms[0].StateValue // "MISSING"')" || die "cannot read the requests alarm"
  if [ "$st" != OK ]; then die "the requests alarm is $st, not OK. Nothing was changed. Wait until it is OK (or find out why it is not) and run again."; fi
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
read_logs() { # START_EPOCH: sets LOG_JSON (AWS errors are printed, not swallowed)
  ensure_log_group
  LOG_JSON="$(aws_call logs filter-log-events --log-group-name "$LOG_GROUP" --start-time $((($1 - 1) * 1000)) --no-paginate --query 'events[].[timestamp,message]' --output json)" || LOG_JSON='[]'
}
log_has() { jq -e --arg p "$1" 'map(select(.[1] | test($p))) | length > 0' <<<"$LOG_JSON" >/dev/null 2>&1; }

# lambda_not_confirmed: 0 when the Lambda logged "not confirmed" since CHK_T0 and no line matches CHK_PAT.
# The forced ALARM can revert within about a minute; the Lambda then refuses to act. Not a defect of the brake.
lambda_not_confirmed() {
  read_logs "$CHK_T0"
  if log_has 'not confirmed' && ! log_has "$CHK_PAT"; then return 0; fi
  return 1
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
      # head closes the pipe early on long logs: SIGPIPE must not kill the script (pipefail + set -e)
      jq -r '.[] | "  " + (.[1] | gsub("[\\r\\n]+$"; ""))' <<<"$LOG_JSON" | head -n 15 | while IFS= read -r l; do say "$l"; done || true ;;
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

# on_exit: a second Ctrl-C, SIGTERM or SIGHUP must not interrupt the cleanup, so they are ignored from here on.
# Order: hint first (it is the lifeline), reset our forced alarm, then restore the distribution.
on_exit() {
  local rc=$?
  trap '' INT TERM HUP
  trap - EXIT
  set +e
  exec >&3 2>&4   # a signal can arrive inside "aws_call ... >/dev/null": talk to the real terminal again
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
  if [ "$rc" -eq 0 ] && [ "$FAILS" -gt 0 ]; then rc=1; fi
  exit "$rc"
}
install_traps() { exec 3>&1 4>&2; trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP; }
