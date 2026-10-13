#!/usr/bin/env bash
# run.sh - tests for cloudfront-cff-time-bucket-cache. No AWS, no network: run-sample.sh runs against a fake aws, curl, date and sleep
# (tests/bin; the fake curl is a small CloudFront simulation that runs the real function code from the template).
# Also runs the node unit tests, cfn-lint and shellcheck when they are installed (else says NOT RUN), and mutation checks.
# Usage: tests/run.sh      Exit 0 only if every check passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
export PATH="$here/bin:$PATH"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cftbt.XXXXXX")"; if [ -z "${KEEP_TMP:-}" ]; then trap 'rm -rf "$TMP"' EXIT; else echo "keeping $TMP"; fi
PASS=0 FAIL=0
RUNID_A=2610101200-ab12
OTHER=9999999999-ffff
PHRASE="DELETE-SAMPLE"
FAKE_ACCT="1234$(printf %s 56789012)"   # built at run time so the repo scan has nothing to flag
FAKE_KEY="AKIA$(printf %s ABCDEFGHIJKLMNOP)"
RS="$root/run-sample.sh"

check() { # description, then a command; passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "  ok   $d"; else FAIL=$((FAIL + 1)); echo "  FAIL $d"; fi
}
has()    { grep -q -- "$2" "$1"; }
hasnot() { ! grep -q -- "$2" "$1"; }
is()     { [ "$1" = "$2" ]; }

