#!/usr/bin/env bash
# Tests the guards in teardown.sh with a fake aws CLI (no AWS): tag check, confirmation, --yes,
# and that explicit environment values win over deploy.env.
set -u
cd "$(dirname "$0")/.." || exit 1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/bin" "$dir/work"
cp test/mock/fake-aws "$dir/bin/aws"
cp teardown.sh "$dir/work/teardown.sh"
printf "STACK_NAME=from-deploy-env\nEDGE_STACK_NAME=from-deploy-env-edge\nNAME_PREFIX=fromenv\nEDGE_NAME_PREFIX=fromenv-edge\n" > "$dir/work/deploy.env"
export FAKE_CALLS="$dir/calls.log"
fail=0
check() { # description, condition result (0 = ok)
  if [ "$2" -ne 0 ]; then echo "TEARDOWN TEST FAIL: $1"; fail=1; fi
}
run() { : > "$FAKE_CALLS"; PATH="$dir/bin:$PATH" bash "$dir/work/teardown.sh" "$@" < "${STDIN_FILE:-/dev/null}" > "$dir/out.txt" 2>&1; echo $?; }
deleted() { grep -c 'delete-stack' "$FAKE_CALLS"; }

# 1. wrong tag: refuses, never deletes
export FAKE_STACK_TAG="something-else"
rc=$(run --yes); check "wrong tag exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "wrong tag: no delete-stack" "$([ "$(deleted)" = 0 ] && echo 0 || echo 1)"
check "wrong tag: message" "$(grep -q REFUSING "$dir/out.txt" && echo 0 || echo 1)"

# 2. right tag, no --yes, answer no: aborts
export FAKE_STACK_TAG="cloudfront-time-window-caching"
echo no > "$dir/no.txt"
rc=$(STDIN_FILE="$dir/no.txt" run); check "answer no exits non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "answer no: no delete-stack" "$([ "$(deleted)" = 0 ] && echo 0 || echo 1)"
check "prints the stack names" "$(grep -q 'from-deploy-env' "$dir/out.txt" && echo 0 || echo 1)"

# 3. --yes: deletes the deploy.env stacks
rc=$(run --yes); check "--yes with right tag succeeds" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "--yes: deletes both stacks" "$([ "$(deleted)" = 2 ] && echo 0 || echo 1)"
check "uses deploy.env prefix" "$(grep -q "fromenv-" "$FAKE_CALLS" && echo 0 || echo 1)"

# 4. explicit environment wins over deploy.env
rc=$(STACK_NAME=explicit-stack NAME_PREFIX=explicit run --yes)
check "explicit STACK_NAME is deleted" "$(grep -q 'delete-stack.*explicit-stack' "$FAKE_CALLS" && echo 0 || echo 1)"
check "deploy.env stack not deleted when overridden" "$(grep 'delete-stack' "$FAKE_CALLS" | grep -q 'from-deploy-env$' && echo 1 || echo 0)"
check "explicit prefix used in the leftover check" "$(grep -q "explicit-" "$FAKE_CALLS" && echo 0 || echo 1)"

# 5. nothing exists: no delete, no prompt
rc=$(FAKE_NO_STACK=1 run); check "no stack: no delete-stack" "$([ "$(deleted)" = 0 ] && echo 0 || echo 1)"

if [ "$fail" = 0 ]; then echo "teardown-test: ok"; else echo "teardown-test: FAILED"; exit 1; fi
