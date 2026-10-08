#!/usr/bin/env bash
# flood.sh - optional second scenario: a REAL burst of requests, measuring request -> metric -> alarm -> disable.
# Lower RequestsPer5Min on the stack below N first (see README.md) and put it back afterwards.
# WITH ActionOnTrip=Disable THE SITE GOES DOWN FOR SEVERAL MINUTES (and stays down until the alarm is OK again).
#
# Usage:
#   STACK_NAME=<cost-protection stack> SITE_URL=https://<your blog> [N=300] [BATCH=50] ./flood.sh [--dry-run] [--no-auto-restore]
# Environment (optional): N (300 requests, max 2000, and at most 3 x RequestsPer5Min + 100), BATCH (50 parallel curls, max 50),
#   REGION (us-east-1 only), TIMEOUT (900), POLL_INTERVAL (5), ALERT_WAIT (120), RESULTS_DIR (.),
#   EXPECT_CODE (200, status of your healthy site), LOG_TRIES (12), EMAIL_PROMPT_TIMEOUT (120), LOG_CHECK_EVERY (30)
# Do not pipe its output (no "| tee"); run it inside tmux. The results file is the log.
# Exit codes: 0 pass, 1 fail, 2 bad input, 3 phrase did not match, 4 inconclusive (Disable mode), 129/130/143 signal
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
N="${N:-300}"; BATCH="${BATCH:-50}"

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --no-auto-restore) NO_AUTO=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
  esac
done
: "${STACK_NAME:?STACK_NAME is required (the cost-protection stack)}"
: "${SITE_URL:?SITE_URL is required (e.g. https://blog.example.com)}"
check_region; check_site_url; require_tools
check_number N "$N"; check_number BATCH "$BATCH"; check_number TIMEOUT "$TIMEOUT"; check_number POLL_INTERVAL "$POLL_INTERVAL"; check_number ALERT_WAIT "$ALERT_WAIT"; check_expect_code
if [ "$BATCH" -lt 1 ] || [ "$BATCH" -gt 50 ]; then echo "BATCH must be between 1 and 50, got: $BATCH" >&2; exit 2; fi
if [ "$N" -lt 1 ] || [ "$N" -gt 2000 ]; then echo "N must be between 1 and 2000, got: $N" >&2; exit 2; fi
install_traps

if [ "$DRY" = 1 ]; then
  cat <<PLAN | redact_stream
DRY RUN: nothing is called or changed. The real run executes, in this order (region $REGION):
+ aws cloudformation describe-stacks --stack-name $STACK_NAME --output json   (refuses unless RequestsPer5Min is a number below N=$N and N <= 3 x RequestsPer5Min + 100)
+ aws cloudfront get-distribution --id <distribution id>   (SITE_URL host must be the distribution domain or one of its aliases)
+ aws cloudwatch describe-alarms --alarm-names <all stack alarms>   (state is shown first; a real trip is flagged)
+ curl -L --globoff $SITE_URL   (must answer $EXPECT_CODE); aws cloudwatch describe-alarms (the alarm must be OK); Disable mode needs the typed phrase 'DISABLE <last 4 chars of distribution id>'
+ $N x curl -s --globoff -o /dev/null "<SITE_URL without query>/?cbt=<run>-<i>" in parallel batches of $BATCH      (T0 = time of the first request)
+ poll every ${POLL_INTERVAL}s, up to ${TIMEOUT}s: aws cloudwatch describe-alarms --alarm-names <requests alarm>
+ evidence: aws lambda get-function-configuration (log group), aws logs filter-log-events --max-items 2000
+ then: aws cloudfront get-distribution-config / get-distribution (Disable: Enabled=false and Deployed; AlertOnly: stays Enabled for ${ALERT_WAIT}s)
+ Disable: wait until the alarm is OK again (so it cannot re-trigger), then restore as in test-disable-enable.sh
PLAN
  rm -rf "$WORK"; exit 0
fi

load_stack
check_number RequestsPer5Min "$THRESHOLD"      # fail closed: an empty or odd value must not slip past the comparison
init_results "mode=flood/$ACTION n=$N batch=$BATCH threshold=$THRESHOLD"
if [ "$THRESHOLD" -ge "$N" ]; then
  die "RequestsPer5Min is $THRESHOLD but N is $N: the alarm cannot trip. Lower RequestsPer5Min below N first (README.md), or raise N."
