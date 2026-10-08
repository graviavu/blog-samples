#!/usr/bin/env bash
# flood-test.sh - the whole real-traffic test in ONE command: lower RequestsPer5Min on the stack, run flood.sh,
# ALWAYS put RequestsPer5Min back (also when flood.sh fails or you press Ctrl-C), THEN re-enable the site, and prove it.
# WITH ActionOnTrip=Disable THE SITE GOES DOWN FOR SEVERAL MINUTES (and stays down until the alarm is OK again).
#
# Usage:
#   STACK_NAME=<cost-protection stack> SITE_URL=https://<your blog> [THRESHOLD=100] [N=300] [BATCH=50] ./flood-test.sh [--dry-run]
# Environment (optional): THRESHOLD (the low value for RequestsPer5Min during the test, default 100; it must be at least
#   2 x the busiest 5 minutes of the last 24 h), N (300), BATCH (50), FORCE_NO_PEAK (0; 1 = go on when that peak cannot be
#   read), RESTORE_TRIES (5), RESTORE_BACKOFF (30 s), STACK_POLICY (0; 1 = untested stack policy during the update that only
#   lets RequestsAlarm be modified), and everything flood.sh reads: REGION (us-east-1 only), TIMEOUT (900), POLL_INTERVAL (5),
#   ALERT_WAIT (120), RESULTS_DIR (.), EXPECT_CODE (200), LOG_TRIES (12), EMAIL_PROMPT_TIMEOUT (120), LOG_CHECK_EVERY (30)
# STACK_NAME is the plain stack name (not an ARN).
# You type  FLOOD <last 4 chars of the distribution id>  once. In Disable mode flood.sh then asks for its own
# DISABLE <last 4> phrase and, at the end, for the optional minute the alert email arrived (Enter skips).
# CloudShell ends a session after about 20-30 minutes without keyboard input, and tmux does not survive that: keep the tab
# active (or run from a local or EC2 shell) and copy the restore commands it prints before and after lowering.
# Do not pipe its output (no "| tee"). The results file is the log.
# Exit codes: flood.sh's own code is forwarded (0 pass, 1 fail, 3 phrase did not match, 4 inconclusive), 1 refusal before
#   any change, 2 bad input, 5 the end state is NOT safe (RequestsPer5Min not back, distribution not Enabled, or alarm not OK;
#   read the warning and run the printed commands; 5 wins over every other code), 129/130/143 signal.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
LOW_THRESHOLD="${THRESHOLD:-100}"; unset THRESHOLD    # lib.sh uses THRESHOLD for the stack's CURRENT value
export CBT_MAIN_PID=$$                                 # flood.sh keeps this pid (see lib.sh), so a signal aimed at us finds us
# shellcheck source=lib.sh
. "$here/lib.sh"
N="${N:-300}"; BATCH="${BATCH:-50}"
RESTORE_TRIES="${RESTORE_TRIES:-5}"; RESTORE_BACKOFF="${RESTORE_BACKOFF:-30}"
FORCE_NO_PEAK="${FORCE_NO_PEAK:-0}"; STACK_POLICY="${STACK_POLICY:-0}"
export N BATCH

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (see --help)" >&2; exit 2 ;;
  esac
done
: "${STACK_NAME:?STACK_NAME is required (the cost-protection stack)}"
: "${SITE_URL:?SITE_URL is required (e.g. https://blog.example.com)}"
# The printed restore commands are the lifeline if the session dies, so they are printed unredacted, and the stack name
# must be a plain name: an ARN would be redacted on screen (account id) and is refused instead.
case "$STACK_NAME" in
  arn:*) echo "STACK_NAME must be the plain stack name, not an ARN, got an ARN." >&2; exit 2 ;;
  [A-Za-z]*) ;;
  *) echo "STACK_NAME must start with a letter, got: $STACK_NAME" >&2; exit 2 ;;
