#!/usr/bin/env bash
# lib.sh - helpers for run-test.sh. Sourced, not run. Needs: aws CLI v2, jq, curl, zip. Works with bash 3.2 or newer.

# shellcheck disable=SC2034  # variables are used by run-test.sh, which sources this file
umask 077   # state and results files are readable by the owner only

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REGION="us-east-1"                        # Lambda@Edge functions (and so the whole stack) must live here
PHRASE="create cloudfront test stack"
CLEANUP_PHRASE="delete cloudfront test stack"
SETTLE_SECS="${SETTLE_SECS:-40}"          # wait after a config change: the edge function keeps the config in memory up to 30 s
HIT_GAP_SECS="${HIT_GAP_SECS:-3}"         # pause between requests that should be cache hits (so Age visibly grows)
EDGE_DELETE_TRIES="${EDGE_DELETE_TRIES:-3}"
EDGE_DELETE_PAUSE="${EDGE_DELETE_PAUSE:-30}"
WARMUP_TRIES="${WARMUP_TRIES:-12}"
IN_TTL=0
OUT_TTL=14400                             # 4 hours; the cache policy max TTL is 86400
CONFIG_KEY="window.json"
EXPECT_IN="public, max-age=0, s-maxage=0"
EXPECT_OUT="public, max-age=0, s-maxage=14400"
RESULTS_DIR="${RESULTS_DIR:-.}"
export AWS_PAGER=""

# Names are derived from the run id (set_names). BUCKET = the config bucket (created by the stack), ART_BUCKET = the small bucket that
# holds the edge code zip (created by this script, because the stack needs the code to exist).
RUNID="" STACK="" BUCKET="" ART_BUCKET="" EDGE_ROLE="" ORIGIN_FN="" EDGE_FN="" DIST_ID="" CF_DOMAIN="" ORIGIN_HOST=""
STATE_FILE="" WORK="" DRY_RUN=0 CREATE_STARTED=0 TEARDOWN_DONE=0 TD_FAIL=0 TD_PENDING=0 REPORT_WRITTEN=0 TRY_STACK=0 ART_MADE=0 STACK_GONE=0 LOGS_LEFT="" ACCOUNT_ID="" ST=""
SETTLE_POLLS="${SETTLE_POLLS:-120}"        # polls while a stack is *_IN_PROGRESS before deleting it ...
STACK_POLL_SECS="${STACK_POLL_SECS:-30}"   # ... 30 s apart: about 60 minutes
MODE="${MODE:-run}"
RES_NAME=() RES_RESULT=() RES_MEAS=()
NOTES=()

# ---------------------------------------------------------------------------------------------------- output, redaction
# Everything that reaches the screen or a results file goes through redact(). Best effort: read the file before you share it.
redact() {
  local extra=() lit name
  for name in BUCKET ART_BUCKET ORIGIN_FN EDGE_FN DIST_ID CF_DOMAIN ORIGIN_HOST; do
    eval "lit=\${$name:-}"
    [ -n "$lit" ] || continue
    lit="$(printf '%s' "$lit" | sed -e 's/[][\.*^$/|+?(){}]/\\&/g')"
    case "$name" in
      BUCKET|ART_BUCKET) extra+=(-e "s|$lit|<bucket>|g") ;;
      ORIGIN_FN|EDGE_FN) extra+=(-e "s|$lit|<function>|g") ;;
      DIST_ID) extra+=(-e "s|$lit|<distribution-id>|g") ;;
      *) extra+=(-e "s|$lit|<host>|g") ;;
    esac
  done
  sed -E \
    -e 's#arn:aws[a-z-]*:[A-Za-z0-9-]*:[a-z0-9-]*:[0-9]*:[^ ",)]*#<arn>#g' \
    -e 's#(^|[^0-9])[0-9]{12}([^0-9]|$)#\1<account-id>\2#g' \
    -e 's#(^|[^0-9])[0-9]{12}([^0-9]|$)#\1<account-id>\2#g' \
    -e 's#(AKIA|ASIA)[0-9A-Z]{16}#<access-key-id>#g' \
    -e 's#[A-Za-z0-9-]+\.lambda-url\.[a-z0-9-]+\.on\.aws#<origin-host>#g' \
    -e 's#[A-Za-z0-9-]+\.cloudfront\.net#<cloudfront-domain>#g' \
    -e 's#(^|[^A-Za-z0-9])E[A-Z0-9]{12,13}([^A-Za-z0-9]|$)#\1<distribution-id>\2#g' \
    -e 's#([Xx]-[Aa]mz-[Cc]f-[Ii]d|[Xx]-[Aa]mz-[Ss]ecurity-[Tt]oken|[Aa]uthorization|[Ss]ession[Tt]oken)([:=" ]+)[^ ,"]+#\1\2<redacted>#g' \
    -e 's#[A-Za-z0-9+/=_-]{40,}#<redacted-token>#g' \
    ${extra[@]+"${extra[@]}"}
}
# say uses a here-string, not a pipe: after Ctrl-C, bash kills pipelines started in the EXIT trap, and the teardown messages vanish.
say() { redact <<< "$*"; }
die() { say "ERROR: $*" >&2; exit 2; }
note() { NOTES+=("$*"); }

