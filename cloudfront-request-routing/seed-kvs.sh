#!/usr/bin/env bash
# Seeds the KeyValueStore route table of the sample. CloudFormation cannot write items without an S3
# import file, so this uses the AWS CLI (data-plane API, needs AWS CLI v2 which bundles SigV4A support).
#
#   ./seed-kvs.sh                 reads the store ARN and origin hosts from the stack outputs
#   KVS_ARN=... ORIGIN_A_HOST=... ORIGIN_B_HOST=... ./seed-kvs.sh     skip the stack lookup
#
# Environment: STACK_NAME (default cfrouting-sample), AWS_REGION (default us-east-1),
#              ALIAS_A / ALIAS_B (optional, only for Host-based routing; lower-case letters, digits, dots, hyphens)
set -euo pipefail

STACK_NAME="${STACK_NAME:-cfrouting-sample}"
REGION="${AWS_REGION:-us-east-1}"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

KVS_ARN="${KVS_ARN:-$(out RouteStoreArn)}"
ORIGIN_A_HOST="${ORIGIN_A_HOST:-$(out OriginAHost)}"
ORIGIN_B_HOST="${ORIGIN_B_HOST:-$(out OriginBHost)}"
ALIAS_A="${ALIAS_A:-}"
ALIAS_B="${ALIAS_B:-}"

# Every value that ends up in JSON must be a plain host name.
valid() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9.:-]+$'; }
for v in "$ORIGIN_A_HOST" "$ORIGIN_B_HOST" "$ALIAS_A" "$ALIAS_B"; do
  if [ -n "$v" ] && ! valid "$v"; then echo "refusing value with unexpected characters: $v" >&2; exit 1; fi
done

# Routes. Keys are lower-case route keys, values are bare backend domain names.
# The bad-* entries are deliberately invalid values, used by test T6 to prove the function fails closed.
pairs=(
  "route-a=${ORIGIN_A_HOST}"
  "route-b=${ORIGIN_B_HOST}"
  "bad-colon=example.net:8443"
  "bad-ip=192.0.2.10"
  "bad-upper=Origin-A.example.net"
  "bad-suffix=origin-a.example.net"
)
if [ -n "$ALIAS_A" ] && [ -n "$ALIAS_B" ]; then
  pairs+=("$(printf '%s' "$ALIAS_A" | tr '[:upper:]' '[:lower:]')=${ORIGIN_A_HOST}")
  pairs+=("$(printf '%s' "$ALIAS_B" | tr '[:upper:]' '[:lower:]')=${ORIGIN_B_HOST}")
fi

if command -v jq >/dev/null 2>&1; then
  puts=$(printf '%s\n' "${pairs[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("=") | {Key: .[0], Value: .[1]})')
else
  # No jq: values were validated above, so plain quoting is safe.
  puts="["
  sep=""
  for p in "${pairs[@]}"; do
    puts="${puts}${sep}{\"Key\":\"${p%%=*}\",\"Value\":\"${p#*=}\"}"
    sep=","
  done
  puts="${puts}]"
fi

etag=$(aws cloudfront-keyvaluestore describe-key-value-store --region "$REGION" --kvs-arn "$KVS_ARN" --query ETag --output text)
aws cloudfront-keyvaluestore update-keys --region "$REGION" --kvs-arn "$KVS_ARN" --if-match "$etag" --puts "$puts" \
  --query ItemCount --output text | sed 's/^/route table items now: /'
echo "Seeded. Changes reach the edge in seconds to minutes; verify.sh waits for them."
