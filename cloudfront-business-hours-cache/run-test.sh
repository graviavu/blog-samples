#!/usr/bin/env bash
# run-test.sh - ONE entry point. Builds a temporary CloudFront + Lambda@Edge stack, runs tests T-A..T-E against it,
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
    --cleanup) shift; MODE=cleanup; CLEANUP_ID="${1:-}" ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bhc.XXXXXX")" || exit 2
export RT_MAIN_PID=$$   # lets the test stubs signal this script
RESULTS_FILE=""

# shellcheck disable=SC2329  # runs from the EXIT trap
on_exit() {
  local rc=$?
  trap '' INT TERM HUP    # a second Ctrl-C must not interrupt the teardown
  if [ "$CREATE_STARTED" = 1 ] && [ "$TEARDOWN_DONE" = 0 ]; then
    TEARDOWN_DONE=1
    if [ "$REPORT_WRITTEN" = 0 ] && [ "${#RES_NAME[@]}" -gt 0 ]; then write_report "ABORTED (rc=$rc), partial results"; fi
    say ""
    teardown
    if [ -n "$RESULTS_FILE" ] && [ -f "$RESULTS_FILE" ]; then
      { printf '\n## Teardown\n\n'; if [ "$TD_FAIL" = 0 ]; then echo "Complete: every resource of this run was deleted."; else echo "INCOMPLETE: some resources of this run may still exist. See the screen output."; fi; } | redact >> "$RESULTS_FILE"
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
  ACCT_LAST4="${acct: -4}"   # screen only: never written to the results file, the state file or a log
  say "AWS identity: profile ${AWS_PROFILE:-<none, default credentials>}, account ********$ACCT_LAST4, region $REGION"
  if [ -n "${EXPECT_ACCOUNT_LAST4:-}" ]; then
    printf '%s' "$EXPECT_ACCOUNT_LAST4" | grep -Eq '^[0-9]{4}$' || die "EXPECT_ACCOUNT_LAST4 must be exactly 4 digits"
    [ "$EXPECT_ACCOUNT_LAST4" = "$ACCT_LAST4" ] || die "the account does not end in EXPECT_ACCOUNT_LAST4: wrong profile? Nothing was done."
  fi
  local m; m="$(minute_of_day)"
  if [ "$m" -lt 90 ] || [ "$m" -gt 1320 ]; then
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

Plan for run $id (every resource below is tagged RunId=$id and is deleted at the end):
  1. S3 bucket              bhc-$id-cfg          holds $CONFIG_KEY (the window), private
  2. IAM roles (two)        bhc-$id-erole        edge: read that one object (+ list the bucket), write logs; trusts lambda and edgelambda
                            bhc-$id-orole        origin: write logs only; trusts lambda
  3. Lambda (origin)        bhc-$id-origin       Node.js 22 + PUBLIC function URL (test only), reserved concurrency 5 if the account allows
  4. Lambda@Edge function   bhc-$id-edge         Node.js 22, us-east-1, one published version, origin-response
  5. Cache policy           bhc-$id-cp           min 0, default 0, max 86400; no query strings, headers or cookies in the key
  6. CloudFront distribution (PriceClass_100)    origin = the function URL, edge function on origin-response, 500 not cached
Tests:  T-A in window, T-B out of window, T-D error status, T-E S3 failure fallback, T-C window boundary.
Teardown: disable the distribution, wait, delete it, then the cache policy, both functions, both roles, the log groups and the bucket.
Cost: an estimate of a few cents at most (a few hundred requests; Lambda@Edge, S3 and CloudFront free-tier or cent-level charges).
Time: about 15-25 minutes, mostly waiting for CloudFront to deploy (and again to disable it).
The origin function URL is PUBLIC (auth NONE) while the stack exists; it returns only a timestamp and a counter.
EOF
}

# ---------------------------------------------------------------------------------------------------- create