# ---------------------------------------------------------------------------------------------------- aws wrappers
# aws_ro: reads only. aws_do: may change things; refuses to run in --dry-run. Both redact error text; stdout is for the caller.
_aws() {
  local err rc
  err="$WORK/aws.err"
  aws --region "$REGION" "$@" 2>"$err"; rc=$?
  if [ -s "$err" ]; then redact < "$err" >&2; fi
  return $rc
}
aws_ro() { _aws "$@"; }
aws_do() {
  [ "$DRY_RUN" = 0 ] || { echo "internal error: aws_do called in --dry-run: $1 $2" >&2; exit 99; }
  _aws "$@"
}
# not_found KIND: did the last aws call fail with the error CODE that means "this resource does not exist"? Codes only, never free
# text (an AccessDenied message that happens to say "does not exist" is not a not-found). Reads the file, so it works across subshells.
# The one exception is a CloudFormation stack: it has no not-found code (ValidationError), so the exact message for THIS stack's
# name is matched.
not_found() {
  local code
  case "$1" in
    s3) code=NoSuchBucket ;; iam) code=NoSuchEntity ;; lambda) code=ResourceNotFoundException ;;
    stack) grep -Fq "(ValidationError)" "$WORK/aws.err" 2>/dev/null && grep -Fq "Stack with id $STACK does not exist" "$WORK/aws.err" 2>/dev/null; return ;;
    *) return 1 ;;
  esac
  grep -Eq "\\($code\\)" "$WORK/aws.err" 2>/dev/null
}
# error_code: the code of the last failed aws call, or empty
error_code() { sed -n 's/^[^(]*An error occurred (\([A-Za-z0-9]*\)).*/\1/p' "$WORK/aws.err" 2>/dev/null | head -n 1; }

# with_region REGION cmd...: run cmd with another region (log groups of the edge function live in the regions that served requests)
with_region() { local old="$REGION" rc; REGION="$1"; shift; "$@"; rc=$?; REGION="$old"; return $rc; }
nap() { sleep "$1"; }
retry() { # tries pause cmd...
  local n="$1" p="$2" i=1; shift 2
  while ! "$@"; do
    [ "$i" -lt "$n" ] || return 1
    i=$((i + 1)); nap "$p"
  done
}

# ---------------------------------------------------------------------------------------------------- state file
# One KEY=VALUE per line (names and ids only, no secrets), so --cleanup RUNID can find what a dead run created.
state_set() { # KEY VALUE (also sets the variable)
  eval "$1=\$2"
  if [ -n "$STATE_FILE" ]; then printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; fi
  return 0
}
state_load() { # file: only well-formed lines are read, nothing is sourced
  local k v
  while IFS='=' read -r k v; do
    case "$k" in RUNID|TRY_STACK|ART_MADE) ;; *) continue ;; esac   # everything else is derived from the run id (set_names)
    printf '%s' "$v" | grep -Eq '^[A-Za-z0-9._:/-]*$' || continue
    eval "$k=\$v"
  done < "$1"
}

