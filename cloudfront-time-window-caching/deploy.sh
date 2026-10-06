#!/usr/bin/env bash
# Deploys the sample with the AWS CLI, seeds the window record and writes deploy.env for verify.sh.
# Run it from this folder. Needs AWS credentials for a TEST account. Creates real resources that cost money
# per request: read "Before you deploy" in the README first (budget alert), and run teardown.sh when done.
#
# Optional environment:
#   STACK_NAME (cftw-sample)  NAME_PREFIX (cftw)  AWS_REGION (must be us-east-1)
#   SLOT_CARRIER (query|header)       how the slot reaches the cache key (default query, the post's sketch)
#   CLOSED_MIN_TTL (600)              minimum TTL of the window cache policy, seconds (600 to 3600)
#   COST_TAG_KEY (project)
#   ENABLE_TEST_BEHAVIORS (true here; the template default is false)
#   TRY_DEFAULT_ABOVE_MAX (true here): after the main deploy, try a second update that adds the policy whose default TTL
#                                   is above its maximum TTL (test T5e). If CloudFront refuses it, the update is rolled
#                                   back, the stack stays healthy and deploy.env records DEFMAX=rejected.
#   DEPLOY_EDGE=true                also deploy the optional Lambda@Edge stack (Option B; deleting it can take hours)
#   EDGE_WINDOW_START_MIN (0) EDGE_WINDOW_END_MIN (1440) EDGE_IN_TTL (15) EDGE_OUT_TTL (45)
#   EDGE_REWRITE_ERRORS (false)       true also rewrites 4xx/5xx (test T9 on the edge stack)
#   ACK_BUDGET=true                   skip the check that an AWS Budget exists (you confirm you have one)
#   EDGE_STACK_NAME (<STACK_NAME>-edge)  EDGE_NAME_PREFIX (cftw-edge)
set -euo pipefail
cd "$(dirname "$0")" || exit 1

STACK_NAME="${STACK_NAME:-cftw-sample}"
NAME_PREFIX="${NAME_PREFIX:-cftw}"
EDGE_NAME_PREFIX="${EDGE_NAME_PREFIX:-cftw-edge}"
EDGE_STACK_NAME="${EDGE_STACK_NAME:-${STACK_NAME}-edge}"
REGION="${AWS_REGION:-us-east-1}"
SLOT_CARRIER="${SLOT_CARRIER:-query}"
CLOSED_MIN_TTL="${CLOSED_MIN_TTL:-600}"
ENABLE_TEST_BEHAVIORS="${ENABLE_TEST_BEHAVIORS:-true}"
TRY_DEFAULT_ABOVE_MAX="${TRY_DEFAULT_ABOVE_MAX:-true}"
EDGE_WINDOW_START_MIN="${EDGE_WINDOW_START_MIN:-0}"
EDGE_WINDOW_END_MIN="${EDGE_WINDOW_END_MIN:-1440}"
EDGE_IN_TTL="${EDGE_IN_TTL:-15}"
EDGE_OUT_TTL="${EDGE_OUT_TTL:-45}"
EDGE_REWRITE_ERRORS="${EDGE_REWRITE_ERRORS:-false}"
[ "$REGION" = "us-east-1" ] || { echo "Use us-east-1 (AWS_REGION=$REGION)"; exit 1; }

# All inputs are validated before they reach a command line, and deploy.env is written with printf %q.
printf '%s' "$NAME_PREFIX" | grep -Eq '^[a-z][a-z0-9-]{0,19}$' || { echo "bad NAME_PREFIX" >&2; exit 1; }
printf '%s' "$EDGE_NAME_PREFIX" | grep -Eq '^[a-z][a-z0-9-]{0,19}$' || { echo "bad EDGE_NAME_PREFIX" >&2; exit 1; }
printf '%s' "$STACK_NAME" | grep -Eq '^[A-Za-z][A-Za-z0-9-]{0,63}$' || { echo "bad STACK_NAME" >&2; exit 1; }
printf '%s' "$EDGE_STACK_NAME" | grep -Eq '^[A-Za-z][A-Za-z0-9-]{0,63}$' || { echo "bad EDGE_STACK_NAME" >&2; exit 1; }
case "$SLOT_CARRIER" in query|header) ;; *) echo "SLOT_CARRIER must be query or header" >&2; exit 1 ;; esac
case "$ENABLE_TEST_BEHAVIORS" in true|false) ;; *) echo "ENABLE_TEST_BEHAVIORS must be true or false" >&2; exit 1 ;; esac
case "$TRY_DEFAULT_ABOVE_MAX" in true|false) ;; *) echo "TRY_DEFAULT_ABOVE_MAX must be true or false" >&2; exit 1 ;; esac
case "$EDGE_REWRITE_ERRORS" in true|false) ;; *) echo "EDGE_REWRITE_ERRORS must be true or false" >&2; exit 1 ;; esac
for v in CLOSED_MIN_TTL EDGE_WINDOW_START_MIN EDGE_WINDOW_END_MIN EDGE_IN_TTL EDGE_OUT_TTL; do
  printf '%s' "${!v}" | grep -Eq '^[0-9]{1,5}$' || { echo "$v must be an integer" >&2; exit 1; }