create_all() {
  local d="$WORK/pkg" role_arn origin_role_arn edge_arn
  mkdir -p "$d"
  say "[1/7] S3 bucket"
  # Bucket names are global: if this one already exists it is not ours, so stop before anything is created.
  if aws_ro s3api head-bucket --bucket "bhc-$RUNID-cfg" >/dev/null 2>&1; then fail "a bucket named bhc-$RUNID-cfg already exists; refusing to use it"; fi
  case "$(error_code)" in 404|NotFound|NoSuchBucket) ;; *) fail "cannot tell whether bucket bhc-$RUNID-cfg exists (code: $(error_code)); refusing to continue" ;; esac
  state_set BUCKET "bhc-$RUNID-cfg"
  aws_do s3api create-bucket --bucket "$BUCKET" >/dev/null || fail "create-bucket"
  state_set BUCKET_MADE 1   # from here on an untagged bucket of exactly this name is ours (tagging may not have run yet)
  aws_do s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null || fail "public access block"
  aws_do s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=RunId,Value=$RUNID},{Key=Purpose,Value=bhc-test}]" >/dev/null || fail "bucket tagging"
  put_config 0 1 "$IN_TTL" "$OUT_TTL" || fail "initial config upload"

  say "[2/7] IAM roles (edge role with S3 read, origin role without)"
  # Logs only for this run's log groups (the edge function logs as /aws/lambda/us-east-1.<name> in the region of the edge location).
  local lg="arn:aws:logs:*:*:log-group:/aws/lambda/*bhc-$RUNID-*"
  jq -n '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:["lambda.amazonaws.com","edgelambda.amazonaws.com"]},Action:"sts:AssumeRole"}]}' > "$d/trust-edge.json"
  jq -n '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"lambda.amazonaws.com"},Action:"sts:AssumeRole"}]}' > "$d/trust-origin.json"
  jq -n --arg b "arn:aws:s3:::$BUCKET" --arg o "arn:aws:s3:::$BUCKET/$CONFIG_KEY" --arg l "$lg" --arg l2 "$lg:*" \
    '{Version:"2012-10-17",Statement:[
      {Effect:"Allow",Action:"s3:GetObject",Resource:$o},
      {Effect:"Allow",Action:"s3:ListBucket",Resource:$b},
      {Effect:"Allow",Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],Resource:[$l,$l2]}]}' > "$d/policy-edge.json" || fail "building the edge policy"
  jq -n --arg l "$lg" --arg l2 "$lg:*" \
    '{Version:"2012-10-17",Statement:[{Effect:"Allow",Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],Resource:[$l,$l2]}]}' > "$d/policy-origin.json" || fail "building the origin policy"
  state_set ROLE "bhc-$RUNID-erole"
  role_arn="$(aws_do iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$d/trust-edge.json" \
    --tags "Key=RunId,Value=$RUNID" "Key=Purpose,Value=bhc-test" --query Role.Arn --output text)" || fail "create-role (edge)"
  aws_do iam put-role-policy --role-name "$ROLE" --policy-name bhc-inline --policy-document "file://$d/policy-edge.json" >/dev/null || fail "put-role-policy (edge)"
  state_set ORIGIN_ROLE "bhc-$RUNID-orole"
  origin_role_arn="$(aws_do iam create-role --role-name "$ORIGIN_ROLE" --assume-role-policy-document "file://$d/trust-origin.json" \
    --tags "Key=RunId,Value=$RUNID" "Key=Purpose,Value=bhc-test" --query Role.Arn --output text)" || fail "create-role (origin)"
  aws_do iam put-role-policy --role-name "$ORIGIN_ROLE" --policy-name bhc-inline --policy-document "file://$d/policy-origin.json" >/dev/null || fail "put-role-policy (origin)"
  nap 10   # IAM is eventually consistent

  say "[3/7] origin function and function URL"
  package_origin "$d" || fail "packaging the origin"
  state_set ORIGIN_FN "bhc-$RUNID-origin"
  retry 6 10 aws_do lambda create-function --function-name "$ORIGIN_FN" --runtime nodejs22.x --handler index.handler --timeout 5 \
    --role "$origin_role_arn" --zip-file "fileb://$d/origin.zip" --tags "RunId=$RUNID,Purpose=bhc-test" >/dev/null || fail "create origin function"
  aws_do lambda wait function-active-v2 --function-name "$ORIGIN_FN" || fail "origin function not active"
  # Best effort: caps what a stranger who finds the public URL can run up. Many accounts cannot reserve (the unreserved pool must stay at 100).
  aws_do lambda put-function-concurrency --function-name "$ORIGIN_FN" --reserved-concurrent-executions 5 >/dev/null \
    || say "  note: reserved concurrency was not set (account limit?); continuing without it"
  local url
  url="$(aws_do lambda create-function-url-config --function-name "$ORIGIN_FN" --auth-type NONE --query FunctionUrl --output text)" || fail "create-function-url-config"
  aws_do lambda add-permission --function-name "$ORIGIN_FN" --statement-id url-invoke-url --action lambda:InvokeFunctionUrl \
    --principal '*' --function-url-auth-type NONE >/dev/null || fail "add-permission InvokeFunctionUrl"
  aws_do lambda add-permission --function-name "$ORIGIN_FN" --statement-id url-invoke-fn --action lambda:InvokeFunction \
    --principal '*' --invoked-via-function-url >/dev/null || fail "add-permission InvokeFunction (needs a recent AWS CLI v2)"
  url="${url#https://}"; url="${url%/}"
  ORIGIN_HOST="$url"   # not saved: the state file keeps names and ids only

  say "[4/7] Lambda@Edge function and version"
  package_edge "$d" || fail "packaging the edge function"
  state_set EDGE_FN "bhc-$RUNID-edge"
  aws_do lambda create-function --function-name "$EDGE_FN" --runtime nodejs22.x --handler index.handler --timeout 5 --memory-size 128 \
    --role "$role_arn" --zip-file "fileb://$d/edge.zip" --tags "RunId=$RUNID,Purpose=bhc-test" >/dev/null || fail "create edge function"
  aws_do lambda wait function-active-v2 --function-name "$EDGE_FN" || fail "edge function not active"
  edge_arn="$(aws_do lambda publish-version --function-name "$EDGE_FN" --query FunctionArn --output text)" || fail "publish-version"
  state_set EDGE_VER "${edge_arn##*:}"

  say "[5/7] cache policy"
  jq -n --arg name "bhc-$RUNID-cp" --arg comment "bhc test $RUNID" '{Name:$name,Comment:$comment,DefaultTTL:0,MinTTL:0,MaxTTL:86400,
    ParametersInCacheKeyAndForwardedToOrigin:{EnableAcceptEncodingGzip:false,EnableAcceptEncodingBrotli:false,
      HeadersConfig:{HeaderBehavior:"none"},CookiesConfig:{CookieBehavior:"none"},QueryStringsConfig:{QueryStringBehavior:"none"}}}' > "$d/cp.json" || fail "building the cache policy"
  local cpid
  state_set TRY_CP 1
  cpid="$(aws_do cloudfront create-cache-policy --cache-policy-config "file://$d/cp.json" --query CachePolicy.Id --output text)" || fail "create-cache-policy"
  [ -n "$cpid" ] && [ "$cpid" != None ] || fail "create-cache-policy returned no id"
  state_set CP_ID "$cpid"

  say "[6/7] CloudFront distribution"
  jq -n --arg run "$RUNID" --arg host "$ORIGIN_HOST" --arg cp "$CP_ID" --arg fn "$edge_arn" '{
    DistributionConfig: {
      CallerReference: $run, Comment: ("bhc test " + $run), Enabled: true, PriceClass: "PriceClass_100",
      Origins: {Quantity: 1, Items: [{Id: "origin", DomainName: $host,
        CustomOriginConfig: {HTTPPort: 80, HTTPSPort: 443, OriginProtocolPolicy: "https-only", OriginSslProtocols: {Quantity: 1, Items: ["TLSv1.2"]}}}]},
      DefaultCacheBehavior: {TargetOriginId: "origin", ViewerProtocolPolicy: "https-only", CachePolicyId: $cp, Compress: false,
        AllowedMethods: {Quantity: 2, Items: ["GET", "HEAD"], CachedMethods: {Quantity: 2, Items: ["GET", "HEAD"]}},
        LambdaFunctionAssociations: {Quantity: 1, Items: [{LambdaFunctionARN: $fn, EventType: "origin-response", IncludeBody: false}]}},
      CustomErrorResponses: {Quantity: 1, Items: [{ErrorCode: 500, ErrorCachingMinTTL: 0}]}
    },
    Tags: {Items: [{Key: "RunId", Value: $run}, {Key: "Purpose", Value: "bhc-test"}]}
  }' > "$d/dist.json" || fail "building the distribution config"
  local out
  state_set TRY_DIST 1
  out="$(aws_do cloudfront create-distribution-with-tags --distribution-config-with-tags "file://$d/dist.json" --output json)" || fail "create-distribution-with-tags"
  local did
  did="$(printf '%s' "$out" | jq -r '.Distribution.Id // empty')"
  [ -n "$did" ] && [ "$did" != null ] || fail "no distribution id returned"
  state_set DIST_ID "$did"
  CF_DOMAIN="$(printf '%s' "$out" | jq -r '.Distribution.DomainName // empty')"
  [ -n "$CF_DOMAIN" ] || fail "no distribution domain returned"

  say "[7/7] waiting until CloudFront has deployed the distribution (usually 5-15 minutes)"
  aws_do cloudfront wait distribution-deployed --id "$DIST_ID" || fail "the distribution did not reach Deployed"
  say "stack is ready"
}

