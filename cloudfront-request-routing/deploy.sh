#!/usr/bin/env bash
# Deploys the sample with the AWS CLI, seeds the route table and writes deploy.env for verify.sh.
# Run it from this folder. Needs AWS credentials for a TEST account. Creates real resources that cost money
# per request: read "Before you deploy" in the README first (budget alert), and run teardown.sh when done.
#
# Optional environment:
#   STACK_NAME (cfrouting-sample)  NAME_PREFIX (cfrouting)  AWS_REGION (must be us-east-1)
#   ROUTE_ATTRIBUTE (x-backend|host)  CACHE_KEY_ATTRIBUTE (x-backend|host|none)
#   ALIAS_A ALIAS_B CERT_ARN        all three, for the Host-based tests (aliases: lower-case a-z 0-9 . -)
#   COST_TAG_KEY (project)
#   ENABLE_TEST_BEHAVIORS (true here; the template default is false)
#   DEPLOY_EDGE=true                also deploy the optional Lambda@Edge stack
#   EDGE_STACK_NAME (<STACK_NAME>-edge)  EDGE_NAME_PREFIX (cfrouting-edge)
set -euo pipefail
cd "$(dirname "$0")" || exit 1

STACK_NAME="${STACK_NAME:-cfrouting-sample}"
NAME_PREFIX="${NAME_PREFIX:-cfrouting}"
EDGE_NAME_PREFIX="${EDGE_NAME_PREFIX:-cfrouting-edge}"
EDGE_STACK_NAME="${EDGE_STACK_NAME:-${STACK_NAME}-edge}"
REGION="${AWS_REGION:-us-east-1}"
ALIAS_A="${ALIAS_A:-}"
ALIAS_B="${ALIAS_B:-}"
[ "$REGION" = "us-east-1" ] || { echo "Use us-east-1 (AWS_REGION=$REGION)"; exit 1; }

for v in "$ALIAS_A" "$ALIAS_B"; do
  if [ -n "$v" ] && ! printf '%s' "$v" | grep -Eq '^[a-z0-9.-]+$'; then
    echo "Alias domains must match ^[a-z0-9.-]+\$ (lower case): '$v'" >&2; exit 1
  fi
done
printf '%s' "$NAME_PREFIX" | grep -Eq '^[a-z][a-z0-9-]{0,19}$' || { echo "bad NAME_PREFIX" >&2; exit 1; }
printf '%s' "$EDGE_NAME_PREFIX" | grep -Eq '^[a-z][a-z0-9-]{0,19}$' || { echo "bad EDGE_NAME_PREFIX" >&2; exit 1; }

params=("NamePrefix=$NAME_PREFIX" "EnableTestBehaviors=${ENABLE_TEST_BEHAVIORS:-true}")
add() { [ -z "${2:-}" ] || params+=("$1=$2"); }
add RouteAttribute "${ROUTE_ATTRIBUTE:-}"
add CacheKeyAttribute "${CACHE_KEY_ATTRIBUTE:-}"
add AliasDomainA "$ALIAS_A"
add AliasDomainB "$ALIAS_B"
add CertificateArn "${CERT_ARN:-}"
add CostTagKey "${COST_TAG_KEY:-}"

echo "Deploying stack $STACK_NAME (a CloudFront distribution usually takes 5 to 15 minutes)..."
aws cloudformation deploy --region "$REGION" --stack-name "$STACK_NAME" \
  --template-file template.yaml --capabilities CAPABILITY_IAM \
  --tags sample=cloudfront-request-routing \
  --parameter-overrides "${params[@]}"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

export STACK_NAME
ORIGIN_A_HOST=$(out "$STACK_NAME" OriginAHost)
ORIGIN_B_HOST=$(out "$STACK_NAME" OriginBHost)
export ORIGIN_A_HOST ORIGIN_B_HOST ALIAS_A ALIAS_B
./seed-kvs.sh

# deploy.env is sourced by verify.sh and teardown.sh, so every value is shell-quoted with printf %q.
kv() { printf '%s=%q\n' "$1" "$2" >> deploy.env; }
{
  echo "# Written by deploy.sh. Sourced by verify.sh and teardown.sh. Contains no secrets. Do not commit."
} > deploy.env
kv CF_DOMAIN "$(out "$STACK_NAME" DistributionDomain)"
kv STACK_NAME "$STACK_NAME"
kv NAME_PREFIX "$NAME_PREFIX"
kv EDGE_STACK_NAME "$EDGE_STACK_NAME"
kv EDGE_NAME_PREFIX "$EDGE_NAME_PREFIX"
kv KVS_ARN "$(out "$STACK_NAME" RouteStoreArn)"
kv ORIGIN_A_HOST "$ORIGIN_A_HOST"
kv ORIGIN_B_HOST "$ORIGIN_B_HOST"
kv ROUTE_ATTRIBUTE "$(out "$STACK_NAME" RouteAttribute)"
kv CACHE_KEY_ATTRIBUTE "$(out "$STACK_NAME" CacheKeyAttribute)"
kv ALIAS_A "$ALIAS_A"
kv ALIAS_B "$ALIAS_B"
kv FUNCTION_NAME "${NAME_PREFIX}-route"

if [ "${DEPLOY_EDGE:-false}" = "true" ]; then
  echo "Deploying optional Lambda@Edge stack $EDGE_STACK_NAME..."
  aws cloudformation deploy --region "$REGION" --stack-name "$EDGE_STACK_NAME" \
    --template-file template-lambda-edge.yaml --capabilities CAPABILITY_IAM \
    --tags sample=cloudfront-request-routing \
    --parameter-overrides "NamePrefix=$EDGE_NAME_PREFIX" "OriginAHost=$ORIGIN_A_HOST" "OriginBHost=$ORIGIN_B_HOST" \
      "DefaultOriginHost=$(out "$STACK_NAME" OriginDefaultHost)"
  kv EDGE_DOMAIN "$(out "$EDGE_STACK_NAME" EdgeDistributionDomain)"
fi

echo "Done. Next: ./verify.sh   Then, immediately: ./teardown.sh (the stack should live hours, not days)."
