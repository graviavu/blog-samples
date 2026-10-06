#!/usr/bin/env bash
# Runs verify.sh against the local mock (no AWS) and checks the machine-readable verdicts. The mock runs the real
# function code with a simplified cache that follows the post's stated rules, and a clock that runs faster than real
# time. This tests the script's logic, parsing, timing code and redaction. It says NOTHING about real CloudFront.
# Takes a few minutes.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=${KEEP:+$KEEP}; dir=${dir:-$(mktemp -d)}; mkdir -p "$dir/bin" "$dir/work"
mock_pid=""
trap 'kill $mock_pid 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$dir"' EXIT
cp test/mock/fake-aws "$dir/bin/aws"
cp verify.sh seed-kvs.sh "$dir/work/"      # run from a copy: a developer's deploy.env must not leak into the test
export FAKE_KVS_LOG="$dir/kvs.log"
fail=0
acct=1234; acct="${acct}56789012"
SPEED=${SPEED:-8}
OHOST=origin.lambda-url.us-east-1.on
OHOST="${OHOST}.aws"

# run_case NAME "VERIFY ENV ASSIGNMENTS" "MOCK ENV ASSIGNMENTS" expected-substrings...
run_case() {
  local name=$1 venv=$2 menv=$3; shift 3
  local anchor
  anchor=$(date +%s)
  : > "$FAKE_KVS_LOG"
  # shellcheck disable=SC2086
  env $menv MOCK_SPEED=$SPEED MOCK_CLOCK_ANCHOR=$anchor PROPAGATION_MS=600 node test/mock/mock-edge.mjs 18787 18788 "$FAKE_KVS_LOG" 18789 &
  mock_pid=$!
  sleep 1
  # shellcheck disable=SC2086
  out=$(cd "$dir/work" && env PATH="$dir/bin:$PATH" VERIFY_SCHEME=http VERIFY_TIME_SCALE=$SPEED MOCK_CLOCK_ANCHOR=$anchor \
    RESULTS_FILE="$dir/results-$name.txt" CF_DOMAIN=127.0.0.1:18787 EDGE_DOMAIN=127.0.0.1:18788 VERIFY_DIRECT_CONNECT=127.0.0.1:18789 \
    ORIGIN_HOST=$OHOST FUNCTION_NAME=fake READY_MAX=20 $venv bash ./verify.sh 2>&1)
  kill $mock_pid 2>/dev/null; wait $mock_pid 2>/dev/null
  for want in "$@"; do
    if ! printf '%s\n' "$out" | grep -q -- "$want"; then echo "MOCK TEST FAIL [$name]: missing '$want'"; fail=1; fi
  done
  [ -s "$dir/results-$name.txt" ] || { echo "MOCK TEST FAIL [$name]: no results file"; fail=1; }
  printf '%s\n' "$out" | grep -E '^TEST=|^SUMMARY' | sed "s/^/  [$name] /"
  LAST_OUT=$out
}

# 1. everything on: query carrier, the whole sample, no deviation from the post's rules
run_case full "KVS_ARN=fake SLOT_CARRIER=query ENABLE_TEST_BEHAVIORS=true DEFMAX=accepted T3_LENGTH=3" "CARRIER=query" \
  'TEST=T0 RESULT=PASS' 'TEST=T10a RESULT=PASS' 'TEST=T10b RESULT=PASS' 'TEST=T10c RESULT=PASS' 'TEST=T10d RESULT=PASS' 'TEST=T10e RESULT=PASS' \
  'TEST=T5a RESULT=PASS' 'TEST=T5b RESULT=PASS' 'TEST=T5c RESULT=PASS' 'TEST=T5d RESULT=PASS' 'TEST=T5e RESULT=PASS' 'TEST=T5f RESULT=PASS' \
  'TEST=T9a RESULT=PASS' 'TEST=T9b RESULT=PASS' 'TEST=T2a RESULT=PASS' 'TEST=T2b RESULT=PASS' 'TEST=T9c RESULT=PASS' \
  'TEST=T3a RESULT=PASS' 'TEST=T3b RESULT=PASS' 'TEST=T3c RESULT=PASS' 'TEST=T3d RESULT=PASS' 'TEST=T4 RESULT=PASS' 'TEST=T4b RESULT=PASS' \
  'SUMMARY pass=23 fail=0 inconclusive=0'

# 2. header carrier, edge stack rewriting errors, default-above-max policy rejected by the API
run_case header "KVS_ARN=fake SLOT_CARRIER=header ENABLE_TEST_BEHAVIORS=true DEFMAX=rejected EDGE_REWRITE_ERRORS=true T3_LENGTH=2" \
  "CARRIER=header EDGE_REWRITE_ERRORS=true" \
  'TEST=T10a RESULT=PASS' 'TEST=T10c RESULT=PASS' 'TEST=T5a RESULT=PASS' 'TEST=T5e RESULT=INCONCLUSIVE' 'TEST=T9c RESULT=PASS' 'TEST=T2a RESULT=PASS' \
  'TEST=T3a RESULT=PASS' 'TEST=T3b RESULT=PASS' 'TEST=T3c RESULT=PASS' 'TEST=T3d RESULT=PASS' 'TEST=T4 RESULT=PASS' 'TEST=T4b RESULT=PASS'