# put_config START END IN OUT: write the window JSON to S3
put_config() {
  local f="$WORK/window.json"
  printf '{"startMin":%s,"endMin":%s,"inTtl":%s,"outTtl":%s}\n' "$1" "$2" "$3" "$4" > "$f"
  aws_do s3api put-object --bucket "$BUCKET" --key "$CONFIG_KEY" --body "$f" --content-type application/json >/dev/null
}
set_window() { # START END: IN_TTL/OUT_TTL fixed; waits for the edge function's 30 s memory cache to expire
  put_config "$1" "$2" "$IN_TTL" "$OUT_TTL" || fail "cannot upload the window config"
  say "  window set to minutes $1..$2 UTC (inTtl=$IN_TTL, outTtl=$OUT_TTL); waiting ${SETTLE_SECS}s for the edge config cache"
  nap "$SETTLE_SECS"
}

# ---------------------------------------------------------------------------------------------------- requests
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
csv() { local IFS=,; echo "$*"; }

# req PATH -> R_ST R_XC R_AGE R_CC R_NONCE R_CNT. Returns 1 when there was no HTTP answer.
req() {
  local h="$WORK/resp.h" b="$WORK/resp.b"
  R_ST="" R_XC="" R_AGE="" R_CC="" R_NONCE="" R_CNT=""
  : > "$h"; : > "$b"
  curl -sS -o "$b" -D "$h" --max-time 30 "https://$CF_DOMAIN$1" 2>"$WORK/curl.err" || return 1
  R_ST="$(tr -d '\r' < "$h" | awk 'NR==1{print $2}')"
  R_XC="$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="x-cache"{print $2; exit}' | awk '{print $1}')"
  R_AGE="$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="age"{print $2; exit}')"
  R_CC="$(tr -d '\r' < "$h" | awk 'tolower(substr($0,1,14))=="cache-control:"{sub(/^[^:]*: */,""); print; exit}')"
  R_NONCE="$(jq -r '.nonce // empty' "$b" 2>/dev/null)"
  R_CNT="$(jq -r '.counter // empty' "$b" 2>/dev/null)"
  [ -n "$R_ST" ]
}