esac
case "$STACK_NAME" in *[!A-Za-z0-9-]*) echo "STACK_NAME may only contain letters, digits and '-', got: $STACK_NAME" >&2; exit 2 ;; esac
if [ "${#STACK_NAME}" -gt 128 ]; then echo "STACK_NAME is longer than 128 characters" >&2; exit 2; fi
check_region; check_site_url; require_tools
check_number N "$N"; check_number BATCH "$BATCH"; check_number THRESHOLD "$LOW_THRESHOLD"
check_number TIMEOUT "$TIMEOUT"; check_number POLL_INTERVAL "$POLL_INTERVAL"; check_number ALERT_WAIT "$ALERT_WAIT"; check_expect_code
check_number RESTORE_TRIES "$RESTORE_TRIES"; check_number RESTORE_BACKOFF "$RESTORE_BACKOFF"
case "$FORCE_NO_PEAK" in 0|1) ;; *) echo "FORCE_NO_PEAK must be 0 or 1, got: $FORCE_NO_PEAK" >&2; exit 2 ;; esac
case "$STACK_POLICY" in 0|1) ;; *) echo "STACK_POLICY must be 0 or 1, got: $STACK_POLICY" >&2; exit 2 ;; esac
if [ "$RESTORE_TRIES" -lt 1 ] || [ "$RESTORE_TRIES" -gt 10 ]; then echo "RESTORE_TRIES must be between 1 and 10, got: $RESTORE_TRIES" >&2; exit 2; fi
if [ "$BATCH" -lt 1 ] || [ "$BATCH" -gt 50 ]; then echo "BATCH must be between 1 and 50, got: $BATCH" >&2; exit 2; fi
if [ "$N" -lt 1 ] || [ "$N" -gt 2000 ]; then echo "N must be between 1 and 2000, got: $N" >&2; exit 2; fi
if [ "$LOW_THRESHOLD" -lt 1 ]; then echo "THRESHOLD must be at least 1, got: $LOW_THRESHOLD" >&2; exit 2; fi
if [ "$LOW_THRESHOLD" -ge "$N" ]; then echo "THRESHOLD ($LOW_THRESHOLD) must be below N ($N), otherwise the alarm cannot trip." >&2; exit 2; fi
if [ "$N" -gt $((3 * LOW_THRESHOLD + 100)) ]; then echo "N ($N) is more than 3 x THRESHOLD + 100 ($((3 * LOW_THRESHOLD + 100))): a needless flood. Lower N or raise THRESHOLD." >&2; exit 2; fi

ORIG=""              # RequestsPer5Min before the test
TOUCHED=0            # 1 from just before the first update-stack until the restore has run (the exit trap acts on it)
LOWERED=0            # 1 once the value may differ from ORIG
RESTORE_FAILED=0     # 1 when the end state is not safe: exit 5
FLOOD_STARTED=0 FLOOD_COLLECTED=0 FRC=0 IN_STEP3=0
FLOOD_DIR=""
OTHER=()             # ParameterKey=<k>,UsePreviousValue=true for every parameter except RequestsPer5Min
RES_NOTE=""
PEAK="" PEAK_NOTE=""
# STACK_POLICY=1 (untested against AWS): during the update only RequestsAlarm may be modified; anything else is denied, so an
# update that would touch another resource fails and rolls back instead of changing it.
POLICY_BODY='{"Statement":[{"Effect":"Deny","Action":"Update:*","Principal":"*","NotResource":"LogicalResourceId/RequestsAlarm"},{"Effect":"Allow","Action":"Update:Modify","Principal":"*","Resource":"LogicalResourceId/RequestsAlarm"}]}'
POLICY_ARGS=()
if [ "$STACK_POLICY" = 1 ]; then POLICY_ARGS=(--stack-policy-during-update-body "$POLICY_BODY"); fi

# --- stack helpers ------------------------------------------------------------------------------------------------
read_stack() { aws_call cloudformation describe-stacks --stack-name "$STACK_NAME" --output json; }
param_of()   { jq -r --arg k "$2" '.Stacks[0].Parameters[]? | select(.ParameterKey==$k) | .ParameterValue' <<<"$1"; }
status_of()  { jq -r '.Stacks[0].StackStatus // ""' <<<"$1" 2>/dev/null || true; }

# load_param_keys JSON: every parameter other than RequestsPer5Min is passed as UsePreviousValue=true. That also covers
# NoEcho and secret-like parameters, whose value describe-stacks only shows as ****: no value is ever read or sent for them.
load_param_keys() {
  local keys k
  keys="$(jq -r '.Stacks[0].Parameters[]? | .ParameterKey' <<<"$1")" || die "cannot parse the stack parameters"
  OTHER=()
  while IFS= read -r k; do
    if [ -z "$k" ] || [ "$k" = RequestsPer5Min ]; then continue; fi
    case "$k" in *[!A-Za-z0-9]*) die "unexpected characters in parameter name '$k'; not building an update-stack call from it" ;; esac
    OTHER=(${OTHER[@]+"${OTHER[@]}"} "ParameterKey=$k,UsePreviousValue=true")
  done <<<"$keys"
}

