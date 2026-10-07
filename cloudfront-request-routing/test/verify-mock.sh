#!/usr/bin/env bash
# Runs verify.sh against the local mock (no AWS) and checks the machine-readable verdicts.
# This tests the script's logic and parsing; it says nothing about real CloudFront behavior.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=${KEEP:+$KEEP}; dir=${dir:-$(mktemp -d)}; mkdir -p "$dir"
trap 'kill $mock_pid 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$dir"' EXIT
export FAKE_KVS_LOG="$dir/kvs.log"
fail=0
SFX=.lambda-url.us-east-1.on
SFX="${SFX}.aws"

run_case() { # name key-attribute expected-substrings...
  local name=$1 keyattr=$2; shift 2
  CACHE_KEY_ATTRIBUTE=$keyattr PROPAGATION_MS=3000 node test/mock/mock-edge.mjs 18787 18788 "$FAKE_KVS_LOG" &
  mock_pid=$!
  sleep 1
  mkdir -p "$dir/bin"; cp test/mock/fake-aws "$dir/bin/aws"
  out=$(PATH="$dir/bin:$PATH" VERIFY_SCHEME=http RESULTS_FILE="$dir/results-$name.txt" CF_DOMAIN=127.0.0.1:18787 EDGE_DOMAIN=127.0.0.1:18788 \
    VERIFY_DIRECT_CONNECT=127.0.0.1:18789 DEFAULT_ORIGIN_HOST=origin-default$SFX KVS_ARN=fake ORIGIN_A_HOST=origin-a$SFX ORIGIN_B_HOST=origin-b$SFX FUNCTION_NAME=fake \
    CACHE_KEY_ATTRIBUTE=$keyattr READY_MAX=20 bash ./verify.sh 2>&1)
  kill $mock_pid 2>/dev/null; wait $mock_pid 2>/dev/null
  rm -f "$FAKE_KVS_LOG"
  for want in "$@"; do
    if ! printf '%s\n' "$out" | grep -q -- "$want"; then echo "MOCK TEST FAIL [$name]: missing '$want'"; fail=1; fi
  done
  [ -s "$dir/results-$name.txt" ] || { echo "MOCK TEST FAIL [$name]: no results file"; fail=1; }
  printf '%s\n' "$out" | grep -E '^TEST=|^SUMMARY' | sed "s/^/  [$name] /"
}

run_case keyed x-backend \
  'TEST=T1a RESULT=PASS' 'TEST=T1b RESULT=PASS' 'TEST=T1c RESULT=PASS' 'TEST=T4 RESULT=MEASURED' \
  'TEST=T6a RESULT=PASS' 'TEST=T6b RESULT=PASS' 'TEST=T6c RESULT=PASS' 'TEST=T6d RESULT=PASS' 'TEST=T6e RESULT=PASS' \
  'TEST=T6f RESULT=PASS' 'TEST=T6i RESULT=PASS' 'TEST=T6h RESULT=PASS' 'TEST=T6g RESULT=PASS' 'TEST=T7 RESULT=PASS' 'TEST=T8 RESULT=MEASURED' 'SUMMARY pass=.* fail=0'

# Same stack but the attribute is NOT in the cache key: T1b must now expect (and see) the shared entry.
run_case unkeyed none 'TEST=T1a RESULT=PASS' 'TEST=T1b RESULT=PASS'

# Origins that answer a direct unsigned call must be reported as exposed.
MOCK_DIRECT_OPEN=1 run_case exposed x-backend 'TEST=T6i RESULT=FAIL'

# AWS CLI failure with an AccessDenied message that contains an account id and ARNs (built at run time).
FAKE_AWS_FAIL=1 run_case awsfail x-backend 'TEST=T4 RESULT=INCONCLUSIVE' 'AccessDeniedException'
acct=1234; acct="${acct}56789012"
if grep -q "$acct" "$dir/results-awsfail.txt" || grep -Eq 'arn:aws[a-z-]*:(iam|cloudfront)' "$dir/results-awsfail.txt"; then
  echo "MOCK TEST FAIL [awsfail]: results file contains an account id or ARN"; fail=1
fi
if ! grep -q 'error-code=AccessDeniedException' "$dir/results-awsfail.txt"; then
  echo "MOCK TEST FAIL [awsfail]: error code not logged"; fail=1
fi
if printf '%s\n' "$out" | grep -q "$acct"; then echo "MOCK TEST FAIL [awsfail]: console output contains an account id"; fail=1; fi

# The final redaction pass on its own: masks 12-digit numbers and ARNs, keeps 13-digit epoch values.
eval "$(sed -n '/^redact_results()/,/^}/p' verify.sh)"
printf 'a arn:aws:iam::%s:role/x b %s c 1760000000000 d\n' "$acct" "$acct" > "$dir/redact.txt"
redact_results "$dir/redact.txt"
if grep -q "$acct" "$dir/redact.txt" || grep -q 'arn:aws:iam' "$dir/redact.txt" || ! grep -q 1760000000000 "$dir/redact.txt"; then
  echo "MOCK TEST FAIL [redact]: $(cat "$dir/redact.txt")"; fail=1
fi

# Interrupted run (TERM): the exit trap must leave a masked results file.
node test/mock/mock-edge.mjs 18787 18788 "$FAKE_KVS_LOG" &
mock_pid=$!
sleep 1
mkdir -p "$dir/bin"; cp test/mock/fake-aws "$dir/bin/aws"
PATH="$dir/bin:$PATH" VERIFY_SCHEME=http RESULTS_FILE="$dir/results-term.txt" CF_DOMAIN=127.0.0.1:18787 \
  KVS_ARN=fake ORIGIN_A_HOST=origin-a$SFX ORIGIN_B_HOST=origin-b$SFX READY_MAX=20 bash ./verify.sh > /dev/null 2>&1 &
vpid=$!
n=0; while [ ! -s "$dir/results-term.txt" ] && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
echo "leaked $acct and arn:aws:iam::$acct:role/x" >> "$dir/results-term.txt"
sleep 1
kill -TERM "$vpid" 2>/dev/null
wait "$vpid" 2>/dev/null
kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null
if grep -q "$acct" "$dir/results-term.txt" || grep -Eq 'arn:aws:iam' "$dir/results-term.txt"; then
  echo "MOCK TEST FAIL [term]: interrupted run left an unmasked results file"; fail=1
fi

if [ "$fail" = 0 ]; then echo "verify-mock: ok"; else echo "verify-mock: FAILED"; exit 1; fi
