#!/usr/bin/env bash
case "$-" in *x*) set +x; echo "refusing to run with xtrace (bash -x / set -x): it would print the Cloudflare token and the AWS key" >&2; exit 2 ;; esac
case ":${SHELLOPTS:-}:" in *:xtrace:*) echo "refusing to run with SHELLOPTS=xtrace" >&2; exit 2 ;; esac
# lwf-sample.sh - the ONE script of the lambda-web-functions sample (blog post 4).
#
#   ./lwf-sample.sh --dry-run --zone example.com     read-only: checks everything, prints the plan, changes nothing
#   ./lwf-sample.sh --zone example.com               real run: preflight, typed confirmation, deploy, tests A1-A8, teardown, leftover scan
#   ./lwf-sample.sh --zone example.com --keep        like the real run but leave everything up (the kill switch still fires at +6 h)
#   ./lwf-sample.sh --resume <run-id>                continue a run that stopped (finished steps are skipped; asks for the phrase;
#                                                    refused when the kill switch fires within the hour or the run was torn down)
#   ./lwf-sample.sh --teardown <run-id> [--zone Z]   remove EVERYTHING of that run, then scan for leftovers
#   ./lwf-sample.sh --status <run-id> [--zone Z]     show the run's state and scan for leftovers (read-only)
#
# Flags: --no-alias (turn off O1: alias, ACM certificate, lwf-g and lwf-o records), --no-probe (O2: eu-west-1 probe),
#        --no-negative (O3: lwf-x record straight to the endpoint).
# Needs (R supplies): AWS admin credentials for a TEST account in the environment/profile; a Cloudflare API token typed at the
#   hidden prompt (or CF_API_TOKEN in the environment); the Cloudflare zone name (--zone or prompt). Tools: aws CLI v2 with
#   `lambda-web`, curl, jq, node 20+, zip, openssl. Set ACK_BUDGET=true if you have an AWS Budget the script cannot see.
#   Optional: LWF_ALERT_EMAIL=you@example.com to be emailed (SNS, confirm the subscription) if the kill switch fails.
# The token is never exported to a child process, never put in argv, a log or a file other than a mode-600 header file that is
# removed on exit (also after Ctrl-C; only kill -9 can leave it in $TMPDIR). The IAM access key of the Worker goes from `aws iam create-access-key` straight into the Cloudflare secrets
# API on stdin; the script keeps it in memory for the signed tests only.
# Exit codes: 0 done and clean; 1 dry run found blockers; 2 error (the restore trap then tears the run down); 3 leftovers found;
#   130/143/129 interrupted by INT/TERM/HUP (the teardown still ran to the end; a third interrupt during it stops it).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() { sed -n '/^# lwf-sample.sh - /,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --keep) KEEP=1 ;;
    --no-alias) O1=0 ;;
    --no-probe) O2=0 ;;
    --no-negative) O3=0 ;;
    --zone) ZONE="${2:-}"; shift ;;
    --resume) MODE=run; RESUME=1; RUN="${2:-}"; shift ;;
    --teardown) MODE=teardown; RUN="${2:-}"; shift ;;
    --status) MODE=status; RUN="${2:-}"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
[ "$DRY" = 0 ] || [ "$MODE" = run ] || { echo "--dry-run goes with the plain run only" >&2; exit 2; }
[ "$RESUME" = 0 ] || [ "$DRY" = 0 ] || { echo "--dry-run cannot be combined with --resume" >&2; exit 2; }
if [ "$MODE" != run ] || [ "$RESUME" = 1 ]; then
  printf '%s' "$RUN" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$' || { echo "run id must look like 2610181230-ab12" >&2; exit 2; }
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lwf.XXXXXX")"; chmod 700 "$TMP"
if [ "$DRY" = 0 ]; then mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"; fi

# ---------------------------------------------------------------------------------------------------- names
HOST_RE='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'
set_names() {
  P="lwf-$RUN"; ART_STACK="$P-art"; APP_STACK="$P-app"; PROBE_STACK="$P-probe"; USERN="$P-worker"; WORKER="$P"
  BUCKET="$P-art-$ACCOUNT"; COMMENT="lwf-sample $RUN"
  H_W="lwf-w.$ZONE"; H_G="lwf-g.$ZONE"; H_O="lwf-o.$ZONE"; H_X="lwf-x.$ZONE"
  STATE_FILE="$STATE_DIR/$RUN.env"
  OUTDIR="$RESULTS_ROOT/$RUN"; RAWDIR="$OUTDIR/raw"; RES_TSV="$OUTDIR/results.tsv"
  redact_add "$ZONE" "<zone>"; redact_add "$ACCOUNT" "<account-id>"; redact_add "$BUCKET" "<bucket>"
}

# ---------------------------------------------------------------------------------------------------- Cloudflare token and zone
get_token() { # 0 = ready, 1 = no token (dry run without a terminal)
  if [ -z "$CF_API_TOKEN" ]; then
    if [ "$DRY" = 1 ] && [ ! -t 0 ]; then return 1; fi
    printf 'Cloudflare API token (input hidden): ' >&2
    IFS= read -rs CF_API_TOKEN || CF_API_TOKEN=""
    printf '\n' >&2
  fi
  [ -n "$CF_API_TOKEN" ] || return 1
  export -n CF_API_TOKEN
  cf_init
}
lookup_zone() { # sets ZID, ACC_CF, ZPLAN
  cf GET "/zones?name=$ZONE" || return 1
  ZID="$(jq -r '.result[0].id // empty' "$TMP/cf.out")"
  ACC_CF="$(jq -r '.result[0].account.id // empty' "$TMP/cf.out")"
  ZPLAN="$(jq -r '.result[0].plan.name // "unknown"' "$TMP/cf.out")"
  ZSTATUS="$(jq -r '.result[0].status // "unknown"' "$TMP/cf.out")"
  [ -n "$ZID" ] && [ -n "$ACC_CF" ] || return 1
  redact_add "$ZID" "<zone-id>"; redact_add "$ACC_CF" "<cf-account-id>"
}

# ---------------------------------------------------------------------------------------------------- preflight
# Properties of the CloudFormation types as the template uses them. UNVERIFIED against the live service: Lambda Web Functions
# launched 2026-10-12. The names below come from the schemas bundled with cfn-lint 1.57.x; this check compares them with what
# `aws cloudformation describe-type` returns for YOUR account and stops, naming the difference, if they do not match.
#   type | property names the template uses | read-only attributes it reads with GetAtt | required names the template sets
LWF_TYPES=(
  "AWS::Lambda::WebFunction|FunctionName Tags|FunctionArn|FunctionName"
  "AWS::Lambda::WebFunctionRevision|FunctionName BuildConfig CodeConfig S3Object Bucket Key RuntimeConfig Runtime ServiceConfig ExecutionRoleArn TimeoutSeconds MaxConcurrencyPerEnvironment|RevisionId|FunctionName BuildConfig CodeConfig S3Object Bucket Key RuntimeConfig Runtime ServiceConfig ExecutionRoleArn"
  "AWS::Lambda::WebFunctionEndpoint|FunctionName EndpointName EndpointType AuthType RevisionWeights RevisionId Weight ScalingConfig MaxEnvironments ThrottleConfig RateLimit|DomainName EndpointArn|FunctionName EndpointName EndpointType AuthType RevisionId Weight"
)
check_cfn_type() { # "type|used|readonly|provided"
  local spec="$1" type used ro prov schema names reqs readonly_ n miss
  type="${spec%%|*}"; spec="${spec#*|}"; used="${spec%%|*}"; spec="${spec#*|}"; ro="${spec%%|*}"; prov="${spec#*|}"
  schema="$(aws_ro cloudformation describe-type --type RESOURCE --type-name "$type" --query Schema --output text)" \
    || { blocker "CloudFormation type $type is not available in $REGION for this account ($(aws_code)). Lambda Web Functions are new; use a launch Region and check the CLI/account."; return 0; }
  if ! printf '%s' "$schema" | jq -e . >/dev/null 2>&1; then blocker "could not read the schema of $type"; return 0; fi
  names="$(printf '%s' "$schema" | jq -r '[.. | objects | select(has("properties")) | .properties | keys[]] | unique | .[]')"
  reqs="$(printf '%s' "$schema" | jq -r '[.. | objects | select(has("required")) | .required[]?] | unique | .[]')"
  readonly_="$(printf '%s' "$schema" | jq -r '(.readOnlyProperties // [])[] | sub("^/properties/"; "")')"
  miss=""
  for n in $used; do printf '%s\n' "$names" | grep -qx "$n" || miss="$miss $n"; done
  [ -z "$miss" ] || blocker "$type no longer has the properties the template uses:$miss (template cfn/app.yaml needs an update)"
  miss=""
  for n in $ro; do printf '%s\n' "$readonly_" | grep -qx "$n" || miss="$miss $n"; done
  [ -z "$miss" ] || blocker "$type has no read-only attribute(s)$miss that the template reads with GetAtt"
  miss=""
  for n in $reqs; do case " $prov " in *" $n "*) ;; *) miss="$miss $n" ;; esac; done
  [ -z "$miss" ] || blocker "$type requires properties the template does not set:$miss"
  case "$type" in
    *WebFunctionEndpoint)
      printf '%s' "$schema" | jq -e '[.. | .enum? // empty | .[]] | (index("IamAuth") != null) and (index("HomeRegion") != null)' >/dev/null 2>&1 \
        || blocker "$type no longer lists AuthType IamAuth and EndpointType HomeRegion" ;;
  esac
  say "ok: $type schema matches the template"
}

preflight_tools() {
  local t v
  for t in aws curl jq zip openssl "$NODE"; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done
  v="$("${NOAWS[@]}" "$NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || v=0
  [ "${v:-0}" -ge 20 ] 2>/dev/null || die "node 20 or newer is required (found major version ${v:-none})"
  say "ok: tools present (node $v)"
}

aws_identity() { # sets ACCOUNT and PARTITION (from the caller ARN, so no ARN below hardcodes "aws")
  local id arn
  id="$(aws_ro sts get-caller-identity --query '[Account,Arn]' --output text)" || return 1
  ACCOUNT="$(printf '%s' "$id" | cut -f1)"; arn="$(printf '%s' "$id" | cut -f2)"
  case "$ACCOUNT" in ''|*[!0-9]*) ACCOUNT=""; return 1 ;; esac
  PARTITION="$(printf '%s' "$arn" | cut -d: -f2)"; [ -n "$PARTITION" ] || PARTITION=aws
  redact_add "$ACCOUNT" "<account-id>"
}
check_budget() { # fail closed unless a Budget with at least one notification exists (or ACK_BUDGET=true). Only error codes are printed.
  local names code b n
  if [ "${ACK_BUDGET:-}" = true ]; then say "ok: budget check skipped (ACK_BUDGET=true)"; return 0; fi
  if ! names="$(aws_ro budgets describe-budgets --account-id "$ACCOUNT" --query 'Budgets[].BudgetName' --output json 2>/dev/null)"; then
    code="$(aws_code)"
    blocker "could not check for an AWS Budget (${code:-error}). Create a budget alert first, then re-run, or set ACK_BUDGET=true to confirm you have one."
    return 0
  fi
  names="$(printf '%s' "$names" | jq -r '.[]?' 2>/dev/null)"
  if [ -z "$names" ]; then
    blocker "no AWS Budget in this account. Create a budget alert first (README: Before you run), then re-run, or set ACK_BUDGET=true."; return 0
  fi
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    n="$(aws_ro budgets describe-notifications-for-budget --account-id "$ACCOUNT" --budget-name "$b" --query 'length(Notifications)' --output text 2>/dev/null)" || n=0
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then say "ok: an AWS Budget with $n notification(s) exists"; return 0; fi
  done <<< "$names"
  blocker "AWS Budget(s) exist but none has a notification, so nobody would be told. Add an alert to a budget, then re-run, or set ACK_BUDGET=true."
}
check_concurrency() { # sets FU_CAP: reserved concurrency for the Function URL function, or -1 (no cap) when the account cannot spare it
  local conc
  conc="$(aws_ro lambda get-account-settings --query 'AccountLimit.ConcurrentExecutions' --output text 2>/dev/null)" || conc=""
  case "$conc" in
    ''|*[!0-9]*) FU_CAP=-1; warn "could not read the account's Lambda concurrency limit ($(aws_code)); the Function URL function gets no reserved-concurrency cap (/slow is still limited to ${SLOW_MAX_MS} ms)" ;;
    *)
      # Lambda keeps 100 of the account's concurrency unreserved
      if [ $((conc - 100)) -ge 1 ]; then
        FU_CAP=$(( conc - 100 < FU_CAP_DEFAULT ? conc - 100 : FU_CAP_DEFAULT ))
        say "ok: account concurrency limit $conc; the Function URL function is capped at $FU_CAP concurrent executions"
        [ "$FU_CAP" -ge 128 ] || warn "the cap is below 128, so A4 with N=128 will show throttling (429) on the Function URL"
      else
        FU_CAP=-1
        warn "the account's Lambda concurrency limit is $conc (new accounts start low) and Lambda keeps 100 unreserved, so the Function URL function cannot get a reserved cap; the account limit of $conc is the cap. A4 with N=64/128 will show throttling"
      fi ;;
  esac
}