fi
if [ "$N" -gt $((3 * THRESHOLD + 100)) ]; then
  die "N is $N but RequestsPer5Min is only $THRESHOLD: more than 3 x threshold + 100 requests is a needless flood. Lower N or raise the threshold a little."
fi
if [ "$ACTION" = Disable ]; then INCONC_EXIT=1; fi   # Disable: INCONCLUSIVE exits 4, the brake was not proven
show_alarm_state
precheck_site
require_alarm_ok
say "Scenario FLOOD ($ACTION): $N requests in batches of $BATCH against the site; threshold is $THRESHOLD per 5 minutes."
if [ "$ACTION" = "Disable" ]; then confirm_disable; fi

NEED_RESTORE=1
RUN="r$(date +%s)"; base="${SITE_URL%%[?#]*}"; base="${base%/}"; : > "$WORK/codes"   # keep a path, drop query and fragment
T0="$(date +%s)"; T0_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "T0 = $T0_ISO (first request)"
i=0
while [ "$i" -lt "$N" ]; do
  b=0
  while [ "$b" -lt "$BATCH" ] && [ "$i" -lt "$N" ]; do
    curl -s --globoff -o /dev/null -w '%{http_code}\n' --max-time 20 "$base/?cbt=$RUN-$i" >> "$WORK/codes" &
    b=$((b + 1)); i=$((i + 1))
  done
  wait
done
ok200="$(grep -c '^200$' "$WORK/codes" || true)"
rec flood_sent PASS "$(( $(date +%s) - T0 ))" "$N requests sent, $ok200 answered 200"

rc=0; wait_alarm ALARM "$T0" || rc=$?
case "$rc" in
  0) rec alarm_in_alarm PASS "$W_SEC_FLAG" "requests alarm reached ALARM on its own" ;;
  1) rec alarm_in_alarm FAIL - "alarm not in ALARM after ${TIMEOUT}s (threshold $THRESHOLD, sent $N)" ;;
  *) die "AWS call failed while polling the alarm" ;;
esac
CHK_T0="$T0"

if [ "$rc" -eq 0 ]; then
  if [ "$ACTION" = "AlertOnly" ]; then
    rc=0; watch_stays_enabled "$(date +%s)" || rc=$?
    if [ "$rc" -eq 0 ]; then rec alertonly_stays_enabled PASS "$ALERT_WAIT" "distribution stayed Enabled"
    elif [ "$rc" -eq 1 ]; then rec alertonly_stays_enabled FAIL - "distribution was DISABLED although AlertOnly"
    else die "AWS call failed while watching the distribution"; fi
    collect_evidence "$T0" "$T0_ISO" 'AlertOnly: would disable'
  else
    CHK_PAT='disabled distribution'; WAIT_CHECK=lambda_not_confirmed_poll
    rc=0; wait_state false "$T0" || rc=$?
    WAIT_CHECK=""
    if [ "$rc" -eq 0 ]; then
      rec enabled_false PASS "$W_SEC_FLAG" "Enabled=false seen"; rec disable_deployed PASS "$W_SEC_DEPLOYED" "Status=Deployed"
    elif [ "$rc" -eq 3 ]; then
      rec enabled_false INCONCLUSIVE - "$NOT_CONFIRMED_HINT"
    elif [ "$rc" -eq 1 ]; then
      rec enabled_false FAIL - "not disabled and deployed within ${TIMEOUT}s"
    else die "AWS call failed while polling the distribution"; fi
    collect_evidence "$T0" "$T0_ISO" 'disabled distribution'
    # Re-enabling while the flooded 5-minute window is still the latest datapoint would trip again. Wait for OK first.
    say "Waiting for the alarm to return to OK before restoring (the site stays down meanwhile)."
    rc=0; wait_alarm OK "$(date +%s)" || rc=$?
    if [ "$rc" -eq 0 ]; then rec alarm_back_to_ok PASS "$W_SEC_FLAG" "alarm OK again"
    else rec alarm_back_to_ok INCONCLUSIVE - "alarm not OK within ${TIMEOUT}s; restoring anyway, it may trip again"; fi
  fi
fi
ask_email_minute "$T0"
# NEED_RESTORE drops to 0 only once the restore worked; if it failed the exit trap tries again.
if restore_phase; then NEED_RESTORE=0; else rec restore FAIL - "see above; run test-disable-enable.sh --restore-only"; fi
say "Done. Now put RequestsPer5Min back to its normal value (README.md)."
