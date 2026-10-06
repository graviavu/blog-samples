#!/usr/bin/env bash
# verify.sh - deploy tests for blog post 1 (CloudFront as a reverse proxy without per-route configuration).
#
# Needs: bash and curl. Test T4 additionally needs the AWS CLI v2 (it changes one KeyValueStore key).
# Safe to run: it sends GET requests to YOUR distribution only, and T4 writes and then deletes the single
# key "t4-probe" in YOUR route table. It never publishes or changes the function or the distribution.
#
# Usage:  ./verify.sh [distribution-domain]        (reads deploy.env if deploy.sh wrote it)
# Environment (all optional when deploy.env exists):
#   CF_DOMAIN             dxxxx.cloudfront.net of the main stack (or first argument)
#   ROUTE_ATTRIBUTE       x-backend (default) or host      CACHE_KEY_ATTRIBUTE  x-backend (default), host or none
#   ALIAS_A ALIAS_B       alias domains, only for Host-based routing
#   KVS_ARN ORIGIN_A_HOST ORIGIN_B_HOST FUNCTION_NAME      for T4 (needs aws CLI)
#   ORIGIN_A_HOST ORIGIN_B_HOST DEFAULT_ORIGIN_HOST ORIGIN_AUTH   for T6i (direct calls must be refused when ORIGIN_AUTH=AWS_IAM)
#   EDGE_DOMAIN           domain of the optional Lambda@Edge stack, enables T7
#   RESULTS_FILE          output file (default verify-results-<utc time>.txt)
#   READY_MAX (900)       seconds to wait for the stack to answer     T4_MAX (180)  seconds to wait in T4
#
# Output: PASS/FAIL/INCONCLUSIVE per test, one machine line per test
#   TEST=T1b RESULT=PASS DETAIL=...
# and a results file with every raw request, header and body. Send that file back (see README).
# PASS means the observed behavior matched the stated expectation (which is the post's claim or the
# documented behavior). FAIL means it did not. INCONCLUSIVE means the test could not decide.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
[ -f deploy.env ] && . ./deploy.env

DOMAIN="${1:-${CF_DOMAIN:-}}"
ROUTE_ATTRIBUTE="${ROUTE_ATTRIBUTE:-x-backend}"
CACHE_KEY_ATTRIBUTE="${CACHE_KEY_ATTRIBUTE:-x-backend}"
ALIAS_A="$(printf '%s' "${ALIAS_A:-}" | tr '[:upper:]' '[:lower:]')"
ALIAS_B="$(printf '%s' "${ALIAS_B:-}" | tr '[:upper:]' '[:lower:]')"
KVS_ARN="${KVS_ARN:-}"
ORIGIN_A_HOST="${ORIGIN_A_HOST:-}"
ORIGIN_B_HOST="${ORIGIN_B_HOST:-}"
FUNCTION_NAME="${FUNCTION_NAME:-}"
DEFAULT_ORIGIN_HOST="${DEFAULT_ORIGIN_HOST:-}"
ORIGIN_AUTH="${ORIGIN_AUTH:-AWS_IAM}"
EDGE_DOMAIN="${EDGE_DOMAIN:-}"
READY_MAX="${READY_MAX:-900}"
T4_MAX="${T4_MAX:-180}"
REGION="us-east-1"
SCHEME="${VERIFY_SCHEME:-https}"   # test hook for the local mock only; leave unset against AWS
RESULTS_FILE="${RESULTS_FILE:-verify-results-$(date -u +%Y%m%dT%H%M%SZ).txt}"

if [ -z "$DOMAIN" ]; then
  echo "Usage: ./verify.sh <distribution-domain>   (or run deploy.sh first, or set CF_DOMAIN)" >&2
  exit 2
fi
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }

RUN="r$(date +%s)p$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")" || exit 2
# On any exit (also Ctrl-C or kill) mask the results file before leaving, then remove the temp dir.
finish() {
  if [ -f "$RESULTS_FILE" ] && type redact_results >/dev/null 2>&1; then redact_results "$RESULTS_FILE"; fi
  rm -rf "$TMP"
}
trap finish EXIT
trap 'exit 130' INT TERM
REQ_N=0
N_PASS=0; N_FAIL=0; N_INC=0
MACHINE=""

if [ "$ROUTE_ATTRIBUTE" = "host" ]; then KEY_A="$ALIAS_A"; KEY_B="$ALIAS_B"; else KEY_A="route-a"; KEY_B="route-b"; fi

