#!/usr/bin/env bash
# run-test.sh - ONE entry point. Deploys cfn/stack.yaml (CloudFormation: CloudFront + Lambda@Edge + test origin), runs tests T-A..T-F,
# prints a results table, writes results-<date>.md, and deletes everything it created (also on error and Ctrl-C).
#
#   ./run-test.sh --dry-run          print the plan; no AWS call that changes anything
#   ./run-test.sh                    ask for the phrase, create, test, tear down
#   ./run-test.sh --cleanup RUNID    only if a run could not delete the Lambda@Edge function (AWS needs hours to release it)
#
# Needs: aws CLI v2, jq, curl, zip, bash 3.2+. Region us-east-1 only. No credentials are stored or printed.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
# shellcheck source-path=SCRIPTDIR
. "$SCRIPT_DIR/lib.sh"

MODE=run CLEANUP_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --cleanup)
      shift; MODE=cleanup; CLEANUP_ID="${1:-}"
      case "$CLEANUP_ID" in --*) echo "--cleanup needs the run id first, then options: ./run-test.sh --cleanup 2610101200-ab12 [--dry-run]" >&2; exit 2 ;; esac ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bhc.XXXXXX")" || exit 2
export RT_MAIN_PID=$$   # lets the test stubs signal this script
# Keep the real stdout and stderr. A Ctrl-C can arrive while a command runs with "> /dev/null": the EXIT trap would inherit that
# redirect and every teardown message would vanish. on_exit puts them back first.
exec 3>&1 4>&2
RESULTS_FILE=""

