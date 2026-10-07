#!/usr/bin/env bash
# Tests the guards in deploy.sh with a fake aws CLI (no AWS): budget check (fail closed, AccessDenied,
# ACK_BUDGET) and the public-origins confirmation for the Lambda@Edge variant.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/bin" "$dir/work"
cp test/mock/fake-aws "$dir/bin/aws"
cp deploy.sh "$dir/work/deploy.sh"
export FAKE_CALLS="$dir/calls.log"
acct=1234; acct="${acct}56789012"
fail=0
check() { if [ "$2" -ne 0 ]; then echo "DEPLOY TEST FAIL: $1"; fail=1; fi; }

# run [args]: prints the exit code; output in $dir/out.txt; calls in $FAKE_CALLS
run() { : > "$FAKE_CALLS"; PATH="$dir/bin:$PATH" bash "$dir/work/deploy.sh" "$@" < /dev/null > "$dir/out.txt" 2>&1; echo $?; }
deployed() { grep -c 'cloudformation deploy' "$FAKE_CALLS"; }
ok() { [ "$1" = "$2" ] && echo 0 || echo 1; }

# 1. no budget: refuses before any deploy
rc=$(FAKE_BUDGETS=0 run); check "no budget exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "no budget: nothing deployed" "$(ok "$(deployed)" 0)"
check "no budget: clear message" "$(grep -q 'No AWS Budget found' "$dir/out.txt" && echo 0 || echo 1)"

# 2. AccessDenied: could not check, fails closed, and the message text (account id, ARN) is not printed
rc=$(FAKE_BUDGETS_DENIED=1 run); check "AccessDenied exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "AccessDenied: nothing deployed" "$(ok "$(deployed)" 0)"
check "AccessDenied: says could not check" "$(grep -q 'Could not check' "$dir/out.txt" && echo 0 || echo 1)"
check "AccessDenied: shows the error code" "$(grep -q AccessDeniedException "$dir/out.txt" && echo 0 || echo 1)"
check "AccessDenied: no account id or ARN printed" "$(grep -Eq "$acct|arn:aws" "$dir/out.txt" && echo 1 || echo 0)"

# 3. a budget exists: proceeds to the deploy
rc=$(FAKE_BUDGETS=2 run); check "budget present: deploy called" "$(ok "$(deployed)" 1)"
check "budget present: IAM origins by default" "$(grep -q 'OriginAuth=AWS_IAM' "$FAKE_CALLS" && echo 0 || echo 1)"

# 4. ACK_BUDGET=true skips the check
rc=$(FAKE_BUDGETS=0 ACK_BUDGET=true run); check "ACK_BUDGET proceeds" "$(ok "$(deployed)" 1)"

# 5. Lambda@Edge variant needs an explicit public-origins decision
rc=$(FAKE_BUDGETS=2 DEPLOY_EDGE=true run); check "edge without ack refuses" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "edge without ack: nothing deployed" "$(ok "$(deployed)" 0)"
rc=$(FAKE_BUDGETS=2 DEPLOY_EDGE=true ORIGIN_AUTH=AWS_IAM run); check "edge with ORIGIN_AUTH=AWS_IAM refuses" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "edge with IAM: nothing deployed" "$(ok "$(deployed)" 0)"
rc=$(FAKE_BUDGETS=2 DEPLOY_EDGE=true ORIGIN_AUTH=NONE run)
check "edge with ORIGIN_AUTH=NONE deploys public origins" "$(grep -q 'OriginAuth=NONE' "$FAKE_CALLS" && echo 0 || echo 1)"
rc=$(FAKE_BUDGETS=2 DEPLOY_EDGE=true ACK_PUBLIC_ORIGINS=true run)
check "edge with ACK_PUBLIC_ORIGINS=true deploys public origins" "$(grep -q 'OriginAuth=NONE' "$FAKE_CALLS" && echo 0 || echo 1)"
rc=$(FAKE_BUDGETS=2 DEPLOY_EDGE=true run --yes)
check "edge with --yes deploys public origins" "$(grep -q 'OriginAuth=NONE' "$FAKE_CALLS" && echo 0 || echo 1)"
echo "$rc" > /dev/null

if [ "$fail" = 0 ]; then echo "deploy-test: ok"; else echo "deploy-test: FAILED"; exit 1; fi
