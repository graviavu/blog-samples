#!/usr/bin/env bash
# flood-test.sh - the whole real-traffic test in ONE command: lower RequestsPer5Min on the stack, run flood.sh,
# ALWAYS put RequestsPer5Min back (also when flood.sh fails or you press Ctrl-C), and prove it is back.
# WITH ActionOnTrip=Disable THE SITE GOES DOWN FOR SEVERAL MINUTES (and stays down until the alarm is OK again).
#
# Usage:
#   STACK_NAME=<cost-protection stack> SITE_URL=https://<your blog> [THRESHOLD=100] [N=300] [BATCH=50] ./flood-test.sh [--dry-run]
# Environment (optional): THRESHOLD (the low value for RequestsPer5Min during the test, default 100), N (300), BATCH (50),
#   and everything flood.sh reads: REGION (us-east-1 only), TIMEOUT (900), POLL_INTERVAL (5), ALERT_WAIT (120),
#   RESULTS_DIR (.), EXPECT_CODE (200), LOG_TRIES (12), EMAIL_PROMPT_TIMEOUT (120), LOG_CHECK_EVERY (30)
# You type  FLOOD <last 4 chars of the distribution id>  once. In Disable mode flood.sh then asks for its own
# DISABLE <last 4> phrase and, at the end, for the optional minute the alert email arrived (Enter skips).
# Do not pipe its output (no "| tee"); run it inside tmux. The results file is the log.
# Exit codes: flood.sh's own code is forwarded (0 pass, 1 fail, 3 phrase did not match, 4 inconclusive), 2 bad input,
#   5 flood.sh passed but RequestsPer5Min could NOT be put back (read the warning and run the printed command),
#   129/130/143 signal. The threshold is restored in every case.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
LOW_THRESHOLD="${THRESHOLD:-100}"; unset THRESHOLD    # lib.sh uses THRESHOLD for the stack's CURRENT value
export CBT_MAIN_PID=$$                                 # flood.sh keeps this pid (see lib.sh), so a signal aimed at us finds us
# shellcheck source=lib.sh
. "$here/lib.sh"
N="${N:-300}"; BATCH="${BATCH:-50}"
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
check_region; check_site_url; require_tools
check_number N "$N"; check_number BATCH "$BATCH"; check_number THRESHOLD "$LOW_THRESHOLD"
check_number TIMEOUT "$TIMEOUT"; check_number POLL_INTERVAL "$POLL_INTERVAL"; check_number ALERT_WAIT "$ALERT_WAIT"; check_expect_code
if [ "$BATCH" -lt 1 ] || [ "$BATCH" -gt 50 ]; then echo "BATCH must be between 1 and 50, got: $BATCH" >&2; exit 2; fi
if [ "$N" -lt 1 ] || [ "$N" -gt 2000 ]; then echo "N must be between 1 and 2000, got: $N" >&2; exit 2; fi
if [ "$LOW_THRESHOLD" -lt 1 ]; then echo "THRESHOLD must be at least 1, got: $LOW_THRESHOLD" >&2; exit 2; fi
if [ "$LOW_THRESHOLD" -ge "$N" ]; then echo "THRESHOLD ($LOW_THRESHOLD) must be below N ($N), otherwise the alarm cannot trip." >&2; exit 2; fi
if [ "$N" -gt $((3 * LOW_THRESHOLD + 100)) ]; then echo "N ($N) is more than 3 x THRESHOLD + 100 ($((3 * LOW_THRESHOLD + 100))): a needless flood. Lower N or raise THRESHOLD." >&2; exit 2; fi

ORIG=""              # RequestsPer5Min before the test
TOUCHED=0            # 1 from just before the first update-stack until the threshold is proven back (the exit trap acts on it)
LOWERED=0            # 1 once the lowered value was proven
RESTORE_FAILED=0
FLOOD_STARTED=0 FLOOD_COLLECTED=0 FRC=0
FLOOD_DIR=""
OTHER=()             # ParameterKey=<k>,UsePreviousValue=true for every parameter except RequestsPer5Min
RES_NOTE=""