# shellcheck disable=SC2329  # runs from the EXIT trap
on_exit() {
  local rc=$?
  trap '' INT TERM HUP    # a second Ctrl-C must not interrupt the teardown
  exec >&3 2>&4           # undo any redirect that was active when the signal arrived
  if [ "$CREATE_STARTED" = 1 ] && [ "$TEARDOWN_DONE" = 0 ]; then
    TEARDOWN_DONE=1
    if [ "$REPORT_WRITTEN" = 0 ] && [ "${#RES_NAME[@]}" -gt 0 ]; then write_report "ABORTED (rc=$rc), partial results"; fi
    say ""
    teardown
    if [ -n "$RESULTS_FILE" ] && [ -f "$RESULTS_FILE" ]; then
      local msg
      if [ "$TD_FAIL" != 0 ]; then msg="INCOMPLETE: some resources of this run may still exist. See the screen output."
      elif [ -n "$LOGS_LEFT" ]; then msg="All resources deleted, but log groups left:$LOGS_LEFT"
      else msg="Complete: every resource of this run was deleted."; fi
      redact <<< "
## Teardown

$msg" >> "$RESULTS_FILE"
    fi
    if [ "$TD_FAIL" = 0 ] && [ -n "$STATE_FILE" ]; then rm -f "$STATE_FILE"; fi
    if [ "$TD_FAIL" != 0 ]; then rc=4; fi   # an incomplete teardown always wins: leftovers must not be hidden by an earlier code
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

fail() { say "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------------- preflight
preflight() {
  local t
  for t in aws jq curl zip; do command -v "$t" >/dev/null 2>&1 || die "$t not found in PATH"; done
  aws --version 2>&1 | grep -q 'aws-cli/2' || die "AWS CLI v2 is required"
  local acct
  acct="$(aws_ro sts get-caller-identity --query Account --output text)" || die "cannot read the AWS identity (are you logged in?)"
  printf '%s' "$acct" | grep -Eq '^[0-9]{12}$' || die "unexpected answer from sts get-caller-identity"
  ACCOUNT_ID="$acct"          # used for --expected-bucket-owner; never printed
  ACCT_LAST4="${acct: -4}"   # screen only: never written to the results file, the state file or a log
  say "AWS identity: profile ${AWS_PROFILE:-<none, default credentials>}, account ********$ACCT_LAST4, region $REGION"
  if [ -n "${EXPECT_ACCOUNT_LAST4:-}" ]; then
    printf '%s' "$EXPECT_ACCOUNT_LAST4" | grep -Eq '^[0-9]{4}$' || die "EXPECT_ACCOUNT_LAST4 must be exactly 4 digits"
    [ "$EXPECT_ACCOUNT_LAST4" = "$ACCT_LAST4" ] || die "the account does not end in EXPECT_ACCOUNT_LAST4: wrong profile? Nothing was done."
  fi
  local m; m="$(minute_of_day)"
  if [ "$m" -le 90 ] || [ "$m" -ge 1320 ]; then   # 01:30 and 22:00 themselves are refused
    MIDNIGHT_BAD=1
  else
    MIDNIGHT_BAD=0
  fi
}
MIDNIGHT_BAD=0
ACCT_LAST4=""

print_plan() {
  local id="$1"
  cat <<EOF

Plan for run $id: ONE CloudFormation stack bhc-$id (cfn/stack.yaml), tagged RunId=$id, deleted at the end.
  Created by this script before the stack (the stack needs the code to exist):
    S3 bucket bhc-$id-art   holds the edge function zip (bucket and key baked in), private
  Created by the stack:
    S3 bucket bhc-$id-cfg   holds $CONFIG_KEY (the windows), private, encrypted, TLS-only deny policy
    IAM roles               bhc-$id-erole (edge: read that one object + list the bucket, write logs; trusts lambda and edgelambda)
                            bhc-$id-orole (origin: write logs only)
    Lambda (origin)         bhc-$id-origin  $ORIGIN_RT, inline code, PUBLIC function URL (test only)
    Lambda@Edge function    bhc-$id-edge    $EDGE_RT, us-east-1, code from the art bucket, plus one published version
    Cache policy            bhc-$id-cp      min 0, default 0, max 86400; no query strings, headers or cookies in the key
    CloudFront distribution (PriceClass_100) origin = the function URL, edge function on origin-response (CloudFront caches a 500 for its default 10 s)
  Then: a best-effort reserved concurrency of 5 on the origin, and the window JSON uploaded by this script.
Tests:  T-A/T-B/T-D two paths with different windows at the same moment (in window / out of window / error status), T-F URI variants, T-E S3 failure fallback, T-C an object cached just before the window opens expires at the opening.
Teardown: empty the config bucket, delete the stack (CloudFormation disables and deletes the distribution), delete the art bucket, the log groups.
          If AWS still holds the Lambda@Edge replicas, the edge function and version are retained (the stack deletes the role) and --cleanup removes the function later.
Cost: an estimate of a few cents at most (a few hundred requests; Lambda@Edge, S3 and CloudFront free-tier or cent-level charges).
Time: about 15-25 minutes, mostly waiting for CloudFront to deploy (and again to delete it).
The origin function URL is PUBLIC (auth NONE) while the stack exists; it returns only a timestamp and a counter.
EOF
}

TEMPLATE="$SCRIPT_DIR/cfn/stack.yaml"

# ---------------------------------------------------------------------------------------------------- create

create_all() {
  local d="$WORK/pkg" out b
  mkdir -p "$d"
  say "[1/5] checking that the bucket names are free"
  # Bucket names are global: if one of these exists it is not ours, so stop before anything is created.
  for b in "$ART_BUCKET" "$BUCKET"; do
    if aws_ro s3api head-bucket --bucket "$b" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then fail "a bucket named $b already exists; refusing to continue"; fi
    case "$(error_code)" in 404|NotFound|NoSuchBucket) ;; *) fail "cannot tell whether bucket $b exists (code: $(error_code)); refusing to continue" ;; esac
  done

  say "[2/5] artifact bucket and the edge function zip"
  package_edge "$d" || fail "packaging the edge function"
  aws_do s3api create-bucket --bucket "$ART_BUCKET" >/dev/null || fail "create-bucket"
  state_set ART_MADE 1   # from here on an untagged bucket of exactly this name is ours (tagging may not have run yet)
  aws_do s3api put-bucket-encryption --bucket "$ART_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null || fail "bucket encryption"
  jq -n --arg a "arn:aws:s3:::$ART_BUCKET" '{Version:"2012-10-17",Statement:[{Sid:"DenyInsecureTransport",Effect:"Deny",Principal:"*",Action:"s3:*",
    Resource:[$a,($a+"/*")],Condition:{Bool:{"aws:SecureTransport":"false"}}}]}' > "$d/art-policy.json" || fail "building the bucket policy"
  aws_do s3api put-bucket-policy --bucket "$ART_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --policy "file://$d/art-policy.json" >/dev/null || fail "bucket policy"
  aws_do s3api put-public-access-block --bucket "$ART_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null || fail "public access block"
  aws_do s3api put-bucket-tagging --bucket "$ART_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" --tagging "TagSet=[{Key=RunId,Value=$RUNID},{Key=Purpose,Value=bhc-test}]" >/dev/null || fail "bucket tagging"
  aws_do s3api put-object --bucket "$ART_BUCKET" --key "$CODE_KEY" --body "$d/$CODE_KEY" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null || fail "uploading the edge function zip"

  say "[3/5] validating the template and creating the stack $STACK"
  aws_ro cloudformation validate-template --template-body "file://$TEMPLATE" >/dev/null || fail "template validation"
  jq -n --arg r "$RUNID" --arg cb "$BUCKET" --arg ck "$CONFIG_KEY" --arg ab "$ART_BUCKET" --arg ak "$CODE_KEY" \
    '[{ParameterKey:"RunId",ParameterValue:$r},{ParameterKey:"ConfigBucketName",ParameterValue:$cb},{ParameterKey:"ConfigKey",ParameterValue:$ck},
      {ParameterKey:"CodeBucket",ParameterValue:$ab},{ParameterKey:"CodeKey",ParameterValue:$ak}]' > "$d/params.json" || fail "building the parameters"
  # Optional overrides (the template has defaults): EDGE_RUNTIME, ORIGIN_RUNTIME, PERMISSIONS_BOUNDARY_ARN
  local pk pv
  for pk in EdgeRuntime:EDGE_RUNTIME OriginRuntime:ORIGIN_RUNTIME PermissionsBoundary:PERMISSIONS_BOUNDARY_ARN; do
    eval "pv=\${${pk#*:}:-}"
    if [ -n "$pv" ]; then jq --arg k "${pk%%:*}" --arg v "$pv" '. + [{ParameterKey:$k,ParameterValue:$v}]' "$d/params.json" > "$d/params2.json" && mv "$d/params2.json" "$d/params.json"; fi
  done
  state_set TRY_STACK 1   # saved before the call: a Ctrl-C during it must still delete the stack
  aws_do cloudformation create-stack --stack-name "$STACK" --template-body "file://$TEMPLATE" --parameters "file://$d/params.json" \
    --capabilities CAPABILITY_NAMED_IAM --tags "Key=RunId,Value=$RUNID" "Key=Purpose,Value=bhc-test" >/dev/null || fail "create-stack"

  say "[4/5] waiting for CloudFormation (CloudFront deploys the distribution: usually 5-15 minutes)"
  aws_do cloudformation wait stack-create-complete --stack-name "$STACK" || fail "the stack did not reach CREATE_COMPLETE"
  out="$(aws_ro cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json)" || fail "cannot read the stack outputs"
  DIST_ID="$(printf '%s' "$out" | jq -r '.[] | select(.OutputKey=="DistributionId") | .OutputValue')"
  CF_DOMAIN="$(printf '%s' "$out" | jq -r '.[] | select(.OutputKey=="DistributionDomain") | .OutputValue')"
  # shellcheck disable=SC2034  # used by redact()
  ORIGIN_HOST="$(printf '%s' "$out" | jq -r '.[] | select(.OutputKey=="OriginHost") | .OutputValue')"
  [ -n "$DIST_ID" ] && [ "$DIST_ID" != null ] && [ -n "$CF_DOMAIN" ] && [ "$CF_DOMAIN" != null ] || fail "the stack outputs have no distribution"
  printf '%s' "$CF_DOMAIN" | grep -Eq '^[a-z0-9]+\.cloudfront\.net$' || fail "the distribution domain does not look like <id>.cloudfront.net; not sending requests to it"

  say "[5/5] initial window config and best-effort reserved concurrency for the public origin"
  put_json "{\"default\":$(win_json 0 1)}" || fail "initial config upload"
  aws_do lambda put-function-concurrency --function-name "$ORIGIN_FN" --reserved-concurrent-executions 5 >/dev/null \
    || say "  note: reserved concurrency was not set (account limit?); continuing without it"
  say "stack is ready"
}