log() { printf '%s\n' "$*" >> "$RESULTS_FILE"; }

# awscall DESCRIPTION AWS_ARGS...  runs the AWS CLI with stdout and stderr captured in temp files.
# Only the description, the exit code and the error CODE (for example AccessDeniedException) are logged:
# AWS error messages can contain account ids and IAM ARNs, so the message text is never written.
# On success the output is left in $AWS_OUT for the caller (it is not logged).
AWS_OUT="$TMP/aws.out"
awscall() {
  local desc=$1 rc code; shift
  aws "$@" > "$AWS_OUT" 2> "$TMP/aws.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    log "# aws $desc: ok"
  else
    code=$(sed -n 's/.*(\([A-Za-z0-9]*\)).*/\1/p' "$TMP/aws.err" | head -1)
    log "# aws $desc: FAILED exit=$rc error-code=${code:-unknown} (message withheld on purpose)"
  fi
  return "$rc"
}

# redact_results FILE  last line of defence: mask 12-digit numbers and ARNs in the results file.
redact_results() {
  sed -E -e 's/arn:aws[a-z-]*:[^[:space:]"'"'"',;)]*/arn:aws:REDACTED/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1REDACTED12\2/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1REDACTED12\2/g' "$1" > "$1.redacted" && mv "$1.redacted" "$1"
}

# ------------------------------------------------------------------ request helpers
# req NAME CURL_ARGS...   sends one request, appends raw request/response to the results file
# sets R_CODE (HTTP status, 000 on failure), R_H (header file), R_B (body file)
req() {
  local name=$1; shift
  REQ_N=$((REQ_N + 1))
  R_H="$TMP/h$REQ_N"; R_B="$TMP/b$REQ_N"
  local rc
  R_CODE=$(curl -sS --max-time 25 -D "$R_H" -o "$R_B" -w '%{http_code}' "$@" 2> "$TMP/err")
  rc=$?
  [ -f "$R_H" ] || : > "$R_H"
  [ -f "$R_B" ] || : > "$R_B"
  {
    echo "=================================================================="
    echo "### request $REQ_N: $name"
    echo "# curl $*"
    echo "# curl exit code $rc, http status $R_CODE, time $(date -u +%H:%M:%SZ)"
    [ -s "$TMP/err" ] && sed 's/^/# curl stderr: /' "$TMP/err"
    echo "--- response headers"
    tr -d '\r' < "$R_H"
    echo "--- response body"
    cat "$R_B"
    echo
  } >> "$RESULTS_FILE"
}

hdr() { tr -d '\r' < "$R_H" | grep -i -m1 "^$1:" | sed 's/^[^:]*:[ ]*//'; }
jget() { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$R_B" | head -1; }
is_hit() { case "$(hdr x-cache)" in Hit*|RefreshHit*) return 0 ;; *) return 1 ;; esac; }

# route_req NAME KEY PATH [EXTRA CURL ARGS]  - send a request that names route KEY
route_req() {
  local name=$1 key=$2 path=$3; shift 3
  if [ "$ROUTE_ATTRIBUTE" = "host" ]; then
    req "$name" "$SCHEME://$key$path" --connect-to "$key:443:$DOMAIN:443" "$@"
  else
    req "$name" "$SCHEME://$DOMAIN$path" -H "x-backend: $key" "$@"
  fi
}

emit() { # id result detail
  local line="TEST=$1 RESULT=$2 DETAIL=$3"
  printf '%-13s %-5s %s\n' "$2" "$1" "$3"
  log "$line"
  MACHINE="${MACHINE}${line}
"
  case "$2" in PASS) N_PASS=$((N_PASS + 1)) ;; FAIL) N_FAIL=$((N_FAIL + 1)) ;; *) N_INC=$((N_INC + 1)) ;; esac
}

hyp() { # id hypothesis expected
  echo
  echo "[$1] hypothesis: $2"
  echo "[$1] expected:   $3"
  log ""
  log "######## $1 hypothesis: $2 | expected: $3"
}

need_route_keys() {
  if [ -z "$KEY_A" ] || [ -z "$KEY_B" ]; then
    emit "$1" INCONCLUSIVE "not run: ROUTE_ATTRIBUTE=host needs ALIAS_A and ALIAS_B (see README)"
    return 1
  fi
}

