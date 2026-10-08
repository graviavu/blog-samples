#!/usr/bin/env bash
# test-disable-enable.sh - proves the cost brake works end to end: alarm -> SNS -> Lambda -> distribution disabled,
# measures how long each step takes, then restores the distribution and checks the site answers HTTP 200.
#
# Run it in AWS CloudShell (us-east-1), inside tmux, with the minimum rights listed in README.md. It uses only: aws CLI, jq, curl, date.
# WITH ActionOnTrip=Disable THE SITE GOES DOWN FOR SEVERAL MINUTES. With AlertOnly nothing is changed.
#
# Usage:
#   STACK_NAME=<cost-protection stack> SITE_URL=https://<your blog> ./test-disable-enable.sh [options]
# Options:
#   --dry-run          print every command, call nothing, change nothing
#   --restore-only     only re-enable the distribution (use after an interrupted run)
#   --no-auto-restore  on error or Ctrl-C do NOT restore automatically, just print how
# Environment (optional): REGION (us-east-1 only), TIMEOUT (600), POLL_INTERVAL (5), ALERT_WAIT (120), RESULTS_DIR (.),
#   EXPECT_CODE (200, status of your healthy site), LOG_TRIES (12), EMAIL_PROMPT_TIMEOUT (120),
#   ATTEMPTS (3, forced-alarm tries if the Lambda says "not confirmed"), RETRY_PAUSE (10)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

DRY=0 RESTORE_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --restore-only) RESTORE_ONLY=1 ;;
    --no-auto-restore) NO_AUTO=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
  esac
done
: "${STACK_NAME:?STACK_NAME is required (the cost-protection stack)}"
: "${SITE_URL:?SITE_URL is required (e.g. https://blog.example.com)}"
check_region; check_site_url; require_tools
check_number TIMEOUT "$TIMEOUT"; check_number POLL_INTERVAL "$POLL_INTERVAL"; check_number ALERT_WAIT "$ALERT_WAIT"; check_expect_code
install_traps

if [ "$DRY" = 1 ]; then
  cat <<PLAN | redact_stream
DRY RUN: nothing is called or changed. The real run executes, in this order (region $REGION):
+ aws cloudformation describe-stacks --stack-name $STACK_NAME --output json      (reads DistributionId, ActionOnTrip, AlarmNames, FunctionName)
+ aws cloudfront get-distribution --id <distribution id> --output json            (SITE_URL host must be the distribution domain or one of its aliases)
+ curl -s -L --globoff -o /dev/null -w '%{http_code}' $SITE_URL                   (site must answer $EXPECT_CODE before we start)
+ aws cloudwatch describe-alarms --alarm-names <requests alarm>                   (must be OK, otherwise we stop)
  If ActionOnTrip=Disable you must type 'DISABLE <last 4 chars of distribution id>' first.
+ aws cloudwatch set-alarm-state --alarm-name <requests alarm> --state-value ALARM --state-reason 'cost-brake-test ...'
  Disable:   poll every ${POLL_INTERVAL}s up to ${TIMEOUT}s:
+ aws cloudfront get-distribution-config --id <distribution id> --query DistributionConfig.Enabled --output text
+ aws cloudfront get-distribution --id <distribution id> --query Distribution.Status --output text
  AlertOnly: watch ${ALERT_WAIT}s that Enabled stays true (same get-distribution-config call)
+ aws cloudwatch describe-alarm-history --alarm-name <requests alarm> --history-item-type StateUpdate --start-date <T0>
  If the Lambda logs 'not confirmed' (forced alarm reverted), the alarm is forced again, up to $ATTEMPTS attempts in total.
+ aws lambda get-function-configuration --function-name <function name> --query LoggingConfig.LogGroup
+ aws logs filter-log-events --log-group-name <that log group> --start-time <T0> --no-paginate
  (asks for the minute the email arrived, optional)
Restore (also on error or Ctrl-C unless --no-auto-restore):
+ aws cloudfront get-distribution-config --id <distribution id> --output json     (ETag + config)
+ jq '.DistributionConfig | .Enabled = true' > cf.json
+ aws cloudfront update-distribution --id <distribution id> --if-match <ETag> --distribution-config file://cf.json
+ poll until Enabled=true and Status=Deployed, then: curl $SITE_URL  (expect $EXPECT_CODE)
  (if CloudFront answers PreconditionFailed the config and ETag are read again, up to 3 tries)