# --- stack helpers ------------------------------------------------------------------------------------------------
read_stack() { aws_call cloudformation describe-stacks --stack-name "$STACK_NAME" --output json; }
param_of()   { jq -r --arg k "$2" '.Stacks[0].Parameters[]? | select(.ParameterKey==$k) | .ParameterValue' <<<"$1"; }

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

# the exact update-stack arguments for a RequestsPer5Min value (one per line, for printing and for the dry run)
update_args() {
  printf '%s\n' --stack-name "$STACK_NAME" --use-previous-template --capabilities CAPABILITY_IAM --parameters "ParameterKey=RequestsPer5Min,ParameterValue=$1"
  if [ "${#OTHER[@]}" -gt 0 ]; then printf '%s\n' "${OTHER[@]}"; fi
}
# the same as one copy-paste command
update_cmd() {
  printf 'aws cloudformation update-stack --region us-east-1 --stack-name %q --use-previous-template --capabilities CAPABILITY_IAM --parameters ParameterKey=RequestsPer5Min,ParameterValue=%s' "$STACK_NAME" "$1"
  local p; for p in ${OTHER[@]+"${OTHER[@]}"}; do printf ' %s' "$p"; done
  printf '\n  aws cloudformation wait stack-update-complete --region us-east-1 --stack-name %q\n' "$STACK_NAME"
}

# set_threshold VALUE: 0 accepted, 1 failed, 2 CloudFormation says there is nothing to change
set_threshold() {
  local rc=0
  aws_call cloudformation update-stack --stack-name "$STACK_NAME" --use-previous-template --capabilities CAPABILITY_IAM \
    --parameters "ParameterKey=RequestsPer5Min,ParameterValue=$1" ${OTHER[@]+"${OTHER[@]}"} >/dev/null || rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'No updates are to be performed' "$WORK/aws.err" 2>/dev/null; then return 2; fi
  return "$rc"
}
stack_wait() { aws_call cloudformation wait stack-update-complete --stack-name "$STACK_NAME"; }

# --- preflight ----------------------------------------------------------------------------------------------------
install_traps
load_stack
check_number RequestsPer5Min "$THRESHOLD"      # fail closed: an empty or odd value must not slip past
ORIG="$THRESHOLD"
J="$(read_stack)" || die "cannot read stack $STACK_NAME"
STATUS="$(jq -r '.Stacks[0].StackStatus // "?"' <<<"$J")"
case "$STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) ;;
  *) die "the stack is in state $STATUS; wait until it is CREATE_COMPLETE or UPDATE_COMPLETE. Nothing was changed." ;;
esac
load_param_keys "$J"
if [ "$ORIG" = "$LOW_THRESHOLD" ]; then
  die "RequestsPer5Min is already $ORIG, so there is nothing to lower and nothing to restore. Run ./flood.sh directly, or pick another THRESHOLD."
fi
LAST4="${DIST_ID: -4}"
PHRASE="FLOOD $LAST4"

say "Stack ........................ $STACK_NAME (region $REGION, state $STATUS)"
say "Distribution ................. ...$LAST4 (last 4 characters)"
say "ActionOnTrip ................. $ACTION"
say "RequestsPer5Min now .......... $ORIG"
say "Other parameters ............. ${#OTHER[@]} (kept with UsePreviousValue=true; values are never read or printed)"
say ""
say "What will happen, in this order:"
say "  1. update-stack: RequestsPer5Min $ORIG -> $LOW_THRESHOLD, wait for stack-update-complete, read it back."
say "  2. ./flood.sh with N=$N requests (batches of $BATCH) to $SITE_URL"
if [ "$ACTION" = Disable ]; then
  say "     ActionOnTrip=Disable: THE SITE GOES DOWN for several minutes, then flood.sh brings it back."
  say "     flood.sh asks for its own DISABLE $LAST4 phrase and for the optional email minute."
else
  say "     ActionOnTrip=AlertOnly: the site stays up; the Lambda only logs what it would do."