preflight_aws() {
  local cmd
  aws_identity || die "AWS credentials do not work"
  say "ok: AWS identity works (account ending ${ACCOUNT: -4}), region $REGION"
  check_budget
  check_concurrency

  if ! aws lambda-web help >/dev/null 2>&1; then
    blocker "this AWS CLI has no 'lambda-web' command ($(aws --version 2>&1 | cut -d' ' -f1)). Update AWS CLI v2 to a release that includes Lambda Web Functions."
  else
    for cmd in put-resource-policy delete-web-function; do
      aws lambda-web "$cmd" help >/dev/null 2>&1 || blocker "AWS CLI: 'aws lambda-web $cmd' does not exist in this CLI version"
    done
    for cmd in get-web-function delete-resource-policy; do
      aws lambda-web "$cmd" help >/dev/null 2>&1 || warn "'aws lambda-web $cmd' not found in this CLI; the leftover scan / policy removal for it is limited (UNVERIFIED command name)"
    done
    say "ok: AWS CLI has lambda-web"
  fi
  local spec
  for spec in "${LWF_TYPES[@]}"; do check_cfn_type "$spec"; done
}

preflight_cloudflare() {
  local n bad
  if cf GET /user/tokens/verify && jq -e '.result.status == "active"' "$TMP/cf.out" >/dev/null 2>&1; then
    say "ok: Cloudflare token is active"
  else
    warn "token verify endpoint did not confirm the token (account-owned tokens use another endpoint); relying on the zone lookup"
  fi
  lookup_zone || { blocker "Cloudflare zone $ZONE not found for this token (HTTP $CF_HTTP $(cf_errors)). Token needs Zone:Read on it."; return 0; }
  say "ok: zone $ZONE found, plan $ZPLAN, status $ZSTATUS"
  [ "$ZSTATUS" = active ] || blocker "zone $ZONE is not active (status $ZSTATUS)"
  if cf GET "/zones/$ZID/settings/ssl"; then ZSSL="$(jq -r '.result.value // "unknown"' "$TMP/cf.out")"; else ZSSL="unknown (token cannot read zone settings)"; fi
  say "ok: zone SSL mode: $ZSSL (the script never changes it)"
  bad="$(cf_list "/zones/$ZID/dns_records" | jq -r --arg c "$COMMENT" 'select((.name | test("^lwf-")) and (.comment != $c)) | "\(.type) \(.name)"' 2>/dev/null)" \
    || { blocker "token cannot list DNS records (needs Zone:DNS:Edit)"; return 0; }
  if [ -n "$bad" ]; then blocker "records starting with lwf- already exist in $ZONE ($(printf '%s' "$bad" | tr '\n' ',' | head -c 200)). Tear down the earlier run (--teardown <run-id>) or remove them; this script never overwrites records."; else say "ok: no lwf-* DNS record exists yet"; fi
  cf GET "/accounts/$ACC_CF/workers/scripts" || blocker "token cannot list Workers scripts (needs Account: Workers Scripts: Edit) (HTTP $CF_HTTP)"
  n="$(cf_list "/accounts/$ACC_CF/workers/domains" | jq -r --arg h "$H_W" --arg s "$WORKER" 'select(.hostname == $h and .service != $s) | .hostname' 2>/dev/null)" \
    || blocker "token cannot list Workers custom domains (needs Account: Workers Scripts: Edit)"
  [ -z "$n" ] || blocker "a Workers custom domain for $H_W already exists"
  if bad="$(packs_touching_our_names)"; then
    local mine id rest others=""
    mine=" $(state_get CF_PACKS) "
    while read -r id rest; do
      [ -n "$id" ] || continue
      case "$mine" in *" $id "*) ;; *) others="$others $rest" ;; esac
    done <<< "$bad"
    [ -z "$others" ] || blocker "a Cloudflare certificate pack already covers lwf-* names of this run ($others); this script deletes only packs it saw appear, so remove that one or pick another zone"
  else
    blocker "token cannot list certificate packs (needs Zone: SSL and Certificates: Edit) (HTTP $CF_HTTP)"
  fi
  say "ok: token can read DNS, Workers scripts, Workers domains and certificate packs"
}

print_plan() {
  say "Plan for run $RUN$([ "$DRY" = 1 ] && echo ' (dry run: nothing is created)'):"
  say "  AWS $REGION: stacks $ART_STACK (versioned S3 bucket) and $APP_STACK (CloudFront + OAC x2, Web Function endpoint IamAuth,"
  say "    Event Function + Function URL AWS_IAM, IAM user $USERN, kill switch Lambda + one-time schedule at +${KILL_HOURS} h)"
  say "  AWS: web function resource policy (CLI), IAM access key for $USERN (one key, goes to the Worker only)"
  [ "$O1" = 0 ] || say "  O1 on: ACM certificate for $H_G and $H_O, validation CNAMEs, aliases on the distribution"
  [ "$O2" = 0 ] || say "  O2 on: stack $PROBE_STACK in $PROBE_REGION (one tiny Event Function, no URL)"
  say "  Cloudflare ($ZONE): Worker $WORKER on custom domain $H_W (Advanced Certificate may appear)"
  [ "$O1" = 0 ] || say "    records: $H_G (DNS only CNAME to CloudFront), $H_O (proxied CNAME to CloudFront)"
  [ "$O3" = 0 ] || say "    record:  $H_X (proxied CNAME straight to the web function endpoint, the negative control)"
  say "  Tests A1-A8 (about 3,000 requests), results in results/$RUN/ next to the script, then full teardown and a leftover scan."
  say "  Cost (estimate, not a measurement): under \$1 per run, mostly CloudFront/Lambda requests inside free tiers; see README."
  say "  Kill switch at +${KILL_HOURS} h: disables CloudFront, deactivates the Worker key, sets the Function URL function to reserved"
  say "    concurrency 0; the web function is then unreachable (throttled too only if the Lambda runtime knows 'lambda-web')."
}

# ---------------------------------------------------------------------------------------------------- build code
build_code() {
  local b="$TMP/build"
  rm -rf "$b"; mkdir -p "$b/wf" "$b/fu"
  cp "$HERE/app/core.mjs" "$HERE/app/wf-server.mjs" "$HERE/app/package.json" "$b/wf/"
  cp "$HERE/app/core.mjs" "$HERE/app/fu-handler.mjs" "$HERE/app/package.json" "$b/fu/"
  ( cd "$b/wf" && zip -q -X -r "$b/wf.zip" . ) || die "zip failed"
  ( cd "$b/fu" && zip -q -X -r "$b/fu.zip" . ) || die "zip failed"
}

stack_failure_reasons() { # stack [region]
  AWS_R="${2:-$REGION}" aws_ro cloudformation describe-stack-events --stack-name "$1" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatusReason]" --output text 2>/dev/null | head -n 8 | redact >&2
}
deploy_stack() { # stack template region params...
  local stack="$1" tpl="$2" region="$3" code; shift 3
  AWS_R="$region" aws_do cloudformation deploy --stack-name "$stack" --template-file "$HERE/cfn/$tpl" \
    --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
    --tags "sample=lambda-web-functions" "RunId=$RUN" --parameter-overrides "$@" >/dev/null \
    || { code="$(aws_code)"; stack_failure_reasons "$stack" "$region"; die "stack $stack failed (${code:-no error code})"; }
}
stack_outputs() { # stack -> sets O_<Key> variables
  local json k v
  json="$(aws_ro cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].Outputs' --output json)" || die "cannot read outputs of $1"
  while IFS=$'\t' read -r k v; do [ -n "$k" ] && eval "O_$k=\$v"; done < <(printf '%s' "$json" | jq -r '.[]? | [.OutputKey, .OutputValue] | @tsv')
}

# ---------------------------------------------------------------------------------------------------- steps
step_artifacts() {
  done_step artifacts && { say "skip: artifacts (done)"; return 0; }
  say "step: artifacts stack and code upload"
  deploy_stack "$ART_STACK" artifacts.yaml "$REGION" "RunId=$RUN" "BucketName=$BUCKET"
  build_code
  aws_do s3api put-object --bucket "$BUCKET" --key wf.zip --body "$TMP/build/wf.zip" >/dev/null || die "upload wf.zip failed ($(aws_code))"
  aws_do s3api put-object --bucket "$BUCKET" --key fu.zip --body "$TMP/build/fu.zip" >/dev/null || die "upload fu.zip failed ($(aws_code))"
  state_set BUCKET "$BUCKET"; mark_done artifacts
}

step_cert() { # O1
  [ "$O1" = 1 ] || return 0
  done_step cert && { CERT_ARN="$(state_get CERT_ARN)"; say "skip: certificate (done)"; return 0; }
  say "step: ACM certificate for $H_G and $H_O (DNS validation through Cloudflare)"
  CERT_ARN="$(aws_do acm request-certificate --domain-name "$H_G" --subject-alternative-names "$H_O" --validation-method DNS \
    --idempotency-token "lwf${RUN//-/}" --tags "Key=sample,Value=lambda-web-functions" "Key=RunId,Value=$RUN" \
    --query CertificateArn --output text)" || die "request-certificate failed ($(aws_code))"
  state_set CERT_ARN "$CERT_ARN"
  local i recs n=0 st=""
  for i in $(seq 1 "${CERT_RECORD_TRIES:-30}"); do
    recs="$(aws_ro acm describe-certificate --certificate-arn "$CERT_ARN" --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output json)" || die "describe-certificate failed"
    n="$(printf '%s' "$recs" | jq '[.[] | select(. != null)] | length')"
    [ "$n" -ge 2 ] 2>/dev/null && break
    nap 5
  done
  [ "${n:-0}" -ge 2 ] 2>/dev/null || die "ACM did not publish its validation records in time"
  local name value
  printf '%s' "$recs" | jq -r '[.[] | select(. != null) | [.Name, .Value]] | unique | .[] | @tsv' | while IFS=$'\t' read -r name value; do
    dns_upsert "${name%.}" "${value%.}" false || exit 1
  done || die "could not create the ACM validation records"
  for i in $(seq 1 "${CERT_ISSUE_TRIES:-60}"); do
    st="$(aws_ro acm describe-certificate --certificate-arn "$CERT_ARN" --query Certificate.Status --output text)" || die "describe-certificate failed"
    case "$st" in ISSUED) break ;; FAILED|VALIDATION_TIMED_OUT) die "certificate $st" ;; esac
    nap 15
  done
  [ "$st" = ISSUED ] || die "certificate not issued in time (status $st)"
  mark_done cert
}

# dns_upsert NAME CONTENT PROXIED -> creates a CNAME with the run comment; refuses to touch an existing record
dns_upsert() {
  local name="$1" content="$2" proxied="$3" have
  have="$(cf_list "/zones/$ZID/dns_records?name=$name" | jq -r '.id' 2>/dev/null)" || { warn "cannot read records for $name"; return 1; }
  if [ -n "$have" ]; then
    if cf GET "/zones/$ZID/dns_records/$(printf '%s' "$have" | head -n 1)" && jq -e --arg c "$COMMENT" '.result.comment == $c' "$TMP/cf.out" >/dev/null 2>&1; then
      return 0   # ours, from an earlier attempt of this run
    fi
    warn "$name already has a record that is not from this run; not touching it"; return 1
  fi
  jq -n --arg n "$name" --arg c "$content" --argjson p "$proxied" --arg cm "$COMMENT" \
    '{type:"CNAME",name:$n,content:$c,ttl:1,proxied:$p,comment:$cm}' > "$TMP/rec.json"
  cf POST "/zones/$ZID/dns_records" "$TMP/rec.json" || { warn "creating $name failed (HTTP $CF_HTTP $(cf_errors))"; return 1; }
  state_set DNS_ID "$(jq -r '.result.id' "$TMP/cf.out")"
}

