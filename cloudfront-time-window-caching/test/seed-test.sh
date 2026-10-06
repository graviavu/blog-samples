#!/usr/bin/env bash
# Tests seed-kvs.sh with a fake aws CLI (no AWS): argument validation, the JSON it writes, relative windows and
# the refusal to write a window across midnight.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/bin"
cp test/mock/fake-aws "$dir/bin/aws"
export FAKE_KVS_LOG="$dir/kvs.log" FAKE_CALLS="$dir/calls.log" KVS_ARN=fake-kvs-arn
fail=0
check() { if [ "$2" -ne 0 ]; then echo "SEED TEST FAIL: $1"; fail=1; fi; }
seed() { : > "$FAKE_KVS_LOG"; : > "$FAKE_CALLS"; PATH="$dir/bin:$PATH" bash ./seed-kvs.sh "$@" > "$dir/out.txt" 2>&1; echo $?; }
written() { awk '{print $4}' "$FAKE_KVS_LOG" | tail -1; }
wrote() { [ "$(written)" = "$1" ] && echo 0 || echo 1; }

rc=$(seed); check "default window succeeds" "$([ "$rc" = 0 ] && echo 0 || echo 1)"
check "default is the post's example" "$(wrote '{"startMin":810,"endMin":1200,"slotSeconds":5,"rev":1}')"
check "key is window" "$(grep -q ' put window ' "$FAKE_KVS_LOG" && echo 0 || echo 1)"
check "uses the ETag" "$(grep -q 'if-match etag-1' "$FAKE_CALLS" && echo 0 || echo 1)"

rc=$(seed --start-min 100 --end-min 200 --slot-seconds 10 --rev 7); check "explicit window" "$(wrote '{"startMin":100,"endMin":200,"slotSeconds":10,"rev":7}')"

for bad in "--start-min 200 --end-min 100" "--start-min 100 --end-min 100" "--start-min 1380 --end-min 60" "--start-min 0 --end-min 1441" \
           "--start-min 1440 --end-min 1440" "--slot-seconds 0" "--slot-seconds 3601" "--rev 1000000" "--start-min abc" "--start-min -1" \
           "--starts-in 2" "--length 3" "--starts-in 2 --length 3 --start-min 5" "--bogus" "--start-min"; do
  # shellcheck disable=SC2086
  rc=$(seed $bad)
  check "rejects '$bad'" "$([ "$rc" != 0 ] && echo 0 || echo 1)"
  check "'$bad' writes nothing" "$([ -s "$FAKE_KVS_LOG" ] && echo 1 || echo 0)"
done

# relative window: opens in 2 minutes, lasts 4 (skipped near midnight UTC, where the script correctly refuses)
rc=$(seed --starts-in 2 --length 4 --slot-seconds 10 --rev 9)
now_min=$(( 10#$(date -u +%H) * 60 + 10#$(date -u +%M) ))
if [ "$now_min" -lt 1430 ]; then
  s=$(( now_min + 2 )); e=$(( s + 4 ))
  # the minute may roll over between the two date calls: accept start +0 or +1
  if [ "$(written)" = "{\"startMin\":$s,\"endMin\":$e,\"slotSeconds\":10,\"rev\":9}" ] || \
     [ "$(written)" = "{\"startMin\":$((s + 1)),\"endMin\":$((e + 1)),\"slotSeconds\":10,\"rev\":9}" ]; then :; else
    echo "SEED TEST FAIL: relative window: $(written) (now minute $now_min)"; fail=1
  fi
else
  check "near midnight the relative window is refused" "$([ "$rc" != 0 ] && echo 0 || echo 1)"
fi

# raw values: only plain characters, written as given
rc=$(seed --raw '{"startMin":"x"}'); check "raw value written" "$(wrote '{"startMin":"x"}')"
# shellcheck disable=SC2016
for bad in '$(touch x)' 'a b' '`id`' 'x;y' "it's"; do
  rc=$(seed --raw "$bad"); check "raw '$bad' rejected" "$([ "$rc" != 0 ] && echo 0 || echo 1)"
  check "raw '$bad' writes nothing" "$([ -s "$FAKE_KVS_LOG" ] && echo 1 || echo 0)"
done

KVS_ARN='bad arn;x' rc=$(KVS_ARN='bad arn;x' seed); check "bad KVS_ARN rejected" "$([ "$rc" != 0 ] && echo 0 || echo 1)"

if [ "$fail" = 0 ]; then echo "seed-test: ok"; else echo "seed-test: FAILED"; exit 1; fi