# ------------------------------------------------------------------ header
: > "$RESULTS_FILE"
{
  echo "verify.sh results - cloudfront-request-routing sample"
  echo "start (utc): $(date -u +%Y-%m-%dT%H:%M:%SZ)   run id: $RUN"
  echo "domain: $DOMAIN   route attribute: $ROUTE_ATTRIBUTE   cache key attribute: $CACHE_KEY_ATTRIBUTE"
  echo "alias a: ${ALIAS_A:-(none)}   alias b: ${ALIAS_B:-(none)}   edge domain: ${EDGE_DOMAIN:-(none)}"
  echo "curl: $(curl --version | head -1)"
  command -v aws >/dev/null 2>&1 && echo "aws cli: $(aws --version 2>/dev/null | grep -o '^aws-cli/[0-9.]*' | head -1)"
  echo "uname: $(uname -sr)"
} >> "$RESULTS_FILE"

echo "verify.sh: GET requests to $DOMAIN; raw results go to $RESULTS_FILE"
echo "mode: route on '$ROUTE_ATTRIBUTE', cache key attribute '$CACHE_KEY_ATTRIBUTE'"

# ------------------------------------------------------------------ readiness
echo
echo "[ready] waiting for the stack to route (distribution deployed, route table propagated), up to ${READY_MAX}s"
ready=0
t0=$(date +%s)
i=0
if [ -n "$KEY_A" ]; then
  while :; do
    i=$((i + 1))
    route_req "ready $i" "$KEY_A" "/ready/$RUN/$i"
    if [ "$R_CODE" = "200" ] && [ "$(jget origin)" = "origin-a" ]; then ready=1; break; fi
    [ $(( $(date +%s) - t0 )) -ge "$READY_MAX" ] && break
    sleep 5
  done
fi
if [ "$ready" = "1" ]; then
  echo "[ready] ok after $(( $(date +%s) - t0 ))s"
else
  echo "[ready] NOT ready (last status $R_CODE). Later tests will most likely be INCONCLUSIVE or FAIL." \
    "Check that the stack is deployed, the route table is seeded and the settings match."
  [ -n "$KEY_A" ] || echo "[ready] no route key for this mode (set ALIAS_A and ALIAS_B for host routing)"
fi
log "ready=$ready"

# ------------------------------------------------------------------ T1: cache key sharing
# t1_pair ID PATH: request PATH for route A, then route B; sets T1_* variables
t1_pair() {
  local id=$1 path=$2
  route_req "$id route A first" "$KEY_A" "$path" -H "x-test-marker: $id"
  T1_CODE1=$R_CODE; T1_O1=$(jget origin); T1_X1=$(hdr x-cache); T1_ID1=$(jget requestId); T1_HOST1=$(jget host)
  T1_MARK1=$(jget xTestMarker); T1_XB1=$(jget xBackend)
  route_req "$id route B same path" "$KEY_B" "$path" -H "x-test-marker: $id"
  T1_CODE2=$R_CODE; T1_O2=$(jget origin); T1_X2=$(hdr x-cache); T1_ID2=$(jget requestId)
}