# win_json START END -> {"startMin":..,"endMin":..,"inTtl":..,"outTtl":..}
win_json() { printf '{"startMin":%s,"endMin":%s,"inTtl":%s,"outTtl":%s}' "$1" "$2" "$IN_TTL" "$OUT_TTL"; }
# put_json JSON: write the config object to S3
put_json() {
  local f="$WORK/window.json"
  printf '%s\n' "$1" > "$f"
  aws_do s3api put-object --bucket "$BUCKET" --key "$CONFIG_KEY" --body "$f" --content-type application/json --expected-bucket-owner "$ACCOUNT_ID" >/dev/null
}
# set_rules JSON TEXT: upload the config, then wait for the edge function's 30 s memory cache to expire
set_rules() {
  put_json "$1" || fail "cannot upload the config"
  say "  config set: $2; waiting ${SETTLE_SECS}s for the edge config cache"
  nap "$SETTLE_SECS"
}
# One config for T-A, T-B and T-D, so one path is inside its window and others are outside at the SAME moment:
#   /prices/*  window now-5 .. now+30 min   (inside)       /rates/*, /err*  window now-60 .. now-30 min (outside)
#   default: the MOST RESTRICTIVE window (all day, never cached), which is what unmatched variants such as /Prices/a get
ABD_READY=0
setup_abd() {
  local m cfg; m="$(minute_of_day)"
  if [ "$m" -lt 60 ] || [ "$m" -gt 1410 ]; then return 0; fi
  cfg="$(jq -nc --argjson p "$(win_json $((m - 5)) $((m + 30)))" --argjson r "$(win_json $((m - 60)) $((m - 30)))" \
    '{rules:[({path:"/prices/*"}+$p), ({path:"/rates/*"}+$r), ({path:"/err*"}+$r)],
      default:{startMin:0,endMin:1440,inTtl:0,outTtl:0}}')"
  say "path rules: /prices/* is inside its window now, /rates/* and /err* are outside theirs, default = never cache"
  set_rules "$cfg" "/prices/* minutes $((m - 5))..$((m + 30)), /rates/* and /err* minutes $((m - 60))..$((m - 30)) (UTC)"
  ABD_READY=1
}

# ---------------------------------------------------------------------------------------------------- requests
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
csv() { local IFS=,; echo "$*"; }

# req PATH -> R_ST R_XC R_AGE R_CC R_NONCE R_CNT. Returns 1 when there was no HTTP answer.
req() {
  local h="$WORK/resp.h" b="$WORK/resp.b"
  R_ST="" R_XC="" R_AGE="" R_CC="" R_NONCE="" R_CNT="" R_PATH=""
  : > "$h"; : > "$b"
  curl -sS --path-as-is -o "$b" -D "$h" --max-time 30 "https://$CF_DOMAIN$1" 2>"$WORK/curl.err" || return 1
  R_ST="$(tr -d '\r' < "$h" | awk 'NR==1{print $2}')"
  R_XC="$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="x-cache"{print $2; exit}' | awk '{print $1}')"
  R_AGE="$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="age"{print $2; exit}')"
  R_CC="$(tr -d '\r' < "$h" | awk 'tolower(substr($0,1,14))=="cache-control:"{sub(/^[^:]*: */,""); print; exit}')"
  R_NONCE="$(jq -r '.nonce // empty' "$b" 2>/dev/null)"
  R_CNT="$(jq -r '.counter // empty' "$b" 2>/dev/null)"
  R_PATH="$(jq -r '.path // empty' "$b" 2>/dev/null)"
  [ -n "$R_ST" ]
}

