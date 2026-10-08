#!/usr/bin/env bash
# lib.sh - shared helpers for test-disable-enable.sh and flood.sh. Sourced, not run.
# Only needs: aws CLI, jq, curl, date. Works with bash 3.2 or newer.

REGION="${REGION:-us-east-1}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"     # seconds between polls
TIMEOUT="${TIMEOUT:-600}"               # seconds to wait for the distribution to change
ALERT_WAIT="${ALERT_WAIT:-120}"         # alert-only scenario: seconds to watch that nothing changes
LOG_TRIES="${LOG_TRIES:-12}"            # tries (POLL_INTERVAL apart) to find evidence in alarm history and Lambda logs
EMAIL_PROMPT_TIMEOUT="${EMAIL_PROMPT_TIMEOUT:-120}"
RESULTS_DIR="${RESULTS_DIR:-.}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTS_FILE="$RESULTS_DIR/results-$STAMP.txt"

FAILS=0 NEED_RESTORE=0 ALARM_FIRED=0 NO_AUTO=0
DIST_ID="" SITE_HOST="" ACTION="" FUNCTION_NAME="" ALARM_REQ="" THRESHOLD=""
W_SEC_FLAG="" W_SEC_DEPLOYED=""
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cost-brake.XXXXXX")"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# redact: account ids (12 digits), ARNs, the distribution id and the site host never reach the screen summary or the results file.
redact() {
  local s="$1"
  if [ -n "$DIST_ID" ]; then s="${s//"$DIST_ID"/<distribution>}"; fi
  if [ -n "$SITE_HOST" ]; then s="${s//"$SITE_HOST"/<site-host>}"; fi
  printf '%s\n' "$s" | sed -E \
    -e 's#arn:aws[a-z-]*:[^[:space:]"]*#<arn>#g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<account-id>\2/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<account-id>\2/g'
}
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

require_tools() {
  local t
  for t in aws jq curl date; do command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 2; }; done
}

check_region() {
  if [ "$REGION" != "us-east-1" ]; then echo "REGION must be us-east-1 (CloudFront metrics and this stack live there), got: $REGION" >&2; exit 2; fi
  AWS=(aws --region "$REGION")
}

check_site_url() {
  case "$SITE_URL" in https://*) ;; *) echo "SITE_URL must start with https://" >&2; exit 2 ;; esac
  local h="${SITE_URL#*://}"; h="${h%%/*}"; SITE_HOST="${h%%:*}"
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

# load_stack: read the cost-protection stack parameters and outputs. Nothing is hardcoded.
load_stack() {
  local j alarms
  j="$("${AWS[@]}" cloudformation describe-stacks --stack-name "$STACK_NAME" --output json)" || die "cannot read stack $STACK_NAME"
  DIST_ID="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="DistributionId") | .ParameterValue' <<<"$j")"
  ACTION="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="ActionOnTrip") | .ParameterValue' <<<"$j")"
  THRESHOLD="$(jq -r '.Stacks[0].Parameters[]? | select(.ParameterKey=="RequestsPer5Min") | .ParameterValue' <<<"$j")"
  alarms="$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="AlarmNames") | .OutputValue' <<<"$j")"
  FUNCTION_NAME="$(jq -r '.Stacks[0].Outputs[]? | select(.OutputKey=="FunctionName") | .OutputValue' <<<"$j")"
  ALARM_REQ="${alarms%%,*}"    # first name in AlarmNames is the requests alarm
  case "$DIST_ID" in E[A-Z0-9]*) ;; *) DIST_ID=""; die "stack has no DistributionId parameter (is this the cost-protection stack?)" ;; esac
  case "$ACTION" in Disable|AlertOnly) ;; *) die "ActionOnTrip is '$ACTION', expected Disable or AlertOnly" ;; esac
  if [ -z "$ALARM_REQ" ] || [ -z "$FUNCTION_NAME" ]; then die "stack outputs AlarmNames or FunctionName are missing"; fi
}

