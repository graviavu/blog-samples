#!/usr/bin/env bash
# Runs verify.sh against the local mock (no AWS) and checks the machine-readable verdicts.
# This tests the script's logic and parsing; it says nothing about real CloudFront behavior.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=$(mktemp -d)
trap 'kill $mock_pid 2>/dev/null; rm -rf "$dir"' EXIT
export FAKE_KVS_LOG="$dir/kvs.log"
fail=0

run_case() { # name key-attribute expected-substrings...
  local name=$1 keyattr=$2; shift 2
  CACHE_KEY_ATTRIBUTE=$keyattr PROPAGATION_MS=3000 node test/mock/mock-edge.mjs 18787 18788 "$FAKE_KVS_LOG" &
  mock_pid=$!
  sleep 1
  mkdir -p "$dir/bin"; cp test/mock/fake-aws "$dir/bin/aws"
  out=$(PATH="$dir/bin:$PATH" VERIFY_SCHEME=http RESULTS_FILE="$dir/results-$name.txt" CF_DOMAIN=127.0.0.1:18787 EDGE_DOMAIN=127.0.0.1:18788 \
    KVS_ARN=fake ORIGIN_A_HOST=origin-a.example.net ORIGIN_B_HOST=origin-b.example.net FUNCTION_NAME=fake \
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
  'TEST=T1a RESULT=PASS' 'TEST=T1b RESULT=PASS' 'TEST=T1c RESULT=PASS' 'TEST=T4 RESULT=PASS' \
  'TEST=T6a RESULT=PASS' 'TEST=T6b RESULT=PASS' 'TEST=T6c RESULT=PASS' 'TEST=T6d RESULT=PASS' 'TEST=T6e RESULT=PASS' \
  'TEST=T6f RESULT=PASS' 'TEST=T6g RESULT=PASS' 'TEST=T7 RESULT=PASS' 'TEST=T8 RESULT=PASS' 'SUMMARY pass=.* fail=0'

# Same stack but the attribute is NOT in the cache key: T1b must now expect (and see) the shared entry.
run_case unkeyed none 'TEST=T1a RESULT=PASS' 'TEST=T1b RESULT=PASS'

if [ "$fail" = 0 ]; then echo "verify-mock: ok"; else echo "verify-mock: FAILED"; exit 1; fi