# series PATH N GAP -> S_ST S_XC S_AGE S_CC S_NONCE S_CNT (arrays), S_BAD=1 when a request got no answer
series() {
  local i
  S_ST=() S_XC=() S_AGE=() S_CC=() S_NONCE=() S_CNT=() S_PATH=() S_BAD=0
  for ((i = 0; i < $2; i++)); do
    [ "$i" -gt 0 ] && nap "$3"
    if req "$1"; then
      S_ST+=("$R_ST"); S_XC+=("${R_XC:-none}"); S_AGE+=("${R_AGE:--}"); S_CC+=("$R_CC"); S_NONCE+=("$R_NONCE"); S_CNT+=("${R_CNT:-?}"); S_PATH+=("${R_PATH:-?}")
    else
      S_BAD=1; S_ST+=("000"); S_XC+=("none"); S_AGE+=("-"); S_CC+=(""); S_NONCE+=(""); S_CNT+=("?"); S_PATH+=("?")
    fi
  done
}
has_hit() { local x; for x in "$@"; do case "$(lc "$x")" in hit|refreshhit) return 0 ;; esac; done; return 1; }
all_eq() { local v="$1" x; shift; for x in "$@"; do [ "$x" = "$v" ] || return 1; done; return 0; }
distinct() { printf '%s\n' "$@" | sort -u | wc -l | tr -d ' '; }
steps_of_one() { # each counter is the previous + 1
  local prev="" x
  for x in "$@"; do
    case "$x" in ''|*[!0-9]*) return 1 ;; esac
    if [ -n "$prev" ] && [ "$x" -ne $((prev + 1)) ]; then return 1; fi
    prev="$x"
  done
  return 0
}
age_grows() { # first last: both must be numbers, last greater
  case "$1$2" in ''|*[!0-9]*) return 1 ;; esac
  [ "$2" -gt "$1" ]
}
all_status() { all_eq "$1" "${S_ST[@]}"; }
meas() { echo "xcache=[$(csv "${S_XC[@]}")] age=[$(csv "${S_AGE[@]}")] origin-counter=[$(csv "${S_CNT[@]}")] cache-control=\"${S_CC[0]}\""; }

# ---------------------------------------------------------------------------------------------------- tests
TOO_CLOSE="too close to UTC midnight for this window (one window per UTC day); rerun at another time of day"

t_a() {
  if [ "$ABD_READY" != 1 ]; then add_result T-A INCONCLUSIVE "$TOO_CLOSE"; return; fi
  say "T-A: /prices/* has now inside its window, 5 requests, every one must reach the origin"
  series /prices/a 5 1
  local other_cc="" other_xc="" other_ok=0
  if req /rates/a && [ "$R_ST" = 200 ]; then other_cc="$R_CC"; other_xc="$R_XC"; other_ok=1; fi   # another path, outside its window, at the same moment
  if [ "$S_BAD" = 1 ] || ! all_status 200; then add_result T-A INCONCLUSIVE "no HTTP 200 from every request: status=[$(csv "${S_ST[@]}")]"
  elif has_hit "${S_XC[@]}"; then add_result T-A FAIL "a request was served from cache: $(meas)"
  elif [ "$(distinct "${S_NONCE[@]}")" != 5 ]; then add_result T-A FAIL "origin nonce repeated, so the origin was not hit every time: $(meas)"
  elif ! all_eq "$EXPECT_IN" "${S_CC[@]}"; then add_result T-A FAIL "viewer Cache-Control is not what the function sets: $(meas)"
  elif ! steps_of_one "${S_CNT[@]}"; then add_result T-A INCONCLUSIVE "distinct nonces but the counter did not step by 1 (new origin instance or other traffic): $(meas)"
  elif [ "$other_ok" != 1 ]; then add_result T-A INCONCLUSIVE "the side request to /rates/a got no HTTP 200, so the two-paths part could not be checked: $(meas)"
  elif [ "$other_cc" != "$EXPECT_OUT" ]; then add_result T-A FAIL "at the same moment /rates/a (outside its window) should get s-maxage=$OUT_TTL, got \"$other_cc\": $(meas)"
  else add_result T-A PASS "/prices/a: $(meas); at the same moment /rates/a (outside its window): cache-control=\"$other_cc\" xcache=$other_xc"; fi
}

