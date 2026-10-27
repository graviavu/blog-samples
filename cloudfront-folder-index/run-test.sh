#!/usr/bin/env bash
# run-test.sh - ONE entry point. Deploys cfn/stack.yaml (private S3 bucket + OAC + two CloudFront distributions + one function),
# checks four claims from the post, prints PASS or FAIL for each with the raw HTTP status and the X-Cache and Age headers,
# writes results-<run id>.md, and deletes everything it created (also on error and Ctrl-C).
#
#   ./run-test.sh                    default is --dry-run: print the plan and the cost note; makes NO AWS call
#   ./run-test.sh --run              ask for the phrase, create, test, tear down
#   ./run-test.sh --cleanup RUNID    delete leftovers of an earlier run after a typed phrase (add --dry-run to only look)
#
# Needs: aws CLI v2, jq, curl, bash 3.2+. Region us-east-1. No credentials are stored or printed.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/cfn/stack.yaml"

REGION="us-east-1"
PHRASE="create folder test stack"
CLEANUP_PHRASE="delete folder test stack"
ERR_WAIT_SECS="${ERR_WAIT_SECS:-75}"          # wait for the 60 s error-caching time to run out
WARMUP_TRIES="${WARMUP_TRIES:-15}"
WARMUP_PAUSE="${WARMUP_PAUSE:-20}"
SETTLE_POLLS="${SETTLE_POLLS:-120}"           # polls while a stack is *_IN_PROGRESS before deleting it ...
STACK_POLL_SECS="${STACK_POLL_SECS:-30}"      # ... 30 s apart: about 60 minutes
RESULTS_DIR="${RESULTS_DIR:-.}"
NEW_HOST_EXPECT="www.example.invalid"
export AWS_PAGER=""
umask 077

MODE=run CLEANUP_ID="" DRY_EXPLICIT=0 RUN_FLAG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_EXPLICIT=1 ;;
    --run) RUN_FLAG=1 ;;
    --cleanup)
      shift; MODE=cleanup; CLEANUP_ID="${1:-}"
      case "$CLEANUP_ID" in --*|"") echo "--cleanup needs the run id first: ./run-test.sh --cleanup 2610101200-ab12 [--dry-run]" >&2; exit 2 ;; esac ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done
# A test run is a dry run unless --run is given. A cleanup acts (after the typed phrase) unless --dry-run is given.
if [ "$DRY_EXPLICIT" = 1 ]; then DRY_RUN=1
elif [ "$MODE" = cleanup ] || [ "$RUN_FLAG" = 1 ]; then DRY_RUN=0
else DRY_RUN=1; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cfi.XXXXXX")" || exit 2
export RT_MAIN_PID=$$   # lets the test stubs signal this script
exec 3>&1 4>&2
RUNID="" STACK="" BUCKET="" PLAIN="" FIXED="" ACCOUNT_ID="" ACCT_LAST4=""
CREATE_STARTED=0 TEARDOWN_DONE=0 TD_FAIL=0 RESULTS_FILE="" REPORT_WRITTEN=0
RES_ID=() RES_RESULT=() RES_TEXT=() RAW=() NOTES=()