# update_cmd VALUE: the update-stack call as one copy-paste command, plus the wait. Printed WITHOUT redaction: it is the
# lifeline (it holds only the plain stack name and parameter names).
update_cmd() {
  printf 'aws cloudformation update-stack --region us-east-1 --stack-name %q --use-previous-template --capabilities CAPABILITY_IAM' "$STACK_NAME"
  if [ "$STACK_POLICY" = 1 ]; then printf ' --stack-policy-during-update-body %q' "$POLICY_BODY"; fi
  printf ' --parameters ParameterKey=RequestsPer5Min,ParameterValue=%s' "$1"
  local p; for p in ${OTHER[@]+"${OTHER[@]}"}; do printf ' %s' "$p"; done
  printf '\n  aws cloudformation wait stack-update-complete --region us-east-1 --stack-name %q\n' "$STACK_NAME"
}
check_cmd() {
  printf "  aws cloudformation describe-stacks --region us-east-1 --stack-name %q --query \"Stacks[0].Parameters[?ParameterKey=='RequestsPer5Min'].ParameterValue\" --output text\n" "$STACK_NAME"
}
rollback_hint() {
  printf '  aws cloudformation continue-update-rollback --region us-east-1 --stack-name %q\n' "$STACK_NAME"
  printf '  aws cloudformation wait stack-rollback-complete --region us-east-1 --stack-name %q\n' "$STACK_NAME"
}

# set_threshold VALUE: 0 accepted, 1 failed, 2 CloudFormation says there is nothing to change, 4 another update is running
set_threshold() {
  local rc=0
  aws_call cloudformation update-stack --stack-name "$STACK_NAME" --use-previous-template --capabilities CAPABILITY_IAM \
    ${POLICY_ARGS[@]+"${POLICY_ARGS[@]}"} \
    --parameters "ParameterKey=RequestsPer5Min,ParameterValue=$1" ${OTHER[@]+"${OTHER[@]}"} >/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if grep -q 'No updates are to be performed' "$WORK/aws.err" 2>/dev/null; then return 2; fi
  if grep -q 'IN_PROGRESS' "$WORK/aws.err" 2>/dev/null; then return 4; fi
  return 1
}
stack_wait() { aws_call cloudformation wait stack-update-complete --stack-name "$STACK_NAME"; }

# read_peak: PEAK = the highest 5-minute sum of CloudFront Requests over the last 24 h (whole number, rounded up).
# Returns 1 with PEAK_NOTE when it cannot be read. No datapoints at all also counts as "cannot read": it cannot be told
# apart from a metric that is somewhere else.
read_peak() {
  local end start out p
  end="$(date +%s)"; start=$((end - 86400))
  if ! out="$(aws_call cloudwatch get-metric-statistics --namespace AWS/CloudFront --metric-name Requests \
      --dimensions "Name=DistributionId,Value=$DIST_ID" Name=Region,Value=Global \
      --start-time "$(iso_utc "$start")" --end-time "$(iso_utc "$end")" --period 300 --statistics Sum --output json)"; then
    PEAK_NOTE="get-metric-statistics failed (message above; it needs cloudwatch:GetMetricStatistics)"; return 1
  fi
  p="$(jq -r '[.Datapoints[]?.Sum | numbers] | if length == 0 then "" else (max | ceil | tostring) end' <<<"$out" 2>/dev/null)" || p=""
  if [ -z "$p" ]; then PEAK_NOTE="no Requests datapoints in the last 24 h (no traffic at all, or the metric is not where expected)"; return 1; fi
  case "$p" in *[!0-9]*) PEAK_NOTE="unexpected peak value '$p'"; return 1 ;; esac
  PEAK="$p"
}

# --- preflight ----------------------------------------------------------------------------------------------------
install_traps
load_stack
check_number RequestsPer5Min "$THRESHOLD" 10   # fail closed: an empty or odd value must not slip past
ORIG="$THRESHOLD"
J="$(read_stack)" || die "cannot read stack $STACK_NAME"
STATUS="$(status_of "$J")"
case "$STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) ;;
  UPDATE_ROLLBACK_FAILED)
    err "ERROR: the stack is UPDATE_ROLLBACK_FAILED and cannot be updated. Nothing was changed. Finish the rollback first:"
    rollback_hint >&2
    exit 1 ;;
  *) die "the stack is in state ${STATUS:-unknown}; wait until it is CREATE_COMPLETE or UPDATE_COMPLETE. Nothing was changed." ;;