step_app() {
  done_step app && { say "skip: app stack (done)"; load_app_outputs; return 0; }
  say "step: app stack (CloudFront takes 10-30 minutes)"
  local params
  params=("RunId=$RUN" "CodeBucket=$BUCKET" "KillAt=$KILL_AT" "MaxEnvironments=$WF_MAX_ENVS" "FuReservedConcurrency=$FU_CAP")
  [ -z "${LWF_ALERT_EMAIL:-}" ] || params+=("AlertEmail=$LWF_ALERT_EMAIL")
  [ "$O1" = 0 ] || params+=("AliasGrey=$H_G" "AliasOrange=$H_O" "CertificateArn=$CERT_ARN")
  deploy_stack "$APP_STACK" app.yaml "$REGION" "${params[@]}"
  load_app_outputs
  mark_done app
}
# shellcheck disable=SC2154  # the O_<OutputKey> variables are set by stack_outputs through eval
load_app_outputs() {
  stack_outputs "$APP_STACK"
  DIST_ID="$O_DistributionId"; CFD="$O_DistributionDomain"; WF_NAME="$O_WebFunctionName"; WF_ARN="$O_WebFunctionArn"
  WFH="$O_WebFunctionEndpointDomain"; EP_ARN="$O_WebFunctionEndpointArn"; FUH="$O_FunctionUrlHost"; FU_NAME="$O_FuFunctionName"
  KILL_FN="$O_KillFunctionName"
  if ! { [ -n "$DIST_ID" ] && [ -n "$CFD" ] && [ -n "$WFH" ] && [ -n "$FUH" ]; }; then die "app stack outputs are incomplete"; fi
  redact_add "$DIST_ID" "<distribution-id>"; redact_add "$CFD" "<cloudfront-domain>"; redact_add "$WFH" "<wf-endpoint-host>"; redact_add "$FUH" "<fu-host>"
  state_set DIST_ID "$DIST_ID"; state_set CFD "$CFD"; state_set EP_ARN "$EP_ARN"; state_set WF_ARN "$WF_ARN"
}

step_policy() {
  done_step policy && { say "skip: resource policy (done)"; return 0; }
  say "step: web function resource policy for the distribution"
  jq -n --arg arn "$WF_ARN/endpoint/*" --arg src "arn:$PARTITION:cloudfront::$ACCOUNT:distribution/$DIST_ID" \
    '{Version:"2012-10-17",Statement:[{Sid:"AllowCloudFrontDistribution",Effect:"Allow",Principal:{Service:"cloudfront.amazonaws.com"},Action:"lambda:InvokeWebFunctionEndpoint",Resource:$arn,Condition:{StringEquals:{"aws:SourceArn":$src}}}]}' > "$TMP/policy.json"
  aws_do lambda-web put-resource-policy --resource-arn "$WF_ARN" --policy "file://$TMP/policy.json" >/dev/null || die "put-resource-policy failed ($(aws_code))"
  mark_done policy
}

step_wait_cloudfront() {
  say "step: wait until CloudFront answers through the policy (a transient 403 is normal for a few minutes)"
  local i st
  for i in $(seq 1 "${READY_TRIES:-30}"); do
    pj_plain ready get "https://$CFD/wf/ping"; st="$(jq -r '.status // 0' "$TMP/pj.ready")"
    [ "$st" = 200 ] && { say "ok: https://<cloudfront-domain>/wf/ping answers 200"; return 0; }
    nap 20
  done
  die "CloudFront did not return 200 for /wf/ping (last status $st). Check the web function: Application.TimeoutListenError means the server did not listen on the port Lambda expects (see app/wf-server.mjs)"
}

# The per-run Worker token lives in memory and in the Worker's secrets only, never in the state file. A resumed run sets a new one.
new_worker_token() {
  WTOKEN="$(openssl rand -hex 16)"; redact_add "$WTOKEN" "<worker-token>"
  printf '%s' "$WTOKEN" | jq -Rc '{name:"LWF_TOKEN",text:.,type:"secret_text"}' | cf PUT "/accounts/$ACC_CF/workers/scripts/$WORKER/secrets" -
}
step_worker() {
  if done_step worker; then
    say "skip: worker (done). The AWS key is not recoverable, so the signed tests are skipped; the Worker gets a new run token"
    new_worker_token || die "could not set a new run token on the Worker (HTTP $CF_HTTP $(cf_errors))"
    return 0
  fi
  say "step: IAM access key, Worker upload, secrets, custom domain"
  local old k json
  old="$(aws_names iam list-access-keys --user-name "$USERN" --query 'AccessKeyMetadata[].AccessKeyId')" || die "cannot list keys of the Worker user"
  for k in $old; do aws_do iam delete-access-key --user-name "$USERN" --access-key-id "$k" || die "cannot remove an old key"; done
  json="$(aws_do iam create-access-key --user-name "$USERN" --output json)" || die "create-access-key failed ($(aws_code))"
  AK_ID="$(printf '%s' "$json" | jq -r '.AccessKey.AccessKeyId')"
  AK_SECRET="$(printf '%s' "$json" | jq -r '.AccessKey.SecretAccessKey')"
  json=""
  if ! { [ -n "$AK_ID" ] && [ -n "$AK_SECRET" ] && [ "$AK_ID" != null ] && [ "$AK_SECRET" != null ]; }; then die "create-access-key returned no key"; fi
  redact_add "$AK_ID" "<access-key-id>"

  jq -n --arg wf "$WFH" --arg fu "$FUH" --arg cf "$CFD" --arg cd "$COMPAT_DATE" --arg region "$REGION" \
    '{main_module:"worker.mjs",compatibility_date:$cd,keep_bindings:["secret_text"],bindings:[
      {type:"plain_text",name:"WF_HOST",text:$wf},{type:"plain_text",name:"FU_HOST",text:$fu},
      {type:"plain_text",name:"CF_ORIGIN",text:$cf},{type:"plain_text",name:"AWS_REGION",text:$region}]}' > "$TMP/meta.json"
  cf_upload_worker "/accounts/$ACC_CF/workers/scripts/$WORKER" "$TMP/meta.json" "$HERE/worker/worker.mjs" "$HERE/worker/sigv4.mjs" \
    || die "Worker upload failed (HTTP $CF_HTTP $(cf_errors))"
  state_set WORKER "$WORKER"
  # secrets go to the API on stdin, never through argv
  printf '%s' "$AK_ID" | jq -Rc '{name:"AWS_ACCESS_KEY_ID",text:.,type:"secret_text"}' | cf PUT "/accounts/$ACC_CF/workers/scripts/$WORKER/secrets" - \
    || die "setting secret AWS_ACCESS_KEY_ID failed (HTTP $CF_HTTP $(cf_errors))"
  printf '%s' "$AK_SECRET" | jq -Rc '{name:"AWS_SECRET_ACCESS_KEY",text:.,type:"secret_text"}' | cf PUT "/accounts/$ACC_CF/workers/scripts/$WORKER/secrets" - \
    || die "setting secret AWS_SECRET_ACCESS_KEY failed (HTTP $CF_HTTP $(cf_errors))"
  new_worker_token || die "setting secret LWF_TOKEN failed (HTTP $CF_HTTP $(cf_errors))"
  # no workers.dev address for this Worker (best effort; the custom domain is the only intended entry)
  echo '{"enabled":false}' > "$TMP/sub.json"
  cf POST "/accounts/$ACC_CF/workers/scripts/$WORKER/subdomain" "$TMP/sub.json" || warn "could not disable the workers.dev route (HTTP $CF_HTTP); the Worker requires the run token anyway"
  jq -n --arg h "$H_W" --arg s "$WORKER" --arg z "$ZID" '{environment:"production",hostname:$h,service:$s,zone_id:$z}' > "$TMP/domain.json"
  cf PUT "/accounts/$ACC_CF/workers/domains" "$TMP/domain.json" || die "Workers custom domain failed (HTTP $CF_HTTP $(cf_errors))"
  state_set WORKER_DOMAIN_ID "$(jq -r '.result.id // empty' "$TMP/cf.out")"
  record_packs
  mark_done worker
}

# Certificate packs: Cloudflare may issue an Advanced Certificate for the Worker's custom domain and does not delete it with the
# domain. The ids seen after this run created the domain are recorded; teardown deletes only recorded ids. (The preflight refuses
# when a pack for one of the run's names already exists, so a pack found later is this run's.)
packs_for_our_names() { # -> ids of packs whose hosts are all names of this run
  cf_list "/zones/$ZID/ssl/certificate_packs?status=all" | jq -r --arg a "$H_W" --arg b "$H_G" --arg c "$H_O" --arg d "$H_X" \
    'select((.hosts // []) | length > 0 and all(.[]; . == $a or . == $b or . == $c or . == $d)) | .id'
}
packs_touching_our_names() { # -> "id hosts" of packs that cover any name of this run
  cf_list "/zones/$ZID/ssl/certificate_packs?status=all" | jq -r --arg a "$H_W" --arg b "$H_G" --arg c "$H_O" --arg d "$H_X" \
    'select(any((.hosts // [])[]; . == $a or . == $b or . == $c or . == $d)) | "\(.id) \((.hosts // []) | join(","))"'
}
record_packs() { # best effort; called after the custom domain step and again once the Worker answers over HTTPS
  local ids have id
  ids="$(packs_for_our_names 2>/dev/null)" || return 0
  have=" $(state_get CF_PACKS) "
  for id in $ids; do case "$have" in *" $id "*) ;; *) have="$have$id " ;; esac; done
  have="$(printf '%s' "$have" | words | tr '\n' ' ' | sed 's/ $//')"
  [ "$have" = "$(state_get CF_PACKS)" ] || state_set CF_PACKS "$have"
}

step_dns() {
  done_step dns && { say "skip: DNS records (done)"; return 0; }
  say "step: DNS records"
  # the extras are experiments: a record Cloudflare refuses (for example a proxied CNAME to an AWS endpoint) is reported, not fatal
  if [ "$O1" = 1 ]; then
    dns_upsert "$H_G" "$CFD" false || warn "could not create $H_G (O1 grey path); its tests will fail"
    dns_upsert "$H_O" "$CFD" true || warn "could not create $H_O (O1 orange path); its tests will fail"
  fi
  if [ "$O3" = 1 ]; then dns_upsert "$H_X" "$WFH" true || warn "could not create $H_X (O3 negative control); that result will be an error, not a status code"; fi
  mark_done dns
}

step_probe() { # O2
  [ "$O2" = 1 ] || return 0
  done_step probe && { say "skip: probe (done)"; return 0; }
  say "step: probe stack in $PROBE_REGION"
  deploy_stack "$PROBE_STACK" probe.yaml "$PROBE_REGION" "RunId=$RUN"
  mark_done probe
}

wait_worker() {
  local i st=""
  for i in $(seq 1 "${READY_TRIES:-30}"); do
    pj_plain wready get "https://$H_W/health"; st="$(jq -r '.status // 0' "$TMP/pj.wready")"
    [ "$st" = 200 ] && { say "ok: the Worker answers on its custom domain"; record_packs; break; }
    nap 20
  done
  [ "$st" = 200 ] || die "the Worker did not answer on https://lwf-w.<zone>/health (last status $st); Cloudflare certificate issuance for a new custom domain can be slow. The restore removes this run; start again with a longer wait (READY_TRIES=90 in the environment, each try is 20 s)"
  for i in $(seq 1 "${READY_TRIES:-30}"); do
    pj_worker wready2 get "https://$H_W/wf/ping"; st="$(jq -r '.status // 0' "$TMP/pj.wready2")"
    [ "$st" = 200 ] && { say "ok: Worker -> web function answers 200"; return 0; }
    nap 15
  done
  warn "Worker -> web function did not return 200 (last status $st); the tests will report what happens"
}
wait_alias() { # O1: the DNS-only alias needs DNS and the distribution's alias to be live; never fatal
  [ "$O1" = 1 ] || return 0
  local i st=""
  for i in $(seq 1 "${READY_TRIES:-30}"); do
    pj_plain gready get "https://$H_G/wf/ping"; st="$(pv gready '.status // 0')"
    [ "$st" = 200 ] && { say "ok: the DNS-only alias answers 200"; return 0; }
    nap 15
  done
  warn "the DNS-only alias did not return 200 (last status $st); A3, A5 and A6 will show what happens on that path"
}