+ aws cloudwatch set-alarm-state --alarm-name <requests alarm> --state-value OK     (only if this test forced it; done BEFORE the restore)
Writes results-<UTC timestamp>.txt with TEST=... RESULT=... SECONDS=... lines (ids, ARNs, account numbers, site host redacted).
PLAN
  rm -rf "$WORK"; exit 0
fi

load_stack
init_results "mode=$([ "$RESTORE_ONLY" = 1 ] && echo restore-only || echo "$ACTION")"
say "Stack read. Distribution ...${DIST_ID: -4}, ActionOnTrip=$ACTION, requests alarm and Lambda found."

if [ "$RESTORE_ONLY" = 1 ]; then
  reset_alarm_if_ours
  restore_phase || true
  exit 0
fi

precheck_site
require_alarm_ok

if [ "$ACTION" = "AlertOnly" ]; then
  say "Scenario ALERT-ONLY: I will force the requests alarm to ALARM and watch ${ALERT_WAIT}s. Expect: an email, a Lambda log line, and the distribution stays Enabled."
else
  say "Scenario DISABLE: I will force the requests alarm to ALARM. Expect: the Lambda disables the distribution (site down), then I re-enable it."
  confirm_disable
fi

NEED_RESTORE=1; ALARM_FIRED=1       # set before the alarm is touched, so any error from here on triggers the restore
if [ "$ACTION" = "AlertOnly" ]; then PAT='AlertOnly: would disable'; else PAT='disabled distribution'; fi
attempt=1
while :; do
  T0="$(date +%s)"; T0_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "T0 = $T0_ISO (attempt $attempt of $ATTEMPTS)"
  aws_call cloudwatch set-alarm-state --alarm-name "$ALARM_REQ" --state-value ALARM \
    --state-reason "cost-brake-test $T0_ISO: manual test of the cost brake, safe to ignore" >/dev/null
  rec alarm_set PASS 0 "requests alarm forced to ALARM (attempt $attempt)"
  CHK_T0="$T0"; CHK_PAT="$PAT"; rc=0
  if [ "$ACTION" = "AlertOnly" ]; then
    watch_stays_enabled "$T0" || rc=$?
    if [ "$rc" -eq 0 ] && lambda_not_confirmed; then rc=3; fi
  else
    WAIT_CHECK=lambda_not_confirmed
    wait_state false "$T0" || rc=$?
    WAIT_CHECK=""
  fi
  if [ "$rc" -eq 3 ] && [ "$attempt" -lt "$ATTEMPTS" ]; then
    say "The Lambda logged 'not confirmed' (the forced alarm reverted before its check). Forcing it again."
    attempt=$((attempt + 1)); sleep "$RETRY_PAUSE"; continue
  fi
  break
done

if [ "$ACTION" = "AlertOnly" ]; then
  case "$rc" in
    0) rec alertonly_stays_enabled PASS "$ALERT_WAIT" "distribution stayed Enabled for ${ALERT_WAIT}s" ;;
    1) rec alertonly_stays_enabled FAIL "$W_SEC_FLAG" "distribution was DISABLED although ActionOnTrip=AlertOnly" ;;
    3) rec alertonly_stays_enabled INCONCLUSIVE - "stayed Enabled, but $NOT_CONFIRMED_HINT" ;;
    *) die "AWS call failed while watching the distribution" ;;
  esac
else
  case "$rc" in
    0) rec enabled_false PASS "$W_SEC_FLAG" "Enabled=false seen"
       rec disable_deployed PASS "$W_SEC_DEPLOYED" "Status=Deployed after the disable" ;;
    1) if [ -n "$W_SEC_FLAG" ]; then
         rec enabled_false PASS "$W_SEC_FLAG" "Enabled=false seen"
       else
         rec enabled_false FAIL - "still Enabled after ${TIMEOUT}s"
       fi
       rec disable_deployed FAIL - "not Deployed within ${TIMEOUT}s" ;;
    3) rec enabled_false INCONCLUSIVE - "$NOT_CONFIRMED_HINT (after $ATTEMPTS attempts)"
       rec disable_deployed INCONCLUSIVE - "no disable happened" ;;
    *) die "AWS call failed while polling the distribution" ;;
  esac
fi
collect_evidence "$T0" "$T0_ISO" "$PAT"
ask_email_minute "$T0"

# Reset our forced alarm first, so the restored (enabled) distribution cannot be hit by a lingering ALARM.
reset_alarm_if_ours
ALARM_FIRED=0
if restore_phase; then NEED_RESTORE=0; else rec restore FAIL - "see above; run --restore-only"; fi   # on failure NEED_RESTORE stays 1: the exit trap tries once more
say "Done. Read the SECONDS values in README.md (How to read the timing)."
