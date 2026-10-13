#!/usr/bin/env bash
# run-sample.sh - ONE entry point. Deploys cfn/stack.yaml (CloudFormation: CloudFront + CloudFront Function + private S3 bucket
# behind origin access control), measures the time-bucket cache key with curl, writes results-<runid>.md, deletes everything.
#
#   ./run-sample.sh --dry-run          read-only: identity + template validation, prints the plan and the windows it would use
#   ./run-sample.sh                    asks for the phrase DELETE-SAMPLE, creates the stack, tests, deletes the stack
#   ./run-sample.sh --cleanup RUNID    deletes the stack of an earlier run that could not finish (asks for the phrase too)
#
# Needs: aws CLI v2, jq, curl, bash 3.2+. No credentials are stored or printed. Everything it creates is in ONE stack named cftb-<RunId>.
# Knobs (environment): BUCKET_SECONDS (default 60, 20..600), PROP_WAIT (seconds to wait for a function update to show, default 300).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/cfn/stack.yaml"
REGION="${SAMPLE_REGION:-us-east-1}"
PHRASE="DELETE-SAMPLE"
BUCKET_SECONDS="${BUCKET_SECONDS:-60}"
LONG_TTL=86400
PROP_WAIT="${PROP_WAIT:-300}"           # bounded wait for a function update to take effect at the edge
POLL_GAP="${POLL_GAP:-10}"
HIT_GAP="${HIT_GAP:-2}"
WARMUP_TRIES="${WARMUP_TRIES:-12}"
MARGIN=3                                 # seconds past a bucket boundary before the next request (clock skew between here and the edge)
SETTLE_POLLS="${SETTLE_POLLS:-120}"      # polls while a stack is *_IN_PROGRESS before it is deleted ...
STACK_POLL_SECS="${STACK_POLL_SECS:-30}" # ... 30 s apart
RESULTS_DIR="${RESULTS_DIR:-.}"
PROBE_KEY="probe.txt"; LONG_KEY="long.txt"; WARM_KEY="warm.txt"
export AWS_PAGER=""
umask 077

DRY_RUN=0 MODE=run CLEANUP_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --cleanup)
      shift; MODE=cleanup; CLEANUP_ID="${1:-}"
      case "$CLEANUP_ID" in ''|--*) echo "--cleanup needs the run id first: ./run-sample.sh --cleanup 2610101200-ab12 [--dry-run]" >&2; exit 2 ;; esac ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cftb.XXXXXX")" || exit 2
export RT_MAIN_PID=$$   # lets the test stubs signal this script
exec 3>&1 4>&2          # the EXIT trap puts these back (a Ctrl-C can arrive while a command runs with output redirected)

RUNID="" STACK="" BUCKET="" DIST_ID="" CF_DOMAIN="" ACCOUNT_ID=""
CREATE_STARTED=0 TEARDOWN_DONE=0 TD_FAIL=0 REPORT_WRITTEN=0 STACK_GONE=0 ST="" RESULTS_FILE=""
IN_START="" IN_END="" OUT_START="" OUT_END=""
RES_ID=() RES_RESULT=() RES_TEXT=()
FACTS=()