# series PATH N GAP -> S_ST S_XC S_AGE S_CC S_NONCE S_CNT (arrays), S_BAD=1 when a request got no answer
series() {
  local i
  S_ST=() S_XC=() S_AGE=() S_CC=() S_NONCE=() S_CNT=() S_BAD=0
  for ((i = 0; i < $2; i++)); do
    [ "$i" -gt 0 ] && nap "$3"
    if req "$1"; then
      S_ST+=("$R_ST"); S_XC+=("${R_XC:-none}"); S_AGE+=("${R_AGE:--}"); S_CC+=("$R_CC"); S_NONCE+=("$R_NONCE"); S_CNT+=("${R_CNT:-?}")
    else
      S_BAD=1; S_ST+=("000"); S_XC+=("none"); S_AGE+=("-"); S_CC+=(""); S_NONCE+=(""); S_CNT+=("?")
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
  local m; m="$(minute_of_day)"
  if [ "$m" -lt 5 ] || [ "$m" -gt 1410 ]; then add_result T-A INCONCLUSIVE "$TOO_CLOSE"; return; fi
  say "T-A: window contains now, 5 requests, every one must reach the origin"
  set_window $((m - 5)) $((m + 30))
  series /a 5 1
  if [ "$S_BAD" = 1 ] || ! all_status 200; then add_result T-A INCONCLUSIVE "no HTTP 200 from every request: status=[$(csv "${S_ST[@]}")]"
  elif has_hit "${S_XC[@]}"; then add_result T-A FAIL "a request was served from cache: $(meas)"
  elif [ "$(distinct "${S_NONCE[@]}")" != 5 ]; then add_result T-A FAIL "origin nonce repeated, so the origin was not hit every time: $(meas)"
  elif ! all_eq "$EXPECT_IN" "${S_CC[@]}"; then add_result T-A FAIL "viewer Cache-Control is not what the function sets: $(meas)"
  elif ! steps_of_one "${S_CNT[@]}"; then add_result T-A INCONCLUSIVE "distinct nonces but the counter did not step by 1 (new origin instance or other traffic): $(meas)"
  else add_result T-A PASS "$(meas)"; fi
}

