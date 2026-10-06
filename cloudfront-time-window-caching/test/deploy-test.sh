#!/usr/bin/env bash
# Tests deploy.sh with a fake aws CLI (no AWS): the mandatory budget check (fail closed, AccessDenied, ACK_BUDGET),
# input validation, the two-phase default-above-max update and its rollback handling, and deploy.env.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/bin" "$dir/work"
cp test/mock/fake-aws "$dir/bin/aws"
cp deploy.sh seed-kvs.sh "$dir/work/"
export FAKE_CALLS="$dir/calls.log"
acct=1234; acct="${acct}56789012"
fail=0
check() { if [ "$2" -ne 0 ]; then echo "DEPLOY TEST FAIL: $1"; fail=1; fi; }

# run: prints the exit code; output in $dir/out.txt; calls in $FAKE_CALLS
run() { : > "$FAKE_CALLS"; rm -f "$dir/work/deploy.env"; PATH="$dir/bin:$PATH" bash "$dir/work/deploy.sh" "$@" < /dev/null > "$dir/out.txt" 2>&1; echo $?; }
run_env() { : > "$FAKE_CALLS"; env "$1" PATH="$dir/bin:$PATH" FAKE_BUDGETS=1 bash "$dir/work/deploy.sh" < /dev/null > "$dir/out.txt" 2>&1; echo $?; }
deploys() { grep -c 'cloudformation deploy' "$FAKE_CALLS"; }
ok() { [ "$1" = "$2" ] && echo 0 || echo 1; }
has() { grep -q -- "$1" "$2" && echo 0 || echo 1; }

# 1. no budget: refuses before any deploy
rc=$(FAKE_BUDGETS=0 run); check "no budget exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "no budget: nothing deployed" "$(ok "$(deploys)" 0)"
check "no budget: clear message" "$(has 'No AWS Budget found' "$dir/out.txt")"

# 2. AccessDenied: could not check, fails closed, and the message text (account id, ARN) is not printed
rc=$(FAKE_BUDGETS_DENIED=1 run); check "AccessDenied exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "AccessDenied: nothing deployed" "$(ok "$(deploys)" 0)"
check "AccessDenied: says could not check" "$(has 'Could not check' "$dir/out.txt")"
check "AccessDenied: shows the error code" "$(has AccessDeniedException "$dir/out.txt")"
check "AccessDenied: no account id or ARN printed" "$(grep -Eq "$acct|arn:aws" "$dir/out.txt" && echo 1 || echo 0)"

# 3. a budget exists: two deploys (main, then the default-above-max update); test behaviors on; deploy.env written
rc=$(FAKE_BUDGETS=2 run); check "budget present: succeeds" "$(ok "$rc" 0)"
check "budget present: two deploys" "$(ok "$(deploys)" 2)"
check "first deploy keeps the optional policy off" "$(grep 'cloudformation deploy' "$FAKE_CALLS" | head -1 | grep -q 'TryDefaultAboveMax=false' && echo 0 || echo 1)"
check "second deploy turns it on" "$(grep 'cloudformation deploy' "$FAKE_CALLS" | tail -1 | grep -q 'TryDefaultAboveMax=true' && echo 0 || echo 1)"
check "test behaviors enabled for the verify run" "$(has 'EnableTestBehaviors=true' "$FAKE_CALLS")"
check "template tagged" "$(has 'tags sample=cloudfront-time-window-caching' "$FAKE_CALLS")"
check "window record seeded" "$(has 'put-key.*--key window' "$FAKE_CALLS")"
check "deploy.env: DEFMAX=accepted" "$(has '^DEFMAX=accepted' "$dir/work/deploy.env")"
check "deploy.env: carrier and store" "$(grep -q '^SLOT_CARRIER=query' "$dir/work/deploy.env" && grep -q '^KVS_ARN=' "$dir/work/deploy.env" && echo 0 || echo 1)"
check "no edge stack by default" "$(grep 'cloudformation deploy' "$FAKE_CALLS" | grep -q 'template-lambda-edge' && echo 1 || echo 0)"

# 4. ACK_BUDGET=true skips the check
rc=$(FAKE_BUDGETS=0 ACK_BUDGET=true run); check "ACK_BUDGET proceeds" "$(ok "$rc" 0)"
check "ACK_BUDGET: deployed" "$([ "$(deploys)" -ge 1 ] && echo 0 || echo 1)"

# 5. the optional policy update is refused: the script goes on, records it, and does not fail
rc=$(FAKE_BUDGETS=1 FAKE_DEPLOY_FAIL_ON='TryDefaultAboveMax=true' run); check "refused update does not fail the deploy" "$(ok "$rc" 0)"
check "deploy.env: DEFMAX=rejected" "$(has '^DEFMAX=rejected' "$dir/work/deploy.env")"
check "says the refusal is the answer" "$(has 'answer for test T5e' "$dir/out.txt")"
check "window still seeded after a refused update" "$(has 'put-key' "$FAKE_CALLS")"

# 6. TRY_DEFAULT_ABOVE_MAX=false and ENABLE_TEST_BEHAVIORS=false: one deploy, DEFMAX=off
rc=$(FAKE_BUDGETS=1 TRY_DEFAULT_ABOVE_MAX=false run); check "no optional update" "$(ok "$(deploys)" 1)"
check "DEFMAX=off" "$(has '^DEFMAX=off' "$dir/work/deploy.env")"
rc=$(FAKE_BUDGETS=1 ENABLE_TEST_BEHAVIORS=false run); check "no test behaviors: one deploy" "$(ok "$(deploys)" 1)"
check "no test behaviors passed" "$(has 'EnableTestBehaviors=false' "$FAKE_CALLS")"

# 7. optional edge stack: IAM origin, so no public-origin confirmation is needed; window constants are passed
rc=$(FAKE_BUDGETS=1 DEPLOY_EDGE=true EDGE_IN_TTL=20 run); check "edge deploy succeeds" "$(ok "$rc" 0)"
check "edge template deployed" "$(has 'template-lambda-edge.yaml' "$FAKE_CALLS")"
check "edge gets the window constants" "$(grep 'template-lambda-edge' "$FAKE_CALLS" | grep -q 'InTtl=20' && echo 0 || echo 1)"
check "deploy.env: EDGE_DOMAIN" "$(has '^EDGE_DOMAIN=' "$dir/work/deploy.env")"

# 8. validation: bad values never reach the aws CLI
for bad in "NAME_PREFIX=Bad_Name" "SLOT_CARRIER=cookie" "CLOSED_MIN_TTL=5" "CLOSED_MIN_TTL=abc" "ENABLE_TEST_BEHAVIORS=yes" \
           "STACK_NAME=x;touch$IFS/tmp/pwned" "COST_TAG_KEY=a b" "AWS_REGION=eu-west-1" "EDGE_REWRITE_ERRORS=maybe"; do
  rc=$(run_env "$bad")
  check "rejects $bad" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
  check "rejects $bad before any aws call" "$([ -s "$FAKE_CALLS" ] && echo 1 || echo 0)"
done
rc=$(FAKE_BUDGETS=1 DEPLOY_EDGE=true EDGE_WINDOW_START_MIN=900 EDGE_WINDOW_END_MIN=60 run)
check "edge window across midnight rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "edge window across midnight: nothing deployed" "$(ok "$(deploys)" 0)"
rc=$(FAKE_BUDGETS=1 run extra-arg); check "unexpected argument rejected" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

if [ "$fail" = 0 ]; then echo "deploy-test: ok"; else echo "deploy-test: FAILED"; exit 1; fi
