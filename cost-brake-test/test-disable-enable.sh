#!/usr/bin/env bash
# test-disable-enable.sh - proves the cost brake works end to end: alarm -> SNS -> Lambda -> distribution disabled,
# measures how long each step takes, then restores the distribution and checks the site answers HTTP 200.
#
# Run it in AWS CloudShell (us-east-1) with admin credentials. It uses only: aws CLI, jq, curl, date.
# WITH ActionOnTrip=Disable THE SITE GOES DOWN FOR SEVERAL MINUTES. With AlertOnly nothing is changed.
#
# Usage:
#   STACK_NAME=<cost-protection stack> SITE_URL=https://<your blog> ./test-disable-enable.sh [options]
# Options:
#   --dry-run          print every command, call nothing, change nothing
#   --restore-only     only re-enable the distribution (use after an interrupted run)
#   --no-auto-restore  on error or Ctrl-C do NOT restore automatically, just print how
# Environment (optional): REGION (us-east-1 only), TIMEOUT (600), POLL_INTERVAL (5), ALERT_WAIT (120), RESULTS_DIR (.)
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
check_number TIMEOUT "$TIMEOUT"; check_number POLL_INTERVAL "$POLL_INTERVAL"; check_number ALERT_WAIT "$ALERT_WAIT"
install_traps

if [ "$DRY" = 1 ]; then
  cat <<PLAN
DRY RUN: nothing is called or changed. The real run executes, in this order (region $REGION):
+ aws cloudformation describe-stacks --stack-name $STACK_NAME --output json      (reads DistributionId, ActionOnTrip, AlarmNames, FunctionName)
+ curl -s -o /dev/null -w '%{http_code}' $SITE_URL                               (site must answer 200 before we start)
  If ActionOnTrip=Disable you must type 'DISABLE <last 4 chars of distribution id>' first.
+ aws cloudwatch set-alarm-state --alarm-name <requests alarm> --state-value ALARM --state-reason 'cost-brake-test ...'
  Disable:   poll every ${POLL_INTERVAL}s up to ${TIMEOUT}s:
+ aws cloudfront get-distribution-config --id <distribution id> --query DistributionConfig.Enabled --output text
+ aws cloudfront get-distribution --id <distribution id> --query Distribution.Status --output text
  AlertOnly: watch ${ALERT_WAIT}s that Enabled stays true (same get-distribution-config call)
+ aws cloudwatch describe-alarm-history --alarm-name <requests alarm> --history-item-type StateUpdate --start-date <T0>
+ aws logs filter-log-events --log-group-name /aws/lambda/<function name> --start-time <T0>
  (asks for the minute the email arrived, optional)
Restore (also on error or Ctrl-C unless --no-auto-restore):
+ aws cloudfront get-distribution-config --id <distribution id> --output json     (ETag + config)
+ jq '.DistributionConfig | .Enabled = true' > cf.json
+ aws cloudfront update-distribution --id <distribution id> --if-match <ETag> --distribution-config file://cf.json
+ poll until Enabled=true and Status=Deployed, then: curl $SITE_URL  (expect 200)
+ aws cloudwatch set-alarm-state --alarm-name <requests alarm> --state-value OK     (only if this test forced it)
Writes results-<UTC timestamp>.txt with TEST=... RESULT=... SECONDS=... lines (ids, ARNs, account numbers, site host redacted).
PLAN
  rm -rf "$WORK"; exit 0
fi

load_stack
init_results "mode=$([ "$RESTORE_ONLY" = 1 ] && echo restore-only || echo "$ACTION")"
say "Stack read. Distribution ...${DIST_ID: -4}, ActionOnTrip=$ACTION, requests alarm and Lambda found."

if [ "$RESTORE_ONLY" = 1 ]; then
  restore_phase || true
  reset_alarm_if_ours
  exit 0
fi

code="$(http_code "$SITE_URL")"
if [ "$code" != "200" ]; then die "site answered HTTP $code before the test; fix that first (we need a healthy site to prove the restore)"; fi

if [ "$ACTION" = "AlertOnly" ]; then
  say "Scenario ALERT-ONLY: I will force the requests alarm to ALARM and watch ${ALERT_WAIT}s. Expect: an email, a Lambda log line, and the distribution stays Enabled."
else
  say "Scenario DISABLE: I will force the requests alarm to ALARM. Expect: the Lambda disables the distribution (site down), then I re-enable it."
  confirm_disable
fi

NEED_RESTORE=1; ALARM_FIRED=1       # set before the alarm is touched, so any error from here on triggers the restore
T0="$(date +%s)"; T0_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "T0 = $T0_ISO"
"${AWS[@]}" cloudwatch set-alarm-state --alarm-name "$ALARM_REQ" --state-value ALARM \
  --state-reason "cost-brake-test $T0_ISO: manual test of the cost brake, safe to ignore" >/dev/null
rec alarm_set PASS 0 "requests alarm forced to ALARM"

rc=0
if [ "$ACTION" = "AlertOnly" ]; then
  watch_stays_enabled "$T0" || rc=$?
  case "$rc" in
    0) rec alertonly_stays_enabled PASS "$ALERT_WAIT" "distribution stayed Enabled for ${ALERT_WAIT}s" ;;
    1) rec alertonly_stays_enabled FAIL "$W_SEC_FLAG" "distribution was DISABLED although ActionOnTrip=AlertOnly" ;;
    *) die "AWS call failed while watching the distribution" ;;
  esac
  collect_evidence "$T0" "$T0_ISO" 'AlertOnly: would disable'
else
  wait_state false "$T0" || rc=$?
  case "$rc" in
    0) rec enabled_false PASS "$W_SEC_FLAG" "Enabled=false seen"
       rec disable_deployed PASS "$W_SEC_DEPLOYED" "Status=Deployed after the disable" ;;
    1) if [ -n "$W_SEC_FLAG" ]; then
         rec enabled_false PASS "$W_SEC_FLAG" "Enabled=false seen"
       else
         rec enabled_false FAIL - "still Enabled after ${TIMEOUT}s"
       fi
       rec disable_deployed FAIL - "not Deployed within ${TIMEOUT}s" ;;
    *) die "AWS call failed while polling the distribution" ;;
  esac
  collect_evidence "$T0" "$T0_ISO" 'disabled distribution'
fi
ask_email_minute "$T0"

if restore_phase; then NEED_RESTORE=0; else NEED_RESTORE=0; rec restore FAIL - "see above; run --restore-only"; fi
reset_alarm_if_ours
ALARM_FIRED=0
say "Done. Read the SECONDS values in README.md (How to read the timing)."
