#!/usr/bin/env bash
# Deploys the sample with the AWS CLI, seeds the route table and writes deploy.env for verify.sh.
# Run it from this folder. Needs AWS credentials for a TEST account. Creates real (cheap) resources.
#
# Optional environment:
#   STACK_NAME (cfrouting-sample)  NAME_PREFIX (cfrouting)  AWS_REGION (must be us-east-1)
#   ROUTE_ATTRIBUTE (x-backend|host)  CACHE_KEY_ATTRIBUTE (x-backend|host|none)
#   ALIAS_A ALIAS_B CERT_ARN        all three, for the Host-based tests
#   COST_TAG_KEY (project)  ENABLE_TEST_BEHAVIORS (true|false)
#   DEPLOY_EDGE=true                also deploy the optional Lambda@Edge stack
set -euo pipefail
cd "$(dirname "$0")" || exit 1

STACK_NAME="${STACK_NAME:-cfrouting-sample}"
REGION="${AWS_REGION:-us-east-1}"
[ "$REGION" = "us-east-1" ] || { echo "Use us-east-1 (AWS_REGION=$REGION)"; exit 1; }

params=()
add() { [ -z "${2:-}" ] || params+=("$1=$2"); }
add NamePrefix "${NAME_PREFIX:-}"
add RouteAttribute "${ROUTE_ATTRIBUTE:-}"
add CacheKeyAttribute "${CACHE_KEY_ATTRIBUTE:-}"
add AliasDomainA "${ALIAS_A:-}"
add AliasDomainB "${ALIAS_B:-}"
add CertificateArn "${CERT_ARN:-}"
add CostTagKey "${COST_TAG_KEY:-}"
add EnableTestBehaviors "${ENABLE_TEST_BEHAVIORS:-}"

echo "Deploying stack $STACK_NAME (a CloudFront distribution usually takes 5 to 15 minutes)..."
aws cloudformation deploy --region "$REGION" --stack-name "$STACK_NAME" \
  --template-file template.yaml --capabilities CAPABILITY_IAM \
  --tags sample=cloudfront-request-routing \
  --parameter-overrides "${params[@]+"${params[@]}"}"

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

export STACK_NAME
ORIGIN_A_HOST=$(out "$STACK_NAME" OriginAHost)
ORIGIN_B_HOST=$(out "$STACK_NAME" OriginBHost)
export ORIGIN_A_HOST ORIGIN_B_HOST ALIAS_A ALIAS_B
./seed-kvs.sh

: > deploy.env
{
  echo "# Written by deploy.sh. Sourced by verify.sh and teardown.sh. Contains no secrets. Do not commit."
  echo "CF_DOMAIN='$(out "$STACK_NAME" DistributionDomain)'"
  echo "STACK_NAME='$STACK_NAME'"
  echo "KVS_ARN='$(out "$STACK_NAME" RouteStoreArn)'"
  echo "ORIGIN_A_HOST='$ORIGIN_A_HOST'"
  echo "ORIGIN_B_HOST='$ORIGIN_B_HOST'"
  echo "ROUTE_ATTRIBUTE='$(out "$STACK_NAME" RouteAttribute)'"
  echo "CACHE_KEY_ATTRIBUTE='$(out "$STACK_NAME" CacheKeyAttribute)'"
  echo "ALIAS_A='${ALIAS_A:-}'"
  echo "ALIAS_B='${ALIAS_B:-}'"
  echo "FUNCTION_NAME='${NAME_PREFIX:-cfrouting}-route'"
} >> deploy.env

if [ "${DEPLOY_EDGE:-false}" = "true" ]; then
  EDGE_STACK="${EDGE_STACK_NAME:-${STACK_NAME}-edge}"
  echo "Deploying optional Lambda@Edge stack $EDGE_STACK..."
  aws cloudformation deploy --region "$REGION" --stack-name "$EDGE_STACK" \
    --template-file template-lambda-edge.yaml --capabilities CAPABILITY_IAM \
    --tags sample=cloudfront-request-routing \
    --parameter-overrides "OriginAHost=$ORIGIN_A_HOST" "OriginBHost=$ORIGIN_B_HOST" \
      "DefaultOriginHost=$(out "$STACK_NAME" OriginDefaultHost)"
  {
    echo "EDGE_STACK_NAME='$EDGE_STACK'"
    echo "EDGE_DOMAIN='$(out "$EDGE_STACK" EdgeDistributionDomain)'"
  } >> deploy.env
fi

echo "Done. Next: ./verify.sh"
