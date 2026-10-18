#!/usr/bin/env bash
# lib.sh - helpers for lwf-sample.sh. Sourced, not run. Works with bash 3.2 (macOS) or newer.
# Needs: aws CLI v2, curl, jq, node (20+), zip.

# shellcheck disable=SC2034  # variables are used by lwf-sample.sh, which sources this file
umask 077   # state, results and temp files are readable by the owner only

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REGION="us-east-1"                 # everything except the optional probe; CloudFront certificates must be here too
PROBE_REGION="eu-west-1"           # optional O2 probe (eu-west-1 is a launch Region of Lambda Web Functions)
PHRASE="deploy lwf sample"
CF_API="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
STATE_DIR="${LWF_STATE_DIR:-$HERE/lwf-state}"
RESULTS_ROOT="${LWF_RESULTS_DIR:-$HERE/results}"
NODE="${LWF_NODE:-node}"
KILL_HOURS="${LWF_KILL_HOURS:-6}"
ACM_STATUSES="PENDING_VALIDATION ISSUED INACTIVE EXPIRED VALIDATION_TIMED_OUT REVOKED FAILED"   # list-certificates shows only ISSUED by default
COMPAT_DATE="2026-10-01"           # Workers compatibility date; must not be in the future
export AWS_PAGER=""

# list prices used by A7 (extrapolation only). As read 2026-10-18 on https://aws.amazon.com/lambda/pricing/ - check before quoting.
PRICE_WF_PER_M_REQ="0.30"; PRICE_WF_VCPU_S="0.0000276944"; PRICE_WF_GB_S="0.0000036667"
PRICE_FU_PER_M_REQ="0.20"; PRICE_FU_GB_S_ARM="0.0000133334"   # the Event Function is arm64 (Arm duration rate, first tier, us-east-1)
WF_GB=2                            # memory of one web function environment (2 vCPU, 2 GB per the documentation as read 2026-10-18)
WF_MAX_ENVS=2                      # MaxEnvironments of the endpoint (passed to the stack; A4 reports environments against it)
FU_CAP_DEFAULT=130                 # reserved concurrency of the Function URL function (A4 needs 128); lowered to fit the account
SLOW_MAX_MS=3000                   # app/core.mjs caps /slow at this; A4 uses 2000

DRY=0; MODE=run; KEEP=0; O1=1; O2=1; O3=1; ZONE=""; RUN=""; RESUME=0
ACCOUNT=""; ACC_CF=""; ZID=""; CF_API_TOKEN="${CF_API_TOKEN:-}"; export -n CF_API_TOKEN
AK_ID=""; AK_SECRET=""; WTOKEN=""; PARTITION="aws"; FU_CAP=-1
# TD_STATE: 0 teardown not started, 1 running, 2 finished (with or without leftovers). TD_SIGS counts signals during teardown.
CREATE_STARTED=0; TD_STATE=0; TD_FAIL=0; TD_SIGS=0; TD_SIGNAME=""; TD_ABANDONED=0; BLOCKED=0
TMP=""; HDR=""; STATE_FILE=""; RES_TSV=""; RAWDIR=""; OUTDIR=""
CF_HTTP=""; REQ_TOTAL=0; REQ_WF=0
# children that never need AWS credentials (curl to Cloudflare, node for the probes) run without the AWS_* secrets of the environment
NOAWS=(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_SECURITY_TOKEN)
REDACT_FROM=(); REDACT_TO=()