esac
load_param_keys "$J"
if [ "$ORIG" = "$LOW_THRESHOLD" ]; then
  die "RequestsPer5Min is already $ORIG, so there is nothing to lower and nothing to restore. Run ./flood.sh directly, or pick another THRESHOLD."
fi
LAST4="${DIST_ID: -4}"
PHRASE="FLOOD $LAST4"
PEAK_OK=0
if read_peak; then PEAK_OK=1; fi

say "Stack ........................ $STACK_NAME (region $REGION, state $STATUS)"
say "Distribution ................. ...$LAST4 (last 4 characters)"
say "ActionOnTrip ................. $ACTION"
say "RequestsPer5Min now .......... $ORIG"
if [ "$PEAK_OK" = 1 ]; then
  say "Busiest 5 minutes, last 24 h . $PEAK requests (THRESHOLD $LOW_THRESHOLD must be at least 2 x $PEAK = $((2 * PEAK)))"
else
  say "Busiest 5 minutes, last 24 h . UNKNOWN: $PEAK_NOTE"
fi
say "Other parameters ............. ${#OTHER[@]} (kept with UsePreviousValue=true; values are never read or printed)"
if [ "$STACK_POLICY" = 1 ]; then say "Stack policy during update ... only RequestsAlarm may be modified (STACK_POLICY=1, untested)"; fi
say ""
# Real visitors count too while the threshold is low: it must leave room for the normal peak.
if [ "$PEAK_OK" = 1 ]; then
  if [ $((2 * PEAK)) -gt "$LOW_THRESHOLD" ]; then
    die "THRESHOLD $LOW_THRESHOLD is below 2 x the busiest 5 minutes of the last 24 h ($PEAK requests): real visitors could trip the brake. Use THRESHOLD >= $((2 * PEAK)) (and N above it, at most 3 x THRESHOLD + 100). Nothing was changed."
  fi
elif [ "$FORCE_NO_PEAK" = 1 ]; then
  say "WARNING: the traffic peak could not be read ($PEAK_NOTE); FORCE_NO_PEAK=1 is set, so going on without that check."
else
  die "cannot check THRESHOLD against your real traffic: $PEAK_NOTE. Nothing was changed. Look at the CloudFront Requests graph (5-minute sums, last 24 h) and, only if THRESHOLD is at least twice the peak there, run again with FORCE_NO_PEAK=1."
fi

say "What will happen, in this order:"
say "  1. update-stack: RequestsPer5Min $ORIG -> $LOW_THRESHOLD, wait for stack-update-complete, read it back."
say "  2. ./flood.sh with N=$N requests (batches of $BATCH) to $SITE_URL"
if [ "$ACTION" = Disable ]; then
  say "     ActionOnTrip=Disable: THE SITE GOES DOWN for several minutes."
  say "     flood.sh asks for its own DISABLE $LAST4 phrase and for the optional email minute. It does NOT re-enable the site."
else
  say "     ActionOnTrip=AlertOnly: the site stays up; the Lambda only logs what it would do."
fi
say "  3. ALWAYS (also if flood.sh fails or you press Ctrl-C): update-stack RequestsPer5Min back to $ORIG, wait, read it back;"
say "     then wait until the requests alarm is OK, and only then re-enable the distribution if it is disabled;"
say "     then check that the distribution is Enabled and the alarm OK."
say "     While it is lowered, REAL visitors can trip the brake too."
say ""
say "update-stack call that lowers the threshold:"
update_cmd "$LOW_THRESHOLD" | sed 's/^/  /'
say "update-stack call that restores it:"
update_cmd "$ORIG" | sed 's/^/  /'

if [ "$DRY" = 1 ]; then
  say ""
  say "DRY RUN: only describe-stacks, get-distribution and get-metric-statistics were read. Nothing was changed, no request was sent."
  rm -rf "$WORK"; exit 0
fi

# Nothing is changed yet. The site must be up and the alarm OK now, so anything disabled later is from this run.
show_alarm_state
precheck_site
if [ "$(lower "$(dist_enabled)")" != true ]; then die "the distribution is not Enabled now. Nothing was changed."; fi
require_alarm_ok

