#!/usr/bin/env bash
# variants.sh - find which updateRequestOrigin() call CloudFront accepts, in ONE session, by updating the
# EXISTING stack in place (no redeploy from scratch).
#
# For each variant it updates the stack's RouteVariant (and OriginAuth) parameters, waits for UPDATE_COMPLETE, waits for
# the function to be live, sends one routed request per backend (x-backend: route-a / route-b) and prints a table:
# variant, routed status, x-cache value, origin seen. At the end it RESTORES the default variant V2 with IAM-protected origins.
#
# Variants are defined in function/variants.json (V0 to V6): which fields the function passes to updateRequestOrigin().
# Variants V0, V3 and V6 make the three test origins PUBLIC (OriginAuth=NONE) while they run, so they need the same explicit
# consent as deploy.sh: ORIGIN_AUTH=NONE, or ACK_PUBLIC_ORIGINS=true, or --yes, or an interactive yes.
#
# Usage:  ./variants.sh [--yes] [V2 V4 ...]      (default order: V2 V4 V5 V1 V0 V3 V6; IAM variants first)
# Environment: STACK_NAME / CF_DOMAIN (from deploy.env), AWS_REGION (us-east-1), WAIT_CAP (240 s), SETTLE (30 s),
#              POLL_SLEEP (5 s), RESULTS_FILE.
# Output: a table, lines  VARIANT=V2 RESULT=PASS|FAIL DETAIL=...  and a results file (masked like verify.sh's).
# Only AWS error CODES are printed or logged, never AWS error text.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
[ -f deploy.env ] && . ./deploy.env

assume_yes=0
requested=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y) assume_yes=1 ;;
    V[0-9]*) requested="$requested $arg" ;;
    *) echo "usage: $0 [--yes] [V0..V6 ...]" >&2; exit 2 ;;
  esac
done

STACK_NAME="${STACK_NAME:-cfrouting-sample}"
DOMAIN="${CF_DOMAIN:-}"
REGION="${AWS_REGION:-us-east-1}"
SCHEME="${VERIFY_SCHEME:-https}"   # test hook for the local mock only
WAIT_CAP="${WAIT_CAP:-240}"
SETTLE="${SETTLE:-30}"
POLL_SLEEP="${POLL_SLEEP:-5}"
RESULTS_FILE="${RESULTS_FILE:-variants-results-$(date -u +%Y%m%dT%H%M%SZ).txt}"
[ -n "$DOMAIN" ] || { echo "Set CF_DOMAIN (deploy.env has it) to the distribution domain." >&2; exit 2; }
[ "$REGION" = "us-east-1" ] || { echo "Use us-east-1" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }
command -v aws >/dev/null 2>&1 || { echo "the AWS CLI is required" >&2; exit 2; }

# BEGIN variant table (checked against function/variants.json by scripts/check-function-sync.mjs)
VARIANT_TABLE="V0 NONE
V1 AWS_IAM
V2 AWS_IAM
V3 NONE
V4 AWS_IAM
V5 AWS_IAM
V6 NONE"
# END variant table

auth_of() { printf '%s\n' "$VARIANT_TABLE" | awk -v v="$1" '$1 == v { print $2 }'; }

DEFAULT_VARIANT=V2
variants="${requested:-V2 V4 V5 V1 V0 V3 V6}"
needs_public=0
for v in $variants; do
  a=$(auth_of "$v")
  [ -n "$a" ] || { echo "unknown variant: $v" >&2; exit 2; }
  [ "$a" = "NONE" ] && needs_public=1
done

RUN="r$(date +%s)p$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/variants.XXXXXX")" || exit 2
AWS_OUT="$TMP/aws.out"
REQ_N=0
: > "$RESULTS_FILE"
log() { printf '%s\n' "$*" >> "$RESULTS_FILE"; }

# awscall DESCRIPTION AWS_ARGS...  (same rules as verify.sh: only the error CODE is ever logged or printed)
awscall() {
  local desc=$1 rc; shift
  aws "$@" > "$AWS_OUT" 2> "$TMP/aws.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then log "# aws $desc: ok"; else
    LAST_CODE=$(sed -n 's/.*(\([A-Za-z0-9]*\)).*/\1/p' "$TMP/aws.err" | head -1)
    log "# aws $desc: FAILED exit=$rc error-code=${LAST_CODE:-unknown} (message withheld on purpose)"
  fi
  return "$rc"
}
redact_results() {
  sed -E -e 's/arn:aws[a-z-]*:[^[:space:]"'"'"',;)]*/arn:aws:REDACTED/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1REDACTED12\2/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1REDACTED12\2/g' "$1" > "$1.redacted" && mv "$1.redacted" "$1"
}

CURRENT_VARIANT=""
CURRENT_VARIANT_NAME=""
RESTORED=0
machine=""

