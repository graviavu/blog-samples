#!/usr/bin/env bash
# Tests variants.sh against the local mock and a fake aws CLI (no AWS): the table and machine lines, in-place
# updates, restore of V2, consent for public variants, and that AWS error text never reaches the output.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=$(mktemp -d)
mock_pid=""
trap '[ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null; rm -rf "$dir"' EXIT
mkdir -p "$dir/bin" "$dir/work"
cp test/mock/fake-aws "$dir/bin/aws"
cp variants.sh "$dir/work/variants.sh"
export FAKE_CALLS="$dir/calls.log" FAKE_VARIANT_FILE="$dir/variant.txt" FAKE_KVS_LOG="$dir/kvs.log"
export FAKE_STACK_TAG="cloudfront-request-routing"
acct=1234; acct="${acct}56789012"
fail=0
check() { if [ "$2" -ne 0 ]; then echo "VARIANTS TEST FAIL: $1"; fail=1; fi; }
has() { grep -q -- "$2" "$1" && echo 0 || echo 1; }

start_mock() {
  rm -f "$FAKE_VARIANT_FILE"
  node test/mock/mock-edge.mjs 18787 18788 "$FAKE_KVS_LOG" 18789 &
  mock_pid=$!
  sleep 1
}
stop_mock() { kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null; mock_pid=""; }
run() { # args...; output in $dir/out.txt
  : > "$FAKE_CALLS"
  PATH="$dir/bin:$PATH" VERIFY_SCHEME=http CF_DOMAIN=127.0.0.1:18787 STACK_NAME=test-stack SETTLE=0 POLL_SLEEP=0.2 WAIT_CAP=10 \
    RESULTS_FILE="$dir/results.txt" bash "$dir/work/variants.sh" "$@" < /dev/null > "$dir/out.txt" 2>&1
  echo $?
}

# 1. all variants, with the mock rejecting an hostHeader (what the real variants run observed)
MOCK_REJECT_HOSTHEADER=1 start_mock
rc=$(run --yes)
stop_mock
check "run with a passing variant exits 0" "$([ "$rc" = 0 ] && echo 0 || echo 1)"
for v in V2 V3 V4 V5 V6; do check "$v passes" "$(has "$dir/out.txt" "^VARIANT=$v RESULT=PASS")"; done
check "V1 (hostHeader with OAC) fails" "$(has "$dir/out.txt" "^VARIANT=V1 RESULT=FAIL")"
check "V0 (hostHeader, no OAC config) fails" "$(has "$dir/out.txt" "^VARIANT=V0 RESULT=FAIL")"
check "V1 detail shows the x-cache value" "$(has "$dir/out.txt" "FunctionValidationError from cloudfront")"
check "summary names the first passing variant" "$(has "$dir/out.txt" "first-passing=V2")"
check "table header printed" "$(has "$dir/out.txt" "^VARIANT  *STATUS-A")"
check "default variant restored at the end" "$(has "$dir/out.txt" "^VARIANT=V2 RESULT=PASS DETAIL=restored default")"
last=$(grep 'update-stack' "$FAKE_CALLS" | tail -1)
check "last update-stack is V2 with IAM origins" "$(printf '%s' "$last" | grep -q 'RouteVariant,ParameterValue=V2' && printf '%s' "$last" | grep -q 'OriginAuth,ParameterValue=AWS_IAM' && echo 0 || echo 1)"
check "updates are in place with UsePreviousValue" "$(printf '%s' "$last" | grep -q 'UsePreviousValue=true' && echo 0 || echo 1)"
check "results file written" "$([ -s "$dir/results.txt" ] && echo 0 || echo 1)"

# 2. public variants need consent: refuses (no tty), nothing updated
rc=$(run)
check "no consent exits non-zero" "$([ "$rc" != 0 ] && echo 0 || echo 1)"
check "no consent: no update-stack call" "$(grep -c update-stack "$FAKE_CALLS" | grep -q '^0$' && echo 0 || echo 1)"
# ... but IAM-only variants need none
start_mock
rc=$(run V2 V4)
stop_mock
check "IAM-only variants need no consent" "$([ "$rc" = 0 ] && echo 0 || echo 1)"

# 3. AWS failure: only the error code appears, never the message (account id, ARN)
rc=$(FAKE_UPDATE_FAIL=1 run V2)
check "update failure shows the error code" "$(has "$dir/out.txt" "AccessDenied")"
check "AWS failure exits non-zero" "$([ "$rc" != 0 ] && echo 0 || echo 1)"
check "no account id or ARN in the output" "$(grep -Eq "$acct|arn:aws" "$dir/out.txt" "$dir/results.txt" && echo 1 || echo 0)"

# 4. wrong tag: refuses
FAKE_STACK_TAG=other rc=$(FAKE_STACK_TAG=other run V2)
check "untagged stack refused" "$([ "$rc" != 0 ] && echo 0 || echo 1)"

if [ "$fail" = 0 ]; then echo "variants-test: ok"; else echo "variants-test: FAILED"; exit 1; fi