if need_route_keys T1a; then
  hyp T1a "With only the path in the cache key, route A and route B asking for the same path share one cache entry (documented default key)" \
    "second request (route B) returns origin-a's body: PASS = shared entry confirmed (the hazard is real); FAIL = not shared"
  t1_pair T1a "/control/$RUN/same.json"
  if [ "$T1_CODE1" != "200" ] || [ "$T1_O1" != "origin-a" ]; then
    emit T1a INCONCLUSIVE "no clean first response on /control/ (status $T1_CODE1 origin '$T1_O1'); is EnableTestBehaviors true and the stack ready?"
  elif [ "$T1_O2" = "origin-a" ]; then
    emit T1a PASS "shared: route B got origin-a body. first x-cache='$T1_X1' second x-cache='$T1_X2' same requestId=$([ "$T1_ID1" = "$T1_ID2" ] && echo yes || echo no)"
  elif [ "$T1_O2" = "origin-b" ]; then
    emit T1a FAIL "not shared: route B got origin-b body although the cache key has only the path. x-cache '$T1_X1' then '$T1_X2'"
  else
    emit T1a INCONCLUSIVE "second response unusable: status $T1_CODE2 origin '$T1_O2'"
  fi

  if [ "$CACHE_KEY_ATTRIBUTE" = "$ROUTE_ATTRIBUTE" ]; then exp_sep=1; else exp_sep=0; fi
  hyp T1b "Default behavior with cache key attribute '$CACHE_KEY_ATTRIBUTE' and route attribute '$ROUTE_ATTRIBUTE'" \
    "$([ "$exp_sep" = 1 ] && echo "routes are separated: route B gets origin-b, then each route hits its own cached entry" || echo "attribute not in key: route B gets origin-a (shared entry, the hazard)")"
  t1_pair T1b "/t1/$RUN/same.json"
  T1B_FIRST_HOST=$T1_HOST1; T1B_MARK=$T1_MARK1; T1B_XB=$T1_XB1
  if [ "$T1_CODE1" != "200" ] || [ "$T1_O1" != "origin-a" ]; then
    emit T1b INCONCLUSIVE "no clean first response (status $T1_CODE1 origin '$T1_O1')"
  elif [ "$T1_O2" != "origin-a" ] && [ "$T1_O2" != "origin-b" ]; then
    emit T1b INCONCLUSIVE "second response unusable: status $T1_CODE2 origin '$T1_O2'"
  else
    separated=0; [ "$T1_O2" = "origin-b" ] && separated=1
    hits="n/a"
    if [ "$separated" = 1 ]; then
      # Each route should now hit its own entry. Retry a few times: eventual consistency and several cache servers per location.
      hits="no"
      n=0
      while [ "$n" -lt 6 ]; do
        n=$((n + 1))
        route_req "T1b route A repeat $n" "$KEY_A" "/t1/$RUN/same.json"
        if is_hit && [ "$(jget origin)" = "origin-a" ] && [ "$(jget requestId)" = "$T1_ID1" ]; then hits="yes after $n"; break; fi
        sleep 1
      done
    fi
    if [ "$separated" = "$exp_sep" ]; then
      emit T1b PASS "separated=$separated (expected $exp_sep); route B body '$T1_O2'; x-cache '$T1_X1' then '$T1_X2'; route A repeat hit: $hits"
    else
      emit T1b FAIL "separated=$separated but expected $exp_sep; route B body '$T1_O2'; x-cache '$T1_X1' then '$T1_X2'"
    fi
  fi

  hyp T1c "The function sends no hostHeader (CloudFront rejected it in the real run), so the backend sees its own function URL host, not the viewer's; headers in the cache key and the origin request policy reach the backend" \
    "echoed host equals the backend domain; x-test-marker arrives; the cache-key header arrives"
  if [ -z "${T1B_FIRST_HOST:-}" ]; then
    emit T1c INCONCLUSIVE "no response from T1b to inspect"
  else
    want="${ORIGIN_A_HOST:-}"
    if [ -n "$want" ]; then
      [ "$T1B_FIRST_HOST" = "$want" ] && host_ok=1 || host_ok=0
    else
      case "$T1B_FIRST_HOST" in "$DOMAIN"|"$KEY_A"|"") host_ok=0 ;; *) host_ok=1 ;; esac
    fi
    detail="backend saw Host='$T1B_FIRST_HOST' (viewer used '$DOMAIN'${ALIAS_A:+ / alias $ALIAS_A}); x-test-marker='${T1B_MARK:-absent}'; x-backend at origin='${T1B_XB:-absent}'"
    if [ "$host_ok" = 1 ] && [ "$T1B_MARK" = "T1b" ]; then emit T1c PASS "$detail"; else emit T1c FAIL "$detail"; fi
  fi
fi

# ------------------------------------------------------------------ T4: KeyValueStore propagation
hyp T4 "A changed KeyValueStore value is live at the edge without republishing the function, within seconds (AWS blog: 'a few seconds')" \
  "after put-key, the route answers from the new backend within about 10 seconds; the function is never republished"
t4_skip=""
if [ "$ROUTE_ATTRIBUTE" != "x-backend" ]; then
  t4_skip="T4 uses a header route key; run with ROUTE_ATTRIBUTE=x-backend"
elif ! command -v aws >/dev/null 2>&1; then
  t4_skip="aws CLI not found (T4 needs it to write the KeyValueStore)"
elif [ -z "$KVS_ARN" ] || [ -z "$ORIGIN_A_HOST" ] || [ -z "$ORIGIN_B_HOST" ]; then
  t4_skip="set KVS_ARN, ORIGIN_A_HOST and ORIGIN_B_HOST (deploy.env has them)"
fi
if [ -n "$t4_skip" ]; then
  emit T4 INCONCLUSIVE "not run: $t4_skip"