fi
say "  3. ALWAYS (also if flood.sh fails or you press Ctrl-C): update-stack RequestsPer5Min back to $ORIG, wait, read it back."
say "     While it is lowered, REAL visitors can trip the brake too."
say ""
say "update-stack call that lowers the threshold:"
update_cmd "$LOW_THRESHOLD" | redact_stream | sed 's/^/  /'
say "update-stack call that restores it:"
update_cmd "$ORIG" | redact_stream | sed 's/^/  /'

if [ "$DRY" = 1 ]; then
  say ""
  say "DRY RUN: only describe-stacks and get-distribution were read. Nothing was changed, no request was sent."
  rm -rf "$WORK"; exit 0
fi

printf 'Type exactly  %s  to continue: ' "$PHRASE"
reply=""; IFS= read -r reply || true
if [ "$reply" != "$PHRASE" ]; then echo; echo "Phrase did not match. Nothing was changed."; exit 3; fi

# --- exit trap ----------------------------------------------------------------------------------------------------
collect_flood_lines() {
  local f
  if [ "$FLOOD_COLLECTED" = 1 ] || [ "$FLOOD_STARTED" != 1 ]; then return 0; fi
  FLOOD_COLLECTED=1
  for f in "$FLOOD_DIR"/results-*.txt; do
    if [ -f "$f" ]; then grep '^TEST=' "$f" >> "$RESULTS_FILE" || true; fi
  done
}

# restore_once: 0 when the stack reports RequestsPer5Min == ORIG (RES_NOTE says how), 1 otherwise
restore_once() {
  local j st cur="" rc=0
  RES_NOTE=""
  if ! j="$(read_stack)"; then j=""; fi
  st="$(jq -r '.Stacks[0].StackStatus // ""' <<<"$j" 2>/dev/null)" || st=""
  case "$st" in
    *_IN_PROGRESS)
      say "Stack is $st: waiting until it settles before the restore."
      stack_wait || say "note: the wait did not end in UPDATE_COMPLETE (a rollback ends like that); checking the value."
      if ! j="$(read_stack)"; then j=""; fi ;;
  esac
  cur="$(param_of "$j" RequestsPer5Min 2>/dev/null)" || cur=""
  if [ "$cur" = "$ORIG" ]; then
    if [ "$LOWERED" = 1 ]; then RES_NOTE="RequestsPer5Min is $ORIG again"; else RES_NOTE="RequestsPer5Min was never changed, still $ORIG"; fi
    return 0
  fi
  say "Restoring RequestsPer5Min to $ORIG (it reads '${cur:-unknown}' now)."
  LOWERED=1       # the value differs from the original: it was lowered (maybe by an update that was cut short)
  set_threshold "$ORIG" || rc=$?
  if [ "$rc" -eq 2 ]; then
    : # "no updates": the stack already has ORIG; the read-back below decides
  elif [ "$rc" -ne 0 ]; then
    RES_NOTE="update-stack failed"; return 1
  fi
  if [ "$rc" -ne 2 ] && ! stack_wait; then RES_NOTE="the restore update did not complete"; return 1; fi
  if ! j="$(read_stack)"; then RES_NOTE="cannot read the stack to prove the restore"; return 1; fi
  cur="$(param_of "$j" RequestsPer5Min)" || cur=""
  if [ "$cur" = "$ORIG" ]; then RES_NOTE="RequestsPer5Min is $ORIG again (read back)"; return 0; fi
  RES_NOTE="stack reports '${cur:-nothing}', expected $ORIG"; return 1
}