t_b() {
  if [ "$ABD_READY" != 1 ]; then add_result T-B INCONCLUSIVE "$TOO_CLOSE"; return; fi
  say "T-B: /rates/* is outside its window, first request Miss, repeats Hit, origin counter flat"
  series /rates/b 5 "$HIT_GAP_SECS"
  local n=${#S_XC[@]} i ok=1 stray=0 other=0
  if [ "$S_BAD" = 1 ] || ! all_status 200; then add_result T-B INCONCLUSIVE "no HTTP 200 from every request: status=[$(csv "${S_ST[@]}")]"; return; fi
  [ "$(lc "${S_XC[0]}")" = miss ] || { ok=0; other=1; }
  for ((i = 1; i < n; i++)); do
    case "$(lc "${S_XC[$i]}")" in hit|refreshhit) ;; miss) ok=0; stray=$((stray + 1)) ;; *) ok=0; other=1 ;; esac
  done
  if [ "$ok" = 0 ] && [ "$stray" = 1 ] && [ "$other" = 0 ] && [ "$(distinct "${S_NONCE[@]}")" = 1 ] && [ "$(distinct "${S_CNT[@]}")" = 1 ]; then
    # One Miss between Hits while the origin was NOT reached again: a POP with several cache servers answered from another layer.
    add_result T-B INCONCLUSIVE "one stray Miss among Hits, but the origin was not reached again (same nonce, flat counter): likely another cache server in the same POP, not a failure of the function: $(meas)"
  elif [ "$ok" = 0 ]; then add_result T-B FAIL "expected Miss then Hit: $(meas)"
  elif [ "$(distinct "${S_NONCE[@]}")" != 1 ] || [ "$(distinct "${S_CNT[@]}")" != 1 ]; then add_result T-B FAIL "origin was hit again (nonce or counter changed): $(meas)"
  elif ! all_eq "$EXPECT_OUT" "${S_CC[@]}"; then add_result T-B FAIL "viewer Cache-Control is not what the function sets: $(meas)"
  elif ! age_grows "${S_AGE[1]}" "${S_AGE[$((n - 1))]}"; then
    add_result T-B FAIL "Age did not increase between hits: $(meas)"
  else add_result T-B PASS "$(meas)"; fi
}

t_d() {
  say "T-D: origin answers 500 on /err (a rule for /err* is outside its window); the long TTL must not be applied or cached"
  if [ "$ABD_READY" != 1 ]; then add_result T-D INCONCLUSIVE "$TOO_CLOSE"; return; fi
  # CloudFront caches a 5xx for 10 s by default, so: two requests 1 s apart (the second may be the cached copy), then one 16 s after the
  # first (it must be a fresh answer from the origin), then one more. No Age may be above ~15 s.
  local first_nonce n3 a3 a4="-" ages
  series /err 2 1
  if [ "$S_BAD" = 1 ] || ! all_status 500; then add_result T-D INCONCLUSIVE "expected HTTP 500 from every request: status=[$(csv "${S_ST[@]}")]"; return; fi
  first_nonce="${S_NONCE[0]}"
  if [ "${S_AGE[0]}" != "-" ]; then add_result T-D INCONCLUSIVE "the first answer already carries Age ${S_AGE[0]}: the timing cannot be established (an earlier request cached it)"; return; fi
  nap 15
  if ! req /err || [ "$R_ST" != 500 ]; then add_result T-D INCONCLUSIVE "no HTTP 500 for the request 16 s later (status=${R_ST:-none})"; return; fi
  n3="$R_NONCE"; a3="${R_AGE:--}"
  ages="age=[$(csv "${S_AGE[@]}"),$a3"
  if req /err && [ "$R_ST" = 500 ]; then a4="${R_AGE:--}"; ages="$ages,$a4"; fi
  ages="$ages]"
  if printf '%s\n' "${S_CC[@]}" "$R_CC" | grep -q 's-maxage=14400'; then add_result T-D FAIL "the function rewrote an error response: $(meas)"
  elif [ "$n3" = "$first_nonce" ] || { [ "$a3" != "-" ] && [ "$a3" -ge 10 ] 2>/dev/null; }; then
    add_result T-D FAIL "the 500 was still served from cache 16 s after the first answer (same nonce or Age $a3): cached longer than CloudFront's 10 s default; $ages"
  elif printf '%s\n' "${S_AGE[@]}" "$a3" "$a4" | awk '$1 ~ /^[0-9]+$/ && $1 > 15 {f=1} END {exit !f}'; then
    add_result T-D FAIL "an Age above 15 s on a 500: $ages"
  else add_result T-D PASS "status 500 each time, no s-maxage=14400, a fresh origin answer 16 s after the first (new nonce); CloudFront's default 5xx caching is 10 s; $ages"; fi
}

# T-F: URI variants of a rule path (//prices/a, /Prices/a, /%70rices/a) during the /prices/* window. They must not get a long TTL.
# They are matched raw: "//" and "%" variants get s-maxage=0, the case variant falls to "default" (here: never cache). The
# origin shows the path CloudFront forwarded; the function's own view (cf.request.uri) is not visible from outside.
t_f() {
  local v seen="" bad=0 fail=0 why=""
  if [ "$ABD_READY" != 1 ]; then add_result T-F INCONCLUSIVE "$TOO_CLOSE"; return; fi
  say "T-F: URI variants of /prices/a must not be cached for long"
  for v in //prices/a /Prices/a /%70rices/a; do
    series "$v" 2 1
    if [ "$S_BAD" = 1 ] || ! all_status 200; then bad=1; seen="$seen [$v: status=$(csv "${S_ST[@]}")]"; continue; fi
    seen="$seen [$v -> origin saw ${S_PATH[0]}; cache-control=\"${S_CC[0]}\" xcache=$(csv "${S_XC[@]}")]"
    if has_hit "${S_XC[@]}"; then fail=1; why="$why $v was served from cache;"; fi
    if printf '%s\n' "${S_CC[@]}" | grep -Eq 's-maxage=[1-9]'; then fail=1; why="$why $v got a positive s-maxage;"; fi
    note "T-F INFO: request $v reached the origin as path ${S_PATH[0]} (what CloudFront forwarded; the function's own cf.request.uri is not visible from outside)."
  done
  if [ "$fail" = 1 ]; then add_result T-F FAIL "$why$seen"
  elif [ "$bad" = 1 ]; then add_result T-F INCONCLUSIVE "no HTTP 200 for some variant:$seen"
  else add_result T-F PASS "not cached for long:$seen"; fi
}

