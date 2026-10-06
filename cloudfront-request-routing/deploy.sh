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
#   ROUTE_VARIANT (V1 default; see variants.sh, only for debugging)
#   ORIGIN_AUTH (AWS_IAM|NONE; default AWS_IAM)
#   ENABLE_TEST_BEHAVIORS (true here; the template default is false)
#   DEPLOY_EDGE=true                also deploy the optional Lambda@Edge stack; needs PUBLIC origins, so also set
#                                   ORIGIN_AUTH=NONE (or ACK_PUBLIC_ORIGINS=true, or pass --yes, or answer yes)
#   ACK_BUDGET=true                 skip the check that an AWS Budget exists (you confirm you have one)
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
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) assume_yes=1 ;;
    *) echo "usage: $0 [--yes]" >&2; exit 2 ;;
  esac
done

# --- budget guard: fail closed unless an AWS Budget exists (or you acknowledge with ACK_BUDGET=true).
# Only the error code is printed, never the AWS error text (it can contain account ids and ARNs).
if [ "${ACK_BUDGET:-}" != "true" ]; then
  budget_err=$(mktemp)
  budget_count=""
  if account=$(aws sts get-caller-identity --query Account --output text 2> "$budget_err") &&
     budget_count=$(aws budgets describe-budgets --region us-east-1 --account-id "$account" --query 'length(Budgets)' --output text 2> "$budget_err"); then
    :
  else
    code=$(sed -n 's/.*(\([A-Za-z0-9]*\)).*/\1/p' "$budget_err" | head -1)
    budget_count="unknown:${code:-error}"
  fi
  rm -f "$budget_err"
  case "$budget_count" in
    ''|*[!0-9]*)
      echo "Could not check for an AWS Budget (${budget_count#unknown:}). Create a budget alert first (README, Before you deploy)," >&2
      echo "then re-run, or set ACK_BUDGET=true to confirm you have one." >&2
      exit 1 ;;
    0)
      echo "No AWS Budget found in this account. Create a budget alert first (README, Before you deploy)," >&2
      echo "then re-run, or set ACK_BUDGET=true to confirm you have one." >&2
      exit 1 ;;
    *) echo "Budget check: $budget_count budget(s) found." ;;
  esac
fi

# --- origin exposure. The Lambda@Edge variant needs PUBLIC test origins (Lambda@Edge cannot sign requests to a
# retargeted origin), so it must be asked for explicitly: ORIGIN_AUTH=NONE, or ACK_PUBLIC_ORIGINS=true / --yes,
# or an interactive "yes".
if [ "${DEPLOY_EDGE:-false}" = "true" ]; then
  if [ "${ORIGIN_AUTH+set}" = "set" ] && [ "$ORIGIN_AUTH" != "NONE" ]; then
    echo "DEPLOY_EDGE=true needs public test origins (ORIGIN_AUTH=NONE); you set ORIGIN_AUTH=$ORIGIN_AUTH." >&2; exit 1
  fi
  if [ "${ORIGIN_AUTH:-}" != "NONE" ]; then
    echo "The Lambda@Edge variant requires PUBLIC test origins: anyone who learns a function URL can call it, and you pay for it." >&2
    if [ "$assume_yes" = 1 ] || [ "${ACK_PUBLIC_ORIGINS:-}" = "true" ]; then
      echo "Acknowledged (--yes / ACK_PUBLIC_ORIGINS=true)."
    elif [ -t 0 ]; then
      printf 'Type yes to deploy public test origins: '
      read -r answer
      [ "$answer" = "yes" ] || { echo "Aborted." >&2; exit 1; }
    else
      echo "Refusing: set ORIGIN_AUTH=NONE (or ACK_PUBLIC_ORIGINS=true, or pass --yes) to confirm." >&2; exit 1
    fi
  fi
  ORIGIN_AUTH=NONE
fi
ORIGIN_AUTH="${ORIGIN_AUTH:-AWS_IAM}"
params+=("OriginAuth=$ORIGIN_AUTH")
add RouteVariant "${ROUTE_VARIANT:-}"
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
kv DEFAULT_ORIGIN_HOST "$(out "$STACK_NAME" OriginDefaultHost)"
kv ORIGIN_AUTH "$ORIGIN_AUTH"
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