dist_enabled() { "${AWS[@]}" cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.Enabled' --output text; }
dist_status()  { "${AWS[@]}" cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.Status' --output text; }
alarm_json()   { "${AWS[@]}" cloudwatch describe-alarms --alarm-names "$ALARM_REQ" --output json; }

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$1" || true; }

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
# Returns 0 both seen, 1 timeout, 2 API error.
wait_state() {
  local want="$1" start="$2" el en st
  W_SEC_FLAG=""; W_SEC_DEPLOYED=""
  while :; do
    el=$(( $(date +%s) - start ))
    en="$(dist_enabled)" || return 2
    en="$(lower "$en")"
    if [ -z "$W_SEC_FLAG" ] && [ "$en" = "$want" ]; then W_SEC_FLAG=$el; fi
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
alarm_history_seconds() { # START_EPOCH START_ISO -> prints seconds from start to the "to ALARM" history entry, or nothing
  local t="$1" iso="$2" n=0 h ts
  while [ "$n" -lt 6 ]; do
    h="$("${AWS[@]}" cloudwatch describe-alarm-history --alarm-name "$ALARM_REQ" --history-item-type StateUpdate --start-date "$iso" --output json)" || h='{}'
    ts="$(jq -r '[.AlarmHistoryItems[]? | select(.HistorySummary | test("to ALARM")) | .Timestamp | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601] | min // empty' <<<"$h" 2>/dev/null)" || ts=""
    if [ -n "$ts" ]; then echo $((ts - t)); return 0; fi
    n=$((n + 1)); sleep "$POLL_INTERVAL"
  done
  return 1
}

LOG_JSON='[]'
fetch_logs() { # START_EPOCH PATTERN: sets LOG_JSON, returns 0 once a message matches
  local t="$1" pat="$2" n=0
  while :; do
    LOG_JSON="$("${AWS[@]}" logs filter-log-events --log-group-name "/aws/lambda/$FUNCTION_NAME" --start-time $(((t - 1) * 1000)) --query 'events[].[timestamp,message]' --output json)" || LOG_JSON='[]'
    if jq -e --arg p "$pat" 'map(select(.[1] | test($p))) | length > 0' <<<"$LOG_JSON" >/dev/null 2>&1; then return 0; fi
    n=$((n + 1))
    if [ "$n" -ge "$LOG_TRIES" ]; then return 1; fi
    sleep "$POLL_INTERVAL"
  done
}

# collect_evidence START_EPOCH START_ISO LOG_PATTERN
collect_evidence() {
  local t="$1" iso="$2" pat="$3" s first
  if s="$(alarm_history_seconds "$t" "$iso")"; then rec alarm_history PASS "$s" "history entry 'to ALARM' found"
  else rec alarm_history INCONCLUSIVE - "no history entry found yet"; fi
  if fetch_logs "$t" "$pat"; then
    first="$(jq -r --arg p "$pat" '[.[] | select(.[1] | test($p)) | .[0]] | min' <<<"$LOG_JSON")"
    rec lambda_log PASS "$(( first / 1000 - t ))" "log line matching '$pat' found"
    say "Lambda log lines since T0 (first 15):"
    jq -r '.[] | "  " + (.[1] | gsub("[\\r\\n]+$"; ""))' <<<"$LOG_JSON" | head -n 15 | while IFS= read -r l; do say "$l"; done
  else
    rec lambda_log FAIL - "no log line matching '$pat' in /aws/lambda/<function> after $LOG_TRIES tries"
  fi
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
      elif "${AWS[@]}" cloudwatch set-alarm-state --alarm-name "$ALARM_REQ" --state-value OK --state-reason "cost-brake-test: reset after test" >/dev/null; then rec alarm_reset PASS - "alarm set back to OK"
      else rec alarm_reset FAIL - "set-alarm-state OK failed"; fi ;;
    *) rec alarm_reset SKIPPED - "state was not forced by this test, left alone" ;;
  esac
}

# restore_phase: re-enable (read-modify-write with If-Match, like the stack's ReEnableCommand), wait, check the site.
restore_phase() {
  local t0 got etag rc=0 n=0 code=""
  say "Restore: enabling the distribution, then waiting until it is Enabled and Deployed."
  t0="$(date +%s)"
  if ! got="$("${AWS[@]}" cloudfront get-distribution-config --id "$DIST_ID" --output json)"; then
    rec restore_enabled FAIL - "could not read the distribution config"; return 1
  fi
  etag="$(jq -r '.ETag' <<<"$got")"
  if [ "$(jq -r '.DistributionConfig.Enabled' <<<"$got")" = "true" ]; then
    say "Distribution is already Enabled, no update needed."
  else
    jq '.DistributionConfig | .Enabled = true' <<<"$got" > "$WORK/cf.json"
    if ! "${AWS[@]}" cloudfront update-distribution --id "$DIST_ID" --if-match "$etag" --distribution-config "file://$WORK/cf.json" >/dev/null; then
      rec restore_enabled FAIL - "update-distribution failed; use the stack output ReEnableCommand"; return 1
    fi
  fi
  wait_state true "$t0" || rc=$?
  if [ "$rc" -ne 0 ]; then rec restore_enabled FAIL - "restore did not finish (rc=$rc); run again with --restore-only"; return 1; fi
  rec restore_enabled PASS "$W_SEC_FLAG"
  rec restore_deployed PASS "$W_SEC_DEPLOYED"
  while [ "$n" -lt 12 ]; do
    code="$(http_code "$SITE_URL")"
    if [ "$code" = "200" ]; then rec site_http_200 PASS - "HTTP 200"; return 0; fi
    n=$((n + 1)); sleep "$POLL_INTERVAL"
  done
  rec site_http_200 FAIL - "HTTP $code after restore"
  return 1
}

restore_hint() {
  echo "To restore by hand:"
  echo "  STACK_NAME='$STACK_NAME' SITE_URL='<your site url>' ./test-disable-enable.sh --restore-only"
  echo "  or run the stack output ReEnableCommand:"
  echo "  aws cloudformation describe-stacks --region us-east-1 --stack-name '$STACK_NAME' --query \"Stacks[0].Outputs[?OutputKey=='ReEnableCommand'].OutputValue\" --output text"
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM
  set +e
  if [ "$NEED_RESTORE" = 1 ]; then
    NEED_RESTORE=0
    if [ "$NO_AUTO" = 1 ]; then
      echo "Stopped early and --no-auto-restore is set: the distribution may still be DISABLED."
      restore_hint
    else
      echo "Stopped early (exit $rc): restoring the distribution now."
      restore_phase || { echo "Automatic restore did not complete."; restore_hint; }
    fi
  fi
  if [ "$ALARM_FIRED" = 1 ] && [ "$NO_AUTO" != 1 ]; then reset_alarm_if_ours; fi
  if [ -f "$RESULTS_FILE" ]; then echo; echo "Summary ($RESULTS_FILE, redacted):"; grep -v '^#' "$RESULTS_FILE"; fi
  rm -rf "$WORK"
  if [ "$rc" -eq 0 ] && [ "$FAILS" -gt 0 ]; then rc=1; fi
  exit "$rc"
}
install_traps() { trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; }