# ---------------------------------------------------------------------------------------------------- probe helpers
count_requests() { # probe-command URL args... -> adds the requests this probe sends to REQ_TOTAL (and REQ_WF for the web function)
  local cmd="$1" url="$2" n=1 warm=0 a prev=""
  shift 2
  if [ "$cmd" = latency ]; then warm=3; fi   # probe.mjs default
  for a in "$@"; do
    case "$prev" in --n) n="$a" ;; --warm) warm="$a" ;; esac
    prev="$a"
  done
  case "$n$warm" in *[!0-9]*) return 0 ;; esac
  REQ_TOTAL=$((REQ_TOTAL + n + warm))
  case "$url" in "https://$WFH/"*|*/wf/*|*/wf) REQ_WF=$((REQ_WF + n + warm)) ;; esac
}
_pj() { # mode label probe-command URL args...   -> $TMP/pj.<label> (JSON) and a redacted copy in raw/
  local mode="$1" label="$2"; shift 2
  local out="$TMP/pj.$label"
  case "$mode" in
    plain) "${NOAWS[@]}" "$NODE" "$HERE/tools/probe.mjs" "$@" > "$out" 2>"$TMP/pj.err" ;;
    sign)
      if [ -z "$AK_SECRET" ]; then echo '{"error":"the AWS key is not in memory (resumed run); signed test skipped"}' > "$out"; return 1; fi
      printf '{"id":"%s","secret":"%s"}' "$AK_ID" "$AK_SECRET" | "${NOAWS[@]}" "$NODE" "$HERE/tools/probe.mjs" "$@" --sign > "$out" 2>"$TMP/pj.err" ;;
    worker) LWF_TOKEN="$WTOKEN" "${NOAWS[@]}" "$NODE" "$HERE/tools/probe.mjs" "$@" --worker > "$out" 2>"$TMP/pj.err" ;;
  esac
  count_requests "$@"
  jq -e . "$out" >/dev/null 2>&1 || echo '{"error":"probe produced no JSON"}' > "$out"
  [ -z "$RAWDIR" ] || redact < "$out" > "$RAWDIR/$label.json"
  return 0
}
pj_plain() { _pj plain "$@"; }
pj_sign() { _pj sign "$@"; }
pj_worker() { _pj worker "$@"; }
pv() { jq -r "$2" "$TMP/pj.$1" 2>/dev/null; }   # pv label jq-expression

# ---------------------------------------------------------------------------------------------------- tests
FAKE_JWT=""; FAKE_APP=""
run_tests() {
  say "tests A1-A8 (raw output in results/$RUN/raw/)"
  FAKE_JWT="Bearer lwf-fake-jwt-$RUN"; FAKE_APP="lwf-fake-app-token-$RUN"
  T_START="$(date +%s)"
  test_a1; test_a2; test_a3; test_a4; test_a5; test_a6; test_a7; test_a8
}

test_a1() {
  local s1 s2 s3 s4 cf1 cf2 w1 w2 w0 neg obs bad="" inc="" detail
  pj_plain a1_wf_unsigned get "https://$WFH/ping"; s1="$(pv a1_wf_unsigned .status)"
  pj_plain a1_fu_unsigned get "https://$FUH/ping"; s2="$(pv a1_fu_unsigned .status)"
  if [ -n "$AK_SECRET" ]; then
    pj_sign a1_wf_signed get "https://$WFH/ping"; s3="$(pv a1_wf_signed .status)"
    pj_sign a1_fu_signed get "https://$FUH/ping"; s4="$(pv a1_fu_signed .status)"
  else s3=skipped; s4=skipped; inc=1; fi
  pj_plain a1_cf_wf get "https://$CFD/wf/ping"; cf1="$(pv a1_cf_wf .status)"
  pj_plain a1_cf_fu get "https://$CFD/fu/ping"; cf2="$(pv a1_cf_fu .status)"
  pj_worker a1_w_wf get "https://$H_W/wf/ping"; w1="$(pv a1_w_wf .status)"
  pj_worker a1_w_fu get "https://$H_W/fu/ping"; w2="$(pv a1_w_fu .status)"
  pj_plain a1_w_notoken get "https://$H_W/wf/ping"; w0="$(pv a1_w_notoken .status)"
  neg="not run (--no-negative)"; obs="O3 off"
  if [ "$O3" = 1 ]; then
    pj_plain a1_negative get "https://$H_X/ping"; neg="$(pv a1_negative '.error // (.status|tostring)')"
    obs="status=$neg, answered by server=$(pv a1_negative '.headers.server // "?"'), x-amzn-errortype=$(pv a1_negative '.headers["x-amzn-errortype"] // "none"'), cf-ray=$(pv a1_negative 'if .headers["cf-ray"] then "present" else "absent" end')"
  fi
  detail="direct unsigned wf=$s1 fu=$s2 (want 403 403); direct signed wf=$s3 fu=$s4 (want 200 200); via CloudFront wf=$cf1 fu=$cf2; via Worker wf=$w1 fu=$w2; Worker without run token=$w0 (want 403); O3 observation, not a control (a proxied CNAME cannot sign, so an IamAuth endpoint can only refuse it; the point is WHO refuses: AWS with 403 or Cloudflare with a 52x/1xxx page): $obs. Only a 2xx there would count, as a broken lock-down"
  case "$s1" in 2??) bad="web function endpoint answers unsigned requests" ;; esac
  case "$s2" in 2??) bad="$bad function URL answers unsigned requests" ;; esac
  case "$neg" in 2??) bad="$bad the proxied CNAME to the endpoint answers without a signature" ;; esac
  if [ -n "$bad" ]; then rec A1 FAIL "LOCK-DOWN BROKEN: $bad. $detail"
  elif [ "$s1" = 403 ] && [ "$s2" = 403 ] && [ "$cf1" = 200 ] && [ "$cf2" = 200 ] && [ "$w1" = 200 ] && [ "$w2" = 200 ] && [ "$w0" = 403 ] && { [ "$inc" = 1 ] || { [ "$s3" = 200 ] && [ "$s4" = 200 ]; }; }; then
    if [ "$inc" = 1 ]; then rec A1 INCONCLUSIVE "everything else as expected, direct signed calls skipped (no key in memory). $detail"; else rec A1 PASS "$detail"; fi
  else rec A1 FAIL "$detail"; fi
}

hdr_of() { jq -r --arg k "$2" '.body | fromjson? | .[$k] // empty | if type == "object" then (if .present then "present:" + ((.sha256 // "")[0:12]) else "absent" end) else . end' "$TMP/pj.$1" 2>/dev/null; }
test_a2() {
  local expj expa want_j want_a r issues="" lines="" lab
  expj="$(sha256_of "$FAKE_JWT")"; expa="$(sha256_of "$FAKE_APP")"; want_j="present:${expj:0:12}"; want_a="present:${expa:0:12}"
  pj_plain a2_cf_wf get "https://$CFD/wf/headers" --header "Authorization: $FAKE_JWT" --header "x-app-auth: $FAKE_APP"
  pj_plain a2_cf_fu get "https://$CFD/fu/headers" --header "Authorization: $FAKE_JWT" --header "x-app-auth: $FAKE_APP"
  pj_worker a2_w_wf get "https://$H_W/wf/headers" --header "Authorization: $FAKE_JWT" --header "x-app-auth: $FAKE_APP"
  pj_worker a2_w_fu get "https://$H_W/fu/headers" --header "Authorization: $FAKE_JWT" --header "x-app-auth: $FAKE_APP"
  for lab in a2_cf_wf a2_cf_fu a2_w_wf a2_w_fu; do
    lines="$lines ${lab}[viewer-jwt=$(hdr_of "$lab" authorization) x-app-auth=$(hdr_of "$lab" x-app-auth) host=$(pv "$lab" '.body|fromjson?|.host // "?"')]"
  done
  [ "$(hdr_of a2_cf_wf authorization)" = "$want_j" ] || issues="$issues CloudFront->WebFunction did not pass the viewer Authorization unchanged;"
  [ "$(hdr_of a2_cf_fu authorization)" != "$want_j" ] || issues="$issues CloudFront->FunctionUrl passed the viewer Authorization (expected it overwritten by OAC 'always');"
  [ "$(hdr_of a2_w_wf authorization)" != "$want_j" ] || issues="$issues Worker->WebFunction delivered the viewer Authorization;"
  [ "$(hdr_of a2_w_fu authorization)" != "$want_j" ] || issues="$issues Worker->FunctionUrl delivered the viewer Authorization;"
  for lab in a2_cf_wf a2_cf_fu a2_w_wf a2_w_fu; do
    [ "$(hdr_of "$lab" x-app-auth)" = "$want_a" ] || issues="$issues x-app-auth did not arrive on $lab;"
  done
  [ "$(pv a2_cf_wf '.body|fromjson?|.host')" = "$WFH" ] || issues="$issues host seen by the web function via CloudFront is not the endpoint domain;"
  r="values are shown as present:<first 12 hex of SHA-256> or absent; the app never returns a value. $lines"
  if [ -z "$issues" ]; then rec A2 PASS "$r"; else rec A2 FAIL "$issues $r"; fi
}

test_a3() {
  local lab url mode n out="" p50 p90 pop st summary=""
  n="${LAT_N:-30}"
  for spec in "cf_wf|plain|https://$CFD/wf/ping" "cf_fu|plain|https://$CFD/fu/ping" "worker_wf|worker|https://$H_W/wf/ping" "worker_fu|worker|https://$H_W/fu/ping" \
              "worker_cf|worker|https://$H_W/cf/wf/ping" "worker_edge|worker|https://$H_W/edge/ping" \
              "direct_wf_signed|sign|https://$WFH/ping" "direct_fu_signed|sign|https://$FUH/ping"; do
    lab="${spec%%|*}"; mode="${spec#*|}"; url="${mode#*|}"; mode="${mode%%|*}"
    case "$mode" in
      plain) pj_plain "a3_$lab" latency "$url" --n "$n" ;;
      worker) pj_worker "a3_$lab" latency "$url" --n "$n" ;;
      sign) pj_sign "a3_$lab" latency "$url" --n "$n" ;;
    esac
    p50="$(pv "a3_$lab" '.p50 // "n/a"')"; p90="$(pv "a3_$lab" '.p90 // "n/a"')"
    pop="$(pv "a3_$lab" '.firstHeaders["x-amz-cf-pop"] // .firstHeaders["cf-ray"] // "?"')"
    st="$(pv "a3_$lab" '.error // (.status|tostring)')"
    summary="$summary $lab:p50=${p50}ms,p90=${p90}ms,pop=$pop,status=$st;"
  done
  if [ "$O1" = 1 ]; then
    pj_plain a3_grey latency "https://$H_G/wf/ping" --n "$n"
    summary="$summary grey_cf_wf:p50=$(pv a3_grey '.p50 // "n/a"')ms,p90=$(pv a3_grey '.p90 // "n/a"')ms,status=$(pv a3_grey '.error // (.status|tostring)');"
    pj_plain a3_orange latency "https://$H_O/wf/ping" --n "$n"
    summary="$summary orange_cf_wf:p50=$(pv a3_orange '.p50 // "n/a"')ms,p90=$(pv a3_orange '.p90 // "n/a"')ms,status=$(pv a3_orange '.error // (.status|tostring)');"
  fi
  summary="$summary server-timing (first CloudFront response): $(pv a3_cf_wf '.firstHeaders["server-timing"] // "none"')."
  if [ "$O2" = 1 ]; then probe_remote; summary="$summary eu-west-1 probe: $PROBE_SUMMARY"; fi
  rec A3 MEASURED "TTFB from this machine, $n warm sequential GETs per path.$summary"
}

probe_remote() {
  PROBE_SUMMARY="not run"
  local fn="$P-probe" payload="$TMP/probe-event.json"
  jq -n --arg cf "https://$CFD" --arg w "https://$H_W" --arg t "$WTOKEN" --arg g "https://$H_G" --argjson o1 "$O1" \
    '{n:30,warm:3,token:$t,urls:([{u:($cf+"/wf/ping")},{u:($cf+"/fu/ping")},{u:($w+"/wf/ping"),token:true},{u:($w+"/fu/ping"),token:true}] + (if $o1==1 then [{u:($g+"/wf/ping")}] else [] end))}' > "$payload"
  AWS_R="$PROBE_REGION" aws_do lambda invoke --function-name "$fn" --payload "file://$payload" --cli-binary-format raw-in-base64-out "$TMP/probe-out.json" >/dev/null \
    || { PROBE_SUMMARY="invoke failed ($(aws_code))"; return 0; }
  rm -f "$payload"
  REQ_TOTAL=$((REQ_TOTAL + 33 * (4 + O1)))   # n 30 + warm 3 per URL, inside the probe function
  redact < "$TMP/probe-out.json" > "$RAWDIR/a3_probe_eu-west-1.json"
  PROBE_SUMMARY="$(jq -r 'to_entries | map("\(.key | sub("^https://[^/]*/"; "/"))=p50:\(.value.p50)ms,p90:\(.value.p90)ms,status:\(.value.status|tojson)") | join(" ")' "$TMP/probe-out.json" 2>/dev/null || echo unreadable)"
}