req() { # name curl-args...   sets R_CODE R_H R_B
  local name=$1; shift
  REQ_N=$((REQ_N + 1))
  R_H="$TMP/h$REQ_N"; R_B="$TMP/b$REQ_N"
  R_CODE=$(curl -sS --max-time 25 -D "$R_H" -o "$R_B" -w '%{http_code}' "$@" 2> "$TMP/err")
  [ -f "$R_H" ] || : > "$R_H"; [ -f "$R_B" ] || : > "$R_B"
  { echo "=== request $REQ_N: $name"; echo "# curl $*"; echo "# http status $R_CODE"; tr -d '\r' < "$R_H"; echo "--- body"; cat "$R_B"; echo; } >> "$RESULTS_FILE"
}
hdr() { tr -d '\r' < "$R_H" | grep -i -m1 "^$1:" | sed 's/^[^:]*:[ ]*//'; }
jget() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$R_B" | head -1; }
probe() { # name key path
  req "$1" "$SCHEME://$DOMAIN$3" -H "x-backend: $2"
  P_CODE=$R_CODE; P_XC=$(hdr x-cache); P_ORIGIN=$(jget origin)
}

# set_variant VARIANT AUTH   update the stack in place and wait for it. Returns 0 on UPDATE_COMPLETE (or no change).
set_variant() {
  local v=$1 auth=$2 keys k args=()
  awscall "describe-stacks (parameters)" cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Parameters[].ParameterKey' --output text || return 1
  keys=$(cat "$AWS_OUT")
  for k in $keys; do
    case "$k" in RouteVariant|OriginAuth) ;; *) args+=("ParameterKey=$k,UsePreviousValue=true") ;; esac
  done
  args+=("ParameterKey=RouteVariant,ParameterValue=$v" "ParameterKey=OriginAuth,ParameterValue=$auth")
  if ! awscall "update-stack $v/$auth" cloudformation update-stack --region "$REGION" --stack-name "$STACK_NAME" \
      --template-body "file://template.yaml" --capabilities CAPABILITY_IAM --parameters "${args[@]}"; then
    # "No updates are to be performed" is fine; detect it without printing the message.
    if grep -q "No updates are to be performed" "$TMP/aws.err"; then log "# no change needed"; return 0; fi
    return 1
  fi
  awscall "wait stack-update-complete" cloudformation wait stack-update-complete --region "$REGION" --stack-name "$STACK_NAME"
}

# wait_live: after UPDATE_COMPLETE, poll until a routed request succeeds, or the answer is stable for 3 polls and at least
# SETTLE seconds have passed, or WAIT_CAP is reached.
wait_live() {
  local start prev="" same=0 now
  start=$(date +%s)
  while :; do
    probe "wait $CURRENT_VARIANT_NAME" route-a "/variants/$RUN/$CURRENT_VARIANT_NAME/wait$REQ_N"
    if [ "$P_CODE" = "200" ] && [ "$P_ORIGIN" = "origin-a" ]; then return 0; fi
    if [ "$prev" = "$P_CODE/$P_XC" ]; then same=$((same + 1)); else same=0; fi
    prev="$P_CODE/$P_XC"
    now=$(( $(date +%s) - start ))
    if [ "$same" -ge 3 ] && [ "$now" -ge "$SETTLE" ]; then return 0; fi
    [ "$now" -ge "$WAIT_CAP" ] && return 1
    sleep "$POLL_SLEEP"
  done
}

restore_default() {
  [ "$RESTORED" = 1 ] && return 0
  RESTORED=1
  if [ -n "$CURRENT_VARIANT" ] && [ "$CURRENT_VARIANT" != "$DEFAULT_VARIANT/AWS_IAM" ]; then
    echo
    echo "Restoring the default variant $DEFAULT_VARIANT with IAM-protected origins (waits for the stack update)..."
    # A stack update may still be running (for example after Ctrl-C): wait for it first.
    awscall "wait (pending update)" cloudformation wait stack-update-complete --region "$REGION" --stack-name "$STACK_NAME" || true
    if set_variant "$DEFAULT_VARIANT" AWS_IAM; then
      CURRENT_VARIANT="$DEFAULT_VARIANT/AWS_IAM"
      CURRENT_VARIANT_NAME=$DEFAULT_VARIANT; wait_live || true
      probe "restored A" route-a "/variants/$RUN/restored/a"; ra="$P_CODE/${P_ORIGIN:-none}"
      probe "restored B" route-b "/variants/$RUN/restored/b"; rb="$P_CODE/${P_ORIGIN:-none}"
      if [ "$ra" = "200/origin-a" ] && [ "$rb" = "200/origin-b" ]; then fin=PASS; else fin=FAIL; fi
      line="VARIANT=$DEFAULT_VARIANT RESULT=$fin DETAIL=restored default (IAM origins); routed-A=$ra routed-B=$rb"
      echo "$line"; log "$line"; machine="$machine$line
"
    else
      echo "RESTORE FAILED (error code ${LAST_CODE:-unknown}). The stack may still run a test variant with PUBLIC origins." >&2
      echo "Run ./variants.sh $DEFAULT_VARIANT to restore, or delete the stack with ./teardown.sh." >&2
      log "RESTORE FAILED error-code=${LAST_CODE:-unknown}"
    fi
  fi
}