# e_phase PATH: 3 requests while the window cannot be used -> E_RES, E_MEAS
e_phase() {
  series "$1" 3 1
  E_MEAS="$(meas)"
  if [ "$S_BAD" = 1 ] || ! all_status 200; then E_RES=INCONCLUSIVE; E_MEAS="no HTTP 200 from every request: status=[$(csv "${S_ST[@]}")]"
  elif has_hit "${S_XC[@]}"; then E_RES=FAIL; E_MEAS="served from cache although the config could not be used: $E_MEAS"
  elif ! all_eq "$EXPECT_IN" "${S_CC[@]}"; then E_RES=FAIL; E_MEAS="fallback Cache-Control is not s-maxage=0: $E_MEAS"
  elif [ "$(distinct "${S_NONCE[@]}")" != 3 ]; then E_RES=FAIL; E_MEAS="origin nonce repeated: $E_MEAS"
  else E_RES=PASS; fi
}

t_e() {
  local r1 m1 r2 m2 f
  say "T-E: window cannot be used -> fallback s-maxage=0 (E1 object missing, E2 object is not JSON)"
  aws_do s3api delete-object --bucket "$BUCKET" --key "$CONFIG_KEY" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null || fail "cannot delete the config object"
  say "  E1: config object deleted; waiting ${SETTLE_SECS}s for the edge config cache"
  nap "$SETTLE_SECS"
  e_phase /rates/e; r1="$E_RES"; m1="$E_MEAS"
  f="$WORK/notjson.txt"; printf 'this is not json\n' > "$f"
  aws_do s3api put-object --bucket "$BUCKET" --key "$CONFIG_KEY" --body "$f" --content-type application/json --expected-bucket-owner "$ACCOUNT_ID" >/dev/null || fail "cannot upload the bad config"
  say "  E2: config object replaced by text that is not JSON; waiting ${SETTLE_SECS}s"
  nap "$SETTLE_SECS"
  e_phase /rates/e2; r2="$E_RES"; m2="$E_MEAS"
  if [ "$r1" = PASS ] && [ "$r2" = PASS ]; then add_result T-E PASS "fallback s-maxage=0 in both cases. E1 missing key: $m1. E2 bad JSON: $m2"
  elif [ "$r1" = FAIL ] || [ "$r2" = FAIL ]; then add_result T-E FAIL "E1 missing key: $r1 $m1. E2 bad JSON: $r2 $m2"
  else add_result T-E INCONCLUSIVE "E1 missing key: $r1 $m1. E2 bad JSON: $r2 $m2"; fi
}