else
  kvs_put() { # key value
    local etag
    awscall "describe-key-value-store" cloudfront-keyvaluestore describe-key-value-store --region "$REGION" --kvs-arn "$KVS_ARN" --query ETag --output text || return 1
    etag=$(cat "$AWS_OUT")
    awscall "put-key $1" cloudfront-keyvaluestore put-key --region "$REGION" --kvs-arn "$KVS_ARN" --key "$1" --value "$2" --if-match "$etag"
  }
  fn_stamp() {
    [ -n "$FUNCTION_NAME" ] && aws cloudfront describe-function --region "$REGION" --name "$FUNCTION_NAME" --stage LIVE \
      --query 'FunctionSummary.FunctionMetadata.LastModifiedTime' --output text 2>/dev/null
  }
  # poll_for BACKEND_NAME MAX -> sets POLL_SECONDS (seconds since call), returns 0 when seen
  poll_for() {
    local want=$1 max=$2 start n=0 pop=""
    start=$(date +%s)
    while :; do
      n=$((n + 1))
      # a fresh path per poll so the cache never answers
      req "T4 poll $n for $want" "$SCHEME://$DOMAIN/t4/$RUN/$want/$n" -H "x-backend: t4-probe"
      pop=$(hdr x-amz-cf-pop)
      POLL_POP=$pop
      POLL_SECONDS=$(( $(date +%s) - start ))
      if [ "$R_CODE" = "200" ] && [ "$(jget origin)" = "$want" ]; then return 0; fi
      [ "$POLL_SECONDS" -ge "$max" ] && return 1
      sleep 1
    done
  }
  stamp_before=$(fn_stamp)
  if ! kvs_put t4-probe "$ORIGIN_A_HOST"; then
    emit T4 INCONCLUSIVE "put-key failed ($(grep 'FAILED' "$RESULTS_FILE" | tail -1 | sed -n 's/.*error-code=\([A-Za-z0-9]*\).*/\1/p')): needs AWS CLI v2 with SigV4A and permission cloudfront-keyvaluestore:PutKey/DescribeKeyValueStore"
  elif ! poll_for origin-a 120; then
    emit T4 INCONCLUSIVE "baseline key t4-probe not visible after 120s (last status $R_CODE); cannot time an update"
  else
    create_s=$POLL_SECONDS
    if ! kvs_put t4-probe "$ORIGIN_B_HOST"; then
      emit T4 INCONCLUSIVE "update put-key failed (error code in the results file)"
    else
      if poll_for origin-b "$T4_MAX"; then
        stamp_after=$(fn_stamp)
        if [ -n "$stamp_before" ] && [ "$stamp_before" = "$stamp_after" ]; then
          repub="function LIVE LastModifiedTime unchanged ($stamp_before): not republished"
        elif [ -n "$stamp_before" ]; then
          repub="function LastModifiedTime CHANGED ($stamp_before -> $stamp_after)"
        else
          repub="function stamp not checked (FUNCTION_NAME unset); this script never publishes"
        fi
        detail="new value seen after ${POLL_SECONDS}s at pop ${POLL_POP:-?} (single vantage point); create took ${create_s}s; $repub"
        if [ "$POLL_SECONDS" -le 10 ]; then emit T4 PASS "$detail"; else emit T4 FAIL "slower than 10s: $detail"; fi
      else
        emit T4 FAIL "new value NOT seen within ${T4_MAX}s without republishing (last status $R_CODE origin '$(jget origin)')"
      fi
    fi
  fi
  # clean up the probe key (best effort)
  if awscall "describe-key-value-store (cleanup)" cloudfront-keyvaluestore describe-key-value-store --region "$REGION" --kvs-arn "$KVS_ARN" --query ETag --output text; then
    etag=$(cat "$AWS_OUT")
    awscall "delete-key t4-probe" cloudfront-keyvaluestore delete-key --region "$REGION" --kvs-arn "$KVS_ARN" --key t4-probe --if-match "$etag" || true
  fi
fi

# ------------------------------------------------------------------ T6: inheritance and failure cases
if need_route_keys T6a; then
  hyp T6a "A routed request reaches the chosen backend over the inherited HTTPS/443 settings of the default custom origin" "status 200 from origin-a"
  route_req "T6a valid route" "$KEY_A" "/t6/$RUN/valid"
  if [ "$R_CODE" = "200" ] && [ "$(jget origin)" = "origin-a" ]; then
    emit T6a PASS "routed to origin-a, status 200"
    inh=$(jget xOriginMarker)
    hyp T6b "Settings omitted from updateRequestOrigin() are inherited from the default origin, including its custom header" \
      "backend receives x-origin-marker: from-default-origin"
    if [ "$inh" = "from-default-origin" ]; then emit T6b PASS "x-origin-marker inherited from the default origin"
    else emit T6b FAIL "x-origin-marker at backend: '${inh:-absent}' (default origin sets from-default-origin)"; fi
  else
    emit T6a INCONCLUSIVE "no clean routed response: status $R_CODE origin '$(jget origin)'"
    emit T6b INCONCLUSIVE "depends on T6a"
  fi
