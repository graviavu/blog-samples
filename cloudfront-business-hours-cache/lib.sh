#!/usr/bin/env bash
# lib.sh - helpers for run-test.sh. Sourced, not run. Needs: aws CLI v2, jq, curl, zip. Works with bash 3.2 or newer.

# shellcheck disable=SC2034  # variables are used by run-test.sh, which sources this file
umask 077   # state and results files are readable by the owner only

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REGION="us-east-1"                        # Lambda@Edge functions must live here
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

RUNID="" BUCKET="" ROLE="" ORIGIN_ROLE="" ORIGIN_FN="" EDGE_FN="" EDGE_VER="" CP_ID="" DIST_ID="" CF_DOMAIN="" ORIGIN_HOST=""
STATE_FILE="" WORK="" DRY_RUN=0 CREATE_STARTED=0 TEARDOWN_DONE=0 TD_FAIL=0 TD_PENDING=0 REPORT_WRITTEN=0 DIST_GONE=0 TRY_DIST=0 TRY_CP=0 BUCKET_MADE=0 LOGS_LEFT=""
RES_NAME=() RES_RESULT=() RES_MEAS=()
NOTES=()

# ---------------------------------------------------------------------------------------------------- output, redaction
# Everything that reaches the screen or a results file goes through redact(). Best effort: read the file before you share it.
redact() {
  local extra=() lit name
  for name in BUCKET ROLE ORIGIN_ROLE ORIGIN_FN EDGE_FN CP_ID DIST_ID CF_DOMAIN ORIGIN_HOST; do
    eval "lit=\${$name:-}"
    [ -n "$lit" ] || continue
    lit="$(printf '%s' "$lit" | sed -e 's/[][\.*^$/|+?(){}]/\\&/g')"
    case "$name" in
      BUCKET) extra+=(-e "s|$lit|<bucket>|g") ;;
      ROLE|ORIGIN_ROLE) extra+=(-e "s|$lit|<role>|g") ;;
      ORIGIN_FN|EDGE_FN) extra+=(-e "s|$lit|<function>|g") ;;
      CP_ID) extra+=(-e "s|$lit|<cache-policy-id>|g") ;;
      DIST_ID) extra+=(-e "s|$lit|<distribution-id>|g") ;;
      *) extra+=(-e "s|$lit|<host>|g") ;;
    esac
  done
  sed -E \
    -e 's#arn:aws[a-z-]*:[A-Za-z0-9-]*:[a-z0-9-]*:[0-9]*:[^ ",)]*#<arn>#g' \
    -e 's#(^|[^0-9])[0-9]{12}([^0-9]|$)#\1<account-id>\2#g' \
    -e 's#(AKIA|ASIA)[0-9A-Z]{16}#<access-key-id>#g' \
    -e 's#[A-Za-z0-9-]+\.lambda-url\.[a-z0-9-]+\.on\.aws#<origin-host>#g' \
    -e 's#[A-Za-z0-9-]+\.cloudfront\.net#<cloudfront-domain>#g' \
    -e 's#(^|[^A-Za-z0-9])E[A-Z0-9]{12,13}([^A-Za-z0-9]|$)#\1<distribution-id>\2#g' \
    -e 's#([Xx]-[Aa]mz-[Cc]f-[Ii]d|[Xx]-[Aa]mz-[Ss]ecurity-[Tt]oken|[Aa]uthorization|[Ss]ession[Tt]oken)([:=" ]+)[^ ,"]+#\1\2<redacted>#g' \
    -e 's#[A-Za-z0-9+/=_-]{40,}#<redacted-token>#g' \
    ${extra[@]+"${extra[@]}"}
}
say() { printf '%s\n' "$*" | redact; }
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
not_found() {
  local code
  case "$1" in
    s3) code=NoSuchBucket ;; iam) code=NoSuchEntity ;; lambda) code=ResourceNotFoundException ;;
    cf) code=NoSuchDistribution ;; cp) code=NoSuchCachePolicy ;; *) return 1 ;;
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
    case "$k" in RUNID|BUCKET|ROLE|ORIGIN_FN|EDGE_FN|EDGE_VER|CP_ID|DIST_ID|CF_DOMAIN|ORIGIN_HOST|DIST_GONE|TRY_DIST|TRY_CP|BUCKET_MADE|ORIGIN_ROLE) ;; *) continue ;; esac
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
# tag_of KIND ID -> prints the RunId tag (cache policies cannot be tagged: their name carries the run id, printed as RunId
# when it matches). Returns 0 ok, 44 resource not found, 1 other error. Nothing is deleted unless this prints our RUNID.
tag_of() {
  local kind="$1" id="$2" out arn rc
  case "$kind" in
    s3) out="$(aws_ro s3api get-bucket-tagging --bucket "$id" --query "TagSet[?Key=='RunId'].Value | [0]" --output text)"; rc=$? ;;
    iam) out="$(aws_ro iam list-role-tags --role-name "$id" --query "Tags[?Key=='RunId'].Value | [0]" --output text)"; rc=$? ;;
    lambda) out="$(aws_ro lambda get-function --function-name "$id" --query 'Tags.RunId' --output text)"; rc=$? ;;
    cf)
      arn="$(aws_ro cloudfront get-distribution --id "$id" --query 'Distribution.ARN' --output text)"; rc=$?
      if [ "$rc" = 0 ]; then
        out="$(aws_ro cloudfront list-tags-for-resource --resource "$arn" --query "Tags.Items[?Key=='RunId'].Value | [0]" --output text)"; rc=$?
      fi ;;
    cp)
      out="$(aws_ro cloudfront get-cache-policy --id "$id" --query 'CachePolicy.CachePolicyConfig.Name' --output text)"; rc=$?
      if [ "$rc" = 0 ] && [ "$out" = "bhc-$RUNID-cp" ]; then out="$RUNID"; fi ;;
    *) return 1 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    if not_found "$kind"; then return 44; fi
    # A bucket whose tagging call never succeeded has no tag set. It is ours only if its name is exactly this run's bucket name
    # AND create-bucket of this run reported success (BUCKET_MADE).
    if [ "$kind" = s3 ] && [ "$(error_code)" = NoSuchTagSet ] && [ "$id" = "bhc-$RUNID-cfg" ] && [ "$BUCKET_MADE" = 1 ]; then
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
# A Ctrl-C can arrive while a create call is running, before its id was saved. TRY_* is saved before such a call, so the
# teardown looks the resource up again by its run-id name. The ownership check below still applies to what it finds.
td_dist() {
  if [ -z "$DIST_ID" ] && [ "$TRY_DIST" = 1 ]; then
    DIST_ID="$(aws_ro cloudfront list-distributions --query "DistributionList.Items[?Comment=='bhc test $RUNID'].Id | [0]" --output text)" \
      || { say "  distribution: lookup by name failed, so a distribution of this run may exist and was NOT checked"; TD_FAIL=1; DIST_ID=""; }
    case "$DIST_ID" in None|null|'') DIST_ID="" ;; *) say "  distribution: found by its run-id comment" ;; esac
  fi
  [ -n "$DIST_ID" ] || return 0
  [ "$DIST_GONE" = 1 ] && return 0
  owned cf "$DIST_ID" "distribution"; case $? in 44) DIST_GONE=1; return 0 ;; 0) ;; *) return 0 ;; esac
  local cfg etag enabled
  cfg="$(aws_ro cloudfront get-distribution-config --id "$DIST_ID" --output json)" || { say "  distribution: cannot read config"; TD_FAIL=1; return 0; }
  etag="$(printf '%s' "$cfg" | jq -r '.ETag')"; enabled="$(printf '%s' "$cfg" | jq -r '.DistributionConfig.Enabled')"
  if [ "$enabled" = true ]; then
    say "  distribution: disabling"
    printf '%s' "$cfg" | jq '.DistributionConfig | .Enabled = false' > "$WORK/dist-off.json"
    aws_do cloudfront update-distribution --id "$DIST_ID" --distribution-config "file://$WORK/dist-off.json" --if-match "$etag" >/dev/null \
      || { say "  distribution: disable failed"; TD_FAIL=1; return 0; }
  fi
  say "  distribution: waiting until the disable is deployed (several minutes)"
  retry 3 5 aws_ro cloudfront wait distribution-deployed --id "$DIST_ID" || { say "  distribution: wait failed"; TD_FAIL=1; return 0; }
  etag="$(aws_ro cloudfront get-distribution-config --id "$DIST_ID" --query ETag --output text)"
  if aws_do cloudfront delete-distribution --id "$DIST_ID" --if-match "$etag" >/dev/null; then
    say "  distribution: deleted"; state_set DIST_GONE 1
  else
    say "  distribution: delete failed"; TD_FAIL=1
  fi
}
td_cache_policy() {
  if [ -z "$CP_ID" ] && [ "$TRY_CP" = 1 ]; then
    CP_ID="$(aws_ro cloudfront list-cache-policies --type custom --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='bhc-$RUNID-cp'].CachePolicy.Id | [0]" --output text)" \
      || { say "  cache policy: lookup by name failed, so a policy of this run may exist and was NOT checked"; TD_FAIL=1; CP_ID=""; }
    case "$CP_ID" in None|null|'') CP_ID="" ;; *) say "  cache policy: found by its run-id name" ;; esac
  fi
  [ -n "$CP_ID" ] || return 0
  if [ -n "$DIST_ID" ] && [ "$DIST_GONE" != 1 ]; then say "  cache policy: kept (distribution still exists)"; return 0; fi
  owned cp "$CP_ID" "cache policy"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  local etag
  etag="$(aws_ro cloudfront get-cache-policy --id "$CP_ID" --query ETag --output text)"
  if aws_do cloudfront delete-cache-policy --id "$CP_ID" --if-match "$etag" >/dev/null; then say "  cache policy: deleted"; else say "  cache policy: delete failed"; TD_FAIL=1; fi
}
td_edge() {
  [ -n "$EDGE_FN" ] || return 0
  owned lambda "$EDGE_FN" "edge function"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  if [ -n "$DIST_ID" ] && [ "$DIST_GONE" != 1 ]; then say "  edge function: kept (distribution still exists)"; TD_FAIL=1; TD_PENDING=1; return 0; fi
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
td_origin() {
  [ -n "$ORIGIN_FN" ] || return 0
  owned lambda "$ORIGIN_FN" "origin function"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  if aws_do lambda delete-function --function-name "$ORIGIN_FN" >/dev/null; then say "  origin function: deleted"; else say "  origin function: delete failed"; TD_FAIL=1; fi
}
td_role() { # LABEL ROLE_NAME
  [ -n "$2" ] || return 0
  owned iam "$2" "$1"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  aws_do iam delete-role-policy --role-name "$2" --policy-name bhc-inline >/dev/null 2>&1
  if aws_do iam delete-role --role-name "$2" >/dev/null; then say "  $1: deleted"; else say "  $1: delete failed"; TD_FAIL=1; fi
}
td_origin_role() { td_role "origin role" "$ORIGIN_ROLE"; }
td_edge_role() {
  [ -n "$ROLE" ] || return 0
  if [ "$TD_PENDING" = 1 ]; then say "  edge role: kept (the edge function still exists)"; return 0; fi
  td_role "edge role" "$ROLE"
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
  if [ -n "$ORIGIN_FN" ]; then td_log_group "$REGION" "/aws/lambda/$ORIGIN_FN"; fi
  if [ -n "$EDGE_FN" ] && [ "$TD_PENDING" = 1 ]; then say "  edge log groups: kept until the edge function is deleted (--cleanup removes them)"; fi
  if [ -n "$EDGE_FN" ] && [ "$TD_PENDING" != 1 ]; then
    regions="$(aws_ro ec2 describe-regions --query 'Regions[].RegionName' --output text)" || regions="$REGION"
    for r in $regions; do td_log_group "$r" "/aws/lambda/us-east-1.$EDGE_FN"; done
  fi
  if [ -n "$LOGS_LEFT" ]; then say "  log groups NOT deleted:$LOGS_LEFT (a few cents of stored logs at most; delete them in the console)"; fi
}
td_bucket() {
  [ -n "$BUCKET" ] || return 0
  owned s3 "$BUCKET" "bucket"; case $? in 44) return 0 ;; 0) ;; *) return 0 ;; esac
  aws_do s3api delete-object --bucket "$BUCKET" --key "$CONFIG_KEY" >/dev/null 2>&1
  if aws_do s3api delete-bucket --bucket "$BUCKET" >/dev/null; then say "  bucket: deleted"; else say "  bucket: delete failed"; TD_FAIL=1; fi
}
teardown() {
  say "teardown: deleting only resources tagged RunId=$RUNID"
  td_dist; td_cache_policy; td_edge; td_origin; td_edge_role; td_origin_role; td_logs; td_bucket
  if [ "$TD_FAIL" = 0 ]; then
    say "teardown: complete"
  else
    say "teardown: INCOMPLETE. Read the lines above. Resources named bhc-$RUNID-* may still exist (cents at most, but delete them)."
  fi
}

