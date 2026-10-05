#!/usr/bin/env bash
# Seeds the KeyValueStore route table of the sample. CloudFormation cannot write items without an S3
# import file, so this uses the AWS CLI (data-plane API, needs AWS CLI v2 which bundles SigV4A support).
#
#   ./seed-kvs.sh                 reads the store ARN and origin hosts from the stack outputs
#   KVS_ARN=... ORIGIN_A_HOST=... ORIGIN_B_HOST=... ./seed-kvs.sh     skip the stack lookup
#
# Environment: STACK_NAME (default cfrouting-sample), AWS_REGION (default us-east-1),
#              ALIAS_A / ALIAS_B (optional, only for Host-based routing)
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

# Routes. Keys are lower-case route keys, values are bare backend domain names.
# The bad-* entries are deliberately invalid values, used by test T6 to prove the function fails closed.
puts="[
 {\"Key\":\"route-a\",\"Value\":\"${ORIGIN_A_HOST}\"},
 {\"Key\":\"route-b\",\"Value\":\"${ORIGIN_B_HOST}\"},
 {\"Key\":\"bad-colon\",\"Value\":\"example.net:8443\"},
 {\"Key\":\"bad-ip\",\"Value\":\"192.0.2.10\"},
 {\"Key\":\"bad-upper\",\"Value\":\"Origin-A.example.net\"}"
if [ -n "$ALIAS_A" ] && [ -n "$ALIAS_B" ]; then
  a=$(printf '%s' "$ALIAS_A" | tr '[:upper:]' '[:lower:]')
  b=$(printf '%s' "$ALIAS_B" | tr '[:upper:]' '[:lower:]')
  puts="${puts},
 {\"Key\":\"${a}\",\"Value\":\"${ORIGIN_A_HOST}\"},
 {\"Key\":\"${b}\",\"Value\":\"${ORIGIN_B_HOST}\"}"
fi
puts="${puts}
]"

etag=$(aws cloudfront-keyvaluestore describe-key-value-store --region "$REGION" --kvs-arn "$KVS_ARN" --query ETag --output text)
aws cloudfront-keyvaluestore update-keys --region "$REGION" --kvs-arn "$KVS_ARN" --if-match "$etag" --puts "$puts" \
  --query ItemCount --output text | sed 's/^/route table items now: /'
echo "Seeded. Changes reach the edge in seconds to minutes; verify.sh waits for them."