printf 'Type exactly  %s  to continue: ' "$PHRASE"
reply=""; IFS= read -r reply || true
if [ "$reply" != "$PHRASE" ]; then echo; echo "Phrase did not match. Nothing was changed."; exit 3; fi

# --- restore ------------------------------------------------------------------------------------------------------
collect_flood_lines() {
  local f
  if [ "$FLOOD_COLLECTED" = 1 ] || [ "$FLOOD_STARTED" != 1 ]; then return 0; fi
  FLOOD_COLLECTED=1
  for f in "$FLOOD_DIR"/results-*.txt; do
    if [ -f "$f" ]; then grep '^TEST=' "$f" >> "$RESULTS_FILE" || true; fi
  done
}

# print_lifeline: what to run by hand if this session ends, in the right order.
print_lifeline() {
  echo "=== COPY THIS NOW. If this session ends (CloudShell stops after about 20-30 minutes without keyboard input, tmux too), run in this order:"
  echo "  1. put RequestsPer5Min back to $ORIG:"
  update_cmd "$ORIG" | sed 's/^/     /'
  if [ "$ACTION" = Disable ]; then
    echo "  2. then, only once the requests alarm is OK, re-enable the site if it is still down:"
    restore_hint | sed 's/^/     /'
  fi
  echo "==="
}

# restore_once: 0 when the stack reports RequestsPer5Min == ORIG (RES_NOTE says how), 1 failed (try again),
# 3 the stack is UPDATE_ROLLBACK_FAILED (trying again cannot help)
restore_once() {
  local j st cur="" rc=0
  RES_NOTE=""
  if ! j="$(read_stack)"; then j=""; fi
  st="$(status_of "$j")"
  case "$st" in
    *_IN_PROGRESS)
      say "Stack is $st: waiting until it settles before the restore."
      stack_wait || say "note: the wait did not end in UPDATE_COMPLETE (a rollback ends like that); checking the value."
      if ! j="$(read_stack)"; then j=""; fi
      st="$(status_of "$j")" ;;
  esac
  if [ "$st" = UPDATE_ROLLBACK_FAILED ]; then RES_NOTE="the stack is UPDATE_ROLLBACK_FAILED: run continue-update-rollback first"; return 3; fi
  cur="$(param_of "$j" RequestsPer5Min 2>/dev/null)" || cur=""
  if [ "$cur" = "$ORIG" ]; then
    if [ "$LOWERED" = 1 ]; then RES_NOTE="RequestsPer5Min is $ORIG again"; else RES_NOTE="RequestsPer5Min was never changed, still $ORIG"; fi
    return 0
  fi
  say "Restoring RequestsPer5Min to $ORIG (it reads '${cur:-unknown}' now)."
  LOWERED=1       # the value differs from the original: it was lowered (maybe by an update that was cut short)
  set_threshold "$ORIG" || rc=$?
  case "$rc" in
    0|2) ;;       # 2 = "no updates": the stack already has ORIG; the read-back below decides
    4) RES_NOTE="another stack update is in progress"; say "Another update of the stack is in progress: waiting for it."
       stack_wait || true; return 1 ;;
    *) RES_NOTE="update-stack failed"; return 1 ;;
  esac
  if [ "$rc" -ne 2 ] && ! stack_wait; then
    RES_NOTE="the restore update did not complete"
    if j="$(read_stack)" && [ "$(status_of "$j")" = UPDATE_ROLLBACK_FAILED ]; then RES_NOTE="the restore update failed and the stack is UPDATE_ROLLBACK_FAILED: run continue-update-rollback first"; return 3; fi
    return 1
  fi
  if ! j="$(read_stack)"; then RES_NOTE="cannot read the stack to prove the restore"; return 1; fi
  cur="$(param_of "$j" RequestsPer5Min)" || cur=""
  if [ "$cur" = "$ORIG" ]; then RES_NOTE="RequestsPer5Min is $ORIG again (read back)"; return 0; fi
  RES_NOTE="stack reports '${cur:-nothing}', expected $ORIG"; return 1
}