metrics_snapshot() { # label -> raw/metrics-<label>.json with the four Lambda Web metrics (if they exist)
  local label="$1" name dims start end
  start="$(date -u -r "$T_START" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$T_START" +%Y-%m-%dT%H:%M:%SZ)"
  end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  aws_ro cloudwatch list-metrics --namespace AWS/Lambda/Web --output json > "$TMP/m.list" 2>/dev/null || { echo '{"error":"list-metrics failed"}' > "$TMP/m.list"; }
  : > "$TMP/m.out"
  jq -r --arg fn "$WF_NAME" '.Metrics[]? | select(.MetricName | IN("EnvironmentActiveTime","EnvironmentCPUTime","EnvironmentConcurrentRequests","EndpointActiveEnvironments"))
      | select(any(.Dimensions[]?; .Value | tostring | contains($fn))) | [.MetricName, ([.Dimensions[] | "Name=\(.Name),Value=\(.Value)"] | join(" "))] | @tsv' "$TMP/m.list" 2>/dev/null |
  while IFS=$'\t' read -r name dims; do
    # shellcheck disable=SC2086  # $dims is a space separated list of Name=..,Value=.. pairs on purpose
    aws_ro cloudwatch get-metric-statistics --namespace AWS/Lambda/Web --metric-name "$name" --dimensions $dims --start-time "$start" --end-time "$end" \
      --period 60 --statistics Maximum Sum --output json 2>/dev/null | jq -c --arg n "$name" '{metric:$n, unit:(.Datapoints[0].Unit // "?"), max:([.Datapoints[].Maximum]|max), sum:([.Datapoints[].Sum]|add)}' >> "$TMP/m.out"
  done
  redact < "$TMP/m.out" > "$RAWDIR/metrics-$label.jsonl"
  METRICS_SUMMARY="$(jq -rs 'if length==0 then "no AWS/Lambda/Web datapoints found (metrics lag a few minutes; names/dimensions UNVERIFIED)" else map("\(.metric)[\(.unit)] max=\(.max) sum=\(.sum)") | join("; ") end' "$TMP/m.out" 2>/dev/null)"
}

# A4. The claim tested: ONE web function environment serves many requests at once, an Event Function environment serves one.
# The number of environments alone proves nothing here: the endpoint is capped at MaxEnvironments (WF_MAX_ENVS) by configuration,
# so it is reported against that cap. The app reports how many requests were in flight in its environment when each one finished.
test_a4() {
  local N run lab url out="" wfenv=0 fuenv=0 wfinf=0 fuinf=0 thr="" e n200 inf spec status
  for N in 64 128; do
    for run in 1 2; do
      for spec in "wf|https://$CFD/wf/slow?ms=2000" "fu|https://$CFD/fu/slow?ms=2000"; do
        lab="${spec%%|*}"; url="${spec#*|}"
        pj_plain "a4_${lab}_n${N}_r${run}" parallel "$url" --n "$N"
        e="$(pv "a4_${lab}_n${N}_r${run}" '.distinctEnvironments // 0')"; n200="$(pv "a4_${lab}_n${N}_r${run}" '.status["200"] // 0')"
        inf="$(pv "a4_${lab}_n${N}_r${run}" '.maxInflight // 0')"
        status="$(pv "a4_${lab}_n${N}_r${run}" '.status | tojson')"
        out="$out ${lab}:N=$N,run=$run,envs=$e,max-in-flight-per-env=$inf,logstreams=$(pv "a4_${lab}_n${N}_r${run}" '.distinctLogStreams // 0'),status=$status,wall=$(pv "a4_${lab}_n${N}_r${run}" '.wallMs')ms;"
        case "$e$inf$n200" in *[!0-9]*) e=0; inf=0; n200=0 ;; esac
        if [ "$lab" = wf ]; then
          [ "$e" -le "$wfenv" ] || wfenv="$e"
          [ "$inf" -le "$wfinf" ] || wfinf="$inf"
          [ $((n200 * 100)) -ge $((N * 95)) ] || thr="$thr N=$N/run $run: $n200 of $N were 200;"
        else
          [ "$e" -le "$fuenv" ] || fuenv="$e"
          [ "$inf" -le "$fuinf" ] || fuinf="$inf"
        fi
      done
      nap "${A4_GAP:-20}"
    done
  done
  nap "${METRIC_WAIT:-150}"   # CloudWatch metrics arrive a few minutes late
  metrics_snapshot a4
  out="$out CloudWatch: $METRICS_SUMMARY"
  local cap="web function environments used: max $wfenv, bounded by MaxEnvironments=$WF_MAX_ENVS by configuration (so not a finding by itself); Function URL environments: max $fuenv."
  if [ "$wfenv" -gt "$WF_MAX_ENVS" ]; then rec A4 FAIL "the web function used $wfenv environments, more than MaxEnvironments=$WF_MAX_ENVS. $cap$out"
  elif [ "$wfinf" -gt 1 ] && [ "$fuinf" -le 1 ]; then rec A4 PASS "one web function environment had up to $wfinf requests in flight at once; a Function URL environment never more than $fuinf. $cap${thr:+ Not every web function request was 200:$thr}$out"
  elif [ -n "$thr" ]; then rec A4 INCONCLUSIVE "more than 5% of the web function requests were not 200 (rate limit, MaxEnvironments, new-account quotas?) and the in-flight count did not settle it (web function max $wfinf, Function URL max $fuinf):$thr $cap$out"
  elif [ "$wfinf" -le 1 ]; then rec A4 FAIL "no web function environment had more than one request in flight (max $wfinf) although all requests were 200: the documented many-requests-per-environment did not show. $cap$out"
  else rec A4 FAIL "a Function URL environment had $fuinf requests in flight; Event Functions are documented as one request per environment. $cap$out"; fi
}

test_a5() {
  local spec lab mode url out="" cfwf="" cffu=""
  for spec in "cf_wf|plain|https://$CFD/wf/stream" "cf_fu|plain|https://$CFD/fu/stream" "worker_wf|worker|https://$H_W/wf/stream" "worker_fu|worker|https://$H_W/fu/stream" \
              "worker_edge|worker|https://$H_W/edge/stream" "direct_wf_signed|sign|https://$WFH/stream" "direct_fu_signed|sign|https://$FUH/stream"; do
    lab="${spec%%|*}"; mode="${spec#*|}"; url="${mode#*|}"; mode="${mode%%|*}"
    a5_run "a5_$lab" "$mode" "$url"
    out="$out $(a5_line "$A5_USED" "$lab")"
    case "$lab" in cf_wf) cfwf="$A5_USED" ;; cf_fu) cffu="$A5_USED" ;; esac
  done
  if [ "$O1" = 1 ]; then a5_run a5_orange plain "https://$H_O/wf/stream"; out="$out $(a5_line "$A5_USED" orange_cf_wf)"; fi
  if a5_progressive "$cfwf" && a5_progressive "$cffu"; then rec A5 PASS "progressive through CloudFront on both origins (first byte < 1000 ms, total >= 2500 ms, >= 5 data events).$out"
  else rec A5 FAIL "not progressive through CloudFront on at least one origin, also on the second try.$out"; fi
}
A5_USED=""
a5_run() { # label mode url -> A5_USED = the label whose result counts. One retry: the first request on a path can be a cold start.
  local lab="$1" mode="$2" url="$3"
  _pj "$mode" "$lab" stream "$url"
  A5_USED="$lab"
  if ! a5_progressive "$lab" && [ "$(pv "$lab" '.status // 0')" = 200 ]; then
    _pj "$mode" "${lab}_retry" stream "$url"; A5_USED="${lab}_retry"
  fi
}
a5_progressive() { # label
  jq -e '.status == 200 and .firstByteMs < 1000 and .totalMs >= 2500 and .dataEvents >= 5' "$TMP/pj.$1" >/dev/null 2>&1
}
a5_line() { # label name
  local v="buffered/failed"
  a5_progressive "$1" && v="progressive"
  case "$1" in *_retry) v="$v,second-try" ;; esac
  printf '%s:%s(first=%sms,total=%sms,events=%s,status=%s);' "$2" "$v" "$(pv "$1" '.firstByteMs // "n/a"')" "$(pv "$1" '.totalMs // "n/a"')" "$(pv "$1" '.dataEvents // "n/a"')" "$(pv "$1" '.error // (.status|tostring)')"
}

test_a6() {
  local spec lab mode url out="" cfhit=0
  for spec in "cf_wf|plain|https://$CFD/wf/cache" "cf_fu|plain|https://$CFD/fu/cache" "worker_cache_wf|worker|https://$H_W/cache/wf/cache" "worker_to_cloudfront|worker|https://$H_W/cf/wf/cache"; do
    lab="${spec%%|*}"; mode="${spec#*|}"; url="${mode#*|}"; mode="${mode%%|*}"
    a6_pair "$lab" "$mode" "$url"; out="$out $A6_LINE"
    case "$lab" in cf_wf|cf_fu) [ "$A6_HIT" = 1 ] && cfhit=$((cfhit + 1)) ;; esac
  done
  if [ "$O1" = 1 ]; then
    a6_pair grey_cf_wf plain "https://$H_G/wf/cache"; out="$out $A6_LINE"
    a6_pair orange_cf_wf plain "https://$H_O/wf/cache"; out="$out $A6_LINE"
  fi
  if [ "$cfhit" = 2 ]; then rec A6 PASS "CloudFront serves the second request from cache on both origins (max-age=60).$out"
  else rec A6 FAIL "CloudFront did not return Hit on the second request for $((2 - cfhit)) origin(s).$out"; fi
}
A6_LINE=""; A6_HIT=0
a6_pair() { # label mode url
  local lab="$1" mode="$2" url="$3" x1 x2 n1 n2 same
  case "$mode" in plain) pj_plain "a6_${lab}_1" get "$url"; nap 1; pj_plain "a6_${lab}_2" get "$url" ;; worker) pj_worker "a6_${lab}_1" get "$url"; nap 1; pj_worker "a6_${lab}_2" get "$url" ;; esac
  x1="$(pv "a6_${lab}_1" '.headers["x-cache"] // .headers["x-lwf-cache"] // .headers["cf-cache-status"] // "none"')"
  x2="$(pv "a6_${lab}_2" '.headers["x-cache"] // .headers["x-lwf-cache"] // .headers["cf-cache-status"] // "none"')"
  n1="$(pv "a6_${lab}_1" '.body|fromjson?|.nonce // "?"')"; n2="$(pv "a6_${lab}_2" '.body|fromjson?|.nonce // "?"')"
  same=different; [ "$n1" = "$n2" ] && [ "$n1" != "?" ] && same=same
  A6_HIT=0; case "$x2" in Hit*|HIT*) [ "$same" = same ] && A6_HIT=1 ;; esac
  A6_LINE="${lab}[1st=$x1,2nd=$x2,body=$same,cf-cache-status=$(pv "a6_${lab}_2" '.headers["cf-cache-status"] // "none"')];"
}