t_b() {
  local m; m="$(minute_of_day)"
  if [ "$m" -lt 60 ]; then add_result T-B INCONCLUSIVE "$TOO_CLOSE"; return; fi
  say "T-B: window in the past, first request Miss, repeats Hit, origin counter flat"
  set_window $((m - 60)) $((m - 30))
  series /b 5 "$HIT_GAP_SECS"
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
  say "T-D: origin answers 500 on /err; the long TTL must not be applied or cached"
  series /err 3 1
  if [ "$S_BAD" = 1 ] || ! all_status 500; then add_result T-D INCONCLUSIVE "expected HTTP 500 from every request: status=[$(csv "${S_ST[@]}")]"
  elif has_hit "${S_XC[@]}"; then add_result T-D FAIL "the 500 was served from cache: $(meas)"
  elif printf '%s\n' "${S_CC[@]}" | grep -q 's-maxage=14400'; then add_result T-D FAIL "the function rewrote an error response: $(meas)"
  elif [ "$(distinct "${S_NONCE[@]}")" != 3 ]; then add_result T-D FAIL "origin nonce repeated for the 500: $(meas)"
  else add_result T-D PASS "status=500 on all, not cached for outTtl; $(meas)"; fi
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
  aws_do s3api delete-object --bucket "$BUCKET" --key "$CONFIG_KEY" >/dev/null || fail "cannot delete the config object"
  say "  E1: config object deleted; waiting ${SETTLE_SECS}s for the edge config cache"
  nap "$SETTLE_SECS"
  e_phase /e; r1="$E_RES"; m1="$E_MEAS"
  f="$WORK/notjson.txt"; printf 'this is not json\n' > "$f"
  aws_do s3api put-object --bucket "$BUCKET" --key "$CONFIG_KEY" --body "$f" --content-type application/json >/dev/null || fail "cannot upload the bad config"
  say "  E2: config object replaced by text that is not JSON; waiting ${SETTLE_SECS}s"
  nap "$SETTLE_SECS"
  e_phase /e2; r2="$E_RES"; m2="$E_MEAS"
  if [ "$r1" = PASS ] && [ "$r2" = PASS ]; then add_result T-E PASS "fallback s-maxage=0 in both cases. E1 missing key: $m1. E2 bad JSON: $m2"
  elif [ "$r1" = FAIL ] || [ "$r2" = FAIL ]; then add_result T-E FAIL "E1 missing key: $r1 $m1. E2 bad JSON: $r2 $m2"
  else add_result T-E INCONCLUSIVE "E1 missing key: $r1 $m1. E2 bad JSON: $r2 $m2"; fi
}