# ---------------------------------------------------------------------------------------------------- output, redaction
# Everything that reaches the screen or the results file goes through redact(). Best effort: read the file before you share it.
redact() {
  local extra=() lit name
  for name in BUCKET DIST_ID CF_DOMAIN; do
    eval "lit=\${$name:-}"
    [ -n "$lit" ] || continue
    lit="$(printf '%s' "$lit" | sed -e 's/[][\.*^$/|+?(){}]/\\&/g')"
    case "$name" in
      BUCKET) extra+=(-e "s|$lit|<bucket>|g") ;;
      DIST_ID) extra+=(-e "s|$lit|<distribution-id>|g") ;;
      *) extra+=(-e "s|$lit|<host>|g") ;;
    esac
  done
  sed -E \
    -e 's#arn:aws[a-z-]*:[A-Za-z0-9-]*:[a-z0-9-]*:[0-9]*:[^ ",)]*#<arn>#g' \
    -e 's#(^|[^0-9])[0-9]{12}([^0-9]|$)#\1<account-id>\2#g' \
    -e 's#(^|[^0-9])[0-9]{12}([^0-9]|$)#\1<account-id>\2#g' \
    -e 's#(AKIA|ASIA)[0-9A-Z]{16}#<access-key-id>#g' \
    -e 's#[A-Za-z0-9-]+\.cloudfront\.net#<cloudfront-domain>#g' \
    -e 's#(^|[^A-Za-z0-9])E[A-Z0-9]{12,13}([^A-Za-z0-9]|$)#\1<distribution-id>\2#g' \
    -e 's#([Xx]-[Aa]mz-[Cc]f-[Ii]d|[Xx]-[Aa]mz-[Ss]ecurity-[Tt]oken|[Aa]uthorization|[Ss]ession[Tt]oken)([:=" ]+)[^ ,"]+#\1\2<redacted>#g' \
    -e 's#[A-Za-z0-9+/=_-]{40,}#<redacted-token>#g' \
    ${extra[@]+"${extra[@]}"}
}
# say uses a here-string, not a pipe: after Ctrl-C, bash kills pipelines started in the EXIT trap, and the teardown messages vanish.
say() { redact <<< "$*"; }
die() { say "ERROR: $*" >&2; exit 2; }
fail() { say "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------- aws wrappers
# aws_ro: reads only. aws_do: may change things; refuses to run in --dry-run. Both redact error text; stdout is for the caller.
_aws() {
  local rc
  aws --region "$REGION" "$@" 2>"$WORK/aws.err"; rc=$?
  if [ -s "$WORK/aws.err" ]; then redact < "$WORK/aws.err" >&2; fi
  return $rc
}
aws_ro() { _aws "$@"; }
aws_do() {
  [ "$DRY_RUN" = 0 ] || { echo "internal error: aws_do called in --dry-run: $1 $2" >&2; exit 99; }
  _aws "$@"
}
# error_code: the code of the last failed aws call, or empty
error_code() { sed -n 's/^[^(]*An error occurred (\([A-Za-z0-9]*\)).*/\1/p' "$WORK/aws.err" 2>/dev/null | head -n 1; }
# stack_missing: did the last call fail because THIS stack does not exist? (CloudFormation has no not-found code: ValidationError + message)
stack_missing() { grep -Fq "(ValidationError)" "$WORK/aws.err" 2>/dev/null && grep -Fq "Stack with id $STACK does not exist" "$WORK/aws.err" 2>/dev/null; }
nap() { sleep "$1"; }

# ---------------------------------------------------------------------------------------------------- clock
now_epoch() { date -u +%s; }
hour_now() { local e; e="$(now_epoch)"; echo $(( (e % 86400) / 3600 )); }
bucket_now() { local e; e="$(now_epoch)"; echo $(( e / BUCKET_SECONDS )); }
secs_left_in_bucket() { local e; e="$(now_epoch)"; echo $(( BUCKET_SECONDS - e % BUCKET_SECONDS )); }
wait_secs() { # SECONDS: sleep in steps of at most 30 s
  local r="$1"
  while [ "$r" -gt 0 ]; do
    if [ "$r" -gt 30 ]; then nap 30; r=$((r - 30)); else nap "$r"; r=0; fi
  done
}
wait_next_bucket() { wait_secs $(( $(secs_left_in_bucket) + MARGIN )); }
# wait_room N: make sure at least N seconds are left in the current bucket (else wait for the next one)
wait_room() { if [ "$(secs_left_in_bucket)" -lt "$1" ]; then wait_next_bucket; fi; }

# ---------------------------------------------------------------------------------------------------- run id and names
make_runid() {
  if [ -n "${RT_RUNID:-}" ]; then RUNID="$RT_RUNID"; return; fi   # test hook
  RUNID="$(date -u +%y%m%d%H%M)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
}
valid_runid() { printf '%s' "$1" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$'; }
set_names() { STACK="cftb-$RUNID"; BUCKET="cftb-$RUNID-content"; }

# ---------------------------------------------------------------------------------------------------- results
add_result() { # ID PASS|FAIL|INFO text
  RES_ID+=("$1"); RES_RESULT+=("$2"); RES_TEXT+=("$3"); say "  $2  $1  $3"
}
add_fact() { FACTS+=("$1"); say "  FACT  $1"; }
count_result() { local i n=0; for ((i = 0; i < ${#RES_RESULT[@]}; i++)); do [ "${RES_RESULT[$i]}" = "$1" ] && n=$((n + 1)); done; echo "$n"; }
write_report() { # TITLE
  REPORT_WRITTEN=1
  RESULTS_FILE="$RESULTS_DIR/results-$RUNID.md"
  local i
  {
    echo "# Time-bucket cache key, results of run $RUNID"
    echo
    echo "$1"
    echo
    echo "Run at $(date -u +%Y-%m-%dT%H:%M:%SZ). Bucket length ${BUCKET_SECONDS}s, long TTL ${LONG_TTL}s. In-window UTC hours ${IN_START}-${IN_END}, out-of-window ${OUT_START}-${OUT_END} (end exclusive)."
    echo "PASS=$(count_result PASS) FAIL=$(count_result FAIL)"
    echo
    echo "| Check | Result | Measured |"
    echo "|---|---|---|"
    for ((i = 0; i < ${#RES_ID[@]}; i++)); do echo "| ${RES_ID[$i]} | ${RES_RESULT[$i]} | ${RES_TEXT[$i]} |"; done
    echo
    echo "## Facts this run measured"
    echo
    if [ "${#FACTS[@]}" -eq 0 ]; then echo "- none"; fi
    for ((i = 0; i < ${#FACTS[@]}; i++)); do echo "- ${FACTS[$i]}"; done
  } | redact > "$RESULTS_FILE"
  say "results written to results-$RUNID.md (folder: ${RESULTS_DIR##*/})"
}

# ---------------------------------------------------------------------------------------------------- preflight, plan
preflight() {
  local t acct
  for t in aws jq curl; do command -v "$t" >/dev/null 2>&1 || die "$t not found in PATH"; done
  aws --version 2>&1 | grep -q 'aws-cli/2' || die "AWS CLI v2 is required"
  acct="$(aws_ro sts get-caller-identity --query Account --output text)" || die "cannot read the AWS identity (are you logged in?)"
  printf '%s' "$acct" | grep -Eq '^[0-9]{12}$' || die "unexpected answer from sts get-caller-identity"
  ACCOUNT_ID="$acct"   # only used for --expected-bucket-owner; never printed
  say "AWS identity: profile ${AWS_PROFILE:-<none, default credentials>}, region $REGION (account id not shown)"
}
check_inputs() {
  printf '%s' "$BUCKET_SECONDS" | grep -Eq '^[0-9]{1,3}$' || die "BUCKET_SECONDS must be a whole number of seconds, 20 to 600 (got '$BUCKET_SECONDS')"
  [ "$BUCKET_SECONDS" -ge 20 ] && [ "$BUCKET_SECONDS" -le 600 ] || die "BUCKET_SECONDS must be 20 to 600 (got '$BUCKET_SECONDS')"
  printf '%s' "$PROP_WAIT" | grep -Eq '^[0-9]{1,4}$' && [ "$PROP_WAIT" -ge 30 ] || die "PROP_WAIT must be a whole number of seconds, at least 30"
  printf '%s' "$POLL_GAP" | grep -Eq '^[0-9]{1,3}$' && [ "$POLL_GAP" -ge 1 ] || die "POLL_GAP must be a whole number of seconds, at least 1"
  case "$REGION" in *[!a-z0-9-]*|'') die "SAMPLE_REGION looks wrong" ;; esac
}
compute_windows() {
  local h; h="$(hour_now)"
  IN_START=$(( (h + 23) % 24 )); IN_END=$(( (h + 2) % 24 ))    # previous hour .. next hour: contains the current hour for the whole run
  OUT_START=$(( (h + 3) % 24 )); OUT_END=$(( (h + 5) % 24 ))    # excludes the current hour and the next two
}

print_plan() {
  cat <<EOF

Plan for run $RUNID: ONE CloudFormation stack $STACK (cfn/stack.yaml), tagged RunId=$RUNID, deleted at the end.
  S3 bucket $BUCKET           private, encrypted, TLS-only; read only by this distribution (origin access control)
  CloudFront Function          viewer-request, JS runtime 2.0, window and bucket length rendered into the code
  Cache policy                 min TTL 0, default and max ${LONG_TTL}s, header x-cache-bust in the cache key
  CloudFront distribution      PriceClass_100, https only
Windows (UTC hours, end exclusive): start inside [$IN_START,$IN_END), later moved to [$OUT_START,$OUT_END), then back.
Bucket length: ${BUCKET_SECONDS}s.
Phases: 1 deploy, 2 in-window (Miss then Hits, new bucket, overwrite), 3 viewer-supplied header, 4 window moved out and back
        (hits across a boundary, long-cached object not served in-window, header deleted), 5 S3/OAC verdict, 6 teardown verified.
Cost: pennies (a few hundred requests, one distribution for under an hour). Time: about 15-20 minutes, mostly CloudFront deploy and delete.
The run deletes everything it creates, also on error and Ctrl-C. Needs the typed phrase $PHRASE before anything is created.
EOF
}

# ---------------------------------------------------------------------------------------------------- stack
# params_json START END
params_json() {
  jq -n --arg r "$RUNID" --arg s "$1" --arg e "$2" --arg b "$BUCKET_SECONDS" --arg t "$LONG_TTL" \
    '[{ParameterKey:"RunId",ParameterValue:$r},{ParameterKey:"StartHour",ParameterValue:$s},{ParameterKey:"EndHour",ParameterValue:$e},
      {ParameterKey:"BucketSeconds",ParameterValue:$b},{ParameterKey:"LongTtl",ParameterValue:$t}]'
}

create_stack() {
  local out
  say "[1/6] checking that the stack and bucket names are free"
  if aws_ro cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then fail "a stack named $STACK already exists; refusing to continue"; fi
  stack_missing || fail "cannot tell whether stack $STACK exists (code: $(error_code)); refusing to continue"
  if aws_ro s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then fail "a bucket named $BUCKET already exists; refusing to continue"; fi
  case "$(error_code)" in 404|NotFound|NoSuchBucket) ;; *) fail "cannot tell whether bucket $BUCKET exists (code: $(error_code)); refusing to continue" ;; esac
  say "[2/6] creating the stack $STACK with the window [$IN_START,$IN_END) UTC"
  params_json "$IN_START" "$IN_END" > "$WORK/params.json" || fail "building the parameters"
  CREATE_STARTED=1   # set before the call: a Ctrl-C during it must still delete the stack
  aws_do cloudformation create-stack --stack-name "$STACK" --template-body "file://$TEMPLATE" --parameters "file://$WORK/params.json" \
    --tags "Key=RunId,Value=$RUNID" "Key=Purpose,Value=cftb-sample" >/dev/null || fail "create-stack"
  say "[3/6] waiting for CloudFormation (CloudFront deploys the distribution: usually 3-10 minutes)"
  aws_do cloudformation wait stack-create-complete --stack-name "$STACK" || fail "the stack did not reach CREATE_COMPLETE"
  out="$(aws_ro cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json)" || fail "cannot read the stack outputs"
  DIST_ID="$(printf '%s' "$out" | jq -r '.[] | select(.OutputKey=="DistributionId") | .OutputValue')"
  CF_DOMAIN="$(printf '%s' "$out" | jq -r '.[] | select(.OutputKey=="DistributionDomain") | .OutputValue')"
  [ -n "$DIST_ID" ] && [ "$DIST_ID" != null ] && [ -n "$CF_DOMAIN" ] && [ "$CF_DOMAIN" != null ] || fail "the stack outputs have no distribution"
  printf '%s' "$CF_DOMAIN" | grep -Eq '^[a-z0-9]+\.cloudfront\.net$' || fail "the distribution domain does not look like <id>.cloudfront.net; not sending requests to it"
}

# update_window START END: change the two parameters; returns when CloudFormation says the update is complete
update_window() {
  params_json "$1" "$2" > "$WORK/params.json" || fail "building the parameters"
  aws_do cloudformation update-stack --stack-name "$STACK" --use-previous-template --parameters "file://$WORK/params.json" >/dev/null || fail "update-stack"
  aws_do cloudformation wait stack-update-complete --stack-name "$STACK" || fail "the stack update did not complete"
  T_UPDATE="$(now_epoch)"
}
T_UPDATE=0

put_obj() { # KEY TEXT
  printf '%s\n' "$2" > "$WORK/obj.txt"
  aws_do s3api put-object --bucket "$BUCKET" --key "$1" --body "$WORK/obj.txt" --content-type text/plain --expected-bucket-owner "$ACCOUNT_ID" >/dev/null \
    || fail "uploading $1"
}

# ---------------------------------------------------------------------------------------------------- requests
# req PATH [HEADER...] -> R_ST R_XC (hit|miss|refreshhit|error|none) R_AGE (seconds or empty) R_BODY. Returns 1 when there was no HTTP answer.
req() {
  local path="$1" hv; shift
  local args=()
  for hv in "$@"; do args+=(-H "$hv"); done
  R_ST="" R_XC="none" R_AGE="" R_BODY=""
  : > "$WORK/r.h"; : > "$WORK/r.b"
  curl -sS --path-as-is -o "$WORK/r.b" -D "$WORK/r.h" --max-time 30 ${args[@]+"${args[@]}"} "https://$CF_DOMAIN$path" 2>"$WORK/curl.err" || return 1
  R_ST="$(tr -d '\r' < "$WORK/r.h" | awk 'NR==1{print $2}')"
  R_XC="$(tr -d '\r' < "$WORK/r.h" | awk -F': ' 'tolower($1)=="x-cache"{print tolower($2); exit}' | awk '{print $1}')"
  R_XC="${R_XC:-none}"
  R_AGE="$(tr -d '\r' < "$WORK/r.h" | awk -F': ' 'tolower($1)=="age"{print $2; exit}')"
  R_BODY="$(tr -d '\r\n' < "$WORK/r.b" | cut -c1-120)"
  [ -n "$R_ST" ]
}
is_hit() { [ "$R_XC" = hit ] || [ "$R_XC" = refreshhit ]; }
age_over() { # N: R_AGE is a number greater than N
  case "$R_AGE" in ''|*[!0-9]*) return 1 ;; esac
  [ "$R_AGE" -gt "$1" ]
}
desc() { echo "${R_ST:-000}/${R_XC}${R_AGE:+ age=${R_AGE}s} body='${R_BODY}'"; }

# ---------------------------------------------------------------------------------------------------- phases
S3_STATUS=""   # status of the first in-window request (warm-up), the answer to "does S3 accept the extra header"

phase_warmup() {
  local i
  say "[4/6] warm-up: waiting for the distribution to answer with the function active"
  put_obj "$WARM_KEY" "warm $RUNID"
  put_obj "$PROBE_KEY" "probe-v1 $RUNID"
  for ((i = 1; i <= WARMUP_TRIES; i++)); do
    if req "/$WARM_KEY"; then
      S3_STATUS="$R_ST"
      [ "$R_ST" = 200 ] && break
    fi
    nap "$POLL_GAP"
  done
  if [ "$S3_STATUS" = 200 ]; then
    add_result "S3-OAC-HEADER" PASS "in-window request with the forwarded x-cache-bust header: $(desc); S3 accepted the extra header"
    return 0
  fi
  add_result "S3-OAC-HEADER" FAIL "in-window request answered ${S3_STATUS:-no HTTP answer} after $WARMUP_TRIES tries. Diagnosing below."
  return 1
}

# Only when the warm-up never got a 200: move the window out so the header is absent, and see whether S3 then answers.
diagnose_403() {
  local t0 e
  say "diagnosis: moving the window out so that no x-cache-bust header is sent"
  update_window "$OUT_START" "$OUT_END"
  t0="$(now_epoch)"
  while :; do
    if req "/$WARM_KEY" && [ "$R_ST" = 200 ]; then
      add_result "S3-OAC-DIAGNOSIS" FAIL "403 only with the header: S3/OAC rejected the extra forwarded x-cache-bust header (answer without it: $(desc)). The bucket policy had time to propagate, so it is not the policy."
      return 0
    fi
    e=$(( $(now_epoch) - t0 ))
    [ "$e" -lt "$PROP_WAIT" ] || break
    nap "$POLL_GAP"
  done
  add_result "S3-OAC-DIAGNOSIS" FAIL "still ${R_ST:-no answer} without the header after ${PROP_WAIT}s: not (only) the header. Check the bucket policy / origin access control, or the function update never took effect."
}

phase_in_window() {
  local i first="" later_hits=0 x1 b1 b2
  say "[5/6] phase 2: in-window behaviour (bucket ${BUCKET_SECONDS}s)"
  wait_room 20
  req "/$PROBE_KEY"; first="$R_XC"; x1="$(desc)"
  b1="$(bucket_now)"
  for i in 1 2 3; do
    nap "$HIT_GAP"
    if req "/$PROBE_KEY" && is_hit; then later_hits=$((later_hits + 1)); fi
  done
  if [ "$first" = miss ] && [ "$later_hits" -ge 2 ]; then
    add_result "P2-MISS-THEN-HITS" PASS "4 requests in one bucket: first $x1, then $later_hits of 3 were Hit (last: $(desc))"
  else
    add_result "P2-MISS-THEN-HITS" FAIL "4 requests in one bucket: first '$first' ($x1), Hits among the next 3: $later_hits (expected Miss, then Hits)"
  fi
  add_fact "x-cache in one bucket: first=$first, then $later_hits Hit of 3 (bucket ${b1})"

  wait_next_bucket
  req "/$PROBE_KEY"; b2="$(bucket_now)"
  if [ "$R_XC" = miss ] && [ "$b2" != "$b1" ]; then
    add_result "P2-NEW-BUCKET-MISS" PASS "first request in the next bucket: $(desc) (same object, new cache key)"
  else
    add_result "P2-NEW-BUCKET-MISS" FAIL "first request in the next bucket: $(desc), expected Miss"
  fi
  req "/$PROBE_KEY"
  if is_hit; then add_result "P2-HIT-AGAIN" PASS "second request in that bucket: $(desc)"; else add_result "P2-HIT-AGAIN" FAIL "second request in that bucket: $(desc), expected Hit"; fi

  put_obj "$PROBE_KEY" "probe-v2 $RUNID"
  nap "$HIT_GAP"
  req "/$PROBE_KEY"
  add_result "P2-STALE-INSIDE-BUCKET" INFO "after overwriting the object, same bucket: $(desc) (bounded staleness, v1 expected until the boundary)"
  wait_next_bucket
  req "/$PROBE_KEY"
  case "$R_BODY" in
    *probe-v2*) add_result "P2-OVERWRITE-VISIBLE" PASS "after the next boundary: $(desc)" ;;
    *) add_result "P2-OVERWRITE-VISIBLE" FAIL "after the next boundary: $(desc), expected the new content probe-v2" ;;
  esac
}

phase_viewer_header_in() {
  local before
  say "phase 3: viewer-supplied x-cache-bust inside the window"
  wait_room 15
  req "/$PROBE_KEY"; before="$R_BODY"        # primes (or hits) the key of this bucket
  req "/$PROBE_KEY" "x-cache-bust: attacker-$RUNID"
  if is_hit && [ "$R_BODY" = "$before" ]; then
    add_result "P3-VIEWER-HEADER-OVERWRITTEN" PASS "request carrying x-cache-bust: attacker-... in-window: $(desc); same cache entry as without it, so the function overwrote the value"
  else
    add_result "P3-VIEWER-HEADER-OVERWRITTEN" FAIL "request carrying x-cache-bust: attacker-... in-window: $(desc), expected a Hit on the entry of this bucket"
  fi
}

# poll_until CONDITION-FUNCTION PATH: request PATH every POLL_GAP seconds until CONDITION returns 0 (PROP_SECS set), or PROP_WAIT is over
PROP_SECS=0
poll_until() {
  local cond="$1" path="$2" t0 e
  t0="$T_UPDATE"
  while :; do
    if req "$path" && "$cond"; then PROP_SECS=$(( $(now_epoch) - t0 )); return 0; fi
    e=$(( $(now_epoch) - T_UPDATE ))
    if [ "$e" -ge "$PROP_WAIT" ]; then PROP_SECS=$e; return 1; fi
    nap "$POLL_GAP"
  done
}
# R_AGE larger than the bucket length can only happen when the cache key does NOT change with time = window is out
cond_out() { [ "$R_ST" = 200 ] && is_hit && age_over $((BUCKET_SECONDS + 5)); }
# the new content shows up although an old copy is cached for a day = the in-window key differs from the long-cached one
cond_in() { [ "$R_ST" = 200 ] && case "$R_BODY" in *long-v2*) true ;; *) false ;; esac; }

phase_out_and_back() {
  local i hits=0
  say "phase 4: window moved to [$OUT_START,$OUT_END), which excludes the current hour"
  update_window "$OUT_START" "$OUT_END"
  if poll_until cond_out "/$PROBE_KEY"; then
    add_result "P4-OUT-OF-WINDOW-EFFECTIVE" PASS "Hit with Age > bucket length: $(desc), ${PROP_SECS}s after the update completed"
    add_fact "function update visible at the edge within ${PROP_SECS}s of the stack update completing (upper bound: includes up to $((BUCKET_SECONDS + 5))s for the Age check)"
  else
    add_result "P4-OUT-OF-WINDOW-EFFECTIVE" FAIL "the function update was not visible after ${PROP_SECS}s (waited at most ${PROP_WAIT}s); last: $(desc). Later phase-4 checks are skipped."
    return 1
  fi
  for i in 1 2 3; do nap "$HIT_GAP"; if req "/$PROBE_KEY" && is_hit; then hits=$((hits + 1)); fi; done
  if [ "$hits" = 3 ]; then
    add_result "P4-HITS-ACROSS-BOUNDARY" PASS "object stays a Hit across at least one bucket boundary (Age $R_AGE s > ${BUCKET_SECONDS}s); 3 of 3 further requests Hit"
  else
    add_result "P4-HITS-ACROSS-BOUNDARY" FAIL "only $hits of 3 further requests were Hit out of window"
  fi
  local before="$R_BODY"
  req "/$PROBE_KEY" "x-cache-bust: force-miss-$RUNID"
  if is_hit && [ "$R_BODY" = "$before" ]; then
    add_result "P4-VIEWER-HEADER-DELETED" PASS "x-cache-bust: force-miss-... out of window: $(desc); still the cached entry, the header was deleted"
  else
    add_result "P4-VIEWER-HEADER-DELETED" FAIL "x-cache-bust: force-miss-... out of window: $(desc); a viewer-supplied header changed the cache key"
  fi

  # long-cached object, then move the window back in
  put_obj "$LONG_KEY" "long-v1 $RUNID"
  req "/$LONG_KEY"; local l1="$R_XC"
  nap "$HIT_GAP"; req "/$LONG_KEY"; local l2="$R_XC"
  put_obj "$LONG_KEY" "long-v2 $RUNID"
  nap "$HIT_GAP"; req "/$LONG_KEY"
  if [ "$l1" = miss ] && [ "$l2" = hit ] && is_hit && case "$R_BODY" in *long-v1*) true ;; *) false ;; esac; then
    add_result "P4-LONG-CACHE" PASS "out of window: Miss, Hit, then after the S3 overwrite still the old copy: $(desc)"
  else
    add_result "P4-LONG-CACHE" FAIL "out of window: first '$l1', second '$l2', after overwrite: $(desc) (expected Miss, Hit, old content)"
  fi
  say "phase 4b: window moved back to [$IN_START,$IN_END)"
  update_window "$IN_START" "$IN_END"
  if poll_until cond_in "/$LONG_KEY"; then
    local first="$R_XC"
    req "/$LONG_KEY"
    if [ "$first" = miss ] && is_hit; then
      add_result "P4-LONG-NOT-SERVED-IN-WINDOW" PASS "back in-window: the long-cached copy was not used; new content after ${PROP_SECS}s: Miss then Hit ($(desc))"
    else
      add_result "P4-LONG-NOT-SERVED-IN-WINDOW" PASS "back in-window: the long-cached copy was not used (new content after ${PROP_SECS}s) but x-cache was '$first' then '$R_XC'"
    fi
    add_fact "function update (window moved back in) visible within ${PROP_SECS}s of the stack update completing"
  else
    add_result "P4-LONG-NOT-SERVED-IN-WINDOW" FAIL "after ${PROP_SECS}s in-window the object still shows the long-cached content: $(desc)"
  fi
}

# ---------------------------------------------------------------------------------------------------- teardown
tag_of_stack() {
  aws_ro cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Tags[?Key=='RunId'].Value | [0]" --output text
}
settle_stack() { # sets ST. 0 settled, 1 timed out, 2 cannot read
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
td_main() {
  local tag rc k
  say "teardown: deleting only stack $STACK (tagged RunId=$RUNID) and its bucket content"
  tag="$(tag_of_stack)"; rc=$?
  if [ "$rc" != 0 ]; then
    if stack_missing; then say "  stack: already gone"; STACK_GONE=1; return 0; fi
    say "  stack: cannot read its tags, NOT deleting"; TD_FAIL=1; return 0
  fi
  if [ "$tag" != "$RUNID" ]; then say "  stack: tag RunId is '$tag', not this run: NOT deleting"; TD_FAIL=1; return 0; fi
  say "  stack: waiting until it is no longer in progress"
  settle_stack; rc=$?
  case $rc in
    1) say "  stack: still $ST after the waiting time; NOT deleting it. Look in the CloudFormation console, then ./run-sample.sh --cleanup $RUNID"; TD_FAIL=1; return 0 ;;
    2) if stack_missing; then say "  stack: gone"; STACK_GONE=1; return 0; fi; say "  stack: cannot read its status"; TD_FAIL=1; return 0 ;;
  esac
  say "  stack: status $ST"
  # The bucket must be empty before the stack can delete it. Only the three keys this script writes are removed.
  for k in "$PROBE_KEY" "$LONG_KEY" "$WARM_KEY"; do
    aws_do s3api delete-object --bucket "$BUCKET" --key "$k" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1
  done
  say "  stack: deleting (CloudFront disables and deletes the distribution: several minutes)"
  if ! aws_do cloudformation delete-stack --stack-name "$STACK" >/dev/null; then say "  stack: delete-stack failed"; TD_FAIL=1; return 0; fi
  if ! aws_ro cloudformation wait stack-delete-complete --stack-name "$STACK"; then
    say "  stack: delete FAILED or timed out. Look at the stack events in the CloudFormation console; stack $STACK is kept."
    TD_FAIL=1; return 0
  fi
  # verified, not assumed: the stack must be reported as not existing, and the bucket must be gone
  aws_ro cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1
  if stack_missing; then STACK_GONE=1; say "  stack: deleted and verified gone"; else say "  stack: delete reported done but the stack can still be read"; TD_FAIL=1; fi
  if aws_ro s3api head-bucket --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
    say "  bucket: still exists after the stack delete"; TD_FAIL=1
  else
    case "$(error_code)" in 404|NotFound|NoSuchBucket) say "  bucket: verified gone" ;; *) say "  bucket: cannot verify (code: $(error_code))"; TD_FAIL=1 ;; esac
  fi
}
teardown() {
  td_main
  if [ "$TD_FAIL" = 0 ]; then say "teardown: complete"; else say "teardown: INCOMPLETE. Read the lines above. Resources named cftb-$RUNID* may still exist (cents at most). Retry: ./run-sample.sh --cleanup $RUNID"; fi
}