restore_threshold() {
  local n=0 tries=2
  while [ "$n" -lt "$tries" ]; do
    n=$((n + 1))
    if restore_once; then
      if [ "$LOWERED" = 1 ]; then rec threshold_restored PASS - "$RES_NOTE"; else rec threshold_restored SKIPPED - "$RES_NOTE"; fi
      return 0
    fi
    if [ "$n" -lt "$tries" ]; then say "Restore attempt $n failed ($RES_NOTE); trying once more in ${POLL_INTERVAL}s."; sleep "$POLL_INTERVAL"; fi
  done
  rec threshold_restored FAIL - "$RES_NOTE"
  echo
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "!!! WARNING: RequestsPer5Min COULD NOT BE PUT BACK ($RES_NOTE)."
  echo "!!! It may still be $LOW_THRESHOLD instead of $ORIG. A threshold that low trips on REAL visitors."
  echo "!!! Run this NOW (or change the parameter in the CloudFormation console), then check it:"
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  update_cmd "$ORIG" | redact_stream
  printf "  aws cloudformation describe-stacks --region us-east-1 --stack-name %q --query \"Stacks[0].Parameters[?ParameterKey=='RequestsPer5Min'].ParameterValue\" --output text\n" "$STACK_NAME"
  return 1
}

# Same pattern as lib.sh on_exit: SIGPIPE, INT, TERM and HUP are ignored from here on, so neither a second Ctrl-C nor a dead
# "| tee" can interrupt the restore. The threshold restore runs after flood.sh has finished (and has restored the distribution).
on_exit() {
  local rc=$?       # must be read before any other command
  trap '' PIPE
  trap '' INT TERM HUP
  trap - EXIT
  set +e
  exec >&3 2>&4
  pick_output
  if [ "$TOUCHED" = 1 ]; then
    if [ "$rc" -ne 0 ]; then echo "Not finished (exit $rc): putting RequestsPer5Min back now. Do not close this window. If it is cut off, run:"; update_cmd "$ORIG" | redact_stream; fi
    collect_flood_lines
    if restore_threshold; then TOUCHED=0; else RESTORE_FAILED=1; fi
  fi
  if [ -f "$RESULTS_FILE" ]; then echo; echo "Summary ($RESULTS_FILE, redacted):"; grep -v '^#' "$RESULTS_FILE"; fi
  rm -rf "$WORK"
  if [ "$rc" -eq 0 ] && [ "$RESTORE_FAILED" = 1 ]; then rc=5
  elif [ "$rc" -eq 0 ] && [ "$FAILS" -gt 0 ]; then rc=1; fi
  exit "$rc"
}

# --- 1. lower the threshold ---------------------------------------------------------------------------------------
init_results "mode=flood-test/$ACTION n=$N batch=$BATCH threshold $ORIG -> $LOW_THRESHOLD"
say ""
say "If this window is cut off, this puts the threshold back:"
update_cmd "$ORIG" | redact_stream
TOUCHED=1          # from here on the exit trap checks the stack and puts the value back if needed
say "Step 1: lowering RequestsPer5Min $ORIG -> $LOW_THRESHOLD."
rc=0; set_threshold "$LOW_THRESHOLD" || rc=$?
if [ "$rc" -eq 2 ]; then
  rec threshold_lowered FAIL - "CloudFormation reports no changes"
  die "update-stack: no changes to perform, RequestsPer5Min was not changed. Nothing to restore; flood.sh was not run."
elif [ "$rc" -ne 0 ]; then
  rec threshold_lowered FAIL - "update-stack failed"
  die "update-stack failed (message above). RequestsPer5Min was not changed (the exit check confirms it). flood.sh was not run."
fi
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

# --- 2. flood.sh, exactly as it is ---------------------------------------------------------------------------------
FLOOD_DIR="$RESULTS_DIR/flood-$STAMP"; mkdir -p "$FLOOD_DIR"
say ""
say "Step 2: ./flood.sh (N=$N, BATCH=$BATCH). Its own results file is in $FLOOD_DIR."
FLOOD_STARTED=1
RESULTS_DIR="$FLOOD_DIR" "$here/flood.sh" || FRC=$?
collect_flood_lines
say "flood.sh finished with exit code $FRC."

# --- 3. restore (also done by the exit trap if we never get here) --------------------------------------------------
say ""
say "Step 3: putting RequestsPer5Min back to $ORIG."
if restore_threshold; then TOUCHED=0; else RESTORE_FAILED=1; TOUCHED=0; fi
exit "$FRC"