# ---------------------------------------------------------------------------------------------------- clock
now_epoch() { date -u +%s; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
minute_of_day() { local e; e="$(now_epoch)"; echo $(( (e % 86400) / 60 )); }
day_start_epoch() { local e; e="$(now_epoch)"; echo $(( e - e % 86400 )); }
wait_until_epoch() { # epoch: sleep in steps of at most 30 s
  local t r
  while :; do
    t="$(now_epoch)"; r=$(($1 - t))
    [ "$r" -gt 0 ] || return 0
    [ "$r" -gt 30 ] && r=30
    nap "$r"
  done
}

# ---------------------------------------------------------------------------------------------------- ownership check
# set_names: every name of a run is derived from the run id, so --cleanup needs nothing but the id.
set_names() {
  STACK="bhc-$RUNID"; BUCKET="bhc-$RUNID-cfg"; ART_BUCKET="bhc-$RUNID-art"
  EDGE_FN="bhc-$RUNID-edge"; ORIGIN_FN="bhc-$RUNID-origin"; EDGE_ROLE="bhc-$RUNID-erole"
}

# tag_of KIND ID -> prints the RunId tag. Returns 0 ok, 44 resource not found, 1 other error. Nothing is deleted unless this
# prints our RUNID (and the name is the one derived from the run id).
tag_of() {
  local kind="$1" id="$2" out rc
  case "$kind" in
    s3) out="$(aws_ro s3api get-bucket-tagging --bucket "$id" --expected-bucket-owner "$ACCOUNT_ID" --query "TagSet[?Key=='RunId'].Value | [0]" --output text)"; rc=$? ;;
    iam) out="$(aws_ro iam list-role-tags --role-name "$id" --query "Tags[?Key=='RunId'].Value | [0]" --output text)"; rc=$? ;;
    lambda) out="$(aws_ro lambda get-function --function-name "$id" --query 'Tags.RunId' --output text)"; rc=$? ;;
    stack) out="$(aws_ro cloudformation describe-stacks --stack-name "$id" --query "Stacks[0].Tags[?Key=='RunId'].Value | [0]" --output text)"; rc=$? ;;
    *) return 1 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    if not_found "$kind"; then return 44; fi
    # The artifact bucket is created by this script; if its tagging call never succeeded it has no tag set. It is ours only if
    # its name is exactly this run's artifact bucket name AND create-bucket of this run reported success (ART_MADE).
    if [ "$kind" = s3 ] && [ "$(error_code)" = NoSuchTagSet ] && [ "$id" = "$ART_BUCKET" ] && [ "$ART_MADE" = 1 ]; then
      printf '%s' "$RUNID"; return 0
    fi
    return 1
  fi
  printf '%s' "$out"
}
# owned KIND ID LABEL -> 0: ours, delete it. 44: already gone. 1: not ours or unknown, leave it alone (TD_FAIL=1).
owned() {
  local tag rc
  tag="$(tag_of "$1" "$2")"; rc=$?
  if [ "$rc" = 44 ]; then say "  $3: already gone"; return 44; fi
  if [ "$rc" != 0 ]; then say "  $3: cannot read its tags, NOT deleting"; TD_FAIL=1; return 1; fi
  if [ "$tag" != "$RUNID" ]; then say "  $3: tag RunId is '$tag', not this run: NOT deleting"; TD_FAIL=1; return 1; fi
  return 0
}