t_c() {
  local m start end open t0 t1 gap age rem first_nonce c2a c2b
  m="$(minute_of_day)"
  if [ "$m" -gt 1375 ]; then add_result T-C INCONCLUSIVE "$TOO_CLOSE"; return; fi
  say "T-C: window opens in about 2-3 minutes; an object cached before that stays cached"
  start=$((m + 3)); end=$((start + 60))
  put_config "$start" "$end" "$IN_TTL" "$OUT_TTL" || fail "cannot upload the window config"
  say "  window set to minutes $start..$end UTC; waiting ${SETTLE_SECS}s for the edge config cache"
  nap "$SETTLE_SECS"
  open=$(( $(day_start_epoch) + start * 60 ))
  t0="$(now_epoch)"
  if [ "$t0" -ge "$open" ]; then add_result T-C INCONCLUSIVE "the window opened before the first request (slow start)"; return; fi
  if ! req /c; then add_result T-C INCONCLUSIVE "no answer for /c"; return; fi
  first_nonce="$R_NONCE"
  if [ "$(lc "$R_XC")" != miss ] || [ "$R_CC" != "$EXPECT_OUT" ]; then add_result T-C INCONCLUSIVE "first request not a Miss with s-maxage=$OUT_TTL (xcache=$R_XC cache-control=\"$R_CC\")"; return; fi
  nap "$HIT_GAP_SECS"
  req /c || { add_result T-C INCONCLUSIVE "no answer for /c"; return; }
  case "$(lc "$R_XC")" in hit|refreshhit) ;; *) add_result T-C INCONCLUSIVE "object not cached before the opening (xcache=$R_XC)"; return ;; esac
  say "  cached before the opening; waiting for the window to open at $((open - t0))s from the first request"
  wait_until_epoch $((open + 10))
  req /c || { add_result T-C INCONCLUSIVE "no answer for /c after opening"; return; }
  t1="$(now_epoch)"; gap=$((t1 - open)); age="${R_AGE:-0}"
  if [ "$R_NONCE" != "$first_nonce" ]; then
    add_result T-C INCONCLUSIVE "object was refreshed ${gap}s after the opening (xcache=$R_XC); the stale-until-TTL behaviour was NOT reproduced"; return
  fi
  rem=$((OUT_TTL - age))
  series /c2 2 1
  c2a="${S_XC[0]}"; c2b="${S_XC[1]}"
  if [ "$S_BAD" = 1 ] || ! all_status 200; then add_result T-C INCONCLUSIVE "no HTTP 200 for /c2"
  elif has_hit "${S_XC[@]}" || [ "$(distinct "${S_NONCE[@]}")" != 2 ] || ! all_eq "$EXPECT_IN" "${S_CC[@]}"; then
    add_result T-C FAIL "a NEW object after the opening was cached or not marked s-maxage=0 (xcache=$c2a,$c2b)"
  else
    add_result T-C PASS "limitation reproduced: /c cached before the opening was still served from cache (xcache=$R_XC, age=${age}s) ${gap}s after the window opened and stays so for about ${rem}s more (until its TTL ends, outTtl=${OUT_TTL}s); new object /c2 after the opening was not cached (xcache=$c2a,$c2b)"
    note "T-C: boundary expiry gap observed: at least ${gap}s after the window opened, an object cached before the opening was still served from cache; remaining life about ${rem}s of ${OUT_TTL}s. Lower outTtl, or invalidate, if you need the opening to take effect sooner."
  fi
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
    for m in T-A T-B T-D T-E T-C; do add_result "$m" INCONCLUSIVE "CloudFront did not answer 200 after the warm-up (origin, function URL permission or edge function problem)"; done
    return
  fi
  t_a; t_b; t_d; t_e; t_c
}