finish() {
  restore_default
  [ -f "$RESULTS_FILE" ] && redact_results "$RESULTS_FILE"
  rm -rf "$TMP"
}
trap finish EXIT
trap 'exit 130' INT TERM

# ---- consent for public origins, and the stack tag check
if [ "$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" --query "Stacks[0].Tags[?Key=='sample'].Value" --output text 2>/dev/null)" != "cloudfront-request-routing" ]; then
  echo "Stack $STACK_NAME not found or not tagged sample=cloudfront-request-routing. Refusing." >&2
  RESTORED=1; exit 1
fi
if [ "$needs_public" = 1 ]; then
  echo "Variants V0, V3 and V6 make the three test origins PUBLIC while they run (OriginAuth=NONE): anyone who learns a function URL can call it."
  if [ "${ORIGIN_AUTH:-}" = "NONE" ] || [ "${ACK_PUBLIC_ORIGINS:-}" = "true" ] || [ "$assume_yes" = 1 ]; then
    echo "Acknowledged."
  elif [ -t 0 ]; then
    printf 'Type yes to continue: '; read -r answer
    [ "$answer" = "yes" ] || { echo "Aborted."; RESTORED=1; exit 1; }
  else
    echo "Refusing: set ORIGIN_AUTH=NONE (or ACK_PUBLIC_ORIGINS=true, or pass --yes), or run only V2 V4 V5 V1." >&2
    RESTORED=1; exit 1
  fi
fi

echo "variants.sh: in-place updates of stack $STACK_NAME; raw results go to $RESULTS_FILE"
echo "The stack is restored to $DEFAULT_VARIANT (IAM origins) at the end."
printf '\n%-8s %-9s %-34s %-9s %-34s %s\n' VARIANT STATUS-A X-CACHE-A STATUS-B X-CACHE-B ORIGINS
n_pass=0; n_fail=0; first_ok=""
for v in $variants; do
  auth=$(auth_of "$v")
  CURRENT_VARIANT="$v/$auth"
  CURRENT_VARIANT_NAME=$v
  log ""; log "######## variant $v (OriginAuth=$auth)"
  if ! set_variant "$v" "$auth"; then
    line="VARIANT=$v RESULT=FAIL DETAIL=stack update failed (error code ${LAST_CODE:-unknown}); not tested"
    machine="$machine$line
"
    printf '%-8s %s\n' "$v" "UPDATE FAILED (${LAST_CODE:-unknown})"
    n_fail=$((n_fail + 1)); log "$line"
    continue
  fi
  wait_live || log "# function did not settle within ${WAIT_CAP}s"
  probe "$v A" route-a "/variants/$RUN/$v/a"; ca=$P_CODE; xa=$P_XC; oa=$P_ORIGIN
  probe "$v B" route-b "/variants/$RUN/$v/b"; cb=$P_CODE; xb=$P_XC; ob=$P_ORIGIN
  printf '%-8s %-9s %-34s %-9s %-34s %s\n' "$v" "$ca" "${xa:--}" "$cb" "${xb:--}" "${oa:-none}/${ob:-none}"
  if [ "$ca" = "200" ] && [ "$oa" = "origin-a" ] && [ "$cb" = "200" ] && [ "$ob" = "origin-b" ]; then
    res=PASS; n_pass=$((n_pass + 1)); [ -n "$first_ok" ] || first_ok="$v"
  else
    res=FAIL; n_fail=$((n_fail + 1))
  fi
  line="VARIANT=$v RESULT=$res DETAIL=OriginAuth=$auth routed-A=$ca/${oa:-none} x-cache-A='${xa:-}' routed-B=$cb/${ob:-none} x-cache-B='${xb:-}'"
  machine="$machine$line
"
  log "$line"
done

restore_default
echo
echo "================ summary ================"
printf '%s' "$machine"
echo "SUMMARY variants-pass=$n_pass variants-fail=$n_fail first-passing=${first_ok:-none}"
log "SUMMARY variants-pass=$n_pass variants-fail=$n_fail first-passing=${first_ok:-none}"
echo "Results file: $RESULTS_FILE (masked; review it, then send it back)."
[ "$n_pass" -gt 0 ]