# ---------------------------------------------------------------------------------------------------- output, redaction
# Everything that reaches the screen or the results file goes through redact(). Best effort: read the file before you send it.
redact() {
  local extra=() lit
  for lit in "$BUCKET" "$PLAIN" "$FIXED"; do
    [ -n "$lit" ] || continue
    lit="$(printf '%s' "$lit" | sed -e 's/[][\.*^$/|+?(){}]/\\&/g')"
    extra+=(-e "s|$lit|<host-or-bucket>|g")
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
# say uses a here-string, not a pipe: after Ctrl-C, bash kills pipelines started in the EXIT trap.
say() { redact <<< "$*"; }
die() { say "ERROR: $*" >&2; exit 2; }
fail() { say "ERROR: $*" >&2; exit 1; }
note() { NOTES+=("$*"); }

# ---------------------------------------------------------------------------------------------------- aws wrappers
# aws_ro reads, aws_do changes things (refused in --dry-run). Both redact error text; stdout is for the caller.
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
nap() { sleep "$1"; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
set_names() { STACK="cfi-$RUNID"; BUCKET="cfi-$RUNID-site"; }
valid_id() { printf '%s' "$1" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$'; }
new_id() {
  local r; r="$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s-%s' "$(date -u +%y%m%d%H%M)" "$r"
}

# ---------------------------------------------------------------------------------------------------- teardown
stack_missing() { grep -Fq "Stack with id $STACK does not exist" "$WORK/aws.err" 2>/dev/null; }

# Empty the bucket: every key of THIS run's bucket (it is not versioned). Keys that end in "/" are listed like any other.
td_empty_bucket() {
  local keys k n=0
  keys="$(aws_ro s3api list-objects-v2 --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --output json)" || {
    if grep -Eq "NoSuchBucket|404" "$WORK/aws.err" 2>/dev/null; then say "  bucket: already gone"; return 0; fi
    say "  bucket: cannot list it"; TD_FAIL=1; return 1; }
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    aws_do s3api delete-object --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --key "$k" >/dev/null || { TD_FAIL=1; say "  bucket: delete of a key failed"; return 1; }
    n=$((n + 1))
  done < <(jq -r '.Contents[]?.Key' <<< "$keys")
  say "  bucket: $n object(s) deleted"
}

# Returns 0 settled, 1 timed out, 2 cannot read, 44 stack not found.
settle_stack() {
  local i=0 st
  while :; do
    st="$(aws_ro cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].StackStatus' --output text)" || {
      if stack_missing; then return 44; fi
      return 2; }
    case "$st" in *_IN_PROGRESS) ;; *) return 0 ;; esac
    i=$((i + 1)); [ "$i" -lt "$SETTLE_POLLS" ] || return 1
    nap "$STACK_POLL_SECS"
  done
}

# Nothing is deleted unless the stack carries tag RunId = this run id and tag Purpose = sample, and its bucket is the one named for this run.
teardown() {
  local rc tag purpose res
  say "Teardown of run $RUNID"
  tag="$(aws_ro cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Tags[?Key=='RunId'].Value | [0]" --output text)" || {
    if stack_missing; then say "  stack: already gone"; return 0; fi
    say "  stack: cannot read its tags, NOT deleting"; TD_FAIL=1; return 1; }
  purpose="$(aws_ro cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Tags[?Key=='Purpose'].Value | [0]" --output text)"
  if [ "$tag" != "$RUNID" ] || [ "$purpose" != "sample" ]; then
    say "  stack: tags are RunId '$tag' Purpose '$purpose', not this run: NOT deleting"; TD_FAIL=1; return 1
  fi
  say "  stack: waiting until it is no longer in progress (CloudFront needs several minutes)"
  settle_stack; rc=$?
  case $rc in
    0) ;;
    44) say "  stack: already gone"; return 0 ;;
    1) say "  stack: still in progress after the wait, NOT deleting; run --cleanup $RUNID later"; TD_FAIL=1; return 1 ;;
    *) say "  stack: cannot read its status"; TD_FAIL=1; return 1 ;;
  esac
  res="$(aws_ro cloudformation describe-stack-resources --stack-name "$STACK" --query "StackResources[?LogicalResourceId=='SiteBucket'].PhysicalResourceId | [0]" --output text)" || res=""
  if [ -n "$res" ] && [ "$res" != "None" ] && [ "$res" != "$BUCKET" ]; then
    say "  stack: its bucket is not the one named for this run, NOT deleting"; TD_FAIL=1; return 1
  fi
  if [ "$res" = "$BUCKET" ]; then td_empty_bucket || return 1; fi
  aws_do cloudformation delete-stack --stack-name "$STACK" >/dev/null || { say "  stack: delete-stack failed"; TD_FAIL=1; return 1; }
  say "  stack: deleting (CloudFront disables and deletes both distributions, a few minutes)"
  if ! aws_do cloudformation wait stack-delete-complete --stack-name "$STACK"; then
    # one retry after emptying the bucket again (a key written late would block the delete)
    td_empty_bucket
    aws_do cloudformation delete-stack --stack-name "$STACK" >/dev/null || true
    if ! aws_do cloudformation wait stack-delete-complete --stack-name "$STACK"; then
      say "  stack: NOT deleted. Run: ./run-test.sh --cleanup $RUNID"; TD_FAIL=1; return 1
    fi
  fi
  say "  stack: deleted"
}