fi

# T6i: the origins are IAM-protected. A direct call to a function URL without CloudFront signing must be refused,
# while the routed call through CloudFront works. Together they confirm OAC + function-based origin selection.
hyp T6i "With OriginAuth=AWS_IAM, a direct call to each function URL (no CloudFront signing) is refused with 403, while the routed call through CloudFront returns 200 from the right backend (updateRequestOrigin with originAccessControlConfig, originType lambda)" \
  "direct calls: 403 for origin A, B and default; routed calls: 200 from origin-a and origin-b"
if [ "$ORIGIN_AUTH" != "AWS_IAM" ]; then
  emit T6i INCONCLUSIVE "not applicable: origins deployed with OriginAuth=$ORIGIN_AUTH (public)"
elif [ -z "$ORIGIN_A_HOST" ] || [ -z "$ORIGIN_B_HOST" ] || [ -z "$KEY_A" ] || [ -z "$KEY_B" ]; then
  emit T6i INCONCLUSIVE "not run: needs ORIGIN_A_HOST, ORIGIN_B_HOST (deploy.env) and route keys"
else
  [ "$SCHEME" = "https" ] && dport=443 || dport=80
  direct_status() { # name host
    if [ -n "${VERIFY_DIRECT_CONNECT:-}" ]; then   # test hook for the local mock only
      req "T6i direct $1" "$SCHEME://$2/t6i/$RUN" --connect-to "$2:$dport:$VERIFY_DIRECT_CONNECT"
    else
      req "T6i direct $1" "$SCHEME://$2/t6i/$RUN"
    fi
  }
  open_hosts=""; odd=""; detail=""
  for pair in "A|$ORIGIN_A_HOST" "B|$ORIGIN_B_HOST" "default|$DEFAULT_ORIGIN_HOST"; do
    nm=${pair%%|*}; hh=${pair#*|}
    [ -n "$hh" ] || continue
    direct_status "$nm" "$hh"
    detail="$detail direct-$nm=$R_CODE"
    case "$R_CODE" in
      403) ;;
      200) open_hosts="$open_hosts $nm" ;;
      *) odd="$odd $nm" ;;
    esac
  done
  route_req "T6i routed A" "$KEY_A" "/t6i/$RUN/a"; ra=$R_CODE; oa=$(jget origin)
  route_req "T6i routed B" "$KEY_B" "/t6i/$RUN/b"; rb=$R_CODE; ob=$(jget origin)
  detail="$detail; routed-A=$ra/${oa:-none} routed-B=$rb/${ob:-none}"
  if [ -n "$open_hosts" ]; then
    emit T6i FAIL "origin(s)$open_hosts answered a direct unsigned call with 200 (not protected). $detail"
  elif [ "$ra" != "200" ] || [ "$oa" != "origin-a" ] || [ "$rb" != "200" ] || [ "$ob" != "origin-b" ]; then
    emit T6i FAIL "direct calls refused but the routed call failed: OAC with function-based origin selection did not work. Fallback: see README. $detail"
  elif [ -n "$odd" ]; then
    emit T6i INCONCLUSIVE "direct call to$odd returned neither 403 nor 200. $detail"
  else
    emit T6i PASS "$detail"
  fi
fi