# ---------------------------------------------------------------------------------------------------- teardown
# The stack owns everything except the artifact bucket (and, in the Lambda@Edge replica case, the edge function and role that
# were retained). Order: stack, edge leftovers, artifact bucket, log groups.
# settle_stack: poll DescribeStacks until the status is no longer *_IN_PROGRESS (it is unverified whether DeleteStack is accepted
# during CREATE_IN_PROGRESS / ROLLBACK_IN_PROGRESS, so it is never tried). Sets ST. 0 settled, 1 timed out, 2 cannot read.
settle_stack() {
  local i=0 st
  while :; do
    st="$(aws_ro cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text)" || return 2
    ST="$st"
    case "$st" in *_IN_PROGRESS) ;; *) return 0 ;; esac
    i=$((i + 1))
    if [ "$i" -ge "$SETTLE_POLLS" ]; then return 1; fi
    nap "$STACK_POLL_SECS"
  done
}
td_stack() {
  [ "$TRY_STACK" = 1 ] || return 0
  local failed new retain="" attempt=0 x rc
  owned stack "$STACK" "stack"; rc=$?
  case $rc in 44) STACK_GONE=1; return 0 ;; 0) ;; *) return 0 ;; esac
  say "  stack: waiting until it is no longer in progress (CloudFront needs several minutes)"
  settle_stack; rc=$?
  case $rc in
    1) say "  stack: still $ST after the waiting time; NOT deleting it. Check the CloudFormation console, then run --cleanup $RUNID."; TD_FAIL=1; return 0 ;;
    2) if not_found stack; then say "  stack: gone"; STACK_GONE=1; return 0; fi; say "  stack: cannot read its status"; TD_FAIL=1; return 0 ;;
  esac
  say "  stack: status $ST"
  # The config bucket must be empty before the stack can delete it. Only the one object this script writes is removed, and
  # only from the bucket named for this run that carries this run's tag.
  td_empty_bucket
  while :; do
    attempt=$((attempt + 1))
    say "  stack: deleting $STACK (CloudFormation disables and deletes the distribution: several minutes)"
    if [ -n "$retain" ]; then
      # shellcheck disable=SC2086  # $retain is a list of logical ids on purpose
      aws_do cloudformation delete-stack --stack-name "$STACK" --retain-resources $retain >/dev/null || { say "  stack: delete-stack failed"; TD_FAIL=1; return 0; }
    else
      aws_do cloudformation delete-stack --stack-name "$STACK" >/dev/null || { say "  stack: delete-stack failed"; TD_FAIL=1; return 0; }
    fi
    if aws_ro cloudformation wait stack-delete-complete --stack-name "$STACK"; then
      STACK_GONE=1
      if [ -n "$retain" ]; then say "  stack: deleted; retained:$retain (the edge function is deleted next, or later by --cleanup)"; else say "  stack: deleted"; fi
      return 0
    fi
    # RetainResources is only for resources that are in DELETE_FAILED: read which ones failed and retain exactly those (plus the ones
    # retained before). Only the Lambda@Edge replica case is retried; anything else stays as it is.
    failed="$(aws_ro cloudformation describe-stack-resources --stack-name "$STACK" --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text)" || failed="?"
    new=""
    for x in $failed; do case " $retain " in *" $x "*) ;; *) new="$new $x" ;; esac; done
    # shellcheck disable=SC2086  # $failed is a tab separated list of logical ids on purpose
    if [ -n "$failed" ] && [ "$failed" != "?" ] && [ -n "$new" ] && only_edge_resources $failed && [ "$attempt" -lt 4 ]; then
      say "  stack: only the Lambda@Edge function could not be deleted ($failed): AWS keeps its replicas for some hours after the distribution is gone."
      say "  stack: retrying with exactly the failed resources RETAINED:$retain$new"
      retain="$retain$new"
      continue
    fi
    say "  stack: delete FAILED (resources: ${failed:-unknown}${retain:+, retained before:$retain}). Look at the stack events in the CloudFormation console; stack $STACK is kept."
    TD_FAIL=1
    return 0
  done
}
only_edge_resources() { local x; for x in "$@"; do case "$x" in EdgeFunction|EdgeVersion) ;; *) return 1 ;; esac; done; }
td_empty_bucket() {
  owned s3 "$BUCKET" "config bucket"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  aws_do s3api delete-object --bucket "$BUCKET" --key "$CONFIG_KEY" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1
  return 0
}
td_edge() {  # the retained edge function (only exists after the replica case)
  [ "$STACK_GONE" = 1 ] || return 0
  owned lambda "$EDGE_FN" "edge function"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  if retry "$EDGE_DELETE_TRIES" "$EDGE_DELETE_PAUSE" aws_do lambda delete-function --function-name "$EDGE_FN" >/dev/null; then
    say "  edge function: deleted"
  elif not_found lambda; then
    say "  edge function: already gone"
  else
    say "  edge function: NOT deleted yet. AWS removes Lambda@Edge replicas some hours after the distribution is gone."
    say "  Later run:  ./run-test.sh --cleanup $RUNID"
    TD_PENDING=1; TD_FAIL=1
  fi
}
td_edge_role() {  # the retained edge role
  [ "$STACK_GONE" = 1 ] || return 0
  owned iam "$EDGE_ROLE" "edge role"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  aws_do iam delete-role-policy --role-name "$EDGE_ROLE" --policy-name bhc-inline >/dev/null 2>&1
  if aws_do iam delete-role --role-name "$EDGE_ROLE" >/dev/null; then say "  edge role: deleted"; else say "  edge role: delete failed"; TD_FAIL=1; fi
}
# CloudWatch log groups. Only groups whose name is EXACTLY one of this run's names are deleted (log groups carry no tag here).
# The edge function logs in the region of the edge location that ran it, as /aws/lambda/us-east-1.<function>.
td_log_group() { # region name
  local found g
  found="$(with_region "$1" aws_ro logs describe-log-groups --log-group-name-prefix "$2" --query 'logGroups[].logGroupName' --output text)" \
    || { LOGS_LEFT="$LOGS_LEFT $2@$1(lookup failed)"; return 0; }
  for g in $found; do
    [ "$g" = "$2" ] || continue
    if with_region "$1" aws_do logs delete-log-group --log-group-name "$g" >/dev/null; then say "  log group $2 in $1: deleted"; else LOGS_LEFT="$LOGS_LEFT $2@$1"; fi
  done
}
td_logs() {
  local regions r
  if [ "$TRY_STACK" != 1 ] && [ "$ART_MADE" != 1 ]; then return 0; fi   # nothing was ever created
  if [ -n "$ORIGIN_FN" ]; then td_log_group "$REGION" "/aws/lambda/$ORIGIN_FN"; fi
  if [ -n "$EDGE_FN" ] && [ "$TD_PENDING" = 1 ]; then say "  edge log groups: kept until the edge function is deleted (--cleanup removes them)"; fi
  if [ -n "$EDGE_FN" ] && [ "$TD_PENDING" != 1 ]; then
    regions="$(aws_ro ec2 describe-regions --query 'Regions[].RegionName' --output text)" || { regions="$REGION"; LOGS_LEFT="$LOGS_LEFT edge-log-groups-in-other-regions(not-checked:ec2:DescribeRegions-failed)"; }
    for r in $regions; do td_log_group "$r" "/aws/lambda/us-east-1.$EDGE_FN"; done
  fi
  if [ -n "$LOGS_LEFT" ]; then say "  log groups NOT deleted:$LOGS_LEFT (a few cents of stored logs at most; delete them in the console)"; fi
}
td_art_bucket() {
  # In a run, only a bucket this run created (ART_MADE) is looked at. In --cleanup the tag check below is the guard.
  if [ "$MODE" = run ] && [ "$ART_MADE" != 1 ]; then return 0; fi
  owned s3 "$ART_BUCKET" "artifact bucket"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  aws_do s3api delete-object --bucket "$ART_BUCKET" --key "$CODE_KEY" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1
  if aws_do s3api delete-bucket --bucket "$ART_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null; then say "  artifact bucket: deleted"; else say "  artifact bucket: delete failed"; TD_FAIL=1; fi
}
teardown() {
  say "teardown: deleting only resources of stack $STACK (tagged RunId=$RUNID)"
  td_stack; td_edge; td_edge_role; td_art_bucket; td_logs
  if [ "$TD_FAIL" = 0 ] && [ -z "$LOGS_LEFT" ]; then
    say "teardown: complete"
  elif [ "$TD_FAIL" = 0 ]; then
    say "teardown: all resources deleted, but LOG GROUPS LEFT:$LOGS_LEFT"
  else
    say "teardown: INCOMPLETE. Read the lines above. Resources named bhc-$RUNID-* may still exist (cents at most, but delete them)."
  fi
}

# ---------------------------------------------------------------------------------------------------- packaging
# package_edge DIR: copy edge/index.mjs with the config bucket and key baked in (Lambda@Edge has no environment variables).
CODE_KEY="edge.zip"
package_edge() {
  local d="$1"
  mkdir -p "$d/edge"
  sed -e "s|__CONFIG_BUCKET__|$BUCKET|" -e "s|__CONFIG_KEY__|$CONFIG_KEY|" "$SCRIPT_DIR/edge/index.mjs" > "$d/edge/index.mjs"
  if grep -q '__CONFIG_' "$d/edge/index.mjs"; then return 1; fi
  (cd "$d/edge" && zip -q -j "$d/$CODE_KEY" index.mjs)
}

# ---------------------------------------------------------------------------------------------------- results
add_result() { RES_NAME+=("$1"); RES_RESULT+=("$2"); RES_MEAS+=("$3"); say "  $1  $2  $3"; }
count_result() { local i n=0; for ((i = 0; i < ${#RES_RESULT[@]}; i++)); do [ "${RES_RESULT[$i]%% *}" = "$1" ] && n=$((n + 1)); done; echo "$n"; }
