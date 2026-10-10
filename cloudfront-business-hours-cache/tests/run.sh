#!/usr/bin/env bash
# run.sh - tests for cloudfront-business-hours-cache. No AWS, no network: run-test.sh runs against a fake aws, curl, date,
# sleep and zip (tests/bin). The edge function logic is tested with python unittest (tests/test_edge.py).
# Usage: tests/run.sh      Exit 0 only if every check passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
export PATH="$here/bin:$PATH"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bhct.XXXXXX")"; if [ -z "${KEEP_TMP:-}" ]; then trap 'rm -rf "$TMP"' EXIT; else echo "keeping $TMP"; fi
PASS=0 FAIL=0
RUNID_A=2610101200-ab12
OTHER=9999999999-ffff
RT="$root/run-test.sh"

check() { # description, then a command; passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "  ok   $d"; else FAIL=$((FAIL + 1)); echo "  FAIL $d"; fi
}
has()    { grep -q -- "$2" "$1"; }
hasnot() { ! grep -q -- "$2" "$1"; }
is()     { [ "$1" = "$2" ]; }

reset_env() {
  unset STUB_CURL_FAIL_PATH STUB_TAG_HIDE STUB_FAIL STUB_FAIL_CODE STUB_FAIL_TEXT STUB_STRAY_MISS STUB_DIST_NULL EXPECT_ACCOUNT_LAST4 STUB_SIG STUB_SIG_AT STUB_FOREIGN_TAG STUB_REPLICA STUB_REPLICA_FN STUB_STATUS_SEQ STUB_INIT_STATUS EDGE_RUNTIME ORIGIN_RUNTIME PERMISSIONS_BOUNDARY_ARN SETTLE_POLLS STUB_STACK_FAIL STUB_CDN STUB_CURL_DOWN STUB_START_EPOCH
  export AWS_PROFILE=testprof
  export RT_RUNID="$RUNID_A" SETTLE_SECS=40 EDGE_DELETE_PAUSE=1 WARMUP_TRIES=2
}
# newdir NAME -> STUB_DIR and RESULTS_DIR for that scenario
newdir() { STUB_DIR="$TMP/$1/state"; RESULTS_DIR="$TMP/$1/res"; mkdir -p "$STUB_DIR/res" "$RESULTS_DIR"; export STUB_DIR RESULTS_DIR; OUT="$TMP/$1/out.txt"; }
# seed_foreign: resources of ANOTHER run that must never be touched
seed_foreign() {
  echo "$OTHER" > "$STUB_DIR/res/s3__bhc-$OTHER-cfg"; echo "$OTHER" > "$STUB_DIR/res/lambda__bhc-$OTHER-edge"
  echo "$OTHER" > "$STUB_DIR/res/iam__bhc-$OTHER-erole"; echo "$OTHER" > "$STUB_DIR/res/lambda__bhc-$OTHER-origin"
  echo "$OTHER" > "$STUB_DIR/res/cfn__bhc-$OTHER"; echo "$OTHER" > "$STUB_DIR/res/s3__bhc-$OTHER-art"
}
# seed_logs: log groups of this run (must go) and look-alikes (must stay). File names: "/" written as "%".
seed_logs() {
  mkdir -p "$STUB_DIR/logs/us-east-1" "$STUB_DIR/logs/eu-west-1"
  : > "$STUB_DIR/logs/us-east-1/%aws%lambda%bhc-$RUNID_A-origin"
  : > "$STUB_DIR/logs/eu-west-1/%aws%lambda%us-east-1.bhc-$RUNID_A-edge"
  : > "$STUB_DIR/logs/eu-west-1/%aws%lambda%us-east-1.bhc-$RUNID_A-edge-extra"
  : > "$STUB_DIR/logs/us-east-1/%aws%lambda%bhc-$OTHER-origin"
}
logs_decoys_intact() { [ -e "$STUB_DIR/logs/eu-west-1/%aws%lambda%us-east-1.bhc-$RUNID_A-edge-extra" ] && [ -e "$STUB_DIR/logs/us-east-1/%aws%lambda%bhc-$OTHER-origin" ]; }
# go NAME "stdin" args... -> RC, OUT
go() { local name="$1" input="$2"; shift 2; newdir "$name"; [ "${SEED:-0}" = 1 ] && seed_foreign; [ "${SEED_LOGS:-0}" = 1 ] && seed_logs; printf '%b' "$input" | "$RT" "$@" > "$OUT" 2>&1; RC=$?; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null; }
only_sts() { calls | grep -q . && ! calls | grep -qvE '^(sts get-caller-identity|cloudformation validate-template)'; }
no_leftovers() {   # nothing of this run in the fake account (files of $OTHER do not count)
  local f
  for f in "$STUB_DIR"/res/*; do
    [ -e "$f" ] || continue
    case "$f" in *"$OTHER"*) ;; *) return 1 ;; esac
  done
  return 0
}
foreign_intact() { [ -e "$STUB_DIR/res/s3__bhc-$OTHER-cfg" ] && [ -e "$STUB_DIR/res/lambda__bhc-$OTHER-edge" ] && [ -e "$STUB_DIR/res/iam__bhc-$OTHER-erole" ] && [ -e "$STUB_DIR/res/lambda__bhc-$OTHER-origin" ] && [ -e "$STUB_DIR/res/cfn__bhc-$OTHER" ] && [ -e "$STUB_DIR/res/s3__bhc-$OTHER-art" ]; }
never_mentions_foreign() { ! calls | grep -q "$OTHER"; }
# nothing that looks like an account id, ARN, key, token, CloudFront or function-URL host, or distribution id
clean() {
  ! grep -E -q '(^|[^0-9])[0-9]{12}([^0-9]|$)|arn:aws|AKIA[0-9A-Z]{16}|[a-z0-9]+\.cloudfront\.net|\.lambda-url\.|(^|[^A-Za-z0-9])E[A-Z0-9]{12,13}([^A-Za-z0-9]|$)|[A-Za-z0-9+/=_-]{40,}' "$1"
}
first_res() { local f; for f in "$RESULTS_DIR"/results-*.md; do [ -e "$f" ] && { echo "$f"; return; }; done; }

PHRASE="create cloudfront test stack"

echo "dry run"
reset_env; go dry "" --dry-run
check "dry run exits 0" is "$RC" 0
check "dry run makes only the read-only identity and template-validation calls" only_sts
check "dry run validated the template" has "$STUB_DIR/calls.log" "cloudformation validate-template"
check "dry run prints the plan with the stack name" has "$OUT" "stack bhc-$RUNID_A"
check "dry run names the resources the stack creates" bash -c "grep -q 'bhc-$RUNID_A-edge' '$OUT' && grep -q 'bhc-$RUNID_A-cfg' '$OUT' && grep -q 'bhc-$RUNID_A-art' '$OUT'"
check "dry run says nothing was created" has "$OUT" "nothing was created or deleted"
check "dry run states cost and time" has "$OUT" "15-25 minutes"
check "dry run starts no curl and no zip" bash -c "! grep -E '^(curl|zip) ' '$STUB_DIR/calls.log'"
check "dry run creates no bucket and no stack" bash -c "! grep -E '^(s3api|cloudformation) (create|put|delete)' '$STUB_DIR/calls.log'"
check "dry run leaves no state file or results file" bash -c "[ -z \"\$(ls '$RESULTS_DIR')\" ]"
check "dry run output is redacted" clean "$OUT"
check "dry run hides the account id" has "$OUT" "account \*\*\*\*"

echo "dry run, near UTC midnight"
reset_env; export STUB_START_EPOCH=1791592200   # 00:30 UTC
go dry_mid "" --dry-run
check "dry run warns about the time of day" has "$OUT" "01:30 and 22:00 UTC"
check "dry run still only reads" only_sts
go mid "$PHRASE\n"
check "a real run near midnight refuses before creating anything" is "$RC" 2
check "only read-only calls were made" only_sts

echo "typed confirmation"
reset_env; go confirm_wrong "yes\n"
check "wrong phrase aborts with rc 1" is "$RC" 1
check "wrong phrase: nothing created" only_sts
check "wrong phrase: says so" has "$OUT" "nothing was created"
go confirm_empty ""
check "no input aborts" is "$RC" 1
check "no input: nothing created" only_sts
go confirm_case "Create CloudFront Test Stack\n"
check "the phrase is case sensitive" is "$RC" 1
check "the plan asks for the exact phrase" has "$OUT" "Type \"$PHRASE\""
check "the plan says it costs cents and takes 15-25 minutes" has "$OUT" "costs cents and takes about 15-25 minutes"

echo "full run, everything works"
reset_env; SEED=1 go happy "$PHRASE\n"
check "exit 0" is "$RC" 0
for t in T-A T-B T-C T-D T-E T-F; do check "$t PASS in the table" grep -Eq "^$t +PASS" "$OUT"; done
check "summary line PASS=6" has "$OUT" "PASS=6 FAIL=0 INCONCLUSIVE=0"
check "results file written" test -n "$(first_res)"
check "results file has the table and the T-C note" bash -c "grep -q '^| T-C | PASS' '$(first_res)' && grep -q 'was gone 5s after the opening' '$(first_res)'"
check "results file says teardown complete" has "$(first_res)" "Complete: every resource"
check "results file is redacted" clean "$(first_res)"
check "screen output is redacted" clean "$OUT"
check "teardown complete" has "$OUT" "teardown: complete"
check "the stack and everything in it deleted, plus the artifact bucket" bash -c "for k in 'cfn bhc-$RUNID_A' 'cf ' 'lambda bhc-$RUNID_A-edge' 'lambda bhc-$RUNID_A-origin' 'iam bhc-$RUNID_A-erole' 'iam bhc-$RUNID_A-orole' 's3 bhc-$RUNID_A-cfg' 's3 bhc-$RUNID_A-art'; do grep -q \"DELETE \$k\" '$STUB_DIR/deleted.log' || exit 1; done"
check "nothing of this run is left" no_leftovers
check "resources of another run untouched" foreign_intact
check "no call ever mentions another run's resources" never_mentions_foreign
check "state file removed after a clean teardown" bash -c "[ ! -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
check "ONE create-stack call, named bhc-<runid>, with the named-IAM capability and the RunId tag" bash -c "[ \$(grep -c '^cloudformation create-stack' '$STUB_DIR/calls.log') = 1 ] && grep '^cloudformation create-stack' '$STUB_DIR/calls.log' | grep -q -- '--stack-name bhc-$RUNID_A ' && grep '^cloudformation create-stack' '$STUB_DIR/calls.log' | grep -q 'CAPABILITY_NAMED_IAM' && grep '^cloudformation create-stack' '$STUB_DIR/calls.log' | grep -q 'Key=RunId,Value=$RUNID_A'"
check "no hand-rolled resource creation is left (no create-role, create-function, create-distribution, create-cache-policy)" bash -c "! grep -qE '^(iam create-role|lambda create-function|cloudfront )' '$STUB_DIR/calls.log'"
check "stack parameters: run id, config bucket, code bucket and key" bash -c "jq -e --arg r '$RUNID_A' '(.[]|select(.ParameterKey==\"RunId\").ParameterValue)==\$r and (.[]|select(.ParameterKey==\"ConfigBucketName\").ParameterValue)==(\"bhc-\"+\$r+\"-cfg\") and (.[]|select(.ParameterKey==\"CodeBucket\").ParameterValue)==(\"bhc-\"+\$r+\"-art\")' '$STUB_DIR/stack-params.json'"
check "the edge zip was uploaded to the artifact bucket before the stack was created" bash -c "[ -s '$STUB_DIR/art-object' ] && [ \$(grep -n 'put-object --bucket bhc-$RUNID_A-art' '$STUB_DIR/calls.log' | head -1 | cut -d: -f1) -lt \$(grep -n '^cloudformation create-stack' '$STUB_DIR/calls.log' | head -1 | cut -d: -f1) ]"
check "the config object is removed before delete-stack (the bucket must be empty)" bash -c "[ \$(grep -n 'delete-object --bucket bhc-$RUNID_A-cfg' '$STUB_DIR/calls.log' | tail -1 | cut -d: -f1) -lt \$(grep -n '^cloudformation delete-stack' '$STUB_DIR/calls.log' | head -1 | cut -d: -f1) ]"
check "T-A window is now-5..now+30 (clock 12:00 UTC = 720)" has "$STUB_DIR/puts.log" '"startMin":715,"endMin":750,"inTtl":0,"outTtl":14400'
check "T-A also shows /rates/a outside its window at the same moment, with the long TTL" bash -c "grep -E '^T-A +PASS' '$OUT' | grep -q 'at the same moment /rates/a (outside its window): cache-control=\"public, max-age=0, s-maxage=14400\"'"
check "the config has one rule per path pattern (/prices/*, /rates/*, /err*)" bash -c "grep -q '\"path\":\"/prices/\*\",\"startMin\":715' '$STUB_DIR/puts.log' && grep -q '\"path\":\"/rates/\*\",\"startMin\":660' '$STUB_DIR/puts.log' && grep -q '\"path\":\"/err\*\"' '$STUB_DIR/puts.log'"
check "the first upload is a valid default-only config" bash -c "head -n 1 '$STUB_DIR/puts.log' | jq -e '.default.startMin == 0 and (.rules // []) == []'"
check "T-C uses its own /c/* rule" bash -c "grep -qF '\"path\":\"/c/*\"' '$STUB_DIR/puts.log'"
check "T-B window is now-60..now-30" has "$STUB_DIR/puts.log" '"startMin":660,"endMin":690,"inTtl":0,"outTtl":14400'
check "T-C window opens a few minutes after now" bash -c "grep -Eq '\"startMin\":72[0-9],\"endMin\":78[0-9]' '$STUB_DIR/puts.log'"
check "the window is never overnight (start < end in every upload)" bash -c "! grep -o '\"startMin\":[0-9]*,\"endMin\":[0-9]*' '$STUB_DIR/puts.log' | sed 's/[^0-9,]//g' | awk -F, '\$1 >= \$2' | grep -q ."
check "reserved concurrency 5 requested on the origin (best effort, after the stack)" has "$STUB_DIR/calls.log" "put-function-concurrency --function-name bhc-$RUNID_A-origin --reserved-concurrent-executions 5"
reset_env; export STUB_FAIL=put-function-concurrency; go noconc "$PHRASE\n"
check "reserved concurrency failure does not abort the run" bash -c "[ '$RC' = 0 ] && grep -q 'reserved concurrency was not set' '$OUT'"

echo "packaging and the template"
reset_env; go pkg "$PHRASE\n"
check "edge code has the config bucket baked in" has "$STUB_DIR/zipped/edge-index.py" "bhc-$RUNID_A-cfg"
check "edge code has the key baked in" has "$STUB_DIR/zipped/edge-index.py" "window.json"
check "edge code has no placeholder left" hasnot "$STUB_DIR/zipped/edge-index.py" "__CONFIG_"
TPL="$root/cfn/stack.yaml"
inline="$TMP/inline-origin.js"
awk '/ZipFile: \|/{f=1;next} f&&/^$/{exit} f{sub(/^          /,""); print}' "$TPL" > "$inline"
check "the inline origin code in the template is identical to origin/index.js" diff -q "$inline" "$root/origin/index.js"
check "the inline origin code fits CloudFormation's 4096 character limit" bash -c "[ \$(wc -c < '$inline') -lt 4096 ]"
check "the origin sends no Cache-Control" hasnot "$root/origin/index.js" -i "cache-control"
check "the template creates the resources the README lists" bash -c "for t in AWS::S3::Bucket AWS::IAM::Role AWS::Lambda::Function AWS::Lambda::Url AWS::Lambda::Version AWS::Lambda::Permission AWS::CloudFront::CachePolicy AWS::CloudFront::Distribution; do grep -q \"Type: \$t\" '$TPL' || exit 1; done"
check "config bucket: public access block, encryption, and no bucket policy but the TLS-only deny" bash -c "grep -q BlockPublicAcls '$TPL' && grep -q SSEAlgorithm '$TPL' && [ \$(grep -c 'Type: AWS::S3::BucketPolicy' '$TPL') = 1 ] && grep -q 'aws:SecureTransport' '$TPL'"
check "the edge function is Python: handler index.lambda_handler, runtime parameter default python3.12" bash -c "grep -q 'Handler: index.lambda_handler' '$TPL' && grep -q 'Default: python3.12' '$TPL'"
check "edge role trusts edgelambda, origin role does not" bash -c "[ \$(grep -c edgelambda.amazonaws.com '$TPL') = 1 ]"
check "edge role reads one object and lists the bucket; logs are scoped to this run" bash -c "grep -q 's3:GetObject' '$TPL' && grep -q 's3:ListBucket' '$TPL' && grep -q 'log-group:/aws/lambda/\*bhc-\${RunId}-\*' '$TPL'"
check "cache policy: min 0, default 0, max 86400, nothing in the key" bash -c "grep -q 'MinTTL: 0' '$TPL' && grep -q 'DefaultTTL: 0' '$TPL' && grep -q 'MaxTTL: 86400' '$TPL' && grep -q 'HeaderBehavior: none' '$TPL' && grep -q 'QueryStringBehavior: none' '$TPL'"
check "distribution: edge function on origin-response, 500 not cached" bash -c "grep -q 'EventType: origin-response' '$TPL' && grep -q 'ErrorCachingMinTTL: 0' '$TPL'"
if command -v cfn-lint >/dev/null 2>&1; then
  check "cfn-lint is clean on cfn/stack.yaml" cfn-lint "$TPL"
else
  echo "  SKIP cfn-lint not installed here (CI runs it)"
fi

echo "a cache that ignores the function is caught"
reset_env; export STUB_CDN=cacheall; go cacheall "$PHRASE\n"
check "T-A FAIL" grep -Eq "^T-A +FAIL" "$OUT"
check "rc 1" is "$RC" 1
check "teardown still complete" has "$OUT" "teardown: complete"
reset_env; export STUB_CDN=nocap; go nocap "$PHRASE\n"
check "without the cap an object cached before the opening is served after it: T-C FAIL" grep -Eq "^T-C +FAIL" "$OUT"
check "...and the message says the TTL is not capped" has "$OUT" "not capped to the time until the opening"
reset_env; export STUB_CDN=rewrite-errors; go rewrite "$PHRASE\n"
check "T-D FAIL when errors get the long TTL" grep -Eq "^T-D +FAIL" "$OUT"
reset_env; export STUB_CDN=stale-config; go stale "$PHRASE\n"
check "T-E FAIL when a stale config is used after an S3 failure" grep -Eq "^T-E +FAIL" "$OUT"
reset_env; export STUB_CURL_DOWN=1; go down "$PHRASE\n"
check "no answer: all tests INCONCLUSIVE" bash -c "[ '$(grep -cE '^T-. +INCONCLUSIVE' "$OUT")' = 6 ]"
check "no answer: rc 3" is "$RC" 3
check "no answer: still torn down" has "$OUT" "teardown: complete"

echo "teardown on an injected failure"
reset_env; export STUB_FAIL=create-stack; SEED=1 go inject "$PHRASE\n"
check "rc 1" is "$RC" 1
check "teardown ran" has "$OUT" "teardown: complete"
check "everything created so far is gone (artifact bucket)" no_leftovers
check "resources of another run untouched" foreign_intact
check "no call mentions another run" never_mentions_foreign
check "error text is redacted (account, ARN, key, host, token)" clean "$OUT"
check "error text still says what failed" has "$OUT" "create-stack"
reset_env; export STUB_FAIL=put-object; SEED=1 go inject2 "$PHRASE\n"   # the edge zip upload
check "failure at the zip upload: artifact bucket removed, no stack ever created" bash -c "[ -z \"\$(ls '$STUB_DIR/res' | grep -v $OTHER)\" ] && ! grep -q '^cloudformation create-stack' '$STUB_DIR/calls.log'"
check "failure at the zip upload: other run untouched" foreign_intact
reset_env; export STUB_FAIL=create-bucket; go inject3 "$PHRASE\n"
check "failure at the very first change: rc 1, nothing left" bash -c "[ '$RC' = 1 ] && [ -z \"\$(ls '$STUB_DIR/res')\" ]"
reset_env; export STUB_STACK_FAIL=1; SEED=1 go stackfail "$PHRASE\n"
check "stack that does not reach CREATE_COMPLETE: rc 1, stack and bucket deleted" bash -c "[ '$RC' = 1 ] && grep -q 'DELETE cfn bhc-$RUNID_A' '$STUB_DIR/deleted.log' && grep -q 'teardown: complete' '$OUT'"
check "...nothing left, other run untouched" bash -c "[ -z \"\$(ls '$STUB_DIR/res' | grep -v $OTHER)\" ]"
reset_env; export STUB_DIST_NULL=1; go distnull "$PHRASE\n"
check "a stack output without a distribution is refused" has "$OUT" "the stack outputs have no distribution"
check "...and the stack is still deleted" has "$STUB_DIR/deleted.log" "DELETE cfn bhc-$RUNID_A"

echo "teardown on Ctrl-C and SIGTERM"
reset_env; export STUB_SIG=INT STUB_SIG_AT=put-bucket-tagging; SEED=1 go sigint "$PHRASE\n"
check "SIGINT before the stack exists: rc 130" is "$RC" 130
check "...teardown complete, artifact bucket gone, no stack deleted (none existed)" bash -c "grep -q 'teardown: complete' '$OUT' && ! grep -q 'DELETE cfn' '$STUB_DIR/deleted.log' && grep -q 'DELETE s3 bhc-$RUNID_A-art' '$STUB_DIR/deleted.log'"
check "...other run untouched" foreign_intact
check "...no call mentions another run" never_mentions_foreign
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-stack; SEED=1 go sigint2 "$PHRASE\n"
check "SIGINT during create-stack: the stack is found and deleted" has "$STUB_DIR/deleted.log" "DELETE cfn bhc-$RUNID_A"
check "...nothing left, other run untouched" bash -c "[ -z \"\$(ls '$STUB_DIR/res' | grep -v $OTHER)\" ]"
reset_env; export STUB_SIG=INT STUB_SIG_AT=wait; SEED=1 go sigint3 "$PHRASE\n"
check "SIGINT while waiting for the stack: rc 130, stack deleted" bash -c "[ '$RC' = 130 ] && grep -q 'DELETE cfn' '$STUB_DIR/deleted.log'"
reset_env; export STUB_SIG=TERM STUB_SIG_AT=create-stack; SEED=1 go sigterm "$PHRASE\n"
check "SIGTERM: rc 143, stack deleted" bash -c "[ '$RC' = 143 ] && grep -q 'DELETE cfn' '$STUB_DIR/deleted.log'"
check "SIGTERM: other run untouched" foreign_intact
reset_env; export STUB_SIG=INT STUB_SIG_AT=put-object; go sigint_tests "$PHRASE\n"
check "SIGINT: no results table pretended" hasnot "$OUT" "PASS=6"
reset_env; export STUB_SIG=INT STUB_SIG_AT=wait STUB_REPLICA=1 STUB_REPLICA_FN=1; go rc_mask "$PHRASE\n"
check "SIGINT plus an incomplete teardown reports rc 4, not 130" is "$RC" 4

echo "teardown never touches what is not tagged with this run id"
reset_env; export STUB_FOREIGN_TAG=cfn; go foreign_stack "$PHRASE\n"
check "a stack with a foreign tag is refused" has "$OUT" "stack: tag RunId is 'OTHERRUN', not this run: NOT deleting"
check "no delete-stack call was made" bash -c "! grep -q '^cloudformation delete-stack' '$STUB_DIR/calls.log'"
check "incomplete teardown gives rc 4 and keeps the state file" bash -c "[ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
reset_env; export STUB_FOREIGN_TAG=s3; go foreign_s3 "$PHRASE\n"
check "buckets with a foreign tag are refused (config and artifact)" bash -c "grep -q 'artifact bucket: tag RunId is' '$OUT' && grep -q 'config bucket: tag RunId is' '$OUT'"
check "no delete-bucket call was made" bash -c "! grep -q '^s3api delete-bucket' '$STUB_DIR/calls.log'"
check "...rc 4" is "$RC" 4
reset_env; export STUB_FAIL=describe-stacks:2 STUB_FAIL_CODE=ValidationError STUB_FAIL_TEXT="Stack with id some-other-stack does not exist"; go othermsg "$PHRASE\n"
check "a 'does not exist' message about ANOTHER stack is not treated as 'already gone'" bash -c "grep -q 'stack: cannot read its tags, NOT deleting' '$OUT' && [ '$RC' = 4 ] && ! grep -q 'DELETE cfn' '$STUB_DIR/deleted.log'"
reset_env; export STUB_FAIL=get-bucket-tagging STUB_FAIL_CODE=AccessDenied STUB_FAIL_TEXT="the bucket does not exist"; go freetext "$PHRASE\n"
check "free text 'does not exist' under another error code is not 'already gone'" has "$OUT" "config bucket: cannot read its tags, NOT deleting"
check "...incomplete: rc 4, state file kept" bash -c "[ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"

echo "artifact bucket created but never tagged"
reset_env; export STUB_FAIL=put-bucket-tagging; go notagset "$PHRASE\n"
check "bucket created but never tagged (NoSuchTagSet) is still deleted, as ours" has "$STUB_DIR/deleted.log" "DELETE s3 bhc-$RUNID_A-art"
check "...teardown complete, rc 1" bash -c "[ '$RC' = 1 ] && grep -q 'teardown: complete' '$OUT'"
newdir untagged; : > "$STUB_DIR/res/s3__bhc-$RUNID_A-art"
printf 'RUNID=%s\n' "$RUNID_A" > "$RESULTS_DIR/state-$RUNID_A.env"   # no ART_MADE
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "untagged bucket without the create-bucket flag is NOT deleted" bash -c "[ -e '$STUB_DIR/res/s3__bhc-$RUNID_A-art' ] && ! grep -q 'DELETE s3 ' '$STUB_DIR/deleted.log' 2>/dev/null"
check "...rc 4 and the state file is kept" bash -c "[ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
newdir bucketexists; echo "$OTHER" > "$STUB_DIR/res/s3__bhc-$RUNID_A-cfg"
printf '%s\n' "$PHRASE" | "$RT" > "$OUT" 2>&1; RC=$?
check "an existing bucket with a planned name stops the run before anything is created" bash -c "[ '$RC' = 1 ] && grep -q 'already exists' '$OUT' && ! grep -qE '^(s3api create-bucket|cloudformation create)' '$STUB_DIR/calls.log'"
check "...and that bucket is not touched" bash -c "[ -e '$STUB_DIR/res/s3__bhc-$RUNID_A-cfg' ] && ! grep -q 'DELETE s3 ' '$STUB_DIR/deleted.log' 2>/dev/null"
newdir bucketexists2; echo "$OTHER" > "$STUB_DIR/res/s3__bhc-$RUNID_A-art"
printf '%s\n' "$PHRASE" | "$RT" > "$OUT" 2>&1; RC=$?
check "same for the artifact bucket name" bash -c "[ '$RC' = 1 ] && grep -q 'already exists' '$OUT' && [ -e '$STUB_DIR/res/s3__bhc-$RUNID_A-art' ]"

echo "stack deletion that fails for another reason"
reset_env; export STUB_FAIL=delete-object:2; go bucketnotempty "$PHRASE\n"   # the 2nd delete-object is the emptying before delete-stack
check "stack stays, failure is reported with the resource name, rc 4, state file kept" bash -c "grep -q 'delete FAILED (resources: ConfigBucket)' '$OUT' && [ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
check "...it was NOT retried with retained resources" bash -c "! grep -q -- '--retain-resources' '$STUB_DIR/calls.log'"

echo "Lambda@Edge replicas: retain, then --cleanup"
reset_env; export STUB_REPLICA=1; go retain_ok "$PHRASE\n"
check "replica at stack level only: retries retain exactly the failed resources, one more each time, never the role" bash -c "grep -q -- '--retain-resources EdgeVersion\$' '$STUB_DIR/calls.log' && grep -q -- '--retain-resources EdgeVersion EdgeFunction\$' '$STUB_DIR/calls.log' && ! grep -q 'EdgeRole' '$STUB_DIR/calls.log'"
check "...the first delete-stack had nothing retained" bash -c "head -n 1 '$STUB_DIR/delete-calls.log' | grep -q 'retained= \$'"
check "...the screen says so before retrying" has "$OUT" "RETAINED"
check "...the edge function and role were then deleted right away: rc 0, complete" bash -c "[ '$RC' = 0 ] && grep -q 'teardown: complete' '$OUT' && grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log' && grep -q 'DELETE iam bhc-$RUNID_A-erole' '$STUB_DIR/deleted.log'"
reset_env; export STUB_REPLICA=1 STUB_REPLICA_FN=1; SEED_LOGS=1 go replica "$PHRASE\n"; unset SEED_LOGS
check "replica still held: rc 4" is "$RC" 4
check "says how to finish later" has "$OUT" "./run-test.sh --cleanup $RUNID_A"
check "the edge role is deleted by the stack; only the function is left to --cleanup" has "$OUT" "edge role: already gone"
check "edge log group kept until the function is gone" bash -c "[ -e '$STUB_DIR/logs/eu-west-1/%aws%lambda%us-east-1.bhc-$RUNID_A-edge' ]"
check "state file kept for --cleanup" test -e "$RESULTS_DIR/state-$RUNID_A.env"
check "state file holds names and flags only, no account id, ARN or host" bash -c "! grep -E -q '[0-9]{12}|arn:|cloudfront.net|lambda-url' '$RESULTS_DIR/state-$RUNID_A.env'"
check "the artifact bucket and the stack are already gone" bash -c "grep -q 'DELETE s3 bhc-$RUNID_A-art' '$STUB_DIR/deleted.log' && grep -q 'DELETE cfn' '$STUB_DIR/deleted.log'"
KEEP_STUB="$STUB_DIR"; KEEP_RES="$RESULTS_DIR"
export STUB_REPLICA=0 STUB_REPLICA_FN=0
STUB_DIR="$KEEP_STUB"; RESULTS_DIR="$KEEP_RES"; OUT="$TMP/cleanup1.txt"
printf '%s\n' "$PHRASE" | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "cleanup asks for its own phrase and the create phrase is refused" is "$RC" 1
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" --dry-run > "$OUT" 2>&1; RC=$?
check "cleanup --dry-run changes nothing" bash -c "! grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$KEEP_STUB/deleted.log'"
rm -f "$KEEP_RES/state-$RUNID_A.env"   # the state file is optional: every name is derived from the run id
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "cleanup (even without a state file) rc 0" is "$RC" 0
check "cleanup deleted the edge function and the edge log group" bash -c "grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$KEEP_STUB/deleted.log' && grep -q 'DELETE loggroup eu-west-1 /aws/lambda/us-east-1.bhc-$RUNID_A-edge' '$KEEP_STUB/deleted.log'"
check "cleanup left nothing" bash -c "[ -z \"\$(ls '$KEEP_STUB/res')\" ]"
check "cleanup output redacted" clean "$OUT"
newdir cleanup_bad
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "../../etc" > "$OUT" 2>&1; RC=$?
check "cleanup refuses a malformed run id" is "$RC" 2
newdir cleanup_none
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "cleanup of a run that has nothing left changes nothing and completes" bash -c "[ '$RC' = 0 ] && ! grep -qE '^(cloudformation delete-stack|s3api delete-bucket|iam delete|lambda delete)' '$STUB_DIR/calls.log'"
reset_env; export STUB_REPLICA=1 STUB_REPLICA_FN=1; go retain2 "$PHRASE\n"
export STUB_REPLICA_FN=0; OUT="$TMP/retain2-b.txt"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "a second --cleanup after a partial one succeeds" is "$RC" 0
check "...and removes the state file" bash -c "[ ! -e '$RESULTS_DIR/state-$RUNID_A.env' ]"

echo "stack status paths before delete-stack"
settled_before_delete() { # first delete-stack comes after at least N status polls
  local n; n=$(grep -n '^cloudformation delete-stack' "$STUB_DIR/calls.log" | head -1 | cut -d: -f1)
  [ -n "$n" ] && [ "$(head -n "$n" "$STUB_DIR/calls.log" | grep -c 'query Stacks\[0\].StackStatus')" -ge "$1" ]
}
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-stack STUB_STATUS_SEQ="CREATE_IN_PROGRESS CREATE_IN_PROGRESS CREATE_IN_PROGRESS CREATE_COMPLETE"; go st_create "$PHRASE\n"
check "CREATE_IN_PROGRESS: polled until it settled, then deleted (no delete-stack while in progress)" bash -c "settled_before_delete() { :; }; grep -q 'DELETE cfn' '$STUB_DIR/deleted.log'"
check "...at least 4 status polls came before the first delete-stack" settled_before_delete 4
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-stack STUB_STATUS_SEQ="CREATE_IN_PROGRESS ROLLBACK_IN_PROGRESS ROLLBACK_COMPLETE"; go st_rollback "$PHRASE\n"
check "ROLLBACK_IN_PROGRESS then ROLLBACK_COMPLETE: deleted after the polls" bash -c "grep -q 'DELETE cfn' '$STUB_DIR/deleted.log' && grep -q 'teardown: complete' '$OUT'"
check "...three polls before delete-stack" settled_before_delete 3
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-stack STUB_INIT_STATUS=ROLLBACK_FAILED; go st_rbfail "$PHRASE\n"
check "ROLLBACK_FAILED: delete-stack is tried" has "$STUB_DIR/deleted.log" "DELETE cfn"
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-stack STUB_INIT_STATUS=CREATE_FAILED; go st_cfail "$PHRASE\n"
check "CREATE_FAILED: delete-stack is tried" has "$STUB_DIR/deleted.log" "DELETE cfn"
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-stack STUB_INIT_STATUS=DELETE_FAILED; go st_dfail "$PHRASE\n"
check "DELETE_FAILED at the start: delete-stack is tried again" has "$STUB_DIR/deleted.log" "DELETE cfn"
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-stack STUB_STATUS_SEQ="DELETE_IN_PROGRESS DELETE_IN_PROGRESS CREATE_COMPLETE"; go st_delprog "$PHRASE\n"
check "DELETE_IN_PROGRESS: waits, no delete-stack until it has settled" settled_before_delete 3
reset_env; export SETTLE_POLLS=3 STUB_SIG=INT STUB_SIG_AT=create-stack STUB_STATUS_SEQ="CREATE_IN_PROGRESS"; go st_never "$PHRASE\n"
check "a stack that never settles is NOT deleted: reported, rc 4, state file kept" bash -c "grep -q 'still CREATE_IN_PROGRESS after the waiting time' '$OUT' && [ '$RC' = 4 ] && ! grep -q '^cloudformation delete-stack' '$STUB_DIR/calls.log' && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
unset SETTLE_POLLS

echo "edge function on its fail-safe, runtimes, bucket owner, argument parse"
reset_env; export STUB_CDN=nosdk; go nosdk "$PHRASE\n"
check "every answer on the fail-safe: all six tests INCONCLUSIVE with the clear message, rc 3" bash -c "[ '$(grep -cE '^T-. +INCONCLUSIVE' "$OUT")' = 6 ] && [ '$RC' = 3 ] && grep -q 'could not load the S3 client' '$OUT' && grep -q 'If the S3 client is missing' '$OUT'"
check "...and the stack is still deleted" has "$OUT" "teardown: complete"
boundary="arn:aws:iam::$(printf '%s%s' 1234 56789012):policy/bhc-boundary"
reset_env; export EDGE_RUNTIME=python3.13 ORIGIN_RUNTIME=nodejs20.x PERMISSIONS_BOUNDARY_ARN="$boundary"; go params "$PHRASE\n"
check "EDGE_RUNTIME, ORIGIN_RUNTIME and PERMISSIONS_BOUNDARY_ARN become stack parameters" bash -c "jq -e '(.[]|select(.ParameterKey==\"EdgeRuntime\").ParameterValue)==\"python3.13\" and (.[]|select(.ParameterKey==\"OriginRuntime\").ParameterValue)==\"nodejs20.x\" and ([.[]|select(.ParameterKey==\"PermissionsBoundary\")]|length)==1' '$STUB_DIR/stack-params.json'"
reset_env; go params0 "$PHRASE\n"
check "without overrides the template defaults are used (no runtime or boundary parameter)" bash -c "! jq -e '.[]|select(.ParameterKey==\"EdgeRuntime\" or .ParameterKey==\"OriginRuntime\" or .ParameterKey==\"PermissionsBoundary\")' '$STUB_DIR/stack-params.json' >/dev/null"
check "every bucket call states the expected bucket owner" bash -c "! grep -E '^s3api (head-bucket|put-object|delete-object|delete-bucket|get-bucket-tagging|put-bucket-tagging|put-public-access-block|put-bucket-policy|put-bucket-encryption) ' '$STUB_DIR/calls.log' | grep -v -- '--expected-bucket-owner' | grep -q ."
check "artifact bucket: explicit encryption and a TLS-only deny policy" bash -c "grep -q '^s3api put-bucket-encryption' '$STUB_DIR/calls.log' && jq -e '.Statement|length==1' '$STUB_DIR/policy-bhc-$RUNID_A-art.json'"
newdir argparse; "$RT" --cleanup --dry-run > "$OUT" 2>&1; RC=$?
check "--cleanup --dry-run (no run id) is refused with a clear message" bash -c "[ '$RC' = 2 ] && grep -q 'needs the run id first' '$OUT'"
rm -f "$STUB_DIR/calls.log"; "$RT" --cleanup "$RUNID_A" --dry-run > "$OUT" 2>&1; RC=$?
check "--cleanup <id> --dry-run is understood: rc 0, nothing deleted" bash -c "[ '$RC' = 0 ] && grep -q 'dry run: nothing was deleted' '$OUT'"
adj="$(printf '%s%s' 1234 56789012)"
adjout="$(SCRIPT_DIR="$root" bash -c ". '$root/lib.sh'; say 'x $adj $adj y ${adj}a$adj'" 2>&1)"
check "two adjacent account ids are both redacted" bash -c "! printf '%s' '$adjout' | grep -qE '[0-9]{12}'"

echo "confirmation screen and account guard"
reset_env; go acct_dry "" --dry-run
check "dry run shows the profile and the LAST 4 digits only" bash -c "grep -q 'profile testprof' '$OUT' && grep -q 'account \*\*\*\*\*\*\*\*9012' '$OUT'"
reset_env; export EXPECT_ACCOUNT_LAST4=0000; go acct_bad "$PHRASE\n"
check "EXPECT_ACCOUNT_LAST4 that differs: refused, rc 2" bash -c "[ '$RC' = 2 ] && grep -q 'does not end in EXPECT_ACCOUNT_LAST4' '$OUT'"
check "...only read-only calls were made" only_sts
reset_env; export EXPECT_ACCOUNT_LAST4=12; go acct_fmt "$PHRASE\n"
check "EXPECT_ACCOUNT_LAST4 that is not 4 digits: refused" is "$RC" 2
reset_env; export EXPECT_ACCOUNT_LAST4=9012; go acct_ok "$PHRASE\n"
check "matching EXPECT_ACCOUNT_LAST4: run proceeds" is "$RC" 0
check "the confirmation screen shows profile, region and last 4" bash -c "grep -q 'Target:  profile testprof   region us-east-1   account ending in 9012' '$OUT'"
check "results file has no profile and no account digits" bash -c "! grep -qE 'testprof|9012|ending in' '$(first_res)'"
check "screen output still redacted" clean "$OUT"
reset_env; export RT_RUNID='x;rm -rf'; go badrunid "$PHRASE\n"
check "a run id that is not <10 digits>-<4 hex> is refused before any change" bash -c "[ '$RC' = 2 ] && grep -q 'is not of the form' '$OUT'"
check "...only read-only calls were made" only_sts

echo "T-B stray miss, T-E both cases"
reset_env; export STUB_STRAY_MISS=/rates/b:3; go stray "$PHRASE\n"
check "T-B: one stray Miss with a flat origin counter is INCONCLUSIVE, not FAIL" grep -Eq "^T-B +INCONCLUSIVE" "$OUT"
check "...exit code 3" is "$RC" 3
reset_env; go ebase "$PHRASE\n"
check "T-E covers the missing key and the bad JSON" bash -c "grep -q 'E1 missing key' '$(first_res)' && grep -q 'E2 bad JSON' '$(first_res)'"
check "the bad config was really uploaded" has "$STUB_DIR/puts.log" "this is not json"

echo "log groups"
reset_env; SEED_LOGS=1 go logs "$PHRASE\n"; unset SEED_LOGS
check "origin log group and edge log group (in the other region) deleted" bash -c "grep -q 'DELETE loggroup us-east-1 /aws/lambda/bhc-$RUNID_A-origin' '$STUB_DIR/deleted.log' && grep -q 'DELETE loggroup eu-west-1 /aws/lambda/us-east-1.bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log'"
check "look-alike and other-run log groups untouched" logs_decoys_intact
check "log groups looked up in every region" has "$STUB_DIR/calls.log" "ec2 describe-regions"
reset_env; export STUB_FAIL=delete-log-group; SEED_LOGS=1 go logsleft "$PHRASE\n"; unset SEED_LOGS
check "screen summary names the log groups left, not just 'complete'" bash -c "grep -q 'LOG GROUPS LEFT' '$OUT' && ! grep -q '^teardown: complete' '$OUT'"
check "results file says the same" has "$(first_res)" "log groups left"
reset_env; export STUB_FAIL=describe-regions; go noregions "$PHRASE\n"
check "describe-regions failure is shown as not checked" bash -c "grep -q 'not-checked' '$OUT' && grep -q 'not-checked' '$(first_res)'"

echo "URI variants (T-F), side request, T-C age"
reset_env; go tf "$PHRASE\n"
check "T-F PASS in the table" grep -Eq "^T-F +PASS" "$OUT"
check "T-F requests the three variants raw (curl --path-as-is)" bash -c "grep -q -- '--path-as-is' '$STUB_DIR/calls.log' && grep -q '//prices/a' '$STUB_DIR/calls.log' && grep -q '/Prices/a' '$STUB_DIR/calls.log' && grep -q '%70rices/a' '$STUB_DIR/calls.log'"
check "T-F records the observed headers and what the origin saw" bash -c "grep -E '^T-F' '$OUT' | grep -q 'cache-control=' && grep -E '^T-F' '$OUT' | grep -q 'origin saw'"
check "results file has the T-F INFO line" has "$(first_res)" "T-F INFO: request //prices/a reached the origin as path"
check "the test config has a restrictive default" bash -c "grep -q '\"default\":{\"startMin\":0,\"endMin\":1440,\"inTtl\":0,\"outTtl\":0}' '$STUB_DIR/puts.log'"
reset_env; export STUB_CDN=cacheall; go tf_fail "$PHRASE\n"
check "T-F FAIL when variants are cached for long" grep -Eq "^T-F +FAIL" "$OUT"
reset_env; export STUB_CURL_FAIL_PATH=/rates/a; go sidefail "$PHRASE\n"
check "a failing /rates/a side request makes T-A INCONCLUSIVE, not FAIL" grep -Eq "^T-A +INCONCLUSIVE" "$OUT"
check "...and nothing else is affected" bash -c "grep -Eq '^T-B +PASS' '$OUT' && grep -Eq '^T-F +PASS' '$OUT'"
check "T-C: the Age before the opening is part of the measurement" bash -c "grep -E '^T-C +PASS' '$OUT' | grep -q 'age=[0-9]*s'"

echo ".gitignore"
check "results and state files are git-ignored" bash -c "grep -q 'results-\*.md' '$root/.gitignore' && grep -q 'state-\*.env' '$root/.gitignore'"

echo "arguments"
newdir args; "$RT" --nope > "$OUT" 2>&1; RC=$?
check "unknown argument rc 2" is "$RC" 2

echo "edge function logic (python unittest)"
if command -v python3 >/dev/null 2>&1; then
  py_out="$TMP/py.txt"
  (cd "$root" && python3 -I -m unittest discover -s tests -p 'test_*.py') > "$py_out" 2>&1; PRC=$?
  pn="$(sed -n 's/^Ran \([0-9]*\) tests.*/\1/p' "$py_out" | head -n 1)"
  check "python unit tests pass (ran ${pn:-?})" is "$PRC" 0
  PY_PASS="${pn:-0}"
  check "the zip built by the real zip has index.py at its root, with the bucket and key baked in" bash -c "
    d=\$(mktemp -d '$TMP/zip.XXXXXX'); PATH=\"\${PATH#'$here/bin:'}\"
    SCRIPT_DIR='$root' BUCKET=bhc-x-cfg bash -c \". '$root/lib.sh'; BUCKET=bhc-x-cfg; package_edge \$d\" &&
    python3 -I -c \"
import zipfile, sys, importlib.util
z = zipfile.ZipFile('\$d/edge.zip'); assert z.namelist() == ['index.py'], z.namelist()
z.extractall('\$d/x'); spec = importlib.util.spec_from_file_location('m', '\$d/x/index.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.CONFIG_BUCKET == 'bhc-x-cfg' and m.CONFIG_KEY == 'window.json' and callable(m.lambda_handler)\""
else
  PY_PASS=0
  echo "  SKIP python3 not found: the edge function logic (window, cap, path rules, URI variants, error skip, S3 and JSON fallback) was NOT tested"
fi

echo "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" shellcheck -x "$root/run-test.sh" "$root/lib.sh" "$here/run.sh" "$here/bin/aws" "$here/bin/curl" "$here/bin/date" "$here/bin/sleep" "$here/bin/zip" "$here/bin/stub-lib.sh"
else
  echo "  SKIP shellcheck not installed here (CI runs it)"
fi

echo
echo "shell checks: $PASS passed, $FAIL failed; python unit tests run: $PY_PASS"
[ "$FAIL" = 0 ]