# ---------------------------------------------------------------------------------------------------- report
write_report() { # title
  local i f d n=1
  d="$(date -u +%Y%m%d)"; f="$RESULTS_DIR/results-$d.md"
  while [ -e "$f" ]; do n=$((n + 1)); f="$RESULTS_DIR/results-$d-$n.md"; done
  {
    echo "# CloudFront business-hours cache: results"
    echo
    echo "- Run: $RUNID, finished $(stamp), region $REGION, edge function version $EDGE_VER"
    echo "- Status: $1"
    echo "- Config: one daily window in UTC, inTtl=$IN_TTL, outTtl=$OUT_TTL, cache policy min 0 / default 0 / max 86400"
    echo
    echo "| Test | Result | Measured |"
    echo "|---|---|---|"
    for ((i = 0; i < ${#RES_NAME[@]}; i++)); do echo "| ${RES_NAME[$i]} | ${RES_RESULT[$i]} | $(printf '%s' "${RES_MEAS[$i]}" | tr '|' '/') |"; done
    echo
    echo "PASS = measured as expected. FAIL = measured something else. INCONCLUSIVE = the test could not run cleanly, so it says nothing either way."
    if [ "${#NOTES[@]}" -gt 0 ]; then echo; echo "## Notes"; echo; for ((i = 0; i < ${#NOTES[@]}; i++)); do echo "- ${NOTES[$i]}"; done; fi
  } | redact > "$f"
  RESULTS_FILE="$f"; REPORT_WRITTEN=1
  say "results file: $(basename "$f") (in $(basename "$RESULTS_DIR"))"
}

report() {
  local p f i c
  p="$(count_result PASS)"; f="$(count_result FAIL)"; i="$(count_result INCONCLUSIVE)"
  say ""
  say "==================== RESULTS ===================="
  printf '%-6s %-13s %s\n' TEST RESULT MEASURED | redact
  for ((c = 0; c < ${#RES_NAME[@]}; c++)); do printf '%-6s %-13s %s\n' "${RES_NAME[$c]}" "${RES_RESULT[$c]}" "${RES_MEAS[$c]}" | redact; done
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
  RUNID="${RT_RUNID:-$(date -u +%y%m%d%H%M)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')}"
  printf '%s' "$RUNID" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$' || die "run id '$RUNID' is not of the form 2610101200-ab12"
  print_plan "$RUNID"
  if [ "$MIDNIGHT_BAD" = 1 ]; then
    say ""
    say "NOTE: it is now $(stamp). The tests need windows of up to 60 minutes on both sides of 'now' inside one UTC day."
    say "      Start this between 01:30 and 22:00 UTC. A real run refuses to start outside that."
  fi
  if [ "$DRY_RUN" = 1 ]; then
    say ""
    say "dry run: nothing was created or deleted (only sts get-caller-identity was called)."
    return 0
  fi
  [ "$MIDNIGHT_BAD" = 0 ] || die "outside 01:30-22:00 UTC, see the note above"
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

# discover_by_tag: no state file (lost, or another directory). Read-only listing of everything tagged RunId=<id>; the deletes
# that follow are the same tag-checked ones as always. Cache policies cannot be tagged, so they are looked up by name.
discover_by_tag() {
  local arns a n
  arns="$(aws_ro resourcegroupstaggingapi get-resources --tag-filters "Key=RunId,Values=$RUNID" --query 'ResourceTagMappingList[].ResourceARN' --output text)" \
    || die "cannot list resources by tag (needs tag:GetResources)"
  for a in $arns; do
    n="${a##*[:/]}"
    case "$a" in
      arn:aws:s3:::*) [ "$n" = "bhc-$RUNID-cfg" ] && BUCKET="$n" ;;
      arn:aws:iam::*:role/*) case "$n" in "bhc-$RUNID-erole") ROLE="$n" ;; "bhc-$RUNID-orole") ORIGIN_ROLE="$n" ;; esac ;;
      arn:aws:lambda:*:function:*) case "$n" in "bhc-$RUNID-edge") EDGE_FN="$n" ;; "bhc-$RUNID-origin") ORIGIN_FN="$n" ;; esac ;;
      arn:aws:cloudfront::*:distribution/*) DIST_ID="$n" ;;
    esac
  done
  TRY_CP=1; TRY_DIST=1
  if [ -z "$BUCKET$ROLE$ORIGIN_ROLE$EDGE_FN$ORIGIN_FN$DIST_ID" ]; then die "nothing tagged RunId=$RUNID was found (already deleted?)"; fi
}

main_cleanup() {
  printf '%s' "$CLEANUP_ID" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$' || die "--cleanup needs a run id like 2610101200-ab12"
  STATE_FILE="$RESULTS_DIR/state-$CLEANUP_ID.env"
  if [ -f "$STATE_FILE" ]; then
    state_load "$STATE_FILE"
    [ "$RUNID" = "$CLEANUP_ID" ] || die "state file does not belong to run $CLEANUP_ID"
  else
    say "no state file $STATE_FILE (it is written next to where the run started: RESULTS_DIR, default the current directory)."
    say "falling back to a read-only listing by the RunId tag"
    RUNID="$CLEANUP_ID"
    discover_by_tag
  fi
  say "cleanup of run $RUNID: will delete only resources tagged RunId=$RUNID:"
  say "  distribution ${DIST_ID:-none}, cache policy ${CP_ID:-by name}, functions ${EDGE_FN:-none} ${ORIGIN_FN:-none}, roles ${ROLE:-none} ${ORIGIN_ROLE:-none}, bucket ${BUCKET:-none}"
  if [ "$DRY_RUN" = 1 ]; then say "dry run: nothing was deleted."; return 0; fi
  say "Target:  profile ${AWS_PROFILE:-<none, default credentials>}   region $REGION   account ending in $ACCT_LAST4"
  confirm "$CLEANUP_PHRASE"
  [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
  CREATE_STARTED=1
}

preflight
case "$MODE" in
  run) main_run ;;
  cleanup) main_cleanup ;;
esac
exit 0