# restore_threshold: RESTORE_TRIES attempts, RESTORE_BACKOFF seconds apart. 0 when RequestsPer5Min is ORIG.
ROLLBACK_FAILED=0
restore_threshold() {
  local n=0 r
  while [ "$n" -lt "$RESTORE_TRIES" ]; do
    n=$((n + 1)); r=0
    restore_once || r=$?
    if [ "$r" -eq 0 ]; then return 0; fi
    if [ "$r" -eq 3 ]; then ROLLBACK_FAILED=1; return 1; fi
    if [ "$n" -lt "$RESTORE_TRIES" ]; then say "Restore attempt $n of $RESTORE_TRIES failed ($RES_NOTE); trying again in ${RESTORE_BACKOFF}s."; sleep "$RESTORE_BACKOFF"; fi
  done
  return 1
}

# restore_site THR_OK: wait until the requests alarm is OK, then re-enable the distribution if it is disabled. Never while
# RequestsPer5Min is not back (THR_OK=0), never while the alarm is not OK (that may be a REAL trip at the normal threshold).
restore_site() {
  local en rc=0
  en="$(dist_enabled)" || en=unknown
  en="$(lower "$en")"
  if [ "$1" != 1 ]; then
    if [ "$en" != true ]; then say "NOT re-enabling the distribution: RequestsPer5Min is not back, so it could trip again at once."; fi
    return 0
  fi
  say "Waiting (up to ${TIMEOUT}s) for the requests alarm to be OK at the normal threshold."
  wait_alarm OK "$(date +%s)" || rc=$?
  if [ "$rc" -eq 0 ]; then rec alarm_back_to_ok PASS "$W_SEC_FLAG" "alarm OK again (threshold $ORIG)"
  else rec alarm_back_to_ok FAIL - "alarm not OK within ${TIMEOUT}s although RequestsPer5Min is $ORIG again"; fi
  if [ "$en" = true ]; then return 0; fi
  if [ "$rc" -ne 0 ]; then say "NOT re-enabling the distribution: the alarm is not OK at the normal threshold (this may be a REAL trip)."; return 0; fi
  restore_phase || true
}

# restore_all: threshold first, then the site, then check the end state. Records threshold_restored; 0 only when the end
# state is safe (RequestsPer5Min is ORIG and, after a lowering, the distribution is Enabled and the alarm is OK).
restore_all() {
  local thr_ok=0 en st
  if restore_threshold; then thr_ok=1; fi
  if [ "$thr_ok" = 1 ] && [ "$LOWERED" != 1 ]; then rec threshold_restored SKIPPED - "$RES_NOTE"; return 0; fi
  if [ "$ROLLBACK_FAILED" != 1 ]; then restore_site "$thr_ok"; fi
  en="$(dist_enabled)" || en=unknown; en="$(lower "$en")"
  st="$(alarm_json | jq -r '.MetricAlarms[0].StateValue // "MISSING"')" || st=unknown
  if [ "$thr_ok" = 1 ] && [ "$en" = true ] && [ "$st" = OK ]; then
    rec threshold_restored PASS - "$RES_NOTE; distribution Enabled, alarm OK"; return 0
  fi
  if [ "$thr_ok" = 1 ]; then
    rec threshold_restored FAIL - "RequestsPer5Min is $ORIG again, but the distribution Enabled=$en and the alarm is $st"
  else
    rec threshold_restored FAIL - "$RES_NOTE; distribution Enabled=$en, alarm $st"
  fi
  echo
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  if [ "$thr_ok" != 1 ]; then
    echo "!!! WARNING: RequestsPer5Min COULD NOT BE PUT BACK ($RES_NOTE)."
    echo "!!! It may still be $LOW_THRESHOLD instead of $ORIG. A threshold that low trips on REAL visitors."
  fi
  if [ "$en" != true ]; then echo "!!! WARNING: THE DISTRIBUTION IS NOT ENABLED (Enabled=$en): THE SITE IS DOWN."; fi
  if [ "$st" != OK ]; then echo "!!! WARNING: the requests alarm is $st, not OK. If RequestsPer5Min is $ORIG again, this may be a REAL trip: check your traffic."; fi
  echo "!!! Run these NOW, in this order (or do the same in the console):"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  if [ "$ROLLBACK_FAILED" = 1 ]; then
    echo "0. the stack is UPDATE_ROLLBACK_FAILED: finish the rollback first:"
    rollback_hint
  fi
  echo "1. put RequestsPer5Min back to $ORIG (skip if the check below already says $ORIG):"
  update_cmd "$ORIG" | sed 's/^/  /'
  echo "   check it:"
  check_cmd
  echo "2. once the requests alarm is OK, re-enable the site if it is down:"
  restore_hint | sed 's/^/  /'
  return 1
}

