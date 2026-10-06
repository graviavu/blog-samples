#!/usr/bin/env bash
# Writes the window record (KeyValueStore key "window") of the sample. CloudFormation cannot write items without an
# S3 import file, so this uses the AWS CLI data-plane API (AWS CLI v2, which bundles the SigV4A signing it needs).
# The value is the JSON the function reads: {"startMin":..,"endMin":..,"slotSeconds":..,"rev":..}, UTC minutes
# since midnight, startMin < endMin on the same UTC day (a window across 00:00 UTC is not supported in part 1).
#
#   ./seed-kvs.sh                                   the post's example window 810 to 1200, 5 s slots, rev 1
#   ./seed-kvs.sh --start-min 810 --end-min 1200 [--slot-seconds 5] [--rev 1]
#   ./seed-kvs.sh --starts-in 2 --length 4 [--slot-seconds 10] [--rev N]
#                                                   a short window relative to now: opens in about 2 minutes
#                                                   (the next minute boundary after that), lasts 4 minutes
#   ./seed-kvs.sh --raw '{"startMin":"x"}'          writes a value WITHOUT validation, to try the fail-closed path
#
# Environment: KVS_ARN (or STACK_NAME, default cftw-sample, to read it from the stack outputs), AWS_REGION (us-east-1).
set -euo pipefail

STACK_NAME="${STACK_NAME:-cftw-sample}"
REGION="${AWS_REGION:-us-east-1}"
start_min=""; end_min=""; slot=""; rev=""; starts_in=""; length=""; raw=""

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
int() { printf '%s' "$2" | grep -Eq '^[0-9]{1,7}$' || { echo "$1 must be a non-negative integer: '$2'" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --start-min) [ $# -ge 2 ] || usage; int "$1" "$2"; start_min=$2; shift 2 ;;
    --end-min) [ $# -ge 2 ] || usage; int "$1" "$2"; end_min=$2; shift 2 ;;
    --slot-seconds) [ $# -ge 2 ] || usage; int "$1" "$2"; slot=$2; shift 2 ;;
    --rev) [ $# -ge 2 ] || usage; int "$1" "$2"; rev=$2; shift 2 ;;
    --starts-in) [ $# -ge 2 ] || usage; int "$1" "$2"; starts_in=$2; shift 2 ;;
    --length) [ $# -ge 2 ] || usage; int "$1" "$2"; length=$2; shift 2 ;;
    --raw) [ $# -ge 2 ] || usage; raw=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

if [ -n "$raw" ]; then
  # Only plain characters: the value goes into a command line and a JSON store, never through a shell.
  printf '%s' "$raw" | grep -Eq '^[A-Za-z0-9{}":,._-]{1,200}$' || { echo "--raw: only letters, digits and { } \" : , . _ - are allowed" >&2; exit 2; }
  value=$raw
  echo "WARNING: writing an unvalidated value (this is how to test the fail-closed path)." >&2
else
  if [ -n "$starts_in" ] || [ -n "$length" ]; then
    [ -n "$starts_in" ] && [ -n "$length" ] || { echo "--starts-in and --length go together" >&2; exit 2; }
    [ -z "$start_min$end_min" ] || { echo "use either --start-min/--end-min or --starts-in/--length" >&2; exit 2; }
    now_min=$(( 10#$(date -u +%H) * 60 + 10#$(date -u +%M) ))
    start_min=$(( now_min + starts_in ))
    end_min=$(( start_min + length ))
  fi
  start_min=${start_min:-810}; end_min=${end_min:-1200}; slot=${slot:-5}; rev=${rev:-1}
  [ "$start_min" -ge 0 ] && [ "$start_min" -le 1439 ] || { echo "start minute out of range 0..1439 ($start_min): too close to midnight UTC for a relative window? Try again after 00:00 UTC." >&2; exit 2; }
  [ "$end_min" -ge 1 ] && [ "$end_min" -le 1440 ] || { echo "end minute out of range 1..1440 ($end_min): the window would cross 00:00 UTC, which part 1 does not support. Try again after 00:00 UTC." >&2; exit 2; }
  [ "$start_min" -lt "$end_min" ] || { echo "start must be below end (a window across midnight is not supported)" >&2; exit 2; }
  [ "$slot" -ge 1 ] && [ "$slot" -le 3600 ] || { echo "slot seconds out of range 1..3600" >&2; exit 2; }
  [ "$rev" -le 999999 ] || { echo "rev out of range 0..999999" >&2; exit 2; }
  value=$(printf '{"startMin":%d,"endMin":%d,"slotSeconds":%d,"rev":%d}' "$start_min" "$end_min" "$slot" "$rev")
fi

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
KVS_ARN="${KVS_ARN:-$(out WindowStoreArn)}"
printf '%s' "$KVS_ARN" | grep -Eq '^[A-Za-z0-9:/._-]+$' || { echo "KVS_ARN missing or with unexpected characters" >&2; exit 1; }

etag=$(aws cloudfront-keyvaluestore describe-key-value-store --region "$REGION" --kvs-arn "$KVS_ARN" --query ETag --output text)
aws cloudfront-keyvaluestore put-key --region "$REGION" --kvs-arn "$KVS_ARN" --key window --value "$value" --if-match "$etag" \
  --query ItemCount --output text | sed 's/^/window record written, items in the store: /'
echo "SEEDED $value"
echo "Changes reach the edge in seconds to minutes (test T4 measures it)."