# ---------------------------------------------------------------------------------------------------- output, redaction
# Everything that reaches the screen, a results file or the raw files goes through redact(). Exact values first (token, key,
# zone, account, run resources), then patterns. Best effort: read results/ before you share it.
redact_add() { # literal label
  [ -n "${1:-}" ] || return 0
  REDACT_FROM+=("$1"); REDACT_TO+=("$2")
}
redact() {
  local s i
  s="$(cat)"
  [ -n "$s" ] || return 0
  # ARNs first (they contain the account id), then exact values, then patterns
  s="$(printf '%s\n' "$s" | sed -E -e 's#arn:aws[a-z-]*:[A-Za-z0-9-]*:[a-z0-9-]*:[0-9]*:[^ ",)]*#<arn>#g')"
  i=0
  while [ "$i" -lt "${#REDACT_FROM[@]}" ]; do
    s="${s//"${REDACT_FROM[$i]}"/${REDACT_TO[$i]}}"
    i=$((i + 1))
  done
  [ -z "${CF_API_TOKEN:-}" ] || s="${s//"$CF_API_TOKEN"/<cloudflare-token>}"
  [ -z "${AK_SECRET:-}" ] || s="${s//"$AK_SECRET"/<aws-secret-key>}"
  [ -z "${WTOKEN:-}" ] || s="${s//"$WTOKEN"/<worker-token>}"
  printf '%s\n' "$s" | sed -E \
    -e ':a' -e 's#(^|[^0-9])[0-9]{12}([^0-9]|$)#\1<account-id>\2#' -e 'ta' \
    -e 's#(AKIA|ASIA)[0-9A-Z]{16}#<access-key-id>#g' \
    -e 's#[A-Za-z0-9-]+\.lambda-web\.[a-z0-9-]+\.on\.aws#<wf-endpoint-host>#g' \
    -e 's#[A-Za-z0-9-]+\.lambda-url\.[a-z0-9-]+\.on\.aws#<fu-host>#g' \
    -e 's#[A-Za-z0-9-]+\.cloudfront\.net#<cloudfront-domain>#g' \
    -e 's#(^|[^A-Za-z0-9])E[A-Z0-9]{12,13}([^A-Za-z0-9]|$)#\1<distribution-id>\2#g' \
    -e 's#(^|[^0-9a-f])[0-9a-f]{32}([^0-9a-f]|$)#\1<cf-id>\2#g' \
    -e 's#([Xx]-[Aa]mz-[Ss]ecurity-[Tt]oken|[Aa]uthorization|[Ss]ession[Tt]oken|[Xx]-[Ll]wf-[Tt]oken)([:=" ]+)[^ ,"]+#\1\2<redacted>#g' \
    -e 's#[A-Za-z0-9+/=_-]{40,}#<redacted-token>#g'
}
# say uses a here-string, not a pipe: after Ctrl-C, bash kills pipelines started in the EXIT trap.
say() { redact <<< "$*"; }
warn() { redact <<< "WARN: $*" >&2; }
die() { redact <<< "ERROR: $*" >&2; exit 2; }
# a problem the real run refuses on; the dry run lists it, goes on and exits 1 at the end
blocker() { if [ "$DRY" = 1 ]; then say "BLOCKER: $*"; BLOCKED=1; else die "$*"; fi; }

nap() { sleep "$1"; }

# ---------------------------------------------------------------------------------------------------- aws wrappers
# aws_ro: reads only. aws_do: may change things, refuses in --dry-run. stdout is for the caller, stderr is redacted.
# AWS_R=<region> aws_ro ... runs in another Region.
_aws() {
  local rc
  aws --region "${AWS_R:-$REGION}" "$@" 2>"$TMP/aws.err"; rc=$?
  if [ -s "$TMP/aws.err" ]; then redact < "$TMP/aws.err" >&2; fi
  return "$rc"
}
aws_ro() { _aws "$@"; }
aws_do() {
  [ "$DRY" = 0 ] || { echo "internal error: aws_do called in --dry-run: $1 $2" >&2; exit 99; }
  _aws "$@"
}
# did the last aws call fail because the resource does not exist? (error codes and phrases only)
aws_gone() { grep -Eqi 'NoSuchEntity|ResourceNotFound|NoSuchBucket|NoSuchDistribution|NoSuchOriginAccessControl|NoSuchCachePolicy|NoSuchResponseHeadersPolicy|does not exist|NotFoundException|\(404\)|Not Found|NoSuchKey|InvalidParameterValueException.*not found' "$TMP/aws.err"; }
aws_code() { sed -n 's/.*An error occurred (\([A-Za-z0-9.]*\)).*/\1/p' "$TMP/aws.err" | head -n 1; }
# words: one name per line. The CLI's text output prints "None" for a null query result (for example
# DistributionList.Items when an account has no distribution); that is not a name.
words() { tr -s '[:blank:]' '\n' | grep -v -x -e None -e null -e '' || true; }
# aws_names ARGS... : a read-only list query with --output text, as one name per line ("None" removed). 1 if the call failed.
aws_names() {
  local out
  out="$(aws_ro "$@" --output text 2>/dev/null)" || return 1
  printf '%s\n' "$out" | words
}