# fail_case ID KEY EXPECTED_STATUS DESCRIPTION
fail_case() {
  local id=$1 key=$2 want=$3 desc=$4
  hyp "$id" "$desc" "status $want generated at the edge; no origin body and no x-origin-name header (never falls through to the default origin)"
  if [ "$ROUTE_ATTRIBUTE" != "x-backend" ]; then
    emit "$id" INCONCLUSIVE "not run: needs ROUTE_ATTRIBUTE=x-backend to send arbitrary route keys"
    return
  fi
  req "$id" "$SCHEME://$DOMAIN/t6/$RUN/$id" -H "x-backend: $key"
  local o xo
  o=$(jget origin); xo=$(hdr x-origin-name)
  if [ "$R_CODE" = "$want" ] && [ -z "$o" ] && [ -z "$xo" ]; then
    emit "$id" PASS "status $R_CODE, no origin reached"
  elif [ -n "$o" ] || [ -n "$xo" ]; then
    emit "$id" FAIL "FELL THROUGH to an origin: status $R_CODE origin '$o' (fail-open)"
  elif [ "$R_CODE" = "000" ]; then
    emit "$id" INCONCLUSIVE "request failed"
  else
    emit "$id" FAIL "status $R_CODE, expected $want (no origin reached)"
  fi
}
fail_case T6c bad-colon 500 "A stored value with a colon (example.net:8443) is rejected and the request fails closed"
fail_case T6d bad-ip 500 "A stored IP address is rejected and the request fails closed"
fail_case T6e bad-upper 500 "A stored upper-case domain fails the allow-list pattern and the request fails closed"
fail_case T6h bad-suffix 500 "A stored value that is a valid domain but outside the allowed backend suffix is rejected (suffix allow-list)"
fail_case T6f no-such-route 404 "An unknown route key returns 404"
hyp T6g "A request without the routing attribute returns 404 and never reaches the default origin" "status 404, no origin body"
if [ "$ROUTE_ATTRIBUTE" = "x-backend" ]; then
  req "T6g no routing header" "$SCHEME://$DOMAIN/t6/$RUN/none"
  if [ "$R_CODE" = "404" ] && [ -z "$(jget origin)" ]; then emit T6g PASS "status 404, no origin reached"
  elif [ -n "$(jget origin)" ]; then emit T6g FAIL "FELL THROUGH to origin '$(jget origin)' (status $R_CODE)"
  else emit T6g FAIL "status $R_CODE, expected 404"; fi
else
  emit T6g INCONCLUSIVE "not run: Host is always present in host mode"
fi

# ------------------------------------------------------------------ T7: Lambda@Edge variant
hyp T7 "Lambda@Edge origin request retargeting (post sample 2) routes to the chosen backend, TLS validates, backend sees the target as Host, no fall-through" \
  "route-a and route-b answer 200 from their own backends with Host = backend name; same path does not share an entry; unknown key is 404"
if [ -z "$EDGE_DOMAIN" ]; then
  emit T7 INCONCLUSIVE "not run: EDGE_DOMAIN not set (deploy the optional Lambda@Edge stack: DEPLOY_EDGE=true ./deploy.sh)"
else
  p="/t7/$RUN/same.json"
  req "T7 edge route A" "$SCHEME://$EDGE_DOMAIN$p" -H "x-backend: route-a"
  ca=$R_CODE; oa=$(jget origin); ha=$(jget host)
  req "T7 edge route B same path" "$SCHEME://$EDGE_DOMAIN$p" -H "x-backend: route-b"
  cb=$R_CODE; ob=$(jget origin); hb=$(jget host)
  req "T7 edge unknown key" "$SCHEME://$EDGE_DOMAIN/t7/$RUN/none" -H "x-backend: nope"
  cu=$R_CODE; ou=$(jget origin)
  detail="A: status $ca origin '$oa' host '$ha'; B: status $cb origin '$ob' host '$hb'; unknown: status $cu origin '${ou:-none}'; forward viewer host=${EDGE_FORWARD_HOST:-false}"
  if [ "$ca" = "502" ] || [ "$cb" = "502" ]; then
    emit T7 FAIL "502 from the edge: TLS or host mismatch after retargeting. $detail"
  elif [ "$ca" = "200" ] && [ "$oa" = "origin-a" ] && [ "$cb" = "200" ] && [ "$ob" = "origin-b" ] && [ "$cu" = "404" ] && [ -z "$ou" ]; then
    hostok=1
    if [ -n "$ORIGIN_A_HOST" ] && [ -n "$ORIGIN_B_HOST" ]; then
      { [ "$ha" = "$ORIGIN_A_HOST" ] && [ "$hb" = "$ORIGIN_B_HOST" ]; } || hostok=0
    else
      { [ "$ha" != "$EDGE_DOMAIN" ] && [ "$hb" != "$EDGE_DOMAIN" ]; } || hostok=0
    fi
    if [ "$hostok" = 1 ]; then emit T7 PASS "$detail"; else emit T7 FAIL "wrong Host at backend. $detail"; fi
  elif [ "$ca" = "200" ] && [ "$oa" = "origin-a" ] && [ "$ob" = "origin-a" ]; then
    emit T7 FAIL "route B got origin-a (shared entry or no retarget). $detail"
  else
    emit T7 INCONCLUSIVE "unexpected responses (stack not ready or different setup). $detail"
  fi
