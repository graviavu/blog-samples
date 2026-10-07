#!/usr/bin/env bash
# Deletes everything the sample created and then checks that nothing with its name prefix is left.
# Deleting the stack deletes the distribution, the function, the KeyValueStore (and its data), the three
# test endpoints, their log groups, the policies and the role.
#
# Usage: ./teardown.sh [--yes]
#   Prints the stack names and asks you to confirm, unless --yes. A stack is only deleted if it carries the
#   tag sample=cloudfront-request-routing (set by deploy.sh), so a wrong STACK_NAME cannot delete something else.
#
# WARNING: CloudFront must disable and then delete the distribution. This takes many minutes (often 10 to 30).
# The optional Lambda@Edge stack can take hours to delete: AWS removes the function replicas some time after the
# distribution is gone, and deleting the function fails until then. Re-run this script later if it reports that.
#
# Environment: STACK_NAME (cfrouting-sample), NAME_PREFIX (cfrouting), EDGE_STACK_NAME (<STACK_NAME>-edge),
#              EDGE_NAME_PREFIX (cfrouting-edge), AWS_REGION (us-east-1).
#              deploy.env is read if present; values you set explicitly in the environment win over it.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

assume_yes=0
for a in "$@"; do
  case "$a" in
    --yes|-y) assume_yes=1 ;;
    *) echo "usage: $0 [--yes]" >&2; exit 2 ;;
  esac
done

# Explicit environment values win over deploy.env.
e_stack="${STACK_NAME:-}"; e_prefix="${NAME_PREFIX:-}"; e_edge="${EDGE_STACK_NAME:-}"; e_edge_prefix="${EDGE_NAME_PREFIX:-}"
# shellcheck disable=SC1091
[ -f deploy.env ] && . ./deploy.env
[ -n "$e_stack" ] && STACK_NAME="$e_stack"
[ -n "$e_prefix" ] && NAME_PREFIX="$e_prefix"
[ -n "$e_edge" ] && EDGE_STACK_NAME="$e_edge"
[ -n "$e_edge_prefix" ] && EDGE_NAME_PREFIX="$e_edge_prefix"

STACK_NAME="${STACK_NAME:-cfrouting-sample}"
EDGE_STACK_NAME="${EDGE_STACK_NAME:-${STACK_NAME}-edge}"
PREFIX="${NAME_PREFIX:-cfrouting}"
EDGE_PREFIX="${EDGE_NAME_PREFIX:-cfrouting-edge}"
REGION="${AWS_REGION:-us-east-1}"
rc=0

stack_exists() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1; }
stack_tag() { aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" \
  --query "Stacks[0].Tags[?Key=='sample'].Value" --output text 2>/dev/null; }

to_delete=()
for s in "$EDGE_STACK_NAME" "$STACK_NAME"; do
  if ! stack_exists "$s"; then echo "stack $s: not found (already deleted)"; continue; fi
  if [ "$(stack_tag "$s")" != "cloudfront-request-routing" ]; then
    echo "REFUSING to delete stack $s: it does not carry the tag sample=cloudfront-request-routing." >&2
    exit 1
  fi
  to_delete+=("$s")
done

if [ "${#to_delete[@]}" -gt 0 ]; then
  echo "About to DELETE these CloudFormation stacks in $REGION: ${to_delete[*]}"
  echo "This removes the distribution, route table (KeyValueStore and its data), functions and test endpoints."
  if [ "$assume_yes" != 1 ]; then
    printf 'Type yes to continue: '
    read -r answer
    [ "$answer" = "yes" ] || { echo "Aborted."; exit 1; }
  fi
fi

delete_stack() {
  echo "Deleting stack $1. This can take many minutes; waiting..."
  aws cloudformation delete-stack --region "$REGION" --stack-name "$1"
  if aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$1"; then
    echo "stack $1: deleted"
  else
    echo "stack $1: deletion did NOT complete. Failed resources:"
    aws cloudformation describe-stack-events --region "$REGION" --stack-name "$1" \
      --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output text | head -10
    echo "If this is the Lambda@Edge function, wait a few hours and run ./teardown.sh again."
    rc=1
  fi
}

for s in "${to_delete[@]+"${to_delete[@]}"}"; do delete_stack "$s"; done

echo
echo "Checking for leftovers with prefix '$PREFIX-' / '$EDGE_PREFIX-' ..."
left() { # description, output of an aws --query ... --output text
  local v="$2"
  if [ -n "$v" ] && [ "$v" != "None" ]; then echo "LEFTOVER $1: $v"; rc=1; else echo "none    $1"; fi
}
for p in "$PREFIX" "$EDGE_PREFIX"; do
  left "cloudfront functions ($p)" "$(aws cloudfront list-functions --region "$REGION" --query "FunctionList.Items[?starts_with(Name, '$p-')].Name" --output text 2>&1)"
  left "key value stores ($p)" "$(aws cloudfront list-key-value-stores --region "$REGION" --query "KeyValueStoreList.Items[?starts_with(Name, '$p-')].Name" --output text 2>&1)"
  left "distributions ($p)" "$(aws cloudfront list-distributions --region "$REGION" --query "DistributionList.Items[?starts_with(Comment, '$p ')].Id" --output text 2>&1)"
  left "cache policies ($p)" "$(aws cloudfront list-cache-policies --region "$REGION" --type custom --query "CachePolicyList.Items[?starts_with(CachePolicy.CachePolicyConfig.Name, '$p-')].CachePolicy.Id" --output text 2>&1)"
  left "origin request policies ($p)" "$(aws cloudfront list-origin-request-policies --region "$REGION" --type custom --query "OriginRequestPolicyList.Items[?starts_with(OriginRequestPolicy.OriginRequestPolicyConfig.Name, '$p-')].OriginRequestPolicy.Id" --output text 2>&1)"
  left "response headers policies ($p)" "$(aws cloudfront list-response-headers-policies --region "$REGION" --type custom --query "ResponseHeadersPolicyList.Items[?starts_with(ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name, '$p-')].ResponseHeadersPolicy.Id" --output text 2>&1)"
  left "origin access controls ($p)" "$(aws cloudfront list-origin-access-controls --region "$REGION" --query "OriginAccessControlList.Items[?starts_with(Name, '$p-')].Id" --output text 2>&1)"
  left "lambda functions ($p)" "$(aws lambda list-functions --region "$REGION" --query "Functions[?starts_with(FunctionName, '$p-')].FunctionName" --output text 2>&1)"
  left "log groups ($p)" "$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/lambda/$p-" --query 'logGroups[].logGroupName' --output text 2>&1)"
done
left "stack $STACK_NAME" "$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"
left "stack $EDGE_STACK_NAME" "$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$EDGE_STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"

if [ "$rc" -eq 0 ]; then
  echo "Teardown complete: nothing left. You can delete deploy.env and verify-results-*.txt."
else
  echo "Teardown NOT complete (see above). Check the console steps in the README if a leftover remains."
fi
exit "$rc"