# shellcheck disable=SC2329  # runs from the EXIT trap
on_exit() {
  local rc=$?
  trap '' INT TERM HUP
  exec >&3 2>&4
  if [ "$CREATE_STARTED" = 1 ] && [ "$TEARDOWN_DONE" = 0 ]; then
    TEARDOWN_DONE=1
    if [ "$REPORT_WRITTEN" = 0 ] && [ "${#RES_ID[@]}" -gt 0 ]; then write_report "ABORTED (rc=$rc), partial results"; fi
    say ""
    teardown
    if [ -n "$RESULTS_FILE" ] && [ -f "$RESULTS_FILE" ]; then
      if [ "$TD_FAIL" != 0 ]; then
        redact <<< "
## Teardown

INCOMPLETE: some resources of this run may still exist. Run: ./run-test.sh --cleanup $RUNID" >> "$RESULTS_FILE"
      else
        redact <<< "
## Teardown

Complete: every resource of this run was deleted." >> "$RESULTS_FILE"
      fi
    fi
    if [ "$TD_FAIL" != 0 ]; then rc=4; fi   # an incomplete teardown always wins
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# ---------------------------------------------------------------------------------------------------- preflight
preflight() {
  local t acct
  for t in aws jq curl; do command -v "$t" >/dev/null 2>&1 || die "$t not found in PATH"; done
  aws --version 2>&1 | grep -q 'aws-cli/2' || die "AWS CLI v2 is required"
  acct="$(aws_ro sts get-caller-identity --query Account --output text)" || die "cannot read the AWS identity (are you logged in?)"
  printf '%s' "$acct" | grep -Eq '^[0-9]{12}$' || die "unexpected answer from sts get-caller-identity"
  ACCOUNT_ID="$acct"
  ACCT_LAST4="${acct: -4}"   # screen only: never written to the results file
  say "AWS identity: profile ${AWS_PROFILE:-<none, default credentials>}, account ********$ACCT_LAST4, region $REGION"
  if [ -n "${EXPECT_ACCOUNT_LAST4:-}" ]; then
    printf '%s' "$EXPECT_ACCOUNT_LAST4" | grep -Eq '^[0-9]{4}$' || die "EXPECT_ACCOUNT_LAST4 must be exactly 4 digits"
    [ "$EXPECT_ACCOUNT_LAST4" = "$ACCT_LAST4" ] || die "the account does not end in EXPECT_ACCOUNT_LAST4: wrong profile? Nothing was done."
  fi
}

print_plan() {
  local id="$1"
  cat <<PLAN_END

Plan for run $id: ONE CloudFormation stack cfi-$id (cfn/stack.yaml), tagged RunId=$id and Purpose=sample, deleted at the end.
  Created by the stack:
    S3 bucket               cfi-$id-site   private, block public access on, encrypted, TLS-only deny, only s3:GetObject for CloudFront
    Origin access control   cfi-$id-oac
    CloudFront Function     cfi-$id-rewrite   the post's RewriteFunction (old domain off)
    Distribution "plain"    S3 REST origin + OAC, no function, no error response
    Distribution "fixed"    same origin, rewrite function on viewer-request, 403 -> /404.html as 404, error caching 60 s
  Uploaded by this script: posts/x/index.html, posts/y/ (zero bytes), posts/z/ (html), 404.html, late.html (during claim 4).
Checks (each prints PASS or FAIL with the raw HTTP status, X-Cache and Age):
  C1  folder URL /posts/x/ on "plain" returns 403 although posts/x/index.html exists
  C2  keys 'posts/y/' (zero bytes) and 'posts/z/' (html) are served through REST + OAC, block public access on
  C3  the rewrite function makes /posts/x/ return posts/x/index.html on "fixed"
  C4  the 403 -> /404.html custom error response: status 404, the error is held 60 s, the page appears after that
Teardown: empty the bucket, delete the stack (CloudFront disables and deletes the distributions).
Cost: pennies. A few dozen requests, a few KB in S3, inside the free tiers of CloudFront and CloudFront Functions. Nothing is left
      running; if a teardown fails an idle distribution costs nothing without traffic. Fix it with --cleanup $id.
Time: about 15-25 minutes, mostly waiting for CloudFront to deploy and to delete.
PLAN_END
}

# ---------------------------------------------------------------------------------------------------- http checks
F_CODE="" F_XC="" F_AGE="" F_CT="" F_CL="" F_LOC="" F_BODY=""
hdr() { grep -i "^$1:" "$WORK/hdr" 2>/dev/null | tail -n 1 | tr -d '\r' | sed -e 's/^[^:]*: *//'; }
# fetch LABEL HOST PATH : GET https://HOST/PATH, fills F_* and appends a raw line for the results file
fetch() {
  local label="$1" host="$2" path="$3"
  : > "$WORK/hdr"; : > "$WORK/body"
  F_CODE="$(curl -sS --max-time 30 -o "$WORK/body" -D "$WORK/hdr" -w '%{http_code}' "https://$host$path" 2>/dev/null)" || F_CODE="000"
  F_XC="$(hdr x-cache)"; F_AGE="$(hdr age)"; F_CT="$(hdr content-type)"; F_CL="$(hdr content-length)"; F_LOC="$(hdr location)"
  F_BODY="$(head -c 200 "$WORK/body" | tr -d '\r\n')"
  RAW+=("$label|GET $path|$F_CODE|${F_XC:--}|${F_AGE:--}|${F_CT:--}|${F_CL:--}|${F_LOC:--}")
  say "    $label  GET $path  status $F_CODE  X-Cache: ${F_XC:--}  Age: ${F_AGE:--}"
}
put_key() { # KEY CONTENT-TYPE BODYFILE
  aws_do s3api put-object --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --key "$1" --content-type "$2" --body "$3" >/dev/null || fail "upload of $1 failed"
}
add_result() { RES_ID+=("$1"); RES_RESULT+=("$2"); RES_TEXT+=("$3"); say "  $1  $2  $3"; }
is_html() { case "$1" in text/html*) return 0 ;; *) return 1 ;; esac; }