# A7. Extrapolation per 10 million requests, not a quote.
#   Event Function: a batch of light GETs of its own (CloudFront /fu/ping), so the 2-3 s /slow and /stream requests of A4 and A5
#     do not set the per-request duration; billed duration from its REPORT lines, 512 MB, arm64 rate.
#   Web function: request fee plus active CPU plus memory for the environments' lifetime, from the AWS/Lambda/Web metrics of the
#     whole run divided by the web function requests this script sent. Skewed high: the lifetime includes the pauses between tests
#     and the 2 s sleeps of A4, which a steady production load would not have.
test_a7() {
  local n7="${A7_N:-50}" t7 start_ms n=0 avg="n/a" fu_gbs="n/a" fu_cost="n/a" wf_cost="n/a" cpu act ucpu uact wf_detail
  t7="$(date +%s)"; start_ms=$(( t7 * 1000 - 1000 ))
  pj_plain a7_fu_ping latency "https://$CFD/fu/ping" --n "$n7" --warm 0
  for _ in $(seq 1 "${A7_TRIES:-8}"); do
    nap 15   # REPORT lines reach CloudWatch Logs with a delay
    aws_ro logs filter-log-events --log-group-name "/aws/lambda/$FU_NAME" --filter-pattern REPORT --start-time "$start_ms" --output json > "$TMP/fu.reports" 2>/dev/null || echo '{"events":[]}' > "$TMP/fu.reports"
    jq -r '.events[]?.message' "$TMP/fu.reports" | sed -n 's/.*Billed Duration: \([0-9][0-9]*\) ms.*/\1/p' > "$TMP/fu.billed"
    n="$(wc -l < "$TMP/fu.billed" | tr -d ' ')"
    [ "$n" -lt "$n7" ] || break
  done
  avg="$(awk '{s+=$1} END {if (NR>0) printf "%.1f", s/NR; else print "n/a"}' "$TMP/fu.billed")"
  redact < "$TMP/fu.billed" > "$RAWDIR/a7-fu-billed-ms.txt"
  if [ "$avg" != "n/a" ]; then
    fu_gbs="$(awk -v a="$avg" 'BEGIN {printf "%.6f", a/1000*0.5}')"
    fu_cost="$(awk -v g="$fu_gbs" -v r="$PRICE_FU_PER_M_REQ" -v p="$PRICE_FU_GB_S_ARM" 'BEGIN {printf "%.2f", 10*r + 10000000*g*p}')"
  fi
  metrics_snapshot a7
  cpu="$(jq -rs 'map(select(.metric == "EnvironmentCPUTime"))[0] // {} | "\(.sum // "") \(.unit // "")"' "$TMP/m.out" 2>/dev/null)"
  act="$(jq -rs 'map(select(.metric == "EnvironmentActiveTime"))[0] // {} | "\(.sum // "") \(.unit // "")"' "$TMP/m.out" 2>/dev/null)"
  ucpu="$(unit_seconds "$cpu")"; uact="$(unit_seconds "$act")"
  if [ -n "$ucpu" ] && [ -n "$uact" ] && [ "$REQ_WF" -gt 0 ]; then
    wf_cost="$(awk -v c="$ucpu" -v a="$uact" -v q="$REQ_WF" -v r="$PRICE_WF_PER_M_REQ" -v pc="$PRICE_WF_VCPU_S" -v pm="$PRICE_WF_GB_S" -v gb="$WF_GB" \
      'BEGIN {printf "%.2f", 10*r + 10000000*(c*pc + a*gb*pm)/q}')"
    wf_detail="active CPU ${ucpu} s (EnvironmentCPUTime, taken as vCPU-seconds: UNVERIFIED) and environment lifetime ${uact} s (EnvironmentActiveTime) x ${WF_GB} GB over about $REQ_WF web function requests -> about \$${wf_cost} per 10M (request fee \$${PRICE_WF_PER_M_REQ}/M, \$${PRICE_WF_VCPU_S}/vCPU-s, \$${PRICE_WF_GB_S}/GB-s). SKEWED HIGH: the lifetime includes the pauses between tests and the 2 s sleeps of A4"
  else
    wf_detail="requests alone = \$$(awk -v r="$PRICE_WF_PER_M_REQ" 'BEGIN {printf "%.2f", 10*r}') per 10M; CPU and lifetime not converted (metric missing or unit not Seconds/Milliseconds/Microseconds: cpu='${cpu}' lifetime='${act}')"
  fi
  rec A7 MEASURED "Extrapolation, not a quote. Event Function behind the URL: $n of $n7 REPORT lines of a dedicated /fu/ping batch (the /slow and /stream requests of A4/A5 are excluded), average billed ${avg} ms at 512 MB arm64 = ${fu_gbs} GB-s/request -> about \$${fu_cost} per 10M requests (request fee \$${PRICE_FU_PER_M_REQ}/M plus duration at the Arm rate \$${PRICE_FU_GB_S_ARM}/GB-s). Web function: $wf_detail. Raw metrics: $METRICS_SUMMARY. About $REQ_TOTAL test requests were sent in total. List prices as read 2026-10-18; check the pricing page before quoting."
}
unit_seconds() { # "sum unit" -> seconds, or empty when the unit is not a time unit
  local v="${1% *}" u="${1##* }"
  case "$v" in ''|*[!0-9.e+-]*) return 0 ;; esac
  case "$u" in
    Seconds) awk -v v="$v" 'BEGIN {printf "%.3f", v}' ;;
    Milliseconds) awk -v v="$v" 'BEGIN {printf "%.3f", v/1000}' ;;
    Microseconds) awk -v v="$v" 'BEGIN {printf "%.3f", v/1000000}' ;;
  esac
}

# A8. Fire the kill switch and check every outcome: distribution disabled, Worker key inactive, Function URL function at
# reserved concurrency 0, and the web function unreachable (through CloudFront and through the Worker). The web function itself is
# throttled only when the Lambda runtime's boto3 knows 'lambda-web'; without that it is cut off by the other three, which the
# kill output says.
test_a8() {
  local inv fe out keys en conc i w1 w2 cfwf="" cffu="" wfo pass=1 inc=0 why="" detail
  if [ "$KEEP" = 1 ]; then rec A8 SKIPPED "--keep: the kill switch was not fired by the test, so the run stays usable. It fires by itself at $KILL_AT UTC (disables the distribution, deactivates the Worker key, sets the Function URL function to reserved concurrency 0; the web function is then unreachable). Run without --keep to test it."; return 0; fi
  say "A8: invoking the kill switch (the same function the schedule starts at +${KILL_HOURS} h)"
  printf '{"source":"test-a8"}' > "$TMP/kill-event.json"
  if ! inv="$(aws_do lambda invoke --function-name "$KILL_FN" --payload "file://$TMP/kill-event.json" --cli-binary-format raw-in-base64-out "$TMP/kill-out.json")"; then
    rec A8 FAIL "could not invoke the kill switch ($(aws_code))"; return 0
  fi
  fe="$(printf '%s' "$inv" | jq -r '.FunctionError // empty' 2>/dev/null)"
  # when a step fails the function raises with the step results as the message
  out="$(jq -c 'if type == "object" and .errorMessage then (.errorMessage | fromjson? // {error: .}) else . end' "$TMP/kill-out.json" 2>/dev/null || echo '{}')"
  redact < "$TMP/kill-out.json" > "$RAWDIR/a8-kill-output.json"
  [ -z "$fe" ] || { pass=0; why="$why the kill switch raised ($fe): a step that must work failed;"; }
  wfo="$(printf '%s' "$out" | jq -r '.web_function // "missing"' 2>/dev/null)"
  en=""; keys=""; conc=""
  for i in $(seq 1 "${A8_TRIES:-12}"); do
    en="$(aws_ro cloudfront get-distribution --id "$DIST_ID" --query 'Distribution.DistributionConfig.Enabled' --output text)"
    keys="$(aws_names iam list-access-keys --user-name "$USERN" --query 'AccessKeyMetadata[].Status' | tr '\n' ' ')"
    conc="$(aws_ro lambda get-function-concurrency --function-name "$FU_NAME" --query ReservedConcurrentExecutions --output text 2>/dev/null)"
    case "$en" in False|false) case " $keys " in *" Active "*) ;; *) [ "$conc" != 0 ] || break ;; esac ;; esac
    nap 10
  done
  # disabling a distribution takes minutes to reach every edge location: wait until it stops serving both origins
  for i in $(seq 1 "${A8_CF_TRIES:-30}"); do
    pj_plain a8_cf_wf get "https://$CFD/wf/ping"; cfwf="$(pv a8_cf_wf '.status // 0')"
    pj_plain a8_cf_fu get "https://$CFD/fu/ping"; cffu="$(pv a8_cf_fu '.status // 0')"
    [ "$cfwf" = 200 ] || [ "$cffu" = 200 ] || break
    nap 20
  done
  nap "${A8_SETTLE:-30}"
  pj_worker a8_w_wf get "https://$H_W/wf/ping"; w1="$(pv a8_w_wf .status)"
  pj_worker a8_w_fu get "https://$H_W/fu/ping"; w2="$(pv a8_w_fu .status)"
  case "$en" in False|false) ;; *) pass=0; why="$why the distribution is still enabled;" ;; esac
  case " $keys " in *" Active "*) pass=0; why="$why a Worker key is still active;" ;; esac
  [ "$conc" = 0 ] || { pass=0; why="$why the Function URL function is not throttled (reserved concurrency ${conc:-none});"; }
  case "$w1$w2" in *200*) pass=0; why="$why the Worker still gets 200 (wf=$w1 fu=$w2);" ;; esac
  if [ "$cfwf" = 200 ] || [ "$cffu" = 200 ]; then inc=1; why="$why CloudFront still served 200 after the wait (wf=$cfwf fu=$cffu): disabling propagates slowly;"; fi
  case "$wfo" in rate-limit-0) wfo="throttled (rate limit 0)" ;; *) wfo="NOT throttled by the kill switch ($wfo; known limitation, see README)" ;; esac
  detail="outcomes: distribution Enabled=$en; Worker key status(es): ${keys:-none}; function_url: reserved concurrency ${conc:-none} (want 0 = throttled); web_function: $wfo, reachable through CloudFront=$cfwf, through the Worker=$w1 (want not 200 on both = unreachable); Function URL through CloudFront=$cffu, through the Worker=$w2. Kill switch output: $out"
  if [ "$pass" = 0 ]; then rec A8 FAIL "$why $detail"
  elif [ "$inc" = 1 ]; then rec A8 INCONCLUSIVE "$why $detail"
  else rec A8 PASS "$detail"; fi
}

# ---------------------------------------------------------------------------------------------------- report
write_report() {
  local json="$OUTDIR/results.json" md="$OUTDIR/report.md" cli
  cli="$(aws --version 2>&1 | cut -d' ' -f1)"
  jq -R -s --arg run "$RUN" --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg region "$REGION" --arg cli "$cli" --arg plan "${ZPLAN:-unknown}" --arg ssl "${ZSSL:-unknown}" \
     --argjson o1 "$O1" --argjson o2 "$O2" --argjson o3 "$O3" \
    '{run:$run, date:$date, region:$region, aws_cli:$cli, cloudflare_plan:$plan, cloudflare_ssl_mode:$ssl, extras:{O1_alias:($o1==1), O2_probe:($o2==1), O3_negative:($o3==1)},
      results: (split("\n") | map(select(length > 0) | split("\t")) | map({id:.[0], status:.[1], detail:.[2]}))}' "$RES_TSV" | redact > "$json"
  {
    echo "# lambda-web-functions results, run $RUN"
    echo
    echo "Date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ). Region $REGION. AWS CLI $cli. Cloudflare plan: ${ZPLAN:-unknown}; SSL mode: ${ZSSL:-unknown}."
    echo "Extras: O1 alias=$O1, O2 probe=$O2, O3 negative=$O3. Statuses: PASS / FAIL (the documented expectation did not hold) / MEASURED / INCONCLUSIVE / SKIPPED."
    echo
    echo "| Test | Status | Detail |"
    echo "|---|---|---|"
    jq -r '.results[] | "| \(.id) | \(.status) | \(.detail | gsub("\\|"; "/")) |"' "$json"
    echo
    echo "Raw (redacted) responses: \`raw/\`. Read both files before sharing them."
  } | redact > "$md"
  say "report: results/$RUN/report.md and results/$RUN/results.json"
}