t_c() {
  local m start end open t0 ttl0 pre_age pre_xc post_xc post_cc post_age first_nonce c2a c2b t1
  m="$(minute_of_day)"
  if [ "$m" -gt 1375 ]; then add_result T-C INCONCLUSIVE "$TOO_CLOSE"; return; fi
  say "T-C: window opens about 80-140 s after the first request; an object cached just before must expire by the opening"
  start=$((m + 3)); end=$((start + 60))
  set_rules "$(jq -nc --argjson w "$(win_json "$start" "$end")" '{rules:[({path:"/c/*"}+$w)]}')" "/c/* opens at minute $start, closes at $end (UTC)"
  open=$(( $(day_start_epoch) + start * 60 ))
  t0="$(now_epoch)"
  if [ $((open - t0)) -lt 30 ]; then add_result T-C INCONCLUSIVE "less than 30 s left before the opening at the first request (slow start)"; return; fi
  if ! req /c/old; then add_result T-C INCONCLUSIVE "no answer for /c"; return; fi
  first_nonce="$R_NONCE"
  ttl0="${R_CC##*s-maxage=}"
  case "$ttl0" in ''|*[!0-9]*) add_result T-C INCONCLUSIVE "no s-maxage number in the first answer (cache-control=\"$R_CC\")"; return ;; esac
  if [ "$(lc "$R_XC")" != miss ]; then add_result T-C INCONCLUSIVE "first request was not a Miss (xcache=$R_XC)"; return; fi
  # The cap: s-maxage is the time until the opening (here 30 s .. ~3 min), far below outTtl=$OUT_TTL. 5 s tolerance for clock skew.
  if [ "$ttl0" -le 0 ] || [ "$ttl0" -gt $((open - t0 + 5)) ]; then
    add_result T-C FAIL "s-maxage=$ttl0 is not capped to the time until the opening (${open}-${t0} = $((open - t0)) s left; outTtl=$OUT_TTL)"; return
  fi
  nap "$HIT_GAP_SECS"
  req /c/old || { add_result T-C INCONCLUSIVE "no answer for /c"; return; }
  case "$(lc "$R_XC")" in hit|refreshhit) ;; *) add_result T-C INCONCLUSIVE "object not cached before the opening (xcache=$R_XC)"; return ;; esac
  say "  cached with s-maxage=$ttl0; the window opens $((open - t0))s after the first request"
  wait_until_epoch $((open - 10))
  req /c/old || { add_result T-C INCONCLUSIVE "no answer for /c before the opening"; return; }
  pre_xc="$R_XC"; pre_age="${R_AGE:--}"
  case "$(lc "$pre_xc")" in hit|refreshhit) ;; *) add_result T-C INCONCLUSIVE "10 s before the opening /c/old was not a Hit (xcache=$pre_xc): it expired early (clock skew or a very short TTL), so the Age check is not measurable"; return ;; esac
  case "$pre_age" in ''|*[!0-9]*) add_result T-C INCONCLUSIVE "no numeric Age 10 s before the opening (age=$pre_age)"; return ;; esac
  if [ "$pre_age" -gt "$ttl0" ]; then add_result T-C FAIL "Age $pre_age s before the opening is above the TTL $ttl0 s: served past its TTL"; return; fi
  wait_until_epoch $((open + 5))
  req /c/old || { add_result T-C INCONCLUSIVE "no answer for /c after the opening"; return; }
  t1="$(now_epoch)"; post_xc="$R_XC"; post_cc="$R_CC"; post_age="${R_AGE:--}"
  case "$(lc "$post_xc")" in
    hit|refreshhit) add_result T-C FAIL "/c was still served from cache $((t1 - open))s after the opening (age=${post_age}s, s-maxage was $ttl0): the cap did not work"; return ;;
  esac
  if [ "$R_NONCE" = "$first_nonce" ] || [ "$post_cc" != "$EXPECT_IN" ]; then
    add_result T-C INCONCLUSIVE "after the opening: xcache=$post_xc nonce-changed=$([ "$R_NONCE" != "$first_nonce" ] && echo yes || echo no) cache-control=\"$post_cc\""; return
  fi
  series /c/new 2 1
  c2a="${S_XC[0]}"; c2b="${S_XC[1]}"
  if [ "$S_BAD" = 1 ] || ! all_status 200; then add_result T-C INCONCLUSIVE "no HTTP 200 for /c2"
  elif has_hit "${S_XC[@]}" || [ "$(distinct "${S_NONCE[@]}")" != 2 ] || ! all_eq "$EXPECT_IN" "${S_CC[@]}"; then
    add_result T-C FAIL "a NEW object after the opening was cached or not marked s-maxage=0 (xcache=$c2a,$c2b)"
  else
    add_result T-C PASS "cap works: /c was cached with s-maxage=${ttl0} (outTtl is $OUT_TTL; the window opened $((open - t0))s after the first request); 10s before the opening xcache=$pre_xc age=${pre_age}s; 5s after the opening xcache=$post_xc (new nonce, cache-control=\"$post_cc\"); new object /c/new after the opening not cached (xcache=$c2a,$c2b)"
    note "T-C: an object cached $((open - t0))s before the opening got s-maxage=$ttl0 (outTtl is $OUT_TTL) and was gone 5s after the opening. Client and Lambda clocks differ by seconds, and Age and the TTL are whole seconds, so the check allows 5s of skew and an object can expire a few seconds before the opening, not after."
  fi
}

# edge_failsafe_everywhere: a path with a rule outside its window must get the long TTL. If it gets s-maxage=0 instead, the function is
# on its fail-safe (for example boto3 is not available in the Lambda@Edge runtime), and no test can say anything.
edge_failsafe_everywhere() {
  req /rates/probe || return 1
  [ "$R_ST" = 200 ] && [ "$R_CC" = "$EXPECT_IN" ]
}

run_tests() {
  local m i
  say ""
  say "warm-up: waiting for the first good answer through CloudFront"
  for ((i = 1; i <= WARMUP_TRIES; i++)); do
    if req /warm && [ "$R_ST" = 200 ]; then break; fi
    nap 10
  done
  if [ "$i" -gt "$WARMUP_TRIES" ]; then
    for m in T-A T-B T-D T-F T-E T-C; do add_result "$m" INCONCLUSIVE "CloudFront did not answer 200 after the warm-up (origin, function URL permission or edge function problem)"; done
    return
  fi
  setup_abd
  if [ "$ABD_READY" = 1 ] && edge_failsafe_everywhere; then
    for m in T-A T-B T-D T-F T-E T-C; do
      add_result "$m" INCONCLUSIVE "the edge function could not load the S3 client (or cannot read the config): every answer shows the fail-safe s-maxage=0, also on a path that should get the long TTL. See README, \"If the S3 client is missing\""
    done
    return
  fi
  t_a; t_b; t_d; t_f; t_e; t_c
}

# ---------------------------------------------------------------------------------------------------- report
write_report() { # title
  local i f d n=1 nl='
' body
  d="$(date -u +%Y%m%d)"; f="$RESULTS_DIR/results-$d.md"
  while [ -e "$f" ]; do n=$((n + 1)); f="$RESULTS_DIR/results-$d-$n.md"; done
  # Built as one string and redacted with a here-string (no pipes: this also runs from the EXIT trap after Ctrl-C).
  body="# CloudFront business-hours cache: results$nl$nl- Run: $RUNID, finished $(stamp), region $REGION (CloudFormation stack $STACK)"
  body="$body$nl- Status: $1"
  body="$body$nl- Config: path rules in UTC (see README), outTtl=$OUT_TTL capped to the time until the window opens, cache policy min 0 / default 0 / max 86400$nl"
  body="$body$nl| Test | Result | Measured |$nl|---|---|---|"
  for ((i = 0; i < ${#RES_NAME[@]}; i++)); do body="$body$nl| ${RES_NAME[$i]} | ${RES_RESULT[$i]} | ${RES_MEAS[$i]//|//} |"; done
  body="$body$nl${nl}PASS = measured as expected. FAIL = measured something else. INCONCLUSIVE = the test could not run cleanly, so it says nothing either way."
  if [ "${#NOTES[@]}" -gt 0 ]; then
    body="$body$nl$nl## Notes$nl"
    for ((i = 0; i < ${#NOTES[@]}; i++)); do body="$body$nl- ${NOTES[$i]}"; done
  fi
  redact <<< "$body" > "$f"
  RESULTS_FILE="$f"; REPORT_WRITTEN=1
  say "results file: $(basename "$f") (in $(basename "$RESULTS_DIR"))"
}

report() {
  local p f i c
  p="$(count_result PASS)"; f="$(count_result FAIL)"; i="$(count_result INCONCLUSIVE)"
  say ""
  say "==================== RESULTS ===================="
  redact <<< "$(printf '%-6s %-13s %s' TEST RESULT MEASURED)"
  for ((c = 0; c < ${#RES_NAME[@]}; c++)); do redact <<< "$(printf '%-6s %-13s %s' "${RES_NAME[$c]}" "${RES_RESULT[$c]}" "${RES_MEAS[$c]}")"; done
  say "PASS=$p FAIL=$f INCONCLUSIVE=$i"
  write_report "PASS=$p FAIL=$f INCONCLUSIVE=$i"
  RUN_RC=0
  [ "$i" -gt 0 ] && RUN_RC=3
  [ "$f" -gt 0 ] && RUN_RC=1
  return 0
}
RUN_RC=0

# ---------------------------------------------------------------------------------------------------- main
confirm() { # phrase
  local ans
  printf 'Type "%s" to continue, anything else aborts: ' "$1"
  IFS= read -r ans || ans=""
  [ "$ans" = "$1" ] || { say "aborted, nothing was created"; exit 1; }
}

main_run() {
  # RT_RUNID is a TEST HOOK (the stub tests need a fixed id). It must still match the run id format, checked below.
  RUNID="${RT_RUNID:-$(date -u +%y%m%d%H%M)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')}"
  printf '%s' "$RUNID" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$' || die "run id '$RUNID' is not of the form 2610101200-ab12"
  set_names
  EDGE_RT="${EDGE_RUNTIME:-python3.12 (template default)}"; ORIGIN_RT="${ORIGIN_RUNTIME:-nodejs22.x (template default)}"
  print_plan "$RUNID"
  aws_ro cloudformation validate-template --template-body "file://$TEMPLATE" >/dev/null || die "cfn/stack.yaml did not validate"
  say "template check: cloudformation validate-template accepted cfn/stack.yaml"
  if [ "$MIDNIGHT_BAD" = 1 ]; then
    say ""
    say "NOTE: it is now $(stamp). The tests need windows of up to 60 minutes on both sides of 'now' inside one UTC day."
    say "      Start this after 01:30 and before 22:00 UTC. A real run refuses to start at or outside those times."
  fi
  if [ "$DRY_RUN" = 1 ]; then
    say ""
    say "dry run: nothing was created or deleted (only the read-only calls sts get-caller-identity and cloudformation validate-template were made)."
    return 0
  fi
  [ "$MIDNIGHT_BAD" = 0 ] || die "at or outside 01:30 / 22:00 UTC, see the note above"
  say ""
  say "This creates real AWS resources in your account. It costs cents and takes about 15-25 minutes."
  say "Target:  profile ${AWS_PROFILE:-<none, default credentials>}   region $REGION   account ending in $ACCT_LAST4"
  say "         (set EXPECT_ACCOUNT_LAST4=<4 digits> to make the script refuse any other account)"
  confirm "$PHRASE"
  STATE_FILE="$RESULTS_DIR/state-$RUNID.env"
  : > "$STATE_FILE"
  state_set RUNID "$RUNID"
  CREATE_STARTED=1
  create_all
  run_tests
  report
  exit "$RUN_RC"
}

main_cleanup() {
  printf '%s' "$CLEANUP_ID" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$' || die "--cleanup needs a run id like 2610101200-ab12"
  RUNID="$CLEANUP_ID"
  STATE_FILE="$RESULTS_DIR/state-$CLEANUP_ID.env"
  # Every name is derived from the run id, so the state file is optional (it only carries ART_MADE).
  if [ -f "$STATE_FILE" ] && grep -q '^RUNID=' "$STATE_FILE"; then state_load "$STATE_FILE"; RUNID="$CLEANUP_ID"; fi
  set_names
  TRY_STACK=1
  say "cleanup of run $RUNID: will delete only stack $STACK (tagged RunId=$RUNID), what it left behind (the edge function, if AWS still holds its replicas), bucket $ART_BUCKET and the log groups of this run"
  if [ "$DRY_RUN" = 1 ]; then say "dry run: nothing was deleted."; return 0; fi
  say "Target:  profile ${AWS_PROFILE:-<none, default credentials>}   region $REGION   account ending in $ACCT_LAST4"
  confirm "$CLEANUP_PHRASE"
  CREATE_STARTED=1
}

preflight
case "$MODE" in
  run) main_run ;;
  cleanup) main_cleanup ;;
esac
exit 0