write_report() { # heading
  local f i line
  f="$RESULTS_DIR/results-$RUNID.md"; RESULTS_FILE="$f"
  {
    echo "# Results: folder URL sample, run $RUNID"
    echo
    echo "$1. Date $(stamp), region $REGION."
    echo
    echo "| Check | Result | What was measured |"
    echo "|---|---|---|"
    for ((i = 0; i < ${#RES_ID[@]}; i++)); do echo "| ${RES_ID[$i]} | ${RES_RESULT[$i]} | ${RES_TEXT[$i]} |"; done
    echo
    echo "## Raw requests"
    echo
    echo "| Label | Request | Status | X-Cache | Age | Content-Type | Content-Length | Location |"
    echo "|---|---|---|---|---|---|---|---|"
    for line in ${RAW[@]+"${RAW[@]}"}; do echo "| ${line//|/ | } |"; done
    if [ "${#NOTES[@]}" -gt 0 ]; then echo; echo "## Notes"; echo; for line in "${NOTES[@]}"; do echo "- $line"; done; fi
  } | redact > "$f"
  REPORT_WRITTEN=1
}

run_checks() {
  local d="$WORK/up" try ready=0 pab anon c1 c2y c2z c3 c4a c4b c4c o403 ctrl_body a_body
  local y_ct y_cl y_body y_xc y_age y_ok z_ok b_xc b_age
  mkdir -p "$d"
  printf 'INDEX-PAGE-%s' "$RUNID" > "$d/index.html"
  : > "$d/empty"
  printf '<html><body>FOLDER-OBJECT-%s</body></html>' "$RUNID" > "$d/folder.html"
  printf '<html><body>NOT-FOUND-PAGE-%s</body></html>' "$RUNID" > "$d/404.html"
  printf 'LATE-PAGE-%s' "$RUNID" > "$d/late.html"

  say "[3/5] uploading test objects"
  put_key "posts/x/index.html" text/html "$d/index.html"
  put_key "posts/y/" text/html "$d/empty"
  put_key "posts/z/" text/html "$d/folder.html"
  put_key "404.html" text/html "$d/404.html"

  say "[4/5] waiting until both distributions answer"
  for ((try = 1; try <= WARMUP_TRIES; try++)); do
    fetch "warmup-plain" "$PLAIN" "/posts/x/index.html"; c1="$F_CODE"
    fetch "warmup-fixed" "$FIXED" "/404.html"; c2y="$F_CODE"
    if [ "$c1" = 200 ] && [ "$c2y" = 200 ]; then ready=1; break; fi
    nap "$WARMUP_PAUSE"
  done
  [ "$ready" = 1 ] || fail "the distributions did not answer with 200 after $WARMUP_TRIES tries (see the lines above)"

  say "[5/5] checks"
  # ---- C1: the folder URL returns 403 although posts/x/index.html exists
  say "  C1 folder URL on the plain distribution"
  fetch "C1-control" "$PLAIN" "/posts/x/index.html"; c1="$F_CODE"; ctrl_body="$F_BODY"
  fetch "C1-folder" "$PLAIN" "/posts/x/"
  if [ "$c1" = 200 ] && [ "$ctrl_body" = "INDEX-PAGE-$RUNID" ] && [ "$F_CODE" = 403 ]; then
    add_result C1 PASS "/posts/x/index.html gives 200 but /posts/x/ gives 403 (X-Cache: ${F_XC:--}, Age: ${F_AGE:--}); index.html was not appended"
  else
    add_result C1 FAIL "control status $c1, folder status $F_CODE (expected 200 and 403)"
  fi
  case "$F_BODY" in *AccessDenied*) note "C1: the 403 body from S3 is an AccessDenied error document." ;; esac

  # ---- C2: keys that end in "/" are served through REST + OAC with block public access on
  say "  C2 objects stored under keys that end in '/'"
  pab="$(aws_ro s3api get-public-access-block --bucket "$BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,BlockPublicPolicy,IgnorePublicAcls,RestrictPublicBuckets]' --output text 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/ $//')"
  fetch "C2-anonymous-s3" "$BUCKET.s3.$REGION.amazonaws.com" "/posts/z/"; anon="$F_CODE"
  fetch "C2-zero-byte" "$PLAIN" "/posts/y/"; c2y="$F_CODE"
  y_ct="$F_CT"; y_cl="$F_CL"; y_body="$F_BODY"; y_xc="$F_XC"; y_age="$F_AGE"
  fetch "C2-html" "$PLAIN" "/posts/z/"; c2z="$F_CODE"
  y_ok=0; z_ok=0
  if [ "$c2y" = 200 ] && [ -z "$y_body" ] && { [ "$y_cl" = 0 ] || [ -z "$y_cl" ]; } && is_html "$y_ct"; then y_ok=1; fi
  if [ "$c2z" = 200 ] && [ "$F_BODY" = "<html><body>FOLDER-OBJECT-$RUNID</body></html>" ] && is_html "$F_CT"; then z_ok=1; fi
  if [ "$pab" = "True True True True" ] && [ "$anon" = 403 ] && [ "$y_ok" = 1 ] && [ "$z_ok" = 1 ]; then
    add_result C2 PASS "block public access = $pab; anonymous S3 GET $anon; /posts/y/ (zero bytes) 200 text/html X-Cache: ${y_xc:--} Age: ${y_age:--}; /posts/z/ (html) 200 text/html X-Cache: ${F_XC:--} Age: ${F_AGE:--}"
  else
    add_result C2 FAIL "block public access = '${pab:-unreadable}', anonymous S3 GET $anon (want 403), zero-byte object status $c2y (ok=$y_ok), html object status $c2z (ok=$z_ok)"
  fi

  # ---- C3: the rewrite function fixes the folder URL
  say "  C3 rewrite function on the fixed distribution"
  fetch "C3-folder" "$FIXED" "/posts/x/"; c3="$F_CODE"
  if [ "$c3" = 200 ] && [ "$F_BODY" = "INDEX-PAGE-$RUNID" ]; then
    add_result C3 PASS "/posts/x/ gives 200 with the content of posts/x/index.html (X-Cache: ${F_XC:--}, Age: ${F_AGE:--})"
  else
    add_result C3 FAIL "status $c3, body '${F_BODY:0:60}' (expected 200 and the index.html content)"
  fi
  fetch "info-no-slash" "$FIXED" "/posts/x"
  if [ "$F_CODE" = 301 ] && [ "$F_LOC" = "https://$NEW_HOST_EXPECT/posts/x/" ]; then
    note "Info (not one of the four claims): /posts/x on the fixed distribution answered 301 to the slash form, as the function says."
  else
    note "Info (not one of the four claims): /posts/x on the fixed distribution answered status $F_CODE, Location ${F_LOC:--} (expected 301 to https://$NEW_HOST_EXPECT/posts/x/)."
  fi

  # ---- C4: 403 -> /404.html as 404, error held for 60 s
  say "  C4 custom error response 403 -> /404.html, error caching 60 s"
  fetch "C4-missing-key-plain" "$PLAIN" "/late.html"; o403="$F_CODE"
  fetch "C4-a-missing" "$FIXED" "/late.html"; c4a="$F_CODE"; a_body="$F_BODY"
  put_key "late.html" text/html "$d/late.html"
  fetch "C4-b-after-upload-within-60s" "$FIXED" "/late.html"; c4b="$F_CODE"; b_xc="$F_XC"; b_age="$F_AGE"
  say "    waiting $ERR_WAIT_SECS s for the error-caching time to run out"
  nap "$ERR_WAIT_SECS"
  fetch "C4-c-after-wait" "$FIXED" "/late.html"; c4c="$F_CODE"
  if [ "$o403" = 403 ] && [ "$c4a" = 404 ] && [[ "$a_body" == *"NOT-FOUND-PAGE-$RUNID"* ]] && [ "$c4b" = 404 ] && [ "$c4c" = 200 ] && [ "$F_BODY" = "LATE-PAGE-$RUNID" ]; then
    add_result C4 PASS "missing key: origin 403 (plain) became 404 with the /404.html page (fixed); after the upload the error stayed for the 60 s window (status $c4b, X-Cache: ${b_xc:--}, Age: ${b_age:--}); after $ERR_WAIT_SECS s status $c4c"
  else
    add_result C4 FAIL "plain missing-key status $o403 (want 403); fixed: first $c4a (want 404), after upload within 60 s $c4b (want 404), after $ERR_WAIT_SECS s $c4c (want 200)"
    if [ "$c4b" = 200 ]; then note "C4: the second request returned the new page at once. Either the error was not held, or the request reached another edge location that had not cached it."; fi
  fi
}

