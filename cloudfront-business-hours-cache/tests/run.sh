#!/usr/bin/env bash
# run.sh - tests for cloudfront-business-hours-cache. No AWS, no network: run-test.sh runs against a fake aws, curl, date,
# sleep and zip (tests/bin). The edge function logic is tested with node (tests/edge.test.mjs) when node is installed.
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
  unset STUB_CURL_FAIL_PATH STUB_TAG_HIDE STUB_FAIL STUB_FAIL_CODE STUB_FAIL_TEXT STUB_STRAY_MISS STUB_DIST_NULL EXPECT_ACCOUNT_LAST4 STUB_SIG STUB_SIG_AT STUB_FOREIGN_TAG STUB_REPLICA STUB_CDN STUB_CURL_DOWN STUB_START_EPOCH
  export AWS_PROFILE=testprof
  export RT_RUNID="$RUNID_A" SETTLE_SECS=40 EDGE_DELETE_PAUSE=1 WARMUP_TRIES=2
}
# newdir NAME -> STUB_DIR and RESULTS_DIR for that scenario
newdir() { STUB_DIR="$TMP/$1/state"; RESULTS_DIR="$TMP/$1/res"; mkdir -p "$STUB_DIR/res" "$RESULTS_DIR"; export STUB_DIR RESULTS_DIR; OUT="$TMP/$1/out.txt"; }
# seed_foreign: resources of ANOTHER run that must never be touched
seed_foreign() {
  echo "$OTHER" > "$STUB_DIR/res/s3__bhc-$OTHER-cfg"; echo "$OTHER" > "$STUB_DIR/res/lambda__bhc-$OTHER-edge"
  echo "$OTHER" > "$STUB_DIR/res/iam__bhc-$OTHER-role"; echo "$OTHER" > "$STUB_DIR/res/lambda__bhc-$OTHER-origin"
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
only_sts() { calls | grep -q . && ! calls | grep -qv '^sts get-caller-identity'; }
no_leftovers() {   # nothing of this run in the fake account (files of $OTHER do not count)
  local f
  for f in "$STUB_DIR"/res/*; do
    [ -e "$f" ] || continue
    case "$f" in *"$OTHER"*) ;; *) return 1 ;; esac
  done
  return 0
}
foreign_intact() { [ -e "$STUB_DIR/res/s3__bhc-$OTHER-cfg" ] && [ -e "$STUB_DIR/res/lambda__bhc-$OTHER-edge" ] && [ -e "$STUB_DIR/res/iam__bhc-$OTHER-role" ] && [ -e "$STUB_DIR/res/lambda__bhc-$OTHER-origin" ]; }
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
check "dry run makes only the read-only identity call" only_sts
check "dry run prints the plan with the run id" has "$OUT" "bhc-$RUNID_A-edge"
check "dry run says nothing was created" has "$OUT" "nothing was created or deleted"
check "dry run states cost and time" has "$OUT" "15-25 minutes"
check "dry run starts no curl and no zip" bash -c "! grep -E '^(curl|zip) ' '$STUB_DIR/calls.log'"
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
check "only the identity call was made" only_sts

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
check "summary line PASS=5" has "$OUT" "PASS=6 FAIL=0 INCONCLUSIVE=0"
check "results file written" test -n "$(first_res)"
check "results file has the table and the T-C note" bash -c "grep -q '^| T-C | PASS' '$(first_res)' && grep -q 'was gone 5s after the opening' '$(first_res)'"
check "results file says teardown complete" has "$(first_res)" "Complete: every resource"
check "results file is redacted" clean "$(first_res)"
check "screen output is redacted" clean "$OUT"
check "teardown complete" has "$OUT" "teardown: complete"
check "all six kinds of resource deleted" bash -c "for k in 'cf ' 'cp ' 'lambda bhc-$RUNID_A-edge' 'lambda bhc-$RUNID_A-origin' 'iam ' 's3 '; do grep -q \"DELETE \$k\" '$STUB_DIR/deleted.log' || exit 1; done"
check "nothing of this run is left" no_leftovers
check "resources of another run untouched" foreign_intact
check "no call ever mentions another run's resources" never_mentions_foreign
check "state file removed after a clean teardown" bash -c "[ ! -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
check "distribution disabled before delete" bash -c "grep -n -E '^cloudfront (update-distribution|delete-distribution)' '$STUB_DIR/calls.log' | head -n 2 | tr '\n' ' ' | grep -q 'update-distribution.*delete-distribution'"
check "distribution created with the RunId tag" bash -c "grep -q 'create-distribution-with-tags' '$STUB_DIR/calls.log'"
check "T-A window is now-5..now+30 (clock 12:00 UTC = 720)" has "$STUB_DIR/puts.log" '"startMin":715,"endMin":750,"inTtl":0,"outTtl":14400'
check "T-A also shows /rates/a outside its window at the same moment, with the long TTL" bash -c "grep -E '^T-A +PASS' '$OUT' | grep -q 'at the same moment /rates/a (outside its window): cache-control=\"public, max-age=0, s-maxage=14400\"'"
check "the config has one rule per path pattern (/prices/*, /rates/*, /err*)" bash -c "grep -q '\"path\":\"/prices/\*\",\"startMin\":715' '$STUB_DIR/puts.log' && grep -q '\"path\":\"/rates/\*\",\"startMin\":660' '$STUB_DIR/puts.log' && grep -q '\"path\":\"/err\*\"' '$STUB_DIR/puts.log'"
check "the first upload is a valid default-only config" bash -c "head -n 1 '$STUB_DIR/puts.log' | jq -e '.default.startMin == 0 and (.rules // []) == []'"
check "T-C uses its own /c/* rule" bash -c "grep -qF '\"path\":\"/c/*\"' '$STUB_DIR/puts.log'"
check "T-B window is now-60..now-30" has "$STUB_DIR/puts.log" '"startMin":660,"endMin":690,"inTtl":0,"outTtl":14400'
check "T-C window opens a few minutes after now" bash -c "grep -Eq '\"startMin\":72[0-9],\"endMin\":78[0-9]' '$STUB_DIR/puts.log'"
check "the window is never overnight (start < end in every upload)" bash -c "! sed -n 's/.*startMin\":\([0-9]*\),\"endMin\":\([0-9]*\).*/\1 \2/p' '$STUB_DIR/puts.log' | awk '\$1 >= \$2' | grep -q ."

echo "packaging"
check "edge code has the bucket baked in" has "$STUB_DIR/zipped/edge-index.mjs" "bhc-$RUNID_A-cfg"
check "edge code has the key baked in" has "$STUB_DIR/zipped/edge-index.mjs" "window.json"
check "edge code has no placeholder left" hasnot "$STUB_DIR/zipped/edge-index.mjs" "__CONFIG_"
check "origin sends no Cache-Control" hasnot "$STUB_DIR/zipped/origin-index.mjs" -i "cache-control"

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
check "no answer: all tests INCONCLUSIVE, rc 3" bash -c "[ '$(grep -cE '^T-. +INCONCLUSIVE' "$OUT")' = 6 ]"
check "no answer: rc 3" is "$RC" 3
check "no answer: still torn down" has "$OUT" "teardown: complete"

echo "teardown on an injected failure"
reset_env; export STUB_FAIL=create-distribution-with-tags; SEED=1 go inject "$PHRASE\n"
check "rc 1" is "$RC" 1
check "teardown ran" has "$OUT" "teardown: complete"
check "everything created so far is gone" no_leftovers
check "resources of another run untouched" foreign_intact
check "no call mentions another run" never_mentions_foreign
check "error text is redacted (account, ARN, key, host, token)" clean "$OUT"
check "error text still says what failed" has "$OUT" "create-distribution-with-tags"
reset_env; export STUB_FAIL=create-function:2; SEED=1 go inject2 "$PHRASE\n"   # the edge function (second create-function)
check "failure at the edge function: bucket, role, origin removed" no_leftovers
check "failure at the edge function: other run untouched" foreign_intact
reset_env; export STUB_FAIL=create-bucket; go inject3 "$PHRASE\n"
check "failure at the very first call: rc 1, nothing left" bash -c "[ '$RC' = 1 ] && [ -z \"\$(ls '$STUB_DIR/res')\" ]"

echo "teardown on Ctrl-C and SIGTERM"
reset_env; export STUB_SIG=INT STUB_SIG_AT=publish-version; SEED=1 go sigint "$PHRASE\n"
check "SIGINT: rc 130" is "$RC" 130
check "SIGINT: teardown complete" has "$OUT" "teardown: complete"
check "SIGINT: all of this run deleted" no_leftovers
check "SIGINT: other run untouched" foreign_intact
check "SIGINT: no call mentions another run" never_mentions_foreign
check "SIGINT: distribution never existed, none deleted" hasnot "$STUB_DIR/deleted.log" "DELETE cf"
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-distribution-with-tags; SEED=1 go sigint2 "$PHRASE\n"
check "SIGINT during distribution create: distribution disabled and deleted" has "$STUB_DIR/deleted.log" "DELETE cf"
check "SIGINT during distribution create: nothing left" no_leftovers
check "SIGINT during distribution create: other run untouched" foreign_intact
reset_env; export STUB_SIG=TERM STUB_SIG_AT=create-cache-policy; SEED=1 go sigterm "$PHRASE\n"
check "SIGTERM: rc 143" is "$RC" 143
check "SIGTERM: nothing left" no_leftovers
check "SIGTERM: other run untouched" foreign_intact
reset_env; export STUB_SIG=INT STUB_SIG_AT=put-object; go sigint_tests "$PHRASE\n"
check "SIGINT: no results table pretended" hasnot "$OUT" "PASS=5"

echo "teardown never deletes what is not tagged with this run id"
reset_env; export STUB_FOREIGN_TAG=s3; go foreign_tag "$PHRASE\n"
check "bucket with a foreign tag is refused" has "$OUT" "bucket: tag RunId is 'OTHERRUN', not this run: NOT deleting"
check "bucket not deleted" bash -c "! grep -q 'DELETE s3 ' '$STUB_DIR/deleted.log'"
check "no delete-bucket call was even made" bash -c "! grep -q '^s3api delete-bucket' '$STUB_DIR/calls.log'"
check "the rest was deleted" has "$STUB_DIR/deleted.log" "DELETE cf"
check "incomplete teardown gives rc 4" is "$RC" 4
reset_env; export STUB_FOREIGN_TAG=cf; go foreign_cf "$PHRASE\n"
check "distribution with a foreign tag is never disabled or deleted" bash -c "! grep -qE '^cloudfront (update|delete)-distribution' '$STUB_DIR/calls.log'"
check "bucket is kept while the distribution still exists" bash -c "[ -e '$STUB_DIR/res/s3__bhc-$RUNID_A-cfg' ] && grep -q 'bucket: kept' '$OUT'"
check "...and its cache policy and edge function stay too" bash -c "! grep -q 'DELETE cp' '$STUB_DIR/deleted.log' && ! grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log'"

echo "Lambda@Edge replicas still held by AWS, then --cleanup"
reset_env; export STUB_REPLICA=1; go replica "$PHRASE\n"
check "rc 4" is "$RC" 4
check "says how to finish later" has "$OUT" "./run-test.sh --cleanup $RUNID_A"
check "role kept while the edge function exists" has "$OUT" "role: kept"
check "state file kept for --cleanup" test -e "$RESULTS_DIR/state-$RUNID_A.env"
check "state file holds names and ids, no account id, ARN or host" bash -c "! grep -E -q '[0-9]{12}|arn:|cloudfront.net|lambda-url' '$RESULTS_DIR/state-$RUNID_A.env'"
KEEP_STUB="$STUB_DIR"; KEEP_RES="$RESULTS_DIR"
export STUB_REPLICA=0
STUB_DIR="$KEEP_STUB"; RESULTS_DIR="$KEEP_RES"; OUT="$TMP/cleanup1.txt"
printf '%s\n' "$PHRASE" | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "cleanup asks for its own phrase and the create phrase is refused" is "$RC" 1
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" --dry-run > "$OUT" 2>&1; RC=$?
check "cleanup --dry-run changes nothing" bash -c "! grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$KEEP_STUB/deleted.log'"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "cleanup rc 0" is "$RC" 0
check "cleanup deleted the edge function, role" bash -c "grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$KEEP_STUB/deleted.log' && grep -q 'DELETE iam' '$KEEP_STUB/deleted.log'"
check "cleanup left nothing" bash -c "[ -z \"\$(ls '$KEEP_STUB/res')\" ]"
check "cleanup removed the state file" bash -c "[ ! -e '$KEEP_RES/state-$RUNID_A.env' ]"
check "cleanup output redacted" clean "$OUT"
newdir cleanup_bad
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "../../etc" > "$OUT" 2>&1; RC=$?
check "cleanup refuses a malformed run id" is "$RC" 2
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "cleanup without a state file refuses" is "$RC" 2

echo "review round: leftover bucket, lookups, exit codes"
reset_env; export STUB_FAIL=put-bucket-tagging; go notagset "$PHRASE\n"
check "bucket created but never tagged (NoSuchTagSet) is still deleted, as ours" has "$STUB_DIR/deleted.log" "DELETE s3 bhc-$RUNID_A-cfg"
check "...nothing left, teardown complete, rc 1" bash -c "[ '$RC' = 1 ] && grep -q 'teardown: complete' '$OUT'"
newdir untagged; mkdir -p "$STUB_DIR/res"; : > "$STUB_DIR/res/s3__bhc-$RUNID_A-cfg"
printf 'RUNID=%s\nBUCKET=bhc-%s-cfg\n' "$RUNID_A" "$RUNID_A" > "$RESULTS_DIR/state-$RUNID_A.env"   # no BUCKET_MADE
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "untagged bucket without the create-bucket flag is NOT deleted" bash -c "[ -e '$STUB_DIR/res/s3__bhc-$RUNID_A-cfg' ] && ! grep -q 'DELETE s3 ' '$STUB_DIR/deleted.log' 2>/dev/null"
check "...rc 4 and the state file is kept" bash -c "[ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
reset_env; export STUB_FAIL=get-bucket-tagging STUB_FAIL_CODE=AccessDenied STUB_FAIL_TEXT="the bucket does not exist"; go freetext "$PHRASE\n"
check "free text 'does not exist' under another error code is not 'already gone'" has "$OUT" "bucket: cannot read its tags, NOT deleting"
check "...bucket kept, rc 4, state file kept" bash -c "[ -e '$STUB_DIR/res/s3__bhc-$RUNID_A-cfg' ] && [ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
reset_env; export STUB_SIG=INT STUB_SIG_AT=create-distribution-with-tags STUB_FAIL=list-distributions; go lookupfail "$PHRASE\n"
check "failed distribution lookup: reported, rc 4, state file kept" bash -c "grep -q 'lookup by name failed' '$OUT' && [ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
reset_env; export STUB_SIG=TERM STUB_SIG_AT=create-cache-policy STUB_FAIL=list-cache-policies; go lookupfail2 "$PHRASE\n"
check "failed cache policy lookup: reported, rc 4, state file kept" bash -c "grep -q 'cache policy: lookup by name failed' '$OUT' && [ '$RC' = 4 ] && [ -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
reset_env; export STUB_SIG=INT STUB_SIG_AT=publish-version STUB_REPLICA=1; go rc_mask "$PHRASE\n"
check "SIGINT plus an incomplete teardown reports rc 4, not 130" is "$RC" 4
reset_env; export STUB_DIST_NULL=1; go distnull "$PHRASE\n"
check "a null distribution id is refused" has "$OUT" "no distribution id returned"
check "...and the distribution that was created is still found and deleted" bash -c "grep -q 'DELETE cf' '$STUB_DIR/deleted.log'"
newdir bucketexists2; echo "$OTHER" > "$STUB_DIR/res/s3__bhc-$RUNID_A-cfg"
printf '%s\n' "$PHRASE" | "$RT" > "$OUT" 2>&1; RC=$?
check "an existing bucket with the planned name stops the run before anything is created" bash -c "[ '$RC' = 1 ] && grep -q 'already exists' '$OUT' && ! grep -qE '^(s3api create-bucket|iam |lambda |cloudfront )' '$STUB_DIR/calls.log'"
check "...and that bucket is not touched" bash -c "[ -e '$STUB_DIR/res/s3__bhc-$RUNID_A-cfg' ] && ! grep -q 'DELETE s3 ' '$STUB_DIR/deleted.log' 2>/dev/null"

echo "review round: confirmation screen and account guard"
reset_env; go acct_dry "" --dry-run
check "dry run shows the profile and the LAST 4 digits only" bash -c "grep -q 'profile testprof' '$OUT' && grep -q 'account \*\*\*\*\*\*\*\*9012' '$OUT'"
reset_env; export EXPECT_ACCOUNT_LAST4=0000; go acct_bad "$PHRASE\n"
check "EXPECT_ACCOUNT_LAST4 that differs: refused, rc 2, nothing created" bash -c "[ '$RC' = 2 ] && grep -q 'does not end in EXPECT_ACCOUNT_LAST4' '$STUB_DIR/../out.txt'" 
check "...only the identity call was made" only_sts
reset_env; export EXPECT_ACCOUNT_LAST4=12; go acct_fmt "$PHRASE\n"
check "EXPECT_ACCOUNT_LAST4 that is not 4 digits: refused" is "$RC" 2
reset_env; export EXPECT_ACCOUNT_LAST4=9012; go acct_ok "$PHRASE\n"
check "matching EXPECT_ACCOUNT_LAST4: run proceeds" is "$RC" 0
check "the confirmation screen shows profile, region and last 4" bash -c "grep -q 'Target:  profile testprof   region us-east-1   account ending in 9012' '$OUT'"
check "results file has no profile and no account digits" bash -c "! grep -qE 'testprof|9012|ending in' '$(first_res)'"
check "no profile or account digits in the state file" bash -c "! grep -qE 'testprof|9012' '$RESULTS_DIR'/state-*.env 2>/dev/null"
check "screen output still redacted" clean "$OUT"

echo "review round: public origin, roles, policies"
check "reserved concurrency 5 requested on the origin" has "$STUB_DIR/calls.log" "put-function-concurrency --function-name bhc-$RUNID_A-origin --reserved-concurrent-executions 5"
reset_env; export STUB_FAIL=put-function-concurrency; go noconc "$PHRASE\n"
check "reserved concurrency failure does not abort the run" bash -c "[ '$RC' = 0 ] && grep -q 'reserved concurrency was not set' '$OUT'"
check "two roles are created (edge and origin)" bash -c "grep -c '^iam create-role' '$STUB_DIR/calls.log' | grep -q '^2$'"
check "edge role: trust lambda and edgelambda, S3 GetObject and ListBucket" bash -c "grep -q edgelambda '$STUB_DIR/trust-bhc-$RUNID_A-erole.json' && grep -q ListBucket '$STUB_DIR/policy-bhc-$RUNID_A-erole.json' && grep -q GetObject '$STUB_DIR/policy-bhc-$RUNID_A-erole.json'"
check "origin role: no edgelambda trust, no S3 permission" bash -c "! grep -q edgelambda '$STUB_DIR/trust-bhc-$RUNID_A-orole.json' && ! grep -q s3: '$STUB_DIR/policy-bhc-$RUNID_A-orole.json'"
check "logs permission scoped to this run's log groups, no bare *" bash -c "grep -q 'log-group:/aws/lambda/\*bhc-$RUNID_A-\*' '$STUB_DIR/policy-bhc-$RUNID_A-erole.json' && ! grep -q '\"Resource\": \"\*\"' '$STUB_DIR/policy-bhc-$RUNID_A-erole.json'"
reset_env; export RT_RUNID='x;rm -rf'; go badrunid "$PHRASE\n"
check "a run id that is not <10 digits>-<4 hex> is refused before any change" bash -c "[ '$RC' = 2 ] && grep -q 'is not of the form' '$OUT'"
check "...only the identity call was made" only_sts

echo "review round: T-B stray miss, T-E both cases"
reset_env; export STUB_STRAY_MISS=/rates/b:3; go stray "$PHRASE\n"
check "T-B: one stray Miss with a flat origin counter is INCONCLUSIVE, not FAIL" grep -Eq "^T-B +INCONCLUSIVE" "$OUT"
check "...exit code 3" is "$RC" 3
reset_env; go ebase "$PHRASE\n"
check "T-E covers the missing key and the bad JSON" bash -c "grep -q 'E1 missing key' '$(first_res)' && grep -q 'E2 bad JSON' '$(first_res)'"
check "the bad config was really uploaded" has "$STUB_DIR/puts.log" "this is not json"

echo "review round: log groups"
reset_env; SEED_LOGS=1 go logs "$PHRASE\n"; unset SEED_LOGS
check "origin log group and edge log group (in the other region) deleted" bash -c "grep -q 'DELETE loggroup us-east-1 /aws/lambda/bhc-$RUNID_A-origin' '$STUB_DIR/deleted.log' && grep -q 'DELETE loggroup eu-west-1 /aws/lambda/us-east-1.bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log'"
check "look-alike and other-run log groups untouched" logs_decoys_intact
check "log groups looked up in every region" has "$STUB_DIR/calls.log" "ec2 describe-regions"

echo "review round: --cleanup without a state file"
reset_env; export STUB_REPLICA=1; SEED_LOGS=1 go fb "$PHRASE\n"; unset SEED_LOGS
check "edge log group kept while the edge function exists" bash -c "[ -e '$STUB_DIR/logs/eu-west-1/%aws%lambda%us-east-1.bhc-$RUNID_A-edge' ]"
rm -f "$RESULTS_DIR/state-$RUNID_A.env"; export STUB_REPLICA=0; OUT="$TMP/fb-clean.txt"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" --dry-run > "$OUT" 2>&1; RC=$?
check "fallback --dry-run lists by tag and deletes nothing" bash -c "[ '$RC' = 0 ] && grep -q 'falling back to a read-only listing' '$OUT' && ! grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log' && [ ! -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "fallback --cleanup finishes the job from the tag listing" bash -c "[ '$RC' = 0 ] && grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log' && grep -q 'DELETE iam bhc-$RUNID_A-erole' '$STUB_DIR/deleted.log' && grep -q 'DELETE iam bhc-$RUNID_A-orole' '$STUB_DIR/deleted.log'"
check "...including the edge log group, and only exact names" bash -c "grep -q 'DELETE loggroup eu-west-1 /aws/lambda/us-east-1.bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log' && [ -e '$STUB_DIR/logs/eu-west-1/%aws%lambda%us-east-1.bhc-$RUNID_A-edge-extra' ]"
check "...output redacted" clean "$OUT"
check "fallback output shows no redacted-token placeholder for the state file" bash -c "! grep -q 'redacted-token' '$OUT'"
reset_env; export STUB_REPLICA=1; go fb2 "$PHRASE\n"
rm -f "$RESULTS_DIR/state-$RUNID_A.env"; OUT="$TMP/fb2-a.txt"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "fallback cleanup while the replica is still held: rc 4" is "$RC" 4
check "...it left a usable state file with the run id and names" bash -c "grep -q '^RUNID=$RUNID_A' '$RESULTS_DIR/state-$RUNID_A.env' && grep -q '^EDGE_FN=bhc-$RUNID_A-edge' '$RESULTS_DIR/state-$RUNID_A.env'"
export STUB_REPLICA=0; OUT="$TMP/fb2-b.txt"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "the second --cleanup succeeds (no 'does not belong' error)" bash -c "[ '$RC' = 0 ] && ! grep -q 'does not belong' '$OUT' && grep -q 'DELETE lambda bhc-$RUNID_A-edge' '$STUB_DIR/deleted.log'"
check "...and removes the state file" bash -c "[ ! -e '$RESULTS_DIR/state-$RUNID_A.env' ]"
newdir fb_old; mkdir -p "$STUB_DIR/res"; : > "$RESULTS_DIR/state-$RUNID_A.env"
echo "$RUNID_A" > "$STUB_DIR/res/lambda__bhc-$RUNID_A-origin"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "an empty state file from an older run is treated as missing (fallback), not an error" bash -c "[ '$RC' = 0 ] && grep -q 'DELETE lambda bhc-$RUNID_A-origin' '$STUB_DIR/deleted.log'"
reset_env; export STUB_REPLICA=1 STUB_TAG_HIDE=iam; go fb3 "$PHRASE\n"
rm -f "$RESULTS_DIR/state-$RUNID_A.env"; export STUB_REPLICA=0; OUT="$TMP/fb3.txt"
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "fallback also tries the exact role names when the tag listing does not show them" bash -c "grep -q 'DELETE iam bhc-$RUNID_A-erole' '$STUB_DIR/deleted.log' && grep -q 'DELETE iam bhc-$RUNID_A-orole' '$STUB_DIR/deleted.log'"
newdir fb_none
printf 'delete cloudfront test stack\n' | "$RT" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "fallback with nothing tagged: refuses (rc 2)" is "$RC" 2

echo "review round: leftover log groups are reported"
reset_env; export STUB_FAIL=delete-log-group; SEED_LOGS=1 go logsleft "$PHRASE\n"; unset SEED_LOGS
check "screen summary names the log groups left, not just 'complete'" bash -c "grep -q 'LOG GROUPS LEFT' '$OUT' && ! grep -q '^teardown: complete' '$OUT'"
check "results file says the same" has "$(first_res)" "log groups left"
reset_env; export STUB_FAIL=describe-regions; go noregions "$PHRASE\n"
check "describe-regions failure is shown as not checked" bash -c "grep -q 'not-checked' '$OUT' && grep -q 'not-checked' '$(first_res)'"

echo "review round: URI variants (T-F), side request, T-C age, config limits"
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

echo "review round: .gitignore"
check "results and state files are git-ignored" bash -c "grep -q 'results-\*.md' '$root/.gitignore' && grep -q 'state-\*.env' '$root/.gitignore'"

echo "arguments"
newdir args; "$RT" --nope > "$OUT" 2>&1; RC=$?
check "unknown argument rc 2" is "$RC" 2

echo "edge function logic (node)"
if command -v node >/dev/null 2>&1; then
  node_out="$TMP/node.txt"
  node --test "$here"/*.test.mjs > "$node_out" 2>&1; NRC=$?
  np="$(sed -n 's/^# pass \([0-9]*\)/\1/p;s/^ℹ pass \([0-9]*\)/\1/p' "$node_out" | head -n 1)"
  nf="$(sed -n 's/^# fail \([0-9]*\)/\1/p;s/^ℹ fail \([0-9]*\)/\1/p' "$node_out" | head -n 1)"
  check "node unit tests pass (pass=${np:-?} fail=${nf:-?})" is "$NRC" 0
  NODE_PASS="${np:-0}"
else
  NODE_PASS=0
  echo "  SKIP node not found: the edge function logic (window, boundaries, error skip, S3 and JSON fallback) was NOT tested"
fi

echo "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" shellcheck -x "$root/run-test.sh" "$root/lib.sh" "$here/run.sh" "$here/bin/aws" "$here/bin/curl" "$here/bin/date" "$here/bin/sleep" "$here/bin/zip" "$here/bin/stub-lib.sh"
else
  echo "  SKIP shellcheck not installed here (CI runs it)"
fi

echo
echo "shell checks: $PASS passed, $FAIL failed; node unit tests passed: $NODE_PASS"
[ "$FAIL" = 0 ]