# ---------------------------------------------------------------------------------------------------- Cloudflare API
# The token is a shell variable and a mode-600 header file only. curl reads the header with -H @file, so it is never in argv.
cf_init() { # writes the header file once the token is known
  HDR="$TMP/cf.hdr"
  ( umask 077; printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" > "$HDR" )
}
# cf METHOD PATH [json-file | -]   body in $TMP/cf.out, HTTP status in CF_HTTP; returns 0 only when HTTP 2xx and success=true.
# "-" reads the JSON body from stdin (used for secrets).
cf() {
  local method="$1" path="$2" body="${3:-}" args
  [ "$method" = GET ] || [ "$DRY" = 0 ] || { echo "internal error: cf $method in --dry-run: $path" >&2; exit 99; }
  args=(-sS --max-time 90 -H "@$HDR" -X "$method" -o "$TMP/cf.out" -w '%{http_code}')
  if [ -n "$body" ]; then args+=(-H 'Content-Type: application/json' --data "@${body}"); fi
  CF_HTTP="$("${NOAWS[@]}" curl "${args[@]}" "$CF_API$path" 2>"$TMP/cf.err")" || { CF_HTTP=000; redact < "$TMP/cf.err" >&2; return 1; }
  case "$CF_HTTP" in 2??) ;; *) return 1 ;; esac
  jq -e '.success == true' "$TMP/cf.out" >/dev/null 2>&1
}
# cf_multipart PATH METADATA-FILE FILE... : PUT a Worker upload (modules named after the files)
cf_upload_worker() {
  local path="$1" meta="$2"; shift 2
  local args f
  args=(-sS --max-time 120 -H "@$HDR" -X PUT -o "$TMP/cf.out" -w '%{http_code}' -F "metadata=@${meta};type=application/json")
  for f in "$@"; do args+=(-F "$(basename "$f")=@${f};type=application/javascript+module"); done
  CF_HTTP="$("${NOAWS[@]}" curl "${args[@]}" "$CF_API$path" 2>"$TMP/cf.err")" || { CF_HTTP=000; redact < "$TMP/cf.err" >&2; return 1; }
  case "$CF_HTTP" in 2??) ;; *) return 1 ;; esac
  jq -e '.success == true' "$TMP/cf.out" >/dev/null 2>&1
}
cf_errors() { jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' "$TMP/cf.out" 2>/dev/null | head -c 400; }
cf_gone() { [ "$CF_HTTP" = 404 ]; }
# cf_list PATH-with-query-and-page-placeholder -> concatenated .result arrays on stdout (pages of 100, up to 50 pages)
cf_list() {
  local path="$1" page=1 total=1 sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  : > "$TMP/cf.list"
  while [ "$page" -le "$total" ] && [ "$page" -le 50 ]; do
    cf GET "${path}${sep}page=${page}&per_page=100" || return 1
    jq -c '.result[]?' "$TMP/cf.out" >> "$TMP/cf.list" 2>/dev/null || return 1
    total="$(jq -r '.result_info.total_pages // 1' "$TMP/cf.out" 2>/dev/null)"
    case "$total" in ''|*[!0-9]*) total=1 ;; esac
    page=$((page + 1))
  done
  cat "$TMP/cf.list"
}

# ---------------------------------------------------------------------------------------------------- state, results
state_set() { # KEY VALUE (single line)
  case "$2" in *$'\n'*) die "internal: state value for $1 has a newline" ;; esac
  [ -n "$STATE_FILE" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"
}
state_get() { [ -f "$STATE_FILE" ] || return 0; grep -E "^$1=" "$STATE_FILE" | tail -n 1 | cut -d= -f2-; }
done_step() { [ "$(state_get "DONE_$1")" = 1 ]; }
mark_done() { state_set "DONE_$1" 1; }

# rec ID STATUS DETAIL  (STATUS: PASS FAIL MEASURED INCONCLUSIVE SKIPPED)
rec() {
  local id="$1" st="$2" detail="$3"
  detail="$(redact <<< "$detail" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\n' "$id" "$st" "$detail" >> "$RES_TSV"
  say "  $st $id: $detail"
}
raw() { # NAME  (content on stdin) -> redacted file in results/<run>/raw/
  redact > "$RAWDIR/$1"
}
sha256_of() { # string -> hex (no trailing newline hashed)
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.* //'; fi
}
utc_epoch() { # yyyy-mm-ddThh:mm:ss (UTC) -> seconds since the epoch (GNU or BSD date); 1 if it cannot be parsed
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%S' "$1" +%s 2>/dev/null
}
future_utc() { # hours -> yyyy-mm-ddThh:mm:ss in UTC (GNU or BSD date)
  local e
  e=$(( $(date +%s) + $1 * 3600 ))
  date -u -d "@$e" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$e" +%Y-%m-%dT%H:%M:%S
}