# ---------------------------------------------------------------------------------------------------- modes
create_and_test() {
  local out i fails=0
  say "[1/5] creating the stack $STACK (CloudFront deploys two distributions, about 5-15 minutes)"
  CREATE_STARTED=1
  aws_do cloudformation create-stack --stack-name "$STACK" --template-body "file://$TEMPLATE" \
    --parameters "ParameterKey=RunId,ParameterValue=$RUNID" \
    --tags "Key=RunId,Value=$RUNID" "Key=Purpose,Value=sample" >/dev/null || fail "create-stack"
  say "[2/5] waiting for the stack"
  aws_do cloudformation wait stack-create-complete --stack-name "$STACK" || fail "the stack did not reach CREATE_COMPLETE"
  out="$(aws_ro cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json)" || fail "describe-stacks"
  PLAIN="$(jq -r '.[] | select(.OutputKey=="PlainDomain") | .OutputValue' <<< "$out")"
  FIXED="$(jq -r '.[] | select(.OutputKey=="FixedDomain") | .OutputValue' <<< "$out")"
  [ "$(jq -r '.[] | select(.OutputKey=="BucketName") | .OutputValue' <<< "$out")" = "$BUCKET" ] || fail "the stack bucket is not the expected one"
  case "$PLAIN" in *.cloudfront.net) ;; *) fail "unexpected plain domain" ;; esac
  case "$FIXED" in *.cloudfront.net) ;; *) fail "unexpected fixed domain" ;; esac
  run_checks
  for ((i = 0; i < ${#RES_RESULT[@]}; i++)); do [ "${RES_RESULT[$i]}" = PASS ] || fails=$((fails + 1)); done
  write_report "Finished"
  say ""
  say "Results file: $RESULTS_FILE  (read it, then send it back)"
  [ "$fails" = 0 ] || return 1
  return 0
}

if [ "$MODE" = cleanup ]; then
  valid_id "$CLEANUP_ID" || die "run id must look like 2610101200-ab12"
  RUNID="$CLEANUP_ID"; set_names
  if [ "$DRY_RUN" = 1 ]; then
    say "Dry run: would delete stack $STACK and the objects in its bucket, only if the stack carries tags RunId=$RUNID and Purpose=sample. No AWS call made."
    exit 0
  fi
  preflight
  say "Cleanup of run $RUNID: stack $STACK and its bucket."
  printf 'Type "%s" to continue: ' "$CLEANUP_PHRASE" >&3
  IFS= read -r phrase || phrase=""
  [ "$phrase" = "$CLEANUP_PHRASE" ] || die "phrase did not match; nothing was done"
  CREATE_STARTED=1   # the exit trap runs the same guarded teardown
  exit 0
fi

RUNID="${RT_RUNID:-$(new_id)}"; valid_id "$RUNID" || die "bad run id $RUNID"
set_names
if [ "$DRY_RUN" = 1 ]; then
  print_plan "$RUNID"
  say ""
  say "Dry run: no AWS call was made. To run it for real: ./run-test.sh --run"
  exit 0
fi
preflight
print_plan "$RUNID"
printf '\nType "%s" to continue: ' "$PHRASE" >&3
IFS= read -r phrase || phrase=""
[ "$phrase" = "$PHRASE" ] || die "phrase did not match; nothing was done"
create_and_test