# ---------------------------------------------------------------------------------------------------- teardown
# Interrupt-safe. While the teardown runs, INT, TERM and HUP do not stop it: each one is reported and the teardown carries on
# (a step whose aws or curl child died with the Ctrl-C is tried once more). The third one stops the script; the state file stays,
# so --teardown <run-id> finishes the job. A run is marked torn down (TORN_DOWN in the state file) only after a clean scan.
sig_rc() { case "$1" in INT) echo 130 ;; TERM) echo 143 ;; HUP) echo 129 ;; *) echo 2 ;; esac; }
# shellcheck disable=SC2317,SC2329  # runs from a trap
td_on_signal() { # signal name
  TD_SIGS=$((TD_SIGS + 1)); TD_SIGNAME="$1"
  if [ "$TD_SIGS" -ge 3 ]; then
    TD_ABANDONED=1
    say "teardown interrupted ($1, third time): stopping now. Resources of run $RUN may remain; re-run --teardown: $0 --teardown $RUN --zone $ZONE"
    rm -rf "$TMP"
    exit "$(sig_rc "$1")"
  fi
  say "teardown interrupted ($1): carrying on so nothing is left half-deleted. If it stops before the scan, re-run --teardown $RUN (Ctrl-C $((3 - TD_SIGS)) more time(s) stops it now)"
}
td_traps() { trap 'td_on_signal INT' INT; trap 'td_on_signal TERM' TERM; trap 'td_on_signal HUP' HUP; }
td() { # description, then a command; a failure is reported and remembered, never fatal
  local d="$1" s0="$TD_SIGS"; shift
  if "$@"; then return 0; fi
  if [ "$TD_SIGS" != "$s0" ]; then
    say "teardown: trying '$d' once more (it failed while a signal arrived)"
    if "$@"; then return 0; fi
  fi
  TD_FAIL=1; say "TEARDOWN problem: $d"
  return 0
}
# shellcheck disable=SC2317,SC2329  # called through td()
td_cloudflare() {
  [ -n "$HDR" ] || { say "TEARDOWN: no Cloudflare token, Cloudflare resources NOT removed"; TD_FAIL=1; return 0; }
  [ -n "$ZID" ] || lookup_zone || { say "TEARDOWN: Cloudflare zone lookup failed (HTTP $CF_HTTP)"; TD_FAIL=1; return 0; }
  local id rc=0
  # custom domains of this Worker
  if cf_list "/accounts/$ACC_CF/workers/domains" | jq -r --arg s "$WORKER" 'select(.service == $s) | .id' > "$TMP/td.ids" 2>/dev/null; then
    while read -r id; do
      [ -n "$id" ] || continue
      cf DELETE "/accounts/$ACC_CF/workers/domains/$id" || cf_gone || { rc=1; say "TEARDOWN problem: custom domain delete failed (HTTP $CF_HTTP)"; }
    done < "$TMP/td.ids"
  else rc=1; say "TEARDOWN problem: cannot list Workers custom domains"; fi
  cf DELETE "/accounts/$ACC_CF/workers/scripts/$WORKER?force=true" || cf_gone || { rc=1; say "TEARDOWN problem: Worker delete failed (HTTP $CF_HTTP)"; }
  # Advanced Certificate packs this run saw appear (deleting a custom domain does not delete them); only recorded ids
  for id in $(state_get CF_PACKS); do
    cf DELETE "/zones/$ZID/ssl/certificate_packs/$id" || cf_gone || { rc=1; say "TEARDOWN problem: certificate pack delete failed (HTTP $CF_HTTP $(cf_errors))"; }
  done
  # DNS records created by this run (comment match), including the ACM validation records
  if cf_list "/zones/$ZID/dns_records" | jq -r --arg c "$COMMENT" 'select(.comment == $c) | .id' > "$TMP/td.ids" 2>/dev/null; then
    while read -r id; do
      [ -n "$id" ] || continue
      cf DELETE "/zones/$ZID/dns_records/$id" || cf_gone || { rc=1; say "TEARDOWN problem: DNS record delete failed (HTTP $CF_HTTP)"; }
    done < "$TMP/td.ids"
  else rc=1; say "TEARDOWN problem: cannot list DNS records"; fi
  return "$rc"
}
# shellcheck disable=SC2317,SC2329  # called through td()
empty_bucket() { # delete every object version and delete marker
  local b="$BUCKET"
  aws_ro s3api head-bucket --bucket "$b" >/dev/null 2>&1 || return 0
  for _ in $(seq 1 200); do
    aws_ro s3api list-object-versions --bucket "$b" --max-items 1000 --output json > "$TMP/ver.json" || return 1
    jq '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId})), Quiet: true}' "$TMP/ver.json" > "$TMP/ver.del"
    [ "$(jq '.Objects | length' "$TMP/ver.del")" -gt 0 ] || return 0
    aws_do s3api delete-objects --bucket "$b" --delete "file://$TMP/ver.del" >/dev/null || return 1
  done
  return 1
}
stack_status() { # stack region -> GONE or the stack status on stdout; 1 if it could not be read
  local st
  if st="$(AWS_R="$2" aws_ro cloudformation describe-stacks --stack-name "$1" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)"; then
    case "$st" in DELETE_COMPLETE|None|'') echo GONE ;; *) echo "$st" ;; esac
  elif aws_gone; then echo GONE
  else return 1; fi
}
# shellcheck disable=SC2317,SC2329  # called through td()
delete_stack() { # stack region -> 0 only when the stack is gone afterwards
  local st
  st="$(stack_status "$1" "$2")" || return 1
  [ "$st" != GONE ] || return 0
  AWS_R="$2" aws_do cloudformation delete-stack --stack-name "$1" || return 1
  if ! AWS_R="$2" aws_do cloudformation wait stack-delete-complete --stack-name "$1"; then
    # one retry for DELETE_FAILED (for example a bucket that was not empty yet)
    AWS_R="$2" aws_do cloudformation delete-stack --stack-name "$1" || return 1
    AWS_R="$2" aws_do cloudformation wait stack-delete-complete --stack-name "$1" || return 1
  fi
  st="$(stack_status "$1" "$2")" || return 1
  [ "$st" = GONE ] || { say "stack $1 still exists after the delete ($st)"; return 1; }
}
# shellcheck disable=SC2317,SC2329  # called through td()
td_app_stack() { # the kill switch schedule is part of this stack, so it goes last, with the stack
  delete_stack "$APP_STACK" "$REGION" && return 0
  say "teardown: the app stack did not delete; invoking the kill switch now so that what is left cannot serve traffic"
  fire_kill_switch || say "teardown: the kill switch could not be invoked either ($(aws_code)); the schedule at $KILL_AT UTC is still there if the stack is"
  return 1
}
# shellcheck disable=SC2317,SC2329  # called from td_app_stack, which runs through td()
fire_kill_switch() {
  printf '{"source":"teardown"}' > "$TMP/kill-td-event.json"
  aws_do lambda invoke --function-name "${KILL_FN:-$P-kill}" --payload "file://$TMP/kill-td-event.json" --cli-binary-format raw-in-base64-out "$TMP/kill-td.json" >/dev/null
}
# shellcheck disable=SC2317,SC2329  # called through td()
td_keys() {
  local k keys
  keys="$(aws_names iam list-access-keys --user-name "$USERN" --query 'AccessKeyMetadata[].AccessKeyId')" || { aws_gone && return 0; return 1; }
  for k in $keys; do aws_do iam delete-access-key --user-name "$USERN" --access-key-id "$k" || return 1; done
}
# shellcheck disable=SC2317,SC2329  # called through td()
td_policy() { # removed before the stack so that a stack that will not delete no longer lets CloudFront in
  local arn
  if ! aws lambda-web delete-resource-policy help >/dev/null 2>&1; then
    say "teardown: this CLI has no 'lambda-web delete-resource-policy' (UNVERIFIED name); the resource policy goes with the web function (app stack)"
    return 0
  fi
  arn="${WF_ARN:-$(state_get WF_ARN)}"
  [ -n "$arn" ] || arn="arn:$PARTITION:lambda:$REGION:$ACCOUNT:web-function/$P-wf"
  aws_do lambda-web delete-resource-policy --resource-arn "$arn" >/dev/null 2>&1 && return 0
  aws_gone && return 0   # no function or no policy: nothing to remove
  say "teardown: delete-resource-policy failed ($(aws_code))"
  return 1
}
# shellcheck disable=SC2317,SC2329  # called through td()
td_cert() {
  local arn="${CERT_ARN:-$(state_get CERT_ARN)}" found="" a
  if [ -z "$arn" ]; then # discovery: certificates for our alias name that carry this run's tag
    # shellcheck disable=SC2086  # ACM_STATUSES is a list of words on purpose
    for a in $(aws_names acm list-certificates --certificate-statuses $ACM_STATUSES --query "CertificateSummaryList[?DomainName=='$H_G'].CertificateArn"); do
      if [ "$(aws_ro acm list-tags-for-certificate --certificate-arn "$a" --query "Tags[?Key=='RunId'].Value | [0]" --output text 2>/dev/null)" = "$RUN" ]; then found="$a"; fi
    done
    arn="$found"
  fi
  [ -n "$arn" ] || return 0
  for _ in $(seq 1 "${CERT_DELETE_TRIES:-12}"); do
    if aws_do acm delete-certificate --certificate-arn "$arn" 2>/dev/null; then return 0; fi
    aws_gone && return 0
    nap 30   # "in use" until CloudFront has let go of it
  done
  return 1
}
# shellcheck disable=SC2317,SC2329  # called through td()
td_logs() {
  local r pfx g rc=0
  for r in "$REGION" "$PROBE_REGION"; do
    for pfx in "/aws/lambda/$P" "/aws/lambda/web/$P"; do
      for g in $(AWS_R="$r" aws_names logs describe-log-groups --log-group-name-prefix "$pfx" --query 'logGroups[].logGroupName'); do
        AWS_R="$r" aws_do logs delete-log-group --log-group-name "$g" >/dev/null 2>&1 || aws_gone || rc=1
      done
    done
  done
  return "$rc"
}
td_mark_torn_down() { # the run is gone: keep the state file as a record, without the old Worker token line, marked torn down
  [ -f "$STATE_FILE" ] || return 0
  grep -v '^WTOKEN=' "$STATE_FILE" > "$STATE_FILE.tmp"; mv "$STATE_FILE.tmp" "$STATE_FILE"
  state_set TORN_DOWN "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
do_teardown() {
  [ "$TD_STATE" != 2 ] || return 0
  TD_STATE=1; TD_FAIL=0
  td_traps
  [ -n "${ACCOUNT:-}" ] || aws_identity
  say "teardown of run $RUN (only resources named lwf-$RUN* or commented 'lwf-sample $RUN')"
  td "Cloudflare resources" td_cloudflare
  td "Worker IAM access keys" td_keys
  td "web function resource policy" td_policy
  td "app stack $APP_STACK (CloudFront deletion takes 10-30 minutes; the kill switch schedule goes with it)" td_app_stack
  td "ACM certificate" td_cert
  td "object versions in the artifacts bucket" empty_bucket
  td "artifacts stack $ART_STACK" delete_stack "$ART_STACK" "$REGION"
  td "probe stack $PROBE_STACK" delete_stack "$PROBE_STACK" "$PROBE_REGION"
  td "log groups" td_logs
  scan_leftovers
  local rc=$?
  if [ "$rc" = 3 ]; then # the only thing Lambda re-creates is log groups: one more pass, then scan again
    say "teardown: something was left (Lambda re-creates its log groups); second pass over the log groups"
    td "log groups (second pass)" td_logs
    scan_leftovers; rc=$?
  fi
  if [ "$TD_FAIL" != 0 ] && [ "$rc" = 0 ]; then rc=3; fi
  TEARDOWN_RC=$rc
  TD_STATE=2
  if [ "$rc" = 0 ]; then td_mark_torn_down; fi
  if [ "$TD_SIGS" -gt 0 ]; then
    if [ "$rc" = 0 ]; then say "teardown completed despite the interrupt; nothing is left"
    else say "teardown interrupted and incomplete: re-run --teardown $RUN"; fi
  fi
  return 0
}
teardown_exit_code() { # leftovers win; otherwise an interrupt is still reported as one
  if [ "$TEARDOWN_RC" != 0 ]; then echo "$TEARDOWN_RC"
  elif [ "$TD_SIGS" -gt 0 ]; then sig_rc "$TD_SIGNAME"
  else echo 0; fi
}

# ---------------------------------------------------------------------------------------------------- leftover scan
LEFT=0
left() { LEFT=$((LEFT + 1)); say "LEFTOVER $1: $2"; }
gap() { LEFT=$((LEFT + 1)); say "SCAN-GAP $1: could not check ($2)"; }
scan_leftovers() {
  LEFT=0
  say "leftover scan for run $RUN"
  local r s names x
  for s in "$ART_STACK|$REGION" "$APP_STACK|$REGION" "$PROBE_STACK|$PROBE_REGION"; do
    r="${s#*|}"; s="${s%|*}"
    if x="$(stack_status "$s" "$r")"; then
      [ "$x" = GONE ] || left "cloudformation stack" "$s ($x)"
    else gap "cloudformation $s" "$(aws_code)"; fi
  done
  for r in "$REGION" "$PROBE_REGION"; do
    names="$(AWS_R="$r" aws_names lambda list-functions --query "Functions[?starts_with(FunctionName,'$P')].FunctionName")" || { gap "lambda functions in $r" "$(aws_code)"; names=""; }
    for x in $names; do left "lambda function ($r)" "$x"; done
    names="$(AWS_R="$r" aws_names logs describe-log-groups --log-group-name-prefix "/aws/lambda/$P" --query 'logGroups[].logGroupName')" || { gap "log groups in $r" "$(aws_code)"; names=""; }
    for x in $names; do left "log group ($r)" "$x"; done
    names="$(AWS_R="$r" aws_names logs describe-log-groups --log-group-name-prefix "/aws/lambda/web/$P" --query 'logGroups[].logGroupName')" || { gap "web log groups in $r" "$(aws_code)"; names=""; }
    for x in $names; do left "web function log group ($r)" "$x"; done
  done
  if aws lambda-web get-web-function help >/dev/null 2>&1; then
    if aws_ro lambda-web get-web-function --function-name "$P-wf" >/dev/null 2>&1; then left "web function" "$P-wf"; elif ! aws_gone; then gap "web function $P-wf" "$(aws_code)"; fi
  else gap "web functions" "this CLI has no 'lambda-web get-web-function' (UNVERIFIED name); stack deletion status above is the evidence"; fi
  names="$(aws_names cloudfront list-distributions --query "DistributionList.Items[?contains(Comment,'$P ')].Id")" || { gap "cloudfront distributions" "$(aws_code)"; names=""; }
  for x in $names; do left "cloudfront distribution" "$x"; done
  names="$(aws_names cloudfront list-origin-access-controls --query "OriginAccessControlList.Items[?starts_with(Name,'$P')].Id")" || { gap "origin access controls" "$(aws_code)"; names=""; }
  for x in $names; do left "origin access control" "$x"; done
  names="$(aws_names cloudfront list-cache-policies --type custom --query "CachePolicyList.Items[?starts_with(CachePolicy.CachePolicyConfig.Name,'$P')].CachePolicy.Id")" || { gap "cache policies" "$(aws_code)"; names=""; }
  for x in $names; do left "cache policy" "$x"; done
  names="$(aws_names cloudfront list-response-headers-policies --type custom --query "ResponseHeadersPolicyList.Items[?starts_with(ResponseHeadersPolicy.ResponseHeadersPolicyConfig.Name,'$P')].ResponseHeadersPolicy.Id")" || { gap "response headers policies" "$(aws_code)"; names=""; }
  for x in $names; do left "response headers policy" "$x"; done
  names="$(aws_names s3api list-buckets --query "Buckets[?starts_with(Name,'$P')].Name")" || { gap "s3 buckets" "$(aws_code)"; names=""; }
  for x in $names; do left "s3 bucket" "$x"; done
  names="$(aws_names iam list-roles --query "Roles[?starts_with(RoleName,'$P')].RoleName")" || { gap "iam roles" "$(aws_code)"; names=""; }
  for x in $names; do left "iam role" "$x"; done
  names="$(aws_names iam list-users --query "Users[?starts_with(UserName,'$P')].UserName")" || { gap "iam users" "$(aws_code)"; names=""; }
  for x in $names; do left "iam user" "$x"; done
  names="$(aws_names scheduler list-schedules --name-prefix "$P" --query 'Schedules[].Name')" || { gap "scheduler" "$(aws_code)"; names=""; }
  for x in $names; do left "schedule" "$x"; done
  names="$(aws_names cloudwatch describe-alarms --alarm-name-prefix "$P" --query 'MetricAlarms[].AlarmName')" || { gap "cloudwatch alarms" "$(aws_code)"; names=""; }
  for x in $names; do left "cloudwatch alarm" "$x"; done
  names="$(aws_names sns list-topics --query "Topics[?contains(TopicArn,':$P-')].TopicArn")" || { gap "sns topics" "$(aws_code)"; names=""; }
  for x in $names; do left "sns topic" "$x"; done
  # shellcheck disable=SC2086  # ACM_STATUSES is a list of words on purpose
  names="$(aws_names acm list-certificates --certificate-statuses $ACM_STATUSES --query "CertificateSummaryList[?DomainName=='$H_G'].CertificateArn")" || { gap "acm certificates" "$(aws_code)"; names=""; }
  for x in $names; do
    if [ "$(aws_ro acm list-tags-for-certificate --certificate-arn "$x" --query "Tags[?Key=='RunId'].Value | [0]" --output text 2>/dev/null)" = "$RUN" ]; then left "acm certificate" "$x"; fi
  done
  if [ -n "$HDR" ] && [ -n "$ZID" ]; then
    names="$(cf_list "/zones/$ZID/dns_records" | jq -r --arg c "$COMMENT" 'select(.comment == $c) | .name' 2>/dev/null)" || { gap "cloudflare dns" "HTTP $CF_HTTP"; names=""; }
    for x in $names; do left "cloudflare dns record" "$x"; done
    names="$(cf_list "/accounts/$ACC_CF/workers/domains" | jq -r --arg s "$WORKER" 'select(.service == $s) | .hostname' 2>/dev/null)" || { gap "cloudflare workers domains" "HTTP $CF_HTTP"; names=""; }
    for x in $names; do left "cloudflare workers custom domain" "$x"; done
    if cf GET "/accounts/$ACC_CF/workers/scripts/$WORKER/settings"; then left "cloudflare worker" "$WORKER"; elif ! cf_gone; then gap "cloudflare worker" "HTTP $CF_HTTP"; fi
    # any pack that covers only this run's names: reported, but deleted by the teardown only if this run recorded it
    names="$(packs_for_our_names 2>/dev/null)" || { gap "cloudflare certificate packs" "HTTP $CF_HTTP"; names=""; }
    for x in $names; do
      case " $(state_get CF_PACKS) " in
        *" $x "*) left "cloudflare certificate pack" "$x" ;;
        *) left "cloudflare certificate pack" "$x (not recorded by this run, so the teardown did not delete it; delete it in the dashboard if it is not someone else's)" ;;
      esac
    done
  else
    gap "cloudflare" "no token or zone: records, Worker, custom domain and certificates were NOT scanned"
  fi
  if [ "$LEFT" = 0 ]; then say "scan: nothing left"; return 0; fi
  say "scan: $LEFT item(s) left or unchecked"
  return 3
}

