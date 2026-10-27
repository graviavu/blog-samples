#!/usr/bin/env bash
# run.sh - tests for cloudfront-folder-index. No AWS, no network: run-test.sh runs against a fake aws, curl and sleep (tests/bin).
# The function code in the template is tested with node (tests/function.test.mjs) when node is installed.
# Usage: tests/run.sh      Exit 0 only if every check passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
export PATH="$here/bin:$PATH"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cfit.XXXXXX")"; if [ -z "${KEEP_TMP:-}" ]; then trap 'rm -rf "$TMP"' EXIT; else echo "keeping $TMP"; fi
PASS=0 FAIL=0
ID=2610101200-ab12
RT="$root/run-test.sh"
PH="create folder test stack"
CPH="delete folder test stack"

check() { # description, then a command; passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "  ok   $d"; else FAIL=$((FAIL + 1)); echo "  FAIL $d"; fi
}
has()    { grep -q -- "$2" "$1"; }
hasnot() { ! grep -q -- "$2" "$1"; }
is()     { [ "$1" = "$2" ]; }

reset_env() {
  unset STUB_APPEND_INDEX STUB_NO_REWRITE STUB_NO_ERRCACHE STUB_COLD STUB_SIG_AT_CURL STUB_FAIL STUB_FOREIGN_TAG STUB_PAB_OFF STUB_DELETE_STUCK EXPECT_ACCOUNT_LAST4
  export AWS_PROFILE=testprof RT_RUNID="$ID" ERR_WAIT_SECS=75 WARMUP_TRIES=3 WARMUP_PAUSE=1 STACK_POLL_SECS=1 SETTLE_POLLS=3
}
newdir() { STUB_DIR="$TMP/$1/state"; RESULTS_DIR="$TMP/$1/res"; mkdir -p "$STUB_DIR" "$RESULTS_DIR"; export STUB_DIR RESULTS_DIR; OUT="$TMP/$1/out.txt"; RES="$RESULTS_DIR/results-$ID.md"; }
go() { local name="$1" input="$2"; shift 2; newdir "$name"; printf '%b' "$input" | "$RT" "$@" > "$OUT" 2>&1; RC=$?; }
calls() { cat "$STUB_DIR/calls.log" 2>/dev/null; }
only_sts() { calls | grep -q . && ! calls | grep -qvE '^sts get-caller-identity'; }
no_calls() { [ ! -s "$STUB_DIR/calls.log" ]; }
gone() { [ ! -e "$STUB_DIR/stack" ] && ! ls "$STUB_DIR"/bucket/*.key >/dev/null 2>&1; }
seed_stack() { echo "$ID" > "$STUB_DIR/stack"; echo CREATE_COMPLETE > "$STUB_DIR/stack_status"; mkdir -p "$STUB_DIR/bucket"; : > "$STUB_DIR/bucket/posts%x%index.html"; echo posts/x/index.html > "$STUB_DIR/bucket/posts%x%index.html.key"; }
# nothing that looks like an account id, ARN, key, token or CloudFront host
clean() {
  ! grep -Eq '(^|[^0-9])[0-9]{12}([^0-9]|$)|AKIA[0-9A-Z]{16}|arn:aws|[a-z0-9]+\.cloudfront\.net|[A-Za-z0-9+/=_-]{40,}' "$@"
}

echo "== 1. dry run (the default) =="
reset_env
go dry "" ; check "default: exit 0" is "$RC" 0
check "default: makes no AWS call" no_calls
check "default: prints the plan, the checks and the cost note" has "$OUT" "Cost: pennies"
check "default: names the four claims" has "$OUT" "C4  the 403"
check "default: says no AWS call was made" has "$OUT" "no AWS call was made"
check "default: nothing created, no results file" test ! -e "$RES"
go dry2 "" --dry-run; check "--dry-run: exit 0 and no AWS call" no_calls
go dry3 "" --cleanup "$ID" --dry-run; check "cleanup --dry-run: exit 0, no AWS call" no_calls; check "cleanup --dry-run: states what it would do" has "$OUT" "would delete stack"
go dry4 "" --cleanup bad-id --dry-run; check "cleanup: a bad run id is refused (exit 2)" is "$RC" 2
go dry5 "" --cleanup; check "cleanup without run id: exit 2" is "$RC" 2
go dry6 "" --nope; check "unknown argument: exit 2" is "$RC" 2

echo "== 2. full run, all four claims pass =="
reset_env
go full "$PH\n" --run
check "exit 0" is "$RC" 0
for c in C1 C2 C3 C4; do check "$c PASS in results file" has "$RES" "| $c | PASS |"; done
for c in C1 C2 C3 C4; do check "$c PASS on screen" has "$OUT" "$c  PASS"; done
check "stack and bucket deleted at the end" gone
check "teardown says complete" has "$RES" "Complete: every resource of this run was deleted"
check "keys were emptied before delete-stack" grep -q "DELETE key posts/y/" "$STUB_DIR/deleted.log"
check "raw status, X-Cache and Age are in the results" has "$RES" "Error from cloudfront"
check "Age header recorded" has "$RES" "| Hit from cloudfront | [0-9]"
check "C1 control and folder are both listed" has "$RES" "C1-folder | GET /posts/x/ | 403"
check "C4 waited for the error-caching time" grep -q "sleep 75" "$STUB_DIR/sleeps.log"
check "the no-slash redirect is reported as info" has "$RES" "answered 301"
check "screen output is redacted" clean "$OUT"
check "results file is redacted" clean "$RES"
check "create-stack tags carry sample and the run id" grep -q "Key=Purpose,Value=sample" "$STUB_DIR/calls.log"
check "only the run's own names are used" hasnot "$STUB_DIR/calls.log" "cfi-9999"

echo "== 3. confirmation phrase =="
reset_env
go badphrase "nope\n" --run; check "wrong phrase: exit 2" is "$RC" 2; check "wrong phrase: only the identity call was made" only_sts
go eof "" --run; check "no input: exit 2, nothing created" is "$RC" 2
reset_env; export EXPECT_ACCOUNT_LAST4=0000
go wrongacct "$PH\n" --run; check "wrong account suffix: exit 2" is "$RC" 2; check "wrong account suffix: nothing created" only_sts
reset_env; export EXPECT_ACCOUNT_LAST4=9012
go rightacct "$PH\n" --run; check "right account suffix: runs" is "$RC" 0

echo "== 4. a claim that does not hold prints FAIL and still cleans up =="
reset_env; export STUB_APPEND_INDEX=1
go c1fail "$PH\n" --run; check "C1 FAIL when index.html is appended: exit 1" is "$RC" 1; check "C1 FAIL shown" has "$OUT" "C1  FAIL"; check "others still PASS" has "$RES" "| C3 | PASS |"; check "cleaned up" gone
reset_env; export STUB_PAB_OFF=1
go c2fail "$PH\n" --run; check "C2 FAIL when block public access is off" has "$OUT" "C2  FAIL"; check "cleaned up" gone
reset_env; export STUB_NO_REWRITE=1
go c3fail "$PH\n" --run; check "C3 FAIL without the rewrite" has "$OUT" "C3  FAIL"; check "cleaned up" gone
reset_env; export STUB_NO_ERRCACHE=1
go c4fail "$PH\n" --run; check "C4 FAIL when the error is not held" has "$OUT" "C4  FAIL"; check "C4 note explains the 200" has "$RES" "another edge location"; check "cleaned up" gone

echo "== 5. warmup =="
reset_env; export STUB_COLD=3
go cold "$PH\n" --run; check "503 at first, then ok: exit 0" is "$RC" 0; check "slept between warmup tries" grep -q "sleep 1" "$STUB_DIR/sleeps.log"
reset_env; export STUB_COLD=999
go cold2 "$PH\n" --run; check "never ready: exit 1" is "$RC" 1; check "never ready: cleaned up" gone

echo "== 6. failures and Ctrl-C =="
reset_env; export STUB_FAIL=create-stack
go cf "$PH\n" --run; check "create-stack fails: exit 1" is "$RC" 1; check "create-stack fails: error text redacted" clean "$OUT"; check "create-stack fails: teardown ran" has "$OUT" "already gone"
reset_env; export STUB_FAIL=put-object:2
go pf "$PH\n" --run; check "an upload fails: exit 1, cleaned up" is "$RC" 1; check "an upload fails: stack deleted" gone
reset_env; export STUB_SIG_AT_CURL=3
go sig "$PH\n" --run; check "Ctrl-C during the checks: exit 130" is "$RC" 130; check "Ctrl-C: stack deleted anyway" gone; check "Ctrl-C: teardown shown" has "$OUT" "stack: deleted"
reset_env; export STUB_DELETE_STUCK=1
go stuck "$PH\n" --run; check "delete does not finish: exit 4" is "$RC" 4; check "stuck: tells how to clean up" has "$OUT" "--cleanup $ID"
check "stuck: results file says INCOMPLETE" has "$RES" "INCOMPLETE"

echo "== 7. --cleanup =="
reset_env
newdir cl; seed_stack; printf '%s\n' "$CPH" | "$RT" --cleanup "$ID" > "$OUT" 2>&1; RC=$?
check "cleanup: exit 0" is "$RC" 0; check "cleanup: stack and objects deleted" gone
reset_env
newdir cl2; seed_stack; printf 'no\n' | "$RT" --cleanup "$ID" > "$OUT" 2>&1; RC=$?
check "cleanup wrong phrase: exit 2, nothing deleted" test -e "$STUB_DIR/stack"
reset_env; export STUB_FOREIGN_TAG=2699999999-ffff
newdir cl3; seed_stack; printf '%s\n' "$CPH" | "$RT" --cleanup "$ID" > "$OUT" 2>&1; RC=$?
check "cleanup of a stack with another run id: NOT deleted, exit 4" is "$RC" 4; check "foreign stack is still there" test -e "$STUB_DIR/stack"; check "foreign stack: message" has "$OUT" "NOT deleting"
reset_env
newdir cl4; printf '%s\n' "$CPH" | "$RT" --cleanup "$ID" > "$OUT" 2>&1; RC=$?
check "cleanup of a run that no longer exists: exit 0" is "$RC" 0; check "cleanup: says already gone" has "$OUT" "already gone"

echo "== 8. the function code in the template (node) =="
if command -v node >/dev/null 2>&1; then
  check "function.test.mjs passes" node --test "$here/function.test.mjs"
else
  echo "  skip node not installed"
fi

echo "== 9. the template =="
T="$root/cfn/stack.yaml"
check "block public access: all four on" test "$(grep -cE '(BlockPublicAcls|BlockPublicPolicy|IgnorePublicAcls|RestrictPublicBuckets): true' "$T")" = 4
check "the bucket policy grants GetObject only (no ListBucket)" test "$(grep -v '^ *#' "$T" | grep -c 'ListBucket')" = 0
check "OAC signs always with sigv4" has "$T" "SigningBehavior: always"
check "403 mapped to /404.html with status 404" has "$T" "ResponsePagePath: /404.html"
check "error caching 60" has "$T" "ErrorCachingMinTTL: 60"
check "every resource name carries the run id" test "$(grep -cE 'Name: !Sub "cfi-\$\{RunId\}|BucketName: !Sub "cfi-\$\{RunId\}' "$T")" -ge 3
check "tags: sample" has "$T" "Value: sample"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" = 0 ]