done
[ "$CLOSED_MIN_TTL" -ge 600 ] && [ "$CLOSED_MIN_TTL" -le 3600 ] || { echo "CLOSED_MIN_TTL must be 600..3600" >&2; exit 1; }
[ "$EDGE_WINDOW_START_MIN" -lt "$EDGE_WINDOW_END_MIN" ] && [ "$EDGE_WINDOW_END_MIN" -le 1440 ] || {
  echo "EDGE_WINDOW_START_MIN must be below EDGE_WINDOW_END_MIN (max 1440); a window across midnight is not supported" >&2; exit 1; }
[ "$EDGE_IN_TTL" -le 3600 ] && [ "$EDGE_OUT_TTL" -le 3600 ] || { echo "edge TTLs must be at most 3600" >&2; exit 1; }
if [ -n "$(printf '%s' "${COST_TAG_KEY:-}" | tr -d 'A-Za-z0-9:_./-')" ]; then echo "bad COST_TAG_KEY" >&2; exit 1; fi

params=("NamePrefix=$NAME_PREFIX" "SlotCarrier=$SLOT_CARRIER" "ClosedMinTtl=$CLOSED_MIN_TTL" "EnableTestBehaviors=$ENABLE_TEST_BEHAVIORS")
[ -z "${COST_TAG_KEY:-}" ] || params+=("CostTagKey=$COST_TAG_KEY")
[ $# -eq 0 ] || { echo "usage: $0 (configure with environment variables, see the header)" >&2; exit 2; }

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

out() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
  --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }

cfn_deploy() { # extra parameter overrides...
  aws cloudformation deploy --region "$REGION" --stack-name "$STACK_NAME" \
    --template-file template.yaml --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
    --tags sample=cloudfront-time-window-caching \
    --parameter-overrides "${params[@]}" "$@"
}

echo "Deploying stack $STACK_NAME (a CloudFront distribution usually takes 5 to 15 minutes)..."
cfn_deploy TryDefaultAboveMax=false

DEFMAX=off
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ] && [ "$TRY_DEFAULT_ABOVE_MAX" = "true" ]; then
  echo "Trying the optional policy whose default TTL (60) is above its maximum TTL (20) in a second update (test T5e)..."
  if cfn_deploy TryDefaultAboveMax=true; then
    DEFMAX=accepted
  else
    DEFMAX=rejected
    echo "CloudFront or CloudFormation refused that update, and CloudFormation rolled it back: the stack is unchanged and healthy." >&2
    echo "That refusal is itself the answer for test T5e (a default TTL above the maximum TTL is not accepted). Reason (from the stack events):" >&2
    aws cloudformation describe-stack-events --region "$REGION" --stack-name "$STACK_NAME" \
      --query "StackEvents[?ResourceStatus=='UPDATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output text 2>&1 | head -5 >&2 || true
  fi
fi

export STACK_NAME
KVS_ARN=$(out "$STACK_NAME" WindowStoreArn)
export KVS_ARN
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
kv KVS_ARN "$KVS_ARN"
kv ORIGIN_HOST "$(out "$STACK_NAME" OriginHost)"
kv SLOT_CARRIER "$SLOT_CARRIER"
kv CLOSED_MIN_TTL "$CLOSED_MIN_TTL"
kv ENABLE_TEST_BEHAVIORS "$ENABLE_TEST_BEHAVIORS"
kv DEFMAX "$DEFMAX"
kv FUNCTION_NAME "${NAME_PREFIX}-slot"

if [ "${DEPLOY_EDGE:-false}" = "true" ]; then
  echo "Deploying optional Lambda@Edge stack $EDGE_STACK_NAME (Option B). Deleting it later can take hours..."
  aws cloudformation deploy --region "$REGION" --stack-name "$EDGE_STACK_NAME" \
    --template-file template-lambda-edge.yaml --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset \
    --tags sample=cloudfront-time-window-caching \
    --parameter-overrides "NamePrefix=$EDGE_NAME_PREFIX" "OriginHost=$(out "$STACK_NAME" OriginHost)" \
      "OriginFunctionName=$(out "$STACK_NAME" OriginFunctionName)" \
      "WindowStartMin=$EDGE_WINDOW_START_MIN" "WindowEndMin=$EDGE_WINDOW_END_MIN" \
      "InTtl=$EDGE_IN_TTL" "OutTtl=$EDGE_OUT_TTL" "RewriteErrors=$EDGE_REWRITE_ERRORS"
  kv EDGE_DOMAIN "$(out "$EDGE_STACK_NAME" EdgeDistributionDomain)"
  kv EDGE_WINDOW_START_MIN "$EDGE_WINDOW_START_MIN"
  kv EDGE_WINDOW_END_MIN "$EDGE_WINDOW_END_MIN"
  kv EDGE_IN_TTL "$EDGE_IN_TTL"
  kv EDGE_OUT_TTL "$EDGE_OUT_TTL"
  kv EDGE_REWRITE_ERRORS "$EDGE_REWRITE_ERRORS"
fi

echo "Done. Next: ./verify.sh (about 15 to 20 minutes)   Then, immediately: ./teardown.sh (the stack should live hours, not days)."