fi

# ------------------------------------------------------------------ T8: Host header shape
hyp T8 "The function event can carry an upper-case host, a port or a trailing dot, so the sample normalizes it" \
  "PASS = at least one variant reached a function in non-canonical form (normalization needed); FAIL = every variant arrived canonical or was rejected (normalization is defensive only)"
canon=$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')
upper=$(printf '%s' "$DOMAIN" | tr '[:lower:]' '[:upper:]')
req "T8 probe canonical" --http1.1 "$SCHEME://$DOMAIN/probe/$RUN/canon"
if [ "$R_CODE" != "200" ] || [ -z "$(hdr x-seen-host)" ]; then
  emit T8 INCONCLUSIVE "probe behavior /probe/* not answering (status $R_CODE); is EnableTestBehaviors true?"
else
  noncanon=0; summary="canonical->'$(hdr x-seen-host)'"
  for variant in "upper|$upper" "port|$canon:443" "dot|$canon." "upper-port-dot|$upper:443." ; do
    label=${variant%%|*}; hv=${variant#*|}
    req "T8 probe $label (Host: $hv)" --http1.1 -H "Host: $hv" "$SCHEME://$DOMAIN/probe/$RUN/$label"
    seen=$(hdr x-seen-host)
    log "OBSERVED=T8 CASE=$label SENT_HOST=$hv STATUS=$R_CODE SEEN_BY_FUNCTION=${seen:-(none)}"
    summary="$summary; $label sent '$hv' -> status $R_CODE seen '${seen:-none}'"
    if [ "$R_CODE" = "200" ] && [ -n "$seen" ] && [ "$seen" != "$canon" ]; then noncanon=1; fi
  done
  if [ "$noncanon" = 1 ]; then emit T8 PASS "non-canonical host reached the function. $summary"
  else emit T8 FAIL "no non-canonical host reached the function. $summary"; fi
fi

if [ "$ROUTE_ATTRIBUTE" = "host" ] && [ -n "$ALIAS_A" ]; then
  hyp T8b "Routing on Host still finds the route when the viewer Host has upper case, a port or a trailing dot" \
    "every variant that CloudFront passes on routes to origin-a (no 404 or 500 from the function)"
  bad=0; summary=""
  ua=$(printf '%s' "$ALIAS_A" | tr '[:lower:]' '[:upper:]')
  for variant in "plain|$ALIAS_A" "upper|$ua" "port|$ALIAS_A:443" "dot|$ALIAS_A."; do
    label=${variant%%|*}; hv=${variant#*|}
    req "T8b route $label (Host: $hv)" --http1.1 --connect-to "$ALIAS_A:443:$DOMAIN:443" -H "Host: $hv" "$SCHEME://$ALIAS_A/t8b/$RUN/$label"
    summary="$summary; $label '$hv' -> $R_CODE $(jget origin)"
    case "$R_CODE" in 404|500) bad=1 ;; esac
  done
  if [ "$bad" = 0 ]; then emit T8b PASS "no function-level 404/500$summary"; else emit T8b FAIL "function rejected a variant$summary"; fi
else
  emit T8b INCONCLUSIVE "not run: needs ROUTE_ATTRIBUTE=host with ALIAS_A/ALIAS_B (see README)"
fi

# T9 (viewer request invocation count on cache hits) needs CloudWatch metrics and is not implemented here.
emit T9 INCONCLUSIVE "not implemented in this script (needs CloudFront Functions metrics)"

# ------------------------------------------------------------------ summary
echo
echo "================ machine-readable summary ================"
printf '%s' "$MACHINE"
echo "SUMMARY pass=$N_PASS fail=$N_FAIL inconclusive=$N_INC"
{
  echo
  echo "======== machine-readable summary ========"
  printf '%s' "$MACHINE"
  echo "SUMMARY pass=$N_PASS fail=$N_FAIL inconclusive=$N_INC"
  echo "end (utc): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$RESULTS_FILE"
redact_results "$RESULTS_FILE"
echo
echo "Full raw requests and responses: $RESULTS_FILE"
echo "Send that file back as described in the README. Review it first: it contains your distribution domain and test origin hosts."
echo "AWS error text is never written to it, and 12-digit numbers and arn:aws... strings are masked, but check anyway."
[ "$N_FAIL" -eq 0 ]