reset_env() {
  unset STUB_FAIL STUB_FAIL_CODE STUB_SIG STUB_SIG_AT STUB_FOREIGN_TAG STUB_S3_REJECT STUB_S3_ALWAYS403 STUB_PROP_DELAY STUB_START_EPOCH BUCKET_SECONDS PROP_WAIT
  export AWS_PROFILE=testprof
  export RT_RUNID="$RUNID_A" POLL_GAP=10 STACK_POLL_SECS=1
}
newdir() { rm -rf "$TMP/$1"; STUB_DIR="$TMP/$1/state"; RESULTS_DIR="$TMP/$1/res"; mkdir -p "$STUB_DIR/res" "$RESULTS_DIR"; export STUB_DIR RESULTS_DIR; OUT="$TMP/$1/out.txt"; }
seed_foreign() { echo OTHERRUN > "$STUB_DIR/res/s3__cftb-$OTHER-content"; printf 'CREATE_COMPLETE\n%s\n' "$OTHER" > "$STUB_DIR/res/cfn__cftb-$OTHER"; }
# go NAME "stdin" args... -> RC, OUT   (RUN overrides the script, for the mutation checks)
go() { local name="$1" input="$2"; shift 2; newdir "$name"; [ "${SEED:-0}" = 1 ] && seed_foreign; printf '%b' "$input" | "${RUN:-$RS}" "$@" > "$OUT" 2>&1; RC=$?; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null; }
only_readonly() { calls | grep -q . && ! calls | grep -qvE '^(sts get-caller-identity|cloudformation validate-template)'; }
no_leftovers() { local f; for f in "$STUB_DIR"/res/*; do [ -e "$f" ] || continue; case "$f" in *"$OTHER"*) ;; *) return 1 ;; esac; done; return 0; }
foreign_intact() { [ -e "$STUB_DIR/res/s3__cftb-$OTHER-content" ] && [ -e "$STUB_DIR/res/cfn__cftb-$OTHER" ]; }
never_mentions_foreign() { ! calls | grep -q "$OTHER"; }
# nothing that looks like an account id, ARN, key, token, CloudFront host, distribution id or the bucket name
clean() {
  ! grep -E -q '(^|[^0-9])[0-9]{12}([^0-9]|$)|arn:aws|AKIA[0-9A-Z]{16}|[a-z0-9]+\.cloudfront\.net|(^|[^A-Za-z0-9])E[A-Z0-9]{12,13}([^A-Za-z0-9]|$)|[A-Za-z0-9+/=_-]{40,}' "$1"
}
no_bucket_name() { ! grep -q 'cftb-[0-9]*-[0-9a-f]*-content' "$1"; }
res_file() { echo "$RESULTS_DIR/results-$RUNID_A.md"; }
no_state_calls() { ! calls | grep -qE '^(cloudformation (create|update|delete)-stack|s3api (put|delete)-object)'; }

echo "node unit tests (function logic and template)"
if command -v node >/dev/null 2>&1; then
  check "node --test tests/*.test.mjs" node --test "$here"/*.test.mjs
else
  echo "  NOT RUN: node is not installed"
fi

echo "dry run"
reset_env; go dry "" --dry-run
check "dry run exits 0" is "$RC" 0
check "dry run makes only the read-only identity and template-validation calls" only_readonly
check "dry run validated the template" has "$STUB_DIR/calls.log" "cloudformation validate-template"
check "dry run prints the plan with the stack name" has "$OUT" "stack cftb-$RUNID_A"
check "dry run shows the windows" has "$OUT" "Windows (UTC hours"
check "dry run says nothing was created" has "$OUT" "nothing was created or deleted"
check "dry run does not prompt for the phrase" hasnot "$OUT" "Type DELETE-SAMPLE"
check "dry run makes no request with curl" bash -c "! grep -E '^curl ' '$STUB_DIR/calls.log'"
check "dry run changes nothing in the account" no_state_calls
check "dry run leaves no results file" bash -c "[ -z \"\$(ls '$RESULTS_DIR')\" ]"
check "dry run output is redacted" clean "$OUT"
check "dry run does not print the account id" hasnot "$OUT" "$FAKE_ACCT"

echo "bad inputs change nothing"
for bad in "BUCKET_SECONDS=abc" "BUCKET_SECONDS=5" "BUCKET_SECONDS=601" "BUCKET_SECONDS=-3" "PROP_WAIT=x" "POLL_GAP=0"; do
  reset_env; export "${bad?}"; go bad "$PHRASE\n"
  check "$bad is refused (exit 2) before any AWS call" bash -c "[ $RC = 2 ] && [ ! -s '$STUB_DIR/calls.log' ]"
done
reset_env; go badarg "" --nonsense
check "unknown argument exits 2" is "$RC" 2
reset_env; go clean0 "$PHRASE\n" --cleanup
check "--cleanup without a run id exits 2" is "$RC" 2
reset_env; go clean1 "$PHRASE\n" --cleanup not-a-run-id
check "--cleanup with a malformed run id exits 2, no AWS call" bash -c "[ $RC = 2 ] && [ ! -s '$STUB_DIR/calls.log' ]"
reset_env; export RT_RUNID="bad id"; go badrun "$PHRASE\n"
check "a malformed run id exits 2" is "$RC" 2

echo "typed phrase gate"
for ans in "" "yes" "delete-sample" "DELETE-SAMPLE " " DELETE-SAMPLE" "DELETE_SAMPLE" "create cloudfront test stack"; do
  reset_env; go gate "$ans\n"
  check "answer '$ans' is refused (exit 3), nothing created" bash -c "[ $RC = 3 ] && ! grep -qE '^(cloudformation (create|update|delete)-stack|s3api|curl)' '$STUB_DIR/calls.log'"
done
reset_env; go gate_eof ""
check "no answer at all (closed stdin) is refused" is "$RC" 3
reset_env; go gate_clean "wrong\n" --cleanup "$RUNID_A"
check "--cleanup also needs the phrase (exit 3, no delete)" bash -c "[ $RC = 3 ] && ! grep -qE 'delete-stack|delete-object' '$STUB_DIR/calls.log'"

echo "full run, everything behaves as designed"
reset_env; SEED=1 go full "$PHRASE\n"; SEED=0
check "full run exits 0" is "$RC" 0
for id in S3-OAC-HEADER P2-MISS-THEN-HITS P2-NEW-BUCKET-MISS P2-HIT-AGAIN P2-OVERWRITE-VISIBLE P3-VIEWER-HEADER-OVERWRITTEN P4-OUT-OF-WINDOW-EFFECTIVE \
          P4-HITS-ACROSS-BOUNDARY P4-VIEWER-HEADER-DELETED P4-LONG-CACHE P4-LONG-NOT-SERVED-IN-WINDOW; do
  check "PASS line for $id" has "$OUT" "PASS  $id"
done
check "no FAIL line" hasnot "$OUT" "FAIL  "
check "results file written" test -f "$(res_file)"
check "results file says all checks passed" has "$(res_file)" "ALL CHECKS PASSED"
check "results file records the propagation fact" has "$(res_file)" "function update visible at the edge within"
check "results file says the teardown completed and was verified" has "$(res_file)" "deleted and verified gone"
check "screen output is redacted" clean "$OUT"
check "results file is redacted (no account id, ARN, key, token, host)" clean "$(res_file)"
check "results file has no bucket name" no_bucket_name "$(res_file)"
check "the fake account id never reaches the output" hasnot "$OUT" "$FAKE_ACCT"
check "the fake token never reaches the output" hasnot "$OUT" "abcdefghijklmnopqrstuvwxyz0123456789"
check "stack and bucket are gone" no_leftovers
check "the stack was deleted after the bucket keys" bash -c "grep -n 'DELETE s3object\|DELETE stack ' '$STUB_DIR/deleted.log' | tail -n 1 | grep -q 'DELETE stack'"
check "stack delete verified (describe-stacks after the last delete-stack)" bash -c "d=\$(grep -n '^cloudformation delete-stack' '$STUB_DIR/calls.log' | tail -n 1 | cut -d: -f1); g=\$(grep -n '^cloudformation describe-stacks' '$STUB_DIR/calls.log' | tail -n 1 | cut -d: -f1); [ \"\$g\" -gt \"\$d\" ]"
check "foreign run untouched" foreign_intact
check "foreign run never mentioned in an aws call" never_mentions_foreign
check "creates in window [11,14), moves out to [15,17), back in" bash -c "grep -c 'update-stack' '$STUB_DIR/calls.log' | grep -qx 2"
check "windows contain / exclude hour 12 as designed" bash -c "grep -q 'Windows (UTC hours, end exclusive): start inside \[11,14), later moved to \[15,17)' '$OUT'"
check "the run stays within a sane number of requests" bash -c "[ \$(grep -c '^curl ' '$STUB_DIR/calls.log') -lt 120 ]"

echo "other bucket length and an hour near midnight"
reset_env; export BUCKET_SECONDS=30 STUB_START_EPOCH=1791676200   # 23:30:00 UTC: window wraps past midnight (22..1), out window 2..4
go wrap "$PHRASE\n"
check "bucket 30 s, window wrapping midnight: exit 0" is "$RC" 0
check "window printed wrapped" has "$OUT" "start inside \[22,1)"
check "no FAIL line" hasnot "$OUT" "FAIL  "

echo "trap: errors and interrupts undo the changes"
reset_env; export STUB_FAIL=create-stack; go f_create "$PHRASE\n"
check "create-stack fails: exit 1, error redacted" bash -c "[ $RC = 1 ] && grep -q 'ERROR: create-stack' '$OUT'"
check "create-stack fails: nothing left" no_leftovers
check "create-stack fails: output redacted" clean "$OUT"
reset_env; export STUB_FAIL=put-object; go f_put "$PHRASE\n"
check "upload fails after the stack exists: stack deleted again" bash -c "[ $RC = 1 ] && grep -q 'DELETE stack' '$STUB_DIR/deleted.log'"
check "upload fails: nothing left" no_leftovers
reset_env; export STUB_FAIL=update-stack; go f_update "$PHRASE\n"
check "update-stack fails mid-run: stack still deleted, exit 1" bash -c "[ $RC = 1 ] && grep -q 'DELETE stack' '$STUB_DIR/deleted.log'"
check "update-stack fails: a results file with the partial results exists" bash -c "grep -q 'ABORTED' '$(res_file)'"
check "update-stack fails: nothing left" no_leftovers
reset_env; export STUB_SIG=INT STUB_SIG_AT=update-stack; go f_int "$PHRASE\n"
check "Ctrl-C during an update: exit 130" is "$RC" 130
check "Ctrl-C: stack deleted and verified" bash -c "grep -q 'DELETE stack' '$STUB_DIR/deleted.log' && grep -q 'deleted and verified gone' '$OUT'"
check "Ctrl-C: nothing left" no_leftovers
reset_env; export STUB_SIG=TERM STUB_SIG_AT=create-stack; go f_term "$PHRASE\n"
check "SIGTERM during create: exit 143, nothing left" bash -c "[ $RC = 143 ]"
check "SIGTERM during create: stack deleted" no_leftovers
reset_env; export STUB_FAIL=delete-stack; go f_del "$PHRASE\n"
check "delete-stack failing is reported: exit 4" is "$RC" 4
check "delete-stack failing: INCOMPLETE message and the cleanup hint" bash -c "grep -q 'INCOMPLETE' '$OUT' && grep -q 'cftb-$RUNID_A' '$OUT'"
check "delete-stack failing: results file says incomplete" has "$(res_file)" "INCOMPLETE"
reset_env; export STUB_FOREIGN_TAG=1; go f_tag "$PHRASE\n"
check "a stack carrying another run's tag is NOT deleted (exit 4)" bash -c "[ $RC = 4 ] && grep -q 'NOT deleting' '$OUT' && ! grep -q 'DELETE stack' '$STUB_DIR/deleted.log'"

echo "S3 / origin access control answers"
reset_env; export STUB_S3_REJECT=1 PROP_WAIT=60; go s3_rej "$PHRASE\n"
check "S3 rejecting the header: exit 1" is "$RC" 1
check "S3 rejecting the header: clear message" has "$OUT" "rejected the extra forwarded x-cache-bust header"
check "S3 rejecting the header: stack still deleted" no_leftovers
reset_env; export STUB_S3_ALWAYS403=1 PROP_WAIT=60; go s3_403 "$PHRASE\n"
check "403 also without the header: exit 1, message says it is not the header" bash -c "[ $RC = 1 ] && grep -q 'not (only) the header' '$OUT'"
check "403 case: stack still deleted" no_leftovers

echo "function update never shows (bounded wait)"
reset_env; export STUB_PROP_DELAY=99999 PROP_WAIT=90; go noprop "$PHRASE\n"
check "no propagation: exit 1 with a clear FAIL line" bash -c "[ $RC = 1 ] && grep -q 'FAIL  P4-OUT-OF-WINDOW-EFFECTIVE' '$OUT' && grep -q 'was not visible after' '$OUT'"
check "no propagation: the wait was bounded and says how long" has "$OUT" "waited at most 90s"
check "no propagation: stack deleted" no_leftovers
reset_env; export STUB_PROP_DELAY=60; go slowprop "$PHRASE\n"
check "a 60 s propagation delay still passes and is reported" bash -c "[ $RC = 0 ] && grep -q 'function update visible at the edge within' '$OUT'"

echo "idempotence and cleanup"
reset_env; go re1 "$PHRASE\n"; rc1=$RC
reset_env; export RT_RUNID=2610101300-cd34; go re2 "$PHRASE\n"; rc2=$RC
check "two runs with different ids both pass" bash -c "[ $rc1 = 0 ] && [ $rc2 = 0 ]"
reset_env; go clean_gone "$PHRASE\n" --cleanup "$RUNID_A"
check "--cleanup of a stack that is already gone: exit 0, says so" bash -c "[ $RC = 0 ] && grep -q 'already gone' '$OUT'"
reset_env; go clean_dry "" --cleanup "$RUNID_A" --dry-run
check "--cleanup --dry-run deletes nothing and does not prompt" bash -c "[ $RC = 0 ] && ! grep -qE 'delete-' '$STUB_DIR/calls.log' && ! grep -q 'Type DELETE-SAMPLE' '$OUT'"
reset_env
newdir clean_real
printf 'CREATE_COMPLETE\n%s\n' "$RUNID_A" > "$STUB_DIR/res/cfn__cftb-$RUNID_A"; : > "$STUB_DIR/res/s3__cftb-$RUNID_A-content"; echo "$RUNID_A" > "$STUB_DIR/runid"; mkdir -p "$STUB_DIR/s3"; echo x > "$STUB_DIR/s3/probe.txt"
seed_foreign
printf '%s\n' "$PHRASE" | "$RS" --cleanup "$RUNID_A" > "$OUT" 2>&1; RC=$?
check "--cleanup of a leftover stack: exit 0, deleted and verified" bash -c "[ $RC = 0 ] && grep -q 'deleted and verified gone' '$OUT'"
check "--cleanup empties the bucket keys first" bash -c "grep -q 'DELETE s3object probe.txt' '$STUB_DIR/deleted.log'"
check "--cleanup leaves the foreign run alone" foreign_intact
check "--cleanup removed our stack" no_leftovers

echo "mutation checks: a broken script or function must be caught by these tests"
mut="$TMP/mut"
copy_sample() { rm -rf "$mut"; mkdir -p "$mut"; cp -R "$root"/. "$mut"/; }
# 1. phrase gate removed
copy_sample; sed -i.bak 's/\[ "\$answer" = "\$PHRASE" \]/true/' "$mut/run-sample.sh"; rm -f "$mut"/run-sample.sh.bak
check "mutation 1 really changed the gate" bash -c "! grep -q '\"\$answer\" = \"\$PHRASE\"' '$mut/run-sample.sh'"
reset_env; STUB_TEMPLATE_ROOT="$mut" RUN="$mut/run-sample.sh" go mut_gate "wrong\n"; RUN=""
check "mutation 1 (gate always true): the phrase test would FAIL, so it is caught" bash -c "[ $RC != 3 ]"
# 2. function does not delete the viewer-supplied header
copy_sample; sed -i.bak "/delete request.headers\['x-cache-bust'\];/d" "$mut/cfn/stack.yaml" "$mut/function/time-bucket.js"; rm -f "$mut"/cfn/stack.yaml.bak "$mut"/function/time-bucket.js.bak
check "mutation 2 really removed the delete" bash -c "! grep -q 'delete request.headers' '$mut/cfn/stack.yaml'"
reset_env; STUB_TEMPLATE_ROOT="$mut" RUN="$mut/run-sample.sh" go mut_del "$PHRASE\n"; RUN=""
check "mutation 2 (header not deleted): the run reports FAIL P4-VIEWER-HEADER-DELETED" bash -c "[ $RC = 1 ] && grep -q 'FAIL  P4-VIEWER-HEADER-DELETED' '$OUT'"
check "mutation 2: the node unit tests fail too" bash -c "! node --test '$mut'/tests/function.test.mjs"
# 3. function does not overwrite in-window (keeps the viewer value)
copy_sample; sed -i.bak "s/request.headers\['x-cache-bust'\] = { value: bucket };/if (!request.headers['x-cache-bust']) { request.headers['x-cache-bust'] = { value: bucket }; }/; /delete request.headers\['x-cache-bust'\];/d" "$mut/cfn/stack.yaml"; rm -f "$mut"/cfn/stack.yaml.bak
reset_env; STUB_TEMPLATE_ROOT="$mut" RUN="$mut/run-sample.sh" go mut_keep "$PHRASE\n"; RUN=""
check "mutation 3 (viewer value kept): the run reports FAIL P3-VIEWER-HEADER-OVERWRITTEN" bash -c "[ $RC = 1 ] && grep -q 'FAIL  P3-VIEWER-HEADER-OVERWRITTEN' '$OUT'"
# 4. bucket never changes (key constant): new-bucket check must fail
copy_sample; sed -i.bak "s|return String(Math.floor(nowMs / 1000 / cfg.bucketSeconds));|return 'x';|" "$mut/cfn/stack.yaml"; rm -f "$mut"/cfn/stack.yaml.bak
reset_env; STUB_TEMPLATE_ROOT="$mut" RUN="$mut/run-sample.sh" go mut_const "$PHRASE\n"; RUN=""
check "mutation 4 (constant bucket): the run reports FAIL P2-NEW-BUCKET-MISS" bash -c "[ $RC = 1 ] && grep -q 'FAIL  P2-NEW-BUCKET-MISS' '$OUT'"
# 5. redaction removed
copy_sample; sed -i.bak "s/-e 's#(AKIA|ASIA)\[0-9A-Z\]{16}#<access-key-id>#g' \\\\//" "$mut/run-sample.sh"; rm -f "$mut"/run-sample.sh.bak
reset_env; export STUB_FAIL=create-stack; STUB_TEMPLATE_ROOT="$mut" RUN="$mut/run-sample.sh" go mut_red "$PHRASE\n"; RUN=""
check "mutation 5 (access-key redaction removed): the redaction test would FAIL, so it is caught" bash -c "grep -q \"$FAKE_KEY\" '$OUT'"

echo "cfn-lint and shellcheck"
if command -v cfn-lint >/dev/null 2>&1; then check "cfn-lint cfn/stack.yaml" cfn-lint "$root/cfn/stack.yaml"; else echo "  NOT RUN: cfn-lint is not installed (CI runs it)"; fi
if command -v shellcheck >/dev/null 2>&1; then check "shellcheck" shellcheck -x "$root/run-sample.sh" "$here/run.sh" "$here"/bin/aws "$here"/bin/curl "$here"/bin/date "$here"/bin/sleep "$here"/bin/stub-lib.sh; else echo "  NOT RUN: shellcheck is not installed (CI runs it)"; fi
check "bash syntax" bash -n "$RS"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