# 3. a deliberately broken mock must produce FAIL (collapsing off, minimum TTL ignored); no KeyValueStore: T3 and T4 inconclusive
run_case broken "ENABLE_TEST_BEHAVIORS=true DEFMAX=off" "MOCK_BREAK=no-collapse,ignore-min" \
  'TEST=T10d RESULT=FAIL' 'TEST=T5a RESULT=FAIL' 'TEST=T5e RESULT=INCONCLUSIVE' 'TEST=T3a RESULT=INCONCLUSIVE' 'TEST=T4 RESULT=INCONCLUSIVE' 'TEST=T2a RESULT=PASS'

# 4. an origin that answers a direct unsigned call is reported as exposed; no test behaviors, no edge stack
run_case exposed "ENABLE_TEST_BEHAVIORS=false EDGE_DOMAIN=" "MOCK_DIRECT_OPEN=1" \
  'TEST=T0 RESULT=FAIL' 'TEST=T5a RESULT=INCONCLUSIVE' 'TEST=T10b RESULT=INCONCLUSIVE' 'TEST=T10e RESULT=INCONCLUSIVE' 'TEST=T2a RESULT=INCONCLUSIVE' 'TEST=T3d RESULT=INCONCLUSIVE' 'TEST=T10a RESULT=PASS'

# 5. AWS CLI failure with an AccessDenied message that contains an account id and ARNs (built at run time)
run_case awsfail "KVS_ARN=fake ENABLE_TEST_BEHAVIORS=false EDGE_DOMAIN= FAKE_AWS_FAIL=1" "CARRIER=query" \
  'TEST=T3a RESULT=INCONCLUSIVE' 'TEST=T4 RESULT=INCONCLUSIVE'
if grep -q "$acct" "$dir/results-awsfail.txt" || grep -Eq 'arn:aws[a-z-]*:(iam|cloudfront)' "$dir/results-awsfail.txt"; then
  echo "MOCK TEST FAIL [awsfail]: results file contains an account id or ARN"; fail=1
fi
grep -q 'error-code=AccessDeniedException' "$dir/results-awsfail.txt" || { echo "MOCK TEST FAIL [awsfail]: error code not logged"; fail=1; }
if printf '%s\n' "$LAST_OUT" | grep -q "$acct"; then echo "MOCK TEST FAIL [awsfail]: console output contains an account id"; fail=1; fi
printf '%s\n' "$LAST_OUT" | grep -q 'AccessDeniedException' || { echo "MOCK TEST FAIL [awsfail]: error code not shown"; fail=1; }

# 6. results file facts from the full run: machine lines, the T3 timeline, sampler cells, burst summaries
r="$dir/results-full.txt"
grep -q '^TEST=T3b RESULT=PASS' "$r" || { echo "MOCK TEST FAIL [full]: machine lines missing from the results file"; fail=1; }
grep -q '# T3 timeline' "$r" || { echo "MOCK TEST FAIL [full]: T3 timeline missing"; fail=1; }
grep -q '### cell .* T5a p-b/maxage-5' "$r" || { echo "MOCK TEST FAIL [full]: sampler cells missing"; fail=1; }
grep -q '# burst T10d' "$r" || { echo "MOCK TEST FAIL [full]: burst summary missing"; fail=1; }

# 7. the final redaction pass on its own: masks 12-digit numbers and ARNs, keeps 13-digit epoch values
eval "$(sed -n '/^redact_results()/,/^}/p' verify.sh)"
printf 'a arn:aws:iam::%s:role/x b %s c 1760000000000 d\n' "$acct" "$acct" > "$dir/redact.txt"
redact_results "$dir/redact.txt"
if grep -q "$acct" "$dir/redact.txt" || grep -q 'arn:aws:iam' "$dir/redact.txt" || ! grep -q 1760000000000 "$dir/redact.txt"; then
  echo "MOCK TEST FAIL [redact]: $(cat "$dir/redact.txt")"; fail=1
fi

# 8. interrupted run (TERM): the exit trap must leave a masked results file
node test/mock/mock-edge.mjs 18787 18788 "$FAKE_KVS_LOG" 18789 &
mock_pid=$!
sleep 1
rm -f "$dir/results-term.txt"
( cd "$dir/work" && exec env PATH="$dir/bin:$PATH" VERIFY_SCHEME=http RESULTS_FILE="$dir/results-term.txt" CF_DOMAIN=127.0.0.1:18787 \
    ENABLE_TEST_BEHAVIORS=true READY_MAX=20 bash ./verify.sh > /dev/null 2>&1 ) &
vpid=$!
n=0; while [ ! -s "$dir/results-term.txt" ] && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
sleep 1
echo "leaked $acct and arn:aws:iam::$acct:role/x" >> "$dir/results-term.txt"
kill -TERM "$vpid" 2>/dev/null
wait "$vpid" 2>/dev/null
kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null
if grep -q "$acct" "$dir/results-term.txt" || grep -Eq 'arn:aws:iam' "$dir/results-term.txt"; then
  echo "MOCK TEST FAIL [term]: interrupted run left an unmasked results file"; fail=1
fi

if [ "$fail" = 0 ]; then echo "verify-mock: ok"; else echo "verify-mock: FAILED"; exit 1; fi