# Same pattern as lib.sh on_exit: SIGPIPE, INT, TERM and HUP are ignored from here on, so neither a second Ctrl-C nor a dead
# "| tee" can interrupt the restore. flood.sh runs with --leave-disabled, so the order is always: threshold, alarm OK, site.
on_exit() {
  local rc=$?       # must be read before any other command
  trap '' PIPE
  trap '' INT TERM HUP
  trap - EXIT
  set +e
  WAIT_CHECK=""
  exec >&3 2>&4
  pick_output
  if [ "$TOUCHED" = 1 ]; then
    if [ "$rc" -ne 0 ] && [ "$IN_STEP3" != 1 ]; then echo "Not finished (exit $rc): putting everything back now. Do not close this window."; print_lifeline; fi
    collect_flood_lines
    if ! restore_all; then RESTORE_FAILED=1; fi
    TOUCHED=0
  fi
  if [ -f "$RESULTS_FILE" ]; then echo; echo "Summary ($RESULTS_FILE, redacted):"; grep -v '^#' "$RESULTS_FILE"; fi
  rm -rf "$WORK"
  if [ "$RESTORE_FAILED" = 1 ]; then rc=5
  elif [ "$rc" -eq 0 ] && [ "$FAILS" -gt 0 ]; then rc=1; fi
  exit "$rc"
}

# --- 1. lower the threshold ---------------------------------------------------------------------------------------
if [ "$PEAK_OK" = 1 ]; then PEAK_HDR="peak_5min_24h=$PEAK"; else PEAK_HDR="peak_5min_24h=unknown (FORCE_NO_PEAK=1)"; fi
init_results "mode=flood-test/$ACTION n=$N batch=$BATCH threshold $ORIG -> $LOW_THRESHOLD $PEAK_HDR"
say ""
print_lifeline
TOUCHED=1          # from here on the exit trap checks the stack and puts the value back if needed
say "Step 1: lowering RequestsPer5Min $ORIG -> $LOW_THRESHOLD."
rc=0; set_threshold "$LOW_THRESHOLD" || rc=$?
case "$rc" in
  0) ;;
  2) rec threshold_lowered FAIL - "CloudFormation reports no changes"
     die "update-stack: no changes to perform, RequestsPer5Min was not changed. Nothing to restore; flood.sh was not run." ;;
  4) rec threshold_lowered FAIL - "another stack update is in progress"
     die "another update of the stack is in progress, RequestsPer5Min was not changed. flood.sh was not run; run again later." ;;
  *) rec threshold_lowered FAIL - "update-stack failed"
     die "update-stack failed (message above). RequestsPer5Min was not changed (the exit check confirms it). flood.sh was not run." ;;
esac
say "Waiting for the stack update to complete (alarms are updated by CloudFormation)."
if ! stack_wait; then
  rec threshold_lowered FAIL - "stack update did not complete"
  die "the stack update did not complete (rolled back?). flood.sh was not run; the exit check puts the original value back if needed."
fi
J="$(read_stack)" || die "cannot read the stack after the update"
NOW="$(param_of "$J" RequestsPer5Min)"
if [ "$NOW" != "$LOW_THRESHOLD" ]; then
  rec threshold_lowered FAIL - "stack reports '$NOW', expected $LOW_THRESHOLD"
  die "the stack does not report RequestsPer5Min=$LOW_THRESHOLD after the update. flood.sh was not run."
fi
LOWERED=1
rec threshold_lowered PASS - "RequestsPer5Min $ORIG -> $LOW_THRESHOLD, read back"
say ""
print_lifeline

# --- 2. flood.sh, which leaves the distribution to us ---------------------------------------------------------------
FLOOD_DIR="$RESULTS_DIR/flood-$STAMP"; mkdir -p "$FLOOD_DIR"
say ""
say "Step 2: ./flood.sh --leave-disabled (N=$N, BATCH=$BATCH). Its own results file is in $FLOOD_DIR."
FLOOD_STARTED=1
RESULTS_DIR="$FLOOD_DIR" "$here/flood.sh" --leave-disabled || FRC=$?
collect_flood_lines
say "flood.sh finished with exit code $FRC."

# --- 3. restore: the exit trap does it (threshold, alarm OK, site, final check) -------------------------------------
say ""
say "Step 3: putting RequestsPer5Min back to $ORIG, then the site."
IN_STEP3=1
exit "$FRC"