# shellcheck disable=SC2329  # runs from the EXIT trap
on_exit() {
  local rc=$?
  trap '' INT TERM HUP    # a second Ctrl-C must not interrupt the teardown
  exec >&3 2>&4           # undo any redirect that was active when the signal arrived
  if [ "$CREATE_STARTED" = 1 ] && [ "$TEARDOWN_DONE" = 0 ]; then
    TEARDOWN_DONE=1
    if [ "$REPORT_WRITTEN" = 0 ] && [ "${#RES_ID[@]}" -gt 0 ]; then write_report "ABORTED (rc=$rc), partial results"; fi
    say ""
    teardown
    if [ -n "$RESULTS_FILE" ] && [ -f "$RESULTS_FILE" ]; then
      local msg
      if [ "$TD_FAIL" != 0 ]; then msg="INCOMPLETE: some resources of this run may still exist. See the screen output."
      else msg="Complete: the stack and its bucket were deleted and verified gone."; fi
      redact <<< "
## Teardown

$msg" >> "$RESULTS_FILE"
    fi
    if [ "$TD_FAIL" != 0 ]; then rc=4; fi   # an incomplete teardown always wins: leftovers must not be hidden by an earlier code
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

confirm() { # prompt text; the answer must be exactly the phrase
  local answer=""
  printf '%s\nType %s to continue: ' "$1" "$PHRASE" >&3
  IFS= read -r answer || answer=""
  if [ "$answer" = "$PHRASE" ]; then return 0; fi   # GATE
  echo "Phrase not matched. Nothing was created or deleted." >&3
  return 1
}

# ---------------------------------------------------------------------------------------------------- main
check_inputs
if [ "$MODE" = cleanup ]; then
  valid_runid "$CLEANUP_ID" || die "the run id must look like 2610101200-ab12"
  RUNID="$CLEANUP_ID"
else
  make_runid
  valid_runid "$RUNID" || die "RT_RUNID must look like 2610101200-ab12"
fi
set_names
preflight
compute_windows

if [ "$MODE" = cleanup ]; then
  say "cleanup of run $RUNID: stack $STACK, bucket $BUCKET"
  if [ "$DRY_RUN" = 1 ]; then say "dry run: would delete only stack $STACK if it carries the tag RunId=$RUNID. Nothing was created or deleted."; exit 0; fi
  confirm "This deletes stack $STACK and everything in it." || exit 3
  CREATE_STARTED=1   # the EXIT trap runs the teardown
  exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
  aws_ro cloudformation validate-template --template-body "file://$TEMPLATE" >/dev/null || die "template validation failed"
  say "template validates"
  print_plan
  say ""
  say "dry run: nothing was created or deleted."
  exit 0
fi

print_plan
confirm "This creates stack $STACK in region $REGION and deletes it at the end of the run." || exit 3
aws_ro cloudformation validate-template --template-body "file://$TEMPLATE" >/dev/null || die "template validation failed"
say "run id: $RUNID  (if this run is ever cut off: ./run-sample.sh --cleanup $RUNID)"

create_stack
if phase_warmup; then
  phase_in_window
  phase_viewer_header_in
  phase_out_and_back
else
  diagnose_403
fi
FAILS="$(count_result FAIL)"
if [ "$FAILS" = 0 ]; then write_report "Verdict: ALL CHECKS PASSED"; else write_report "Verdict: $FAILS CHECK(S) FAILED"; fi
say ""
say "PASS=$(count_result PASS) FAIL=$FAILS  (teardown follows)"
if [ "$FAILS" = 0 ]; then exit 0; else exit 1; fi