# ---------------------------------------------------------------------------------------------------- restore trap
TEARDOWN_RC=0
exec 3>&1 4>&2   # the real stdout and stderr, for on_exit (a signal can arrive while a command's output goes to /dev/null)
# shellcheck disable=SC2317,SC2329  # runs from the EXIT trap
on_exit() {
  local rc=$?
  trap - EXIT
  exec 1>&3 2>&4
  set +e
  if [ "$rc" -ne 0 ] && [ "$CREATE_STARTED" = 1 ] && [ "$MODE" = run ] && [ "$TD_STATE" != 2 ] && [ "$TD_ABANDONED" = 0 ]; then
    td_traps   # a further Ctrl-C is reported, never a silent stop
    say "RESTORE: the run failed or was interrupted (exit $rc); removing what this run created"
    do_teardown
    say "RESTORE: finished (leftover scan result $TEARDOWN_RC). State file: $STATE_FILE"
  else
    trap '' INT TERM HUP
  fi
  rm -rf "$TMP"   # with it the mode-600 Cloudflare header file
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---------------------------------------------------------------------------------------------------- main
main_teardown_or_status() {
  preflight_tools
  aws_identity || die "AWS credentials do not work"
  [ -z "$ZONE" ] || [ -z "$(state_get_run ZONE)" ] || [ "$ZONE" = "$(state_get_run ZONE)" ] || die "run $RUN was created for another Cloudflare zone than --zone; refusing (a teardown for the wrong zone would report 'nothing left' without having looked at the right records)"
  [ -n "$ZONE" ] || ZONE="$(state_get_run ZONE)"
  if [ -z "$ZONE" ]; then
    [ -t 0 ] || die "--zone is required (the state file of run $RUN does not name it)"
    printf 'Cloudflare zone (domain name): ' >&2; IFS= read -r ZONE
  fi
  [[ "$ZONE" =~ $HOST_RE ]] || die "zone '$ZONE' is not a lower-case DNS name"
  guard_state
  set_names
  mkdir -p "$RAWDIR"
  if get_token; then lookup_zone || { warn "Cloudflare zone lookup failed (HTTP $CF_HTTP); Cloudflare resources cannot be checked"; HDR=""; }; else HDR=""; warn "no Cloudflare token: Cloudflare resources will not be handled"; fi
  if [ "$MODE" = status ]; then
    say "state file $STATE_FILE:"; [ -f "$STATE_FILE" ] && redact < "$STATE_FILE" | grep -v '^WTOKEN='
    scan_leftovers; exit $?
  fi
  do_teardown
  if [ "$TEARDOWN_RC" = 0 ]; then say "teardown complete, nothing left"
  else say "teardown finished with leftovers (exit 3): see LEFTOVER / SCAN-GAP / TEARDOWN lines above"; fi
  exit "$(teardown_exit_code)"
}
guard_state() { # the run's resources are named after the account; another account would look empty and "clean"
  local a4; a4="$(state_get_run ACCOUNT_LAST4)"
  [ -z "$a4" ] || [ "$a4" = "${ACCOUNT: -4}" ] || die "run $RUN was created in the AWS account ending $a4, but these credentials are for the account ending ${ACCOUNT: -4}; refusing"
}
check_resume_kill_at() { # a resumed run must have at least an hour before its kill switch cuts it off
  local k e now
  k="$(state_get_run KILL_AT)"
  [ -n "$k" ] || die "the state file of run $RUN has no KILL_AT; remove the run with --teardown $RUN and start a fresh run"
  e="$(utc_epoch "$k")" || die "cannot read KILL_AT ($k) of run $RUN; remove it with --teardown $RUN and start a fresh run"
  now="$(date +%s)"
  if [ $((e - now)) -lt 3600 ]; then
    if [ "$e" -le "$now" ]; then die "the kill switch of run $RUN fired at $k UTC; resuming would test a braked run. Remove it with --teardown $RUN and start a fresh run"; fi
    die "the kill switch of run $RUN fires at $k UTC, less than an hour from now, which would cut the tests off. Remove it with --teardown $RUN and start a fresh run"
  fi
}
state_get_run() { # key from the state file of --run (before set_names has run)
  [ -f "$STATE_DIR/$RUN.env" ] || return 0
  grep -E "^$1=" "$STATE_DIR/$RUN.env" | tail -n 1 | cut -d= -f2-
}

main() {
  if [ "$MODE" != run ]; then main_teardown_or_status; fi

  say "lwf-sample: Lambda Web Functions vs Function URL behind CloudFront or Cloudflare$([ "$DRY" = 1 ] && echo ' [DRY RUN, read-only]')"
  preflight_tools
  if [ "$RESUME" = 1 ]; then
    [ -f "$STATE_DIR/$RUN.env" ] || die "no state file for run $RUN in $STATE_DIR"
    [ -z "$(state_get_run TORN_DOWN)" ] || die "run $RUN was torn down at $(state_get_run TORN_DOWN); there is nothing to resume. Start a fresh run"
    check_resume_kill_at
    [ -z "${LWF_KILL_HOURS:-}" ] || warn "LWF_KILL_HOURS is ignored on --resume: the kill switch time was fixed when run $RUN started"
    [ -n "$ZONE" ] || ZONE="$(state_get_run ZONE)"
    [ -z "$(state_get_run O1)" ] || { O1="$(state_get_run O1)"; O2="$(state_get_run O2)"; O3="$(state_get_run O3)"; }
  else
    RUN="${LWF_RUN_ID:-$(date -u +%y%m%d%H%M)-$(openssl rand -hex 2)}"
    printf '%s' "$RUN" | grep -Eq '^[0-9]{10}-[0-9a-f]{4}$' || die "LWF_RUN_ID must look like 2610181230-ab12"
  fi
  if [ -n "${LWF_ALERT_EMAIL:-}" ]; then
    printf '%s' "$LWF_ALERT_EMAIL" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' || die "LWF_ALERT_EMAIL is not an email address"
    redact_add "$LWF_ALERT_EMAIL" "<alert-email>"
  fi
  if [ -z "$ZONE" ]; then
    [ -t 0 ] || die "--zone <your Cloudflare zone> is required"
    printf 'Cloudflare zone (domain name): ' >&2; IFS= read -r ZONE
  fi
  [[ "$ZONE" =~ $HOST_RE ]] || die "zone '$ZONE' is not a lower-case DNS name"
  preflight_aws
  [ "$RESUME" = 0 ] || guard_state
  set_names
  if [ "$DRY" = 0 ]; then
    mkdir -p "$RAWDIR"
    [ ! -s "$RES_TSV" ] || mv "$RES_TSV" "$RES_TSV.before-resume-$(date +%s)"   # a resumed run starts its test results afresh
    : > "$RES_TSV"
  fi
  if get_token; then
    preflight_cloudflare
  elif [ "$DRY" = 1 ]; then
    say "NOTE: no Cloudflare token (dry run without a terminal): the Cloudflare checks were skipped"
  else
    die "no Cloudflare token: set CF_API_TOKEN or type it at the prompt"
  fi
  print_plan
  if [ "$DRY" = 1 ]; then
    if [ "$BLOCKED" = 1 ]; then say "dry run: BLOCKERS found, a real run would refuse"; exit 1; fi
    say "dry run: all checks passed; nothing was changed"
    exit 0
  fi

  say ""
  if [ "$RESUME" = 0 ]; then
    say "This creates REAL resources in AWS account ...${ACCOUNT: -4} and in the Cloudflare zone $ZONE (CloudFront, Lambda, IAM, S3, ACM,"
    say "a Worker, DNS records) and removes them at the end. To continue type exactly: $PHRASE"
  else
    say "This RESUMES run $RUN in AWS account ...${ACCOUNT: -4} and the Cloudflare zone $ZONE: it creates the steps that are not done yet"
    say "(REAL resources), runs the tests and removes everything at the end. The kill switch fires at $(state_get_run KILL_AT) UTC. To continue type exactly: $PHRASE"
  fi
  printf '> ' >&2; IFS= read -r typed || typed=""
  [ "$typed" = "$PHRASE" ] || die "confirmation phrase did not match; nothing was changed"
  if [ "$RESUME" = 0 ]; then
    state_set RUN "$RUN"; state_set ZONE "$ZONE"; state_set ACCOUNT_LAST4 "${ACCOUNT: -4}"; state_set O1 "$O1"; state_set O2 "$O2"; state_set O3 "$O3"
    state_set KILL_AT "$(future_utc "$KILL_HOURS")"
  fi
  CREATE_STARTED=1
  KILL_AT="$(state_get KILL_AT)"
  CERT_ARN=""
  step_artifacts
  step_cert
  step_app
  step_policy
  step_wait_cloudfront
  step_worker
  step_dns
  step_probe
  wait_worker
  wait_alias
  run_tests
  write_report
  if [ "$KEEP" = 1 ]; then
    say "kept (--keep): the kill switch fires at $KILL_AT UTC. Remove everything with: $0 --teardown $RUN --zone $ZONE"
    exit 0
  fi
  do_teardown
  exit "$(teardown_exit_code)"
}
main
