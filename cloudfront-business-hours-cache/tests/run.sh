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
  unset STUB_FAIL STUB_SIG STUB_SIG_AT STUB_FOREIGN_TAG STUB_REPLICA STUB_CDN STUB_CURL_DOWN STUB_START_EPOCH
  export RT_RUNID="$RUNID_A" SETTLE_SECS=40 EDGE_DELETE_PAUSE=1 WARMUP_TRIES=2
}
# newdir NAME -> STUB_DIR and RESULTS_DIR for that scenario
newdir() { STUB_DIR="$TMP/$1/state"; RESULTS_DIR="$TMP/$1/res"; mkdir -p "$STUB_DIR/res" "$RESULTS_DIR"; export STUB_DIR RESULTS_DIR; OUT="$TMP/$1/out.txt"; }
# seed_foreign: resources of ANOTHER run that must never be touched
seed_foreign() {
  echo "$OTHER" > "$STUB_DIR/res/s3__bhc-$OTHER-cfg"; echo "$OTHER" > "$STUB_DIR/res/lambda__bhc-$OTHER-edge"
  echo "$OTHER" > "$STUB_DIR/res/iam__bhc-$OTHER-role"; echo "$OTHER" > "$STUB_DIR/res/lambda__bhc-$OTHER-origin"
}
# go NAME "stdin" args... -> RC, OUT
go() { local name="$1" input="$2"; shift 2; newdir "$name"; [ "${SEED:-0}" = 1 ] && seed_foreign; printf '%b' "$input" | "$RT" "$@" > "$OUT" 2>&1; RC=$?; }
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
for t in T-A T-B T-C T-D T-E; do check "$t PASS in the table" grep -Eq "^$t +PASS" "$OUT"; done
check "summary line PASS=5" has "$OUT" "PASS=5 FAIL=0 INCONCLUSIVE=0"
check "results file written" test -n "$(first_res)"
check "results file has the table and the T-C note" bash -c "grep -q '^| T-C | PASS' '$(first_res)' && grep -q 'boundary expiry gap observed' '$(first_res)'"
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
reset_env; export STUB_CDN=rewrite-errors; go rewrite "$PHRASE\n"
check "T-D FAIL when errors get the long TTL" grep -Eq "^T-D +FAIL" "$OUT"
reset_env; export STUB_CDN=stale-config; go stale "$PHRASE\n"
check "T-E FAIL when a stale config is used after an S3 failure" grep -Eq "^T-E +FAIL" "$OUT"
reset_env; export STUB_CURL_DOWN=1; go down "$PHRASE\n"
check "no answer: all tests INCONCLUSIVE, rc 3" bash -c "[ '$(grep -cE '^T-. +INCONCLUSIVE' "$OUT")' = 5 ]"
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