# ---------------------------------------------------------------------------------------------------- packaging
# package_edge DIR: copy edge/index.mjs with the bucket and key baked in (Lambda@Edge has no environment variables).
package_edge() {
  local d="$1"
  mkdir -p "$d/edge"
  sed -e "s|__CONFIG_BUCKET__|$BUCKET|" -e "s|__CONFIG_KEY__|$CONFIG_KEY|" "$SCRIPT_DIR/edge/index.mjs" > "$d/edge/index.mjs"
  if grep -q '__CONFIG_' "$d/edge/index.mjs"; then return 1; fi
  (cd "$d/edge" && zip -q -j "$d/edge.zip" index.mjs)
}
package_origin() {
  local d="$1"
  mkdir -p "$d/origin"
  cp "$SCRIPT_DIR/origin/index.mjs" "$d/origin/index.mjs"
  (cd "$d/origin" && zip -q -j "$d/origin.zip" index.mjs)
}

# ---------------------------------------------------------------------------------------------------- results
add_result() { RES_NAME+=("$1"); RES_RESULT+=("$2"); RES_MEAS+=("$3"); say "  $1  $2  $3"; }
count_result() { local i n=0; for ((i = 0; i < ${#RES_RESULT[@]}; i++)); do [ "${RES_RESULT[$i]%% *}" = "$1" ] && n=$((n + 1)); done; echo "$n"; }
