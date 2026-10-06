#!/usr/bin/env bash
# verify.sh - deploy tests for blog post 2 (time-window caching on CloudFront without changing origins, part 1).
#
# Needs: bash and curl (macOS bash 3.2 is fine). Tests T3 and T4 additionally need the AWS CLI v2 (they write the
# KeyValueStore key "window"; the data API needs SigV4A signing, which AWS CLI v2 includes).
# Safe to run: it sends GET requests to YOUR distribution only. T3, T4 and T4b write the single key "window" in YOUR
# KeyValueStore through seed-kvs.sh. It never publishes or changes a function or a distribution.
#
# DURATION: about 12 to 15 minutes in total. T5/T9/T2 sample for about 100 seconds, T3 waits for a seeded window to
# open and close (2 to 8 minutes for the window plus about 100 seconds after the close), T4 needs a minute or two.
# Keep the terminal open. Ctrl-C is safe (the results file is masked on exit).
#
# Usage:  ./verify.sh [distribution-domain]        (reads deploy.env if deploy.sh wrote it)
# Environment (all optional when deploy.env exists):
#   CF_DOMAIN             dxxxx.cloudfront.net of the main stack (or first argument)
#   EDGE_DOMAIN           domain of the optional Lambda@Edge stack; enables T2 and the edge part of T9
#   EDGE_WINDOW_START_MIN EDGE_WINDOW_END_MIN EDGE_IN_TTL EDGE_OUT_TTL EDGE_REWRITE_ERRORS   edge stack settings (deploy.env)
#   SLOT_CARRIER          query (default) or header     ENABLE_TEST_BEHAVIORS  true (default) or false     DEFMAX  accepted|rejected|off
#   KVS_ARN FUNCTION_NAME ORIGIN_HOST                   for T3, T4 (aws CLI) and the origin lock test T0
#   RESULTS_FILE          output file (default verify-results-<utc time>.txt)
#   READY_MAX (900)       seconds to wait for the stack to answer       T4_MAX (180)  seconds to wait in T4
#   SAMPLE_HORIZON (100)  seconds the T5/T9/T2 sampler runs             BURST (30)    concurrent requests in T10
#   T3_LENGTH (4)         minutes the seeded T3 window stays open       T3_POST_SECS (100) seconds observed after the close
#
# Output: PASS/FAIL/INCONCLUSIVE per test with its hypothesis and expected result, one machine line per test
#   TEST=T3b RESULT=PASS DETAIL=...
# and a results file with the raw requests and the compact samples. Send that file back (see README).
# PASS means the observed behavior matched the stated expectation (the post's claim, the documented behavior, or
# for undocumented cases the stated hypothesis). FAIL means it did not. INCONCLUSIVE means the test could not decide.
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck disable=SC1091
[ -f deploy.env ] && . ./deploy.env

DOMAIN="${1:-${CF_DOMAIN:-}}"
EDGE_DOMAIN="${EDGE_DOMAIN:-}"
SLOT_CARRIER="${SLOT_CARRIER:-query}"
ENABLE_TEST_BEHAVIORS="${ENABLE_TEST_BEHAVIORS:-true}"
DEFMAX="${DEFMAX:-off}"
KVS_ARN="${KVS_ARN:-}"
FUNCTION_NAME="${FUNCTION_NAME:-}"
ORIGIN_HOST="${ORIGIN_HOST:-}"
EDGE_WINDOW_START_MIN="${EDGE_WINDOW_START_MIN:-0}"
EDGE_WINDOW_END_MIN="${EDGE_WINDOW_END_MIN:-1440}"
EDGE_IN_TTL="${EDGE_IN_TTL:-15}"
EDGE_OUT_TTL="${EDGE_OUT_TTL:-45}"
EDGE_REWRITE_ERRORS="${EDGE_REWRITE_ERRORS:-false}"
READY_MAX="${READY_MAX:-900}"
T4_MAX="${T4_MAX:-180}"
SAMPLE_HORIZON="${SAMPLE_HORIZON:-100}"
BURST="${BURST:-30}"
T3_LENGTH="${T3_LENGTH:-4}"
T3_POST_SECS="${T3_POST_SECS:-100}"
REGION="us-east-1"
SCHEME="${VERIFY_SCHEME:-https}"                 # test hook for the local mock only; leave unset against AWS
SCALE="${VERIFY_TIME_SCALE:-1}"                  # test hook for the local mock only: virtual seconds per real second
ANCHOR="${MOCK_CLOCK_ANCHOR:-0}"                 # test hook for the local mock only
RESULTS_FILE="${RESULTS_FILE:-verify-results-$(date -u +%Y%m%dT%H%M%SZ).txt}"

# The TTLs of the test cache policies, as deployed by template.yaml: "minimum default maximum" in seconds.
# A unit test (test/template.test.mjs) fails if these differ from the template.
POLICY_orig="0 0 31536000"
POLICY_b="30 60 3600"
POLICY_m0="0 20 60"
POLICY_defhi="0 60 20"

if [ -z "$DOMAIN" ]; then
  echo "Usage: ./verify.sh <distribution-domain>   (or run deploy.sh first, or set CF_DOMAIN)" >&2
  exit 2
fi
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }
for v in BURST SAMPLE_HORIZON T3_LENGTH T3_POST_SECS READY_MAX T4_MAX; do
  printf '%s' "${!v}" | grep -Eq '^[0-9]{1,5}$' || { echo "$v must be a number" >&2; exit 2; }
done
case "$SLOT_CARRIER" in query|header) ;; *) echo "SLOT_CARRIER must be query or header" >&2; exit 2 ;; esac

RUN="r$(date +%s)p$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")" || exit 2
# On any exit (also Ctrl-C or kill) mask the results file before leaving, then remove the temp dir.
finish() {
  wait 2>/dev/null
  if [ -f "$RESULTS_FILE" ] && type redact_results >/dev/null 2>&1; then redact_results "$RESULTS_FILE"; fi
  rm -rf "$TMP"
}
trap finish EXIT
trap 'exit 130' INT TERM
REQ_N=0
N_PASS=0; N_FAIL=0; N_INC=0
MACHINE=""

# ------------------------------------------------------------------ time (virtual time only for the local mock)
now() {
  if [ "$SCALE" = 1 ]; then date +%s
  else perl -MTime::HiRes=time -e 'printf "%d", $ARGV[0] + (time - $ARGV[0]) * $ARGV[1]' "$ANCHOR" "$SCALE"; fi
}
vsleep() {
  if [ "$SCALE" = 1 ]; then sleep "$1"
  else sleep "$(awk -v s="$1" -v k="$SCALE" 'BEGIN { printf "%.3f", s / k }')"; fi
}

log() { printf '%s\n' "$*" >> "$RESULTS_FILE"; }

# awscall DESCRIPTION AWS_ARGS...  runs the AWS CLI with stdout and stderr captured in temp files.
# Only the description, the exit code and the error CODE (for example AccessDeniedException) are logged:
# AWS error messages can contain account ids and IAM ARNs, so the message text is never written.
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
jbool() { sed -n -E 's/.*"'"$1"'":(true|false).*/\1/p' "$R_B" | head -1; }
xc_word() { local x; x=$(hdr x-cache); x=${x%% *}; printf '%s' "${x:-none}"; }

# Fields of the slot as the origin saw it, for the configured carrier.
if [ "$SLOT_CARRIER" = "header" ]; then SLOT_FIELD=slotHeader; SAW_FIELD=sawSlotHeader; INVALID_FIELD=slotHeaderInvalid
else SLOT_FIELD=slot; SAW_FIELD=sawSlot; INVALID_FIELD=slotInvalid; fi

emit() { # id result detail
  local detail
  detail=$(printf '%s' "$3" | tr '\n' ' ')
  local line="TEST=$1 RESULT=$2 DETAIL=$detail"
  printf '%-13s %-5s %s\n' "$2" "$1" "$detail"
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

# ------------------------------------------------------------------ header
: > "$RESULTS_FILE"
{
  echo "verify.sh results - cloudfront-time-window-caching sample"
  echo "start (utc): $(date -u +%Y-%m-%dT%H:%M:%SZ)   run id: $RUN"
  echo "domain: $DOMAIN   edge domain: ${EDGE_DOMAIN:-(none)}   slot carrier: $SLOT_CARRIER"
  echo "test behaviors: $ENABLE_TEST_BEHAVIORS   default-above-max policy: $DEFMAX   edge rewrite errors: $EDGE_REWRITE_ERRORS"
  echo "edge window: $EDGE_WINDOW_START_MIN..$EDGE_WINDOW_END_MIN utc minutes, in ttl $EDGE_IN_TTL, out ttl $EDGE_OUT_TTL"
  echo "curl: $(curl --version | head -1)"
  command -v aws >/dev/null 2>&1 && echo "aws cli: $(aws --version 2>/dev/null | grep -o '^aws-cli/[0-9.]*' | head -1)"
  echo "uname: $(uname -sr)"
} >> "$RESULTS_FILE"

echo "verify.sh: GET requests to $DOMAIN; raw results go to $RESULTS_FILE"
echo "expected duration: about 12 to 15 minutes (T3 waits for a seeded window to open and close). Slot carrier: $SLOT_CARRIER."

# ------------------------------------------------------------------ readiness
echo
echo "[ready] waiting for the stack to answer (distribution deployed, window record propagated), up to ${READY_MAX}s"
ready=0
t0=$(date +%s)
i=0
while :; do
  i=$((i + 1))
  req "ready $i" "$SCHEME://$DOMAIN/ready/$RUN/$i/none"
  if [ "$R_CODE" = "200" ] && [ -n "$(jget id)" ]; then ready=1; break; fi
  [ $(( $(date +%s) - t0 )) -ge "$READY_MAX" ] && break
  sleep 5
done
if [ "$ready" = "1" ]; then
  echo "[ready] ok after $(( $(date +%s) - t0 ))s"
else
  echo "[ready] NOT ready (last status $R_CODE). Later tests will most likely be INCONCLUSIVE or FAIL." \
    "Check that the stack is deployed and the window record is seeded."
fi
log "ready=$ready"
if [ "$ENABLE_TEST_BEHAVIORS" != "true" ]; then
  echo "[note] ENABLE_TEST_BEHAVIORS is not true: tests that need the /p-*/ and /legacy/ behaviors will be INCONCLUSIVE."
fi

# ------------------------------------------------------------------ T0: the origin is locked to CloudFront (OAC)
hyp T0 "The test origin is an IAM-protected Lambda function URL reachable only through CloudFront (origin access control): a direct unsigned call is refused, the call through CloudFront works" \
  "direct call: 403; call through CloudFront: 200 with a JSON id"
if [ -z "$ORIGIN_HOST" ]; then
  emit T0 INCONCLUSIVE "not run: set ORIGIN_HOST (deploy.env has it)"
else
  [ "$SCHEME" = "https" ] && dport=443 || dport=80
  if [ -n "${VERIFY_DIRECT_CONNECT:-}" ]; then   # test hook for the local mock only
    req "T0 direct call to the origin" "$SCHEME://$ORIGIN_HOST/t0/$RUN/none" --connect-to "$ORIGIN_HOST:$dport:$VERIFY_DIRECT_CONNECT"
  else
    req "T0 direct call to the origin" "$SCHEME://$ORIGIN_HOST/t0/$RUN/none"
  fi
  direct=$R_CODE
  req "T0 call through CloudFront" "$SCHEME://$DOMAIN/t0/$RUN/none"
  via=$R_CODE; viaid=$(jget id)
  if [ "$direct" = "200" ]; then
    emit T0 FAIL "the origin answered a direct unsigned call with 200 (not protected). through-cloudfront=$via"
  elif [ "$via" != "200" ] || [ -z "$viaid" ]; then
    emit T0 FAIL "direct=$direct but the call through CloudFront failed with $via: the OAC setup did not work (see README, Safety notes)"
  elif [ "$direct" = "403" ]; then
    emit T0 PASS "direct=403, through-cloudfront=200"
  else
    emit T0 INCONCLUSIVE "direct call returned $direct (neither 403 nor 200); through-cloudfront=200"
  fi
fi

# ------------------------------------------------------------------ T10: the slot at the origin, collapsing
carrier_ok() { # slot value valid for the origin pattern
  printf '%s' "$1" | grep -Eq '^(w[0-9]+|f[0-9]+|(pre|post)-[0-9]{4}-[0-9]{2}-[0-9]{2}-r[0-9]+)$'
}

hyp T10a "The slot reaches the origin: the cache key value is forwarded as the query parameter slot (or the header x-cache-slot)" \
  "the origin saw the $SLOT_CARRIER carrier with a value like w<n>, pre-<date>-r<rev> or post-<date>-r<rev>"
req "T10a through the default behavior" "$SCHEME://$DOMAIN/t10a/$RUN/none"
a_code=$R_CODE; a_saw=$(jbool "$SAW_FIELD"); a_slot=$(jget "$SLOT_FIELD");
if [ "$a_code" != "200" ]; then
  emit T10a INCONCLUSIVE "request failed with $a_code"
elif [ "$a_saw" = "true" ] && carrier_ok "$a_slot"; then
  emit T10a PASS "origin saw $SLOT_FIELD=$a_slot (carrier $SLOT_CARRIER)"
else
  emit T10a FAIL "origin saw=$a_saw value='${a_slot:-none}' (carrier $SLOT_CARRIER)"
fi

hyp T10b "An origin that knows nothing about the slot returns the same content with and without it (this origin ignores the extra parameter or header)" \
  "same route, status and Cache-Control from /p-orig/ (no slot) and from the default behavior (slot); sawSlot false without, true with"
if [ "$ENABLE_TEST_BEHAVIORS" != "true" ]; then
  emit T10b INCONCLUSIVE "needs the /p-orig/ behavior (EnableTestBehaviors=true)"
else
  same=1; detail=""
  for route in none maxage-30; do
    req "T10b with slot ($route)" "$SCHEME://$DOMAIN/t10b/$RUN/$route"
    w_code=$R_CODE; w_cc=$(jget sentCacheControl); w_route=$(jget route); w_saw=$(jbool "$SAW_FIELD")
    req "T10b without slot ($route)" "$SCHEME://$DOMAIN/p-orig/t10b-$RUN/$route"
    o_code=$R_CODE; o_cc=$(jget sentCacheControl); o_route=$(jget route); o_saw=$(jbool "$SAW_FIELD")
    detail="$detail $route: with=$w_code/$w_route/saw=$w_saw without=$o_code/$o_route/saw=$o_saw;"
    if [ "$w_code" != "200" ] || [ "$o_code" != "200" ]; then same=0
    elif [ "$w_route" != "$o_route" ] || [ "$w_cc" != "$o_cc" ] || [ "$w_saw" != "true" ] || [ "$o_saw" != "false" ]; then same=0; fi
  done
  if [ "$same" = 1 ]; then emit T10b PASS "identical content with and without the slot.$detail"
  else emit T10b FAIL "difference with/without slot.$detail"; fi
fi

hyp T10c "A viewer cannot choose its own cache key: a viewer-supplied slot (query or header) is replaced by the function's value" \
  "the origin sees a valid function slot, never 'evil' or 'w1'"
req "T10c viewer sends its own slot" "$SCHEME://$DOMAIN/t10c/$RUN/none?slot=w1&slot=evil&x=1" -H "x-cache-slot: evil"
c_code=$R_CODE; c_slot=$(jget "$SLOT_FIELD"); c_inv=$(jbool "$INVALID_FIELD")
if [ "$c_code" != "200" ]; then
  emit T10c INCONCLUSIVE "request failed with $c_code"
elif carrier_ok "$c_slot" && [ "$c_slot" != "w1" ] && [ "$c_inv" = "false" ]; then
  emit T10c PASS "origin saw $c_slot, not the viewer's value"
else
  emit T10c FAIL "origin saw '${c_slot:-none}' invalid=$c_inv (the viewer's value must never reach the origin as the slot)"
fi

# burst URL N NAME -> sets B_OK B_ERR B_IDS (distinct origin response ids among the 200 answers)
burst() {
  local url=$1 n=$2 name=$3 d="$TMP/burst.$3" i=0 f
  rm -rf "$d"; mkdir -p "$d"
  while [ "$i" -lt "$n" ]; do
    curl -s --max-time 40 -o "$d/b$i" -w '%{http_code}' "$url" > "$d/c$i" 2>/dev/null &
    i=$((i + 1))
  done
  wait
  B_OK=0; B_ERR=0; : > "$d/ids"
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "$(cat "$d/c$i" 2>/dev/null)" = "200" ]; then
      B_OK=$((B_OK + 1))
      grep -o '"id":"[^"]*"' "$d/b$i" | head -1 >> "$d/ids"
    else B_ERR=$((B_ERR + 1)); fi
    i=$((i + 1))
  done
  B_IDS=$(sort -u "$d/ids" | grep -c .)
  f="$d/ids"
  log "# burst $name: url=$url requests=$n ok=$B_OK errors=$B_ERR distinct-origin-ids=$B_IDS"
  log "# burst $name ids: $(sort "$f" | uniq -c | sort -rn | head -5 | tr '\n' ';')"
}

hyp T10d "Request collapsing: with a minimum TTL above 0, a burst for one new cache key costs the origin far less than one request per viewer, even though the origin sends no-store" \
  "$BURST concurrent requests for one new key (origin delays 1 s, sends no-store; window policy minimum TTL 600): at most 3 distinct origin responses"
burst "$SCHEME://$DOMAIN/t10d/$RUN/slow" "$BURST" T10d
D_IDS=$B_IDS; D_OK=$B_OK; D_ERR=$B_ERR
if [ "$D_OK" -lt $(( BURST * 8 / 10 )) ]; then
  emit T10d INCONCLUSIVE "only $D_OK of $BURST requests answered 200 ($D_ERR errors): cannot count origin fetches"
elif [ "$D_IDS" -le 3 ]; then
  emit T10d PASS "$BURST requests, $D_OK answered, $D_IDS distinct origin response(s)"
else
  emit T10d FAIL "$BURST requests, $D_OK answered, $D_IDS distinct origin responses (collapsing saved little)"
fi

hyp T10e "Counter-case from the documentation: with minimum TTL 0 and an origin that sends no-store, requests for the same key are not collapsed" \
  "the same burst through /p-orig/ (minimum TTL 0) reaches the origin more often than the T10d burst (at least 5 and at least 2 more distinct responses)"
if [ "$ENABLE_TEST_BEHAVIORS" != "true" ]; then
  emit T10e INCONCLUSIVE "needs the /p-orig/ behavior (EnableTestBehaviors=true)"
else
  burst "$SCHEME://$DOMAIN/p-orig/t10e-$RUN/slow" "$BURST" T10e
  if [ "$B_OK" -lt $(( BURST * 8 / 10 )) ]; then
    emit T10e INCONCLUSIVE "only $B_OK of $BURST requests answered 200 ($B_ERR errors; a new account's Lambda concurrency limit can throttle a burst)"
  elif [ "$B_IDS" -ge 5 ] && [ "$B_IDS" -ge $(( D_IDS + 2 )) ]; then
    emit T10e PASS "$B_IDS distinct origin responses for $B_OK answers (T10d: $D_IDS)"
  else
    emit T10e FAIL "$B_IDS distinct origin responses for $B_OK answers (T10d: $D_IDS): collapsing was not prevented"
  fi
fi

# ------------------------------------------------------------------ sampler: T5, T9, T2
# Many cache entries are watched at once. Each cell is one URL requested in rounds for SAMPLE_HORIZON seconds; from the
# X-Cache and Age headers and the per-response id the effective edge TTL is inferred. Cells run in parallel batches of 10.
CELL_URL=(); CELL_LABEL=(); CELL_EXP=(); CELL_GRP=()
add_cell() { # group url label expected
  CELL_GRP+=("$1"); CELL_URL+=("$2"); CELL_LABEL+=("$3"); CELL_EXP+=("$4")
}

# exp_ttl POLICY ROUTE -> expected edge lifetime in seconds under the post's rules (documented cases) or the stated
# hypothesis (undocumented cases): 0 means not cached.
exp_ttl() {
  local pol min def max life
  case "$1" in orig) pol=$POLICY_orig ;; b) pol=$POLICY_b ;; m0) pol=$POLICY_m0 ;; defhi) pol=$POLICY_defhi ;; esac
  # shellcheck disable=SC2086
  set -- $pol "$2"
  min=$1; def=$2; max=$3
  case "$4" in
    none|public-nomax) life=$def ;;
    nostore|private|nocache) if [ "$min" -gt 0 ]; then echo "$min"; else echo 0; fi; return ;;
    maxage-0|expires-past) life=0 ;;
    maxage-5|smaxage-only|both-5|maxage-expires|etag) life=5 ;;
    maxage-3600) life=3600 ;;
    both-14400) life=14400 ;;
    *) life=0 ;;
  esac
  [ "$life" -lt "$min" ] && life=$min
  [ "$life" -gt "$max" ] && life=$max
  echo "$life"
}

ROUTES="none nostore private nocache public-nomax maxage-0 maxage-5 maxage-3600 smaxage-only both-5 both-14400 expires-past maxage-expires"
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ]; then
  pols="orig b m0"
  [ "$DEFMAX" = "accepted" ] && pols="$pols defhi"
  for p in $pols; do
    for r in $ROUTES; do
      g=T5a
      case "$r" in
        smaxage-only) g=T5b ;;
        public-nomax) g=T5c ;;
        nostore|private|nocache) [ "$p" != "b" ] && g=T5d ;;
      esac
      [ "$p" = "defhi" ] && [ "$r" = "none" ] && g=T5e
      add_cell "$g" "$SCHEME://$DOMAIN/p-$p/$RUN/$r" "p-$p/$r" "$(exp_ttl "$p" "$r")"
    done
  done
  add_cell T5f "$SCHEME://$DOMAIN/p-m0/$RUN/etag" "p-m0/etag" 5
  for c in 400 403 404 500 503; do
    case "$c" in 400|403) e=0 ;; *) e=10 ;; esac
    add_cell T9a "$SCHEME://$DOMAIN/p-orig/$RUN/error-$c" "p-orig/error-$c" "$e"
    add_cell T9b "$SCHEME://$DOMAIN/p-orig/$RUN/error-$c-cc" "p-orig/error-$c-cc" 60
  done
fi

edge_minute() { local n; n=$(now); echo $(( (n % 86400) / 60 )); }
EDGE_READY=0
if [ -n "$EDGE_DOMAIN" ]; then
  EDGE_READY=1
  em=$(edge_minute)
  if [ "$em" -ge "$EDGE_WINDOW_START_MIN" ] && [ "$em" -lt "$EDGE_WINDOW_END_MIN" ]; then EDGE_TTL=$EDGE_IN_TTL; EDGE_PHASE=in; else EDGE_TTL=$EDGE_OUT_TTL; EDGE_PHASE=out; fi
  for r in none nostore private maxage-0 maxage-5 maxage-3600; do
    add_cell T2a "$SCHEME://$EDGE_DOMAIN/d0/$RUN/$r" "edge-d0/$r" "$EDGE_TTL"
  done
  for r in none nostore; do
    add_cell T2b "$SCHEME://$EDGE_DOMAIN/d60/$RUN/$r" "edge-d60/$r" "$EDGE_TTL"
  done
  # errors: which are cached, and does a rewritten header count? (expected per EDGE_REWRITE_ERRORS)
  et=$EDGE_TTL; [ "$et" -lt 10 ] && et=10
  if [ "$EDGE_REWRITE_ERRORS" = "true" ]; then
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-403" "edge-d0/error-403" "$et"
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-404" "edge-d0/error-404" "$et"
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-503" "edge-d0/error-503" "$et"
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-403-cc" "edge-d0/error-403-cc" "$et"
  else
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-403" "edge-d0/error-403" 0
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-404" "edge-d0/error-404" 10
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-503" "edge-d0/error-503" 10
    add_cell T9c "$SCHEME://$EDGE_DOMAIN/d0/$RUN/error-403-cc" "edge-d0/error-403-cc" 60
  fi
fi

# sample_cell INDEX ELAPSED   one request; appends "<elapsed> <code> <x-cache word> <age> <id>" to the cell file
sample_cell() {
  local i=$1 el=$2 h="$TMP/ch.$1" b="$TMP/cb.$1" code x age id
  code=$(curl -s --max-time 25 -D "$h" -o "$b" -w '%{http_code}' "${CELL_URL[$i]}" 2>/dev/null)
  [ -f "$h" ] || : > "$h"
  x=$(tr -d '\r' < "$h" | grep -i -m1 '^x-cache:' | sed 's/^[^:]*:[ ]*//'); x=${x%% *}
  age=$(tr -d '\r' < "$h" | grep -i -m1 '^age:' | sed 's/^[^:]*:[ ]*//')
  id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' "$b" 2>/dev/null | head -1)
  echo "$el ${code:-000} ${x:-none} ${age:-0} ${id:--}" >> "$TMP/cell.$i"
  [ "$el" -le 1 ] && cp "$h" "$TMP/ch0.$i" 2>/dev/null
  return 0
}

# eval_cell INDEX -> prints "VERDICT|description"; uses SPACING
eval_cell() {
  local i=$1 exp=${CELL_EXP[$1]}
  awk -v want="$exp" -v hz="$SAMPLE_HORIZON" -v sp="$SPACING" '
    function out(v, d) { print v "|" d; done = 1 }
    { n++; if ($2 == "000" || $5 == "-") bad++   # no answer, or an answer without an origin id (generated by CloudFront)
      if ($3 == "Hit" || $3 == "RefreshHit") { hits++; if ($4 + 0 > maxage) maxage = $4 + 0; if (!hitseen) firsthit = $1; hitseen = 1; if (!firstmiss) lasthit = $1 }
      else if ($3 == "Miss" && hitseen && !firstmiss) firstmiss = $1
      ids[$5] = 1; last = $3 }
    END {
      c = 0; for (k in ids) c++
      desc = sprintf("expected=%s s, samples=%d, hits=%d, last-hit-at=%s s, first-miss-after-hit-at=%s s, max-age=%s s, distinct-ids=%d", (want >= hz - 10 && want > 0 ? ">=" hz : want), n, hits + 0, (hitseen ? lasthit : "-"), (firstmiss ? firstmiss : "-"), maxage + 0, c)
      tol = 3
      if (n < 3 || bad > n / 2) { out("INC", "too few good answers (" bad + 0 " of " n " bad); " desc); exit }
      if (want == 0) { if (hits + 0 == 0) out("PASS", desc); else out("FAIL", "cached although expected not to be; " desc); exit }
      if (want >= hz - 10) {
        if (hits > 0 && !firstmiss && last ~ /Hit/) out("PASS", desc); else out("FAIL", "expected to stay cached for the whole run; " desc); exit }
      if (hits + 0 == 0) {
        if (want < 2 * sp) out("INC", "TTL shorter than twice the sampling spacing (" sp " s), too coarse; " desc); else out("FAIL", "never served from cache; " desc); exit }
      if (!firstmiss) { out("FAIL", "never expired within the run; " desc); exit }
      if (want <= firstmiss + tol && want >= lasthit - tol && maxage <= want + tol) out("PASS", desc)
      else out("FAIL", "lifetime outside the expected range; " desc)
    }' "$TMP/cell.$i"
}

# group_result ID: sets G_N G_PASS G_FAIL G_INC G_FAILS (text of failing cells)
group_result() {
  local g=$1 i=0 n=${#CELL_URL[@]} r v d
  G_N=0; G_PASS=0; G_FAIL=0; G_INC=0; G_FAILS=""
  while [ "$i" -lt "$n" ]; do
    if [ "${CELL_GRP[$i]}" = "$g" ]; then
      r=$(eval_cell "$i"); v=${r%%|*}; d=${r#*|}
      G_N=$((G_N + 1))
      log "# cell $g ${CELL_LABEL[$i]}: $v: $d"
      case "$v" in
        PASS) G_PASS=$((G_PASS + 1)) ;;
        FAIL) G_FAIL=$((G_FAIL + 1)); G_FAILS="$G_FAILS [${CELL_LABEL[$i]}: $d]" ;;
        *) G_INC=$((G_INC + 1)) ;;
      esac
    fi
    i=$((i + 1))
  done
}

# finish_group ID DESCRIPTION  emits the result for a sampler group
finish_group() {
  group_result "$1"
  local extra=""
  [ "$G_INC" -gt 0 ] && extra="; $G_INC inconclusive"
  if [ "$G_N" -eq 0 ]; then emit "$1" INCONCLUSIVE "no cells: $2"
  elif [ "$G_FAIL" -gt 0 ]; then emit "$1" FAIL "$G_FAIL of $G_N cells differ from the expectation:$G_FAILS"
  elif [ "$G_PASS" -eq 0 ]; then emit "$1" INCONCLUSIVE "no cell could be decided ($G_INC inconclusive of $G_N)"
  else emit "$1" PASS "$G_PASS of $G_N cells matched$extra"; fi
}

N_CELLS=${#CELL_URL[@]}
SPACING=3
if [ "$N_CELLS" -gt 0 ]; then
  echo
  echo "[sampler] watching $N_CELLS cache entries for ${SAMPLE_HORIZON}s (tests T5, T9, T2). This takes about $((SAMPLE_HORIZON + 10)) seconds."
  log ""
  log "######## sampler: $N_CELLS cells, horizon ${SAMPLE_HORIZON}s. Cell lines: elapsed-seconds http-code x-cache age id"
  s0=$(now); round=0
  while :; do
    el=$(( $(now) - s0 ))
    i=0
    while [ "$i" -lt "$N_CELLS" ]; do
      sample_cell "$i" "$el" &
      i=$((i + 1))
      [ $((i % 10)) -eq 0 ] && wait
    done
    wait
    round=$((round + 1))
    [ "$el" -ge "$SAMPLE_HORIZON" ] && break
    vsleep 1
  done
  total=$(( $(now) - s0 ))
  SPACING=$(( total / round + 1 ))
  log "# sampler: $round rounds in ${total}s, spacing about ${SPACING}s"
  i=0
  while [ "$i" -lt "$N_CELLS" ]; do
    {
      echo "=================================================================="
      echo "### cell $i ${CELL_GRP[$i]} ${CELL_LABEL[$i]} (expected ${CELL_EXP[$i]} s): ${CELL_URL[$i]}"
      echo "--- first response headers"
      tr -d '\r' < "$TMP/ch0.$i" 2>/dev/null
      echo "--- samples"
      cat "$TMP/cell.$i" 2>/dev/null
    } >> "$RESULTS_FILE"
    i=$((i + 1))
  done
fi

skip_tb="needs the test behaviors (deployed with EnableTestBehaviors=false)"

hyp T5a "Documented precedence (post, tables in 'How a cache policy clamps origin lifetimes'): the edge TTL is the origin max-age or s-maxage clamped between the policy minimum and maximum; no header: default TTL (or the minimum if higher); no-store, no-cache, private win only when the minimum is 0 (otherwise the minimum applies); Expires only, and max-age plus Expires, follow the table" \
  "every observed lifetime matches the expected value for each policy (managed-style 0/0/31536000, post policy B 30/60/3600, 0/20/60)"
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ]; then finish_group T5a "documented cells"; else emit T5a INCONCLUSIVE "$skip_tb"; fi

hyp T5b "UNDOCUMENTED: s-maxage without max-age is honored like max-age (H1: s-maxage=5 caches 5 s, clamped by the policy). H2 would be: treated as no header, so the default TTL applies" \
  "s-maxage=5 only: 5 s (policy minimum 0), 30 s (post policy B)"
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ]; then finish_group T5b "s-maxage only"; else emit T5b INCONCLUSIVE "$skip_tb"; fi

hyp T5c "UNDOCUMENTED: 'Cache-Control: public' with no max-age is treated as no lifetime header, so the default TTL applies (H1). H2 would be: not cached" \
  "default TTL: 0 (managed-style policy), 20 (0/20/60), 60 (post policy B: greater of minimum 30 and default 60)"
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ]; then finish_group T5c "public without max-age"; else emit T5c INCONCLUSIVE "$skip_tb"; fi

hyp T5d "UNDOCUMENTED edge result: with a minimum TTL of 0, no-store, no-cache and private are respected, so nothing is cached (the post's table says CloudFront respects the header; the exact edge result is not confirmed)" \
  "no-store, no-cache and private: never served from cache under the 0-minimum policies"
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ]; then finish_group T5d "no-store/no-cache/private at minimum 0"; else emit T5d INCONCLUSIVE "$skip_tb"; fi

hyp T5e "UNDOCUMENTED: a default TTL above the maximum TTL is clamped to the maximum (H1). Policy 0/60/20, origin sends nothing. H2 would be: the default (60 s) is used" \
  "20 s (the maximum), not 60 s. If CloudFront refuses to create such a policy, deploy.sh records DEFMAX=rejected and this test is INCONCLUSIVE: the refusal is the answer"
if [ "$ENABLE_TEST_BEHAVIORS" != "true" ]; then emit T5e INCONCLUSIVE "$skip_tb"
elif [ "$DEFMAX" = "rejected" ]; then emit T5e INCONCLUSIVE "CloudFront or CloudFormation refused to create the policy (default 60 above maximum 20): that refusal is the answer; send the deploy output"
elif [ "$DEFMAX" != "accepted" ]; then emit T5e INCONCLUSIVE "the default-above-max policy was not deployed (TRY_DEFAULT_ABOVE_MAX=false)"
else finish_group T5e "default above maximum"; fi

hyp T5f "Informational (the post makes no claim): an expired object with an ETag is revalidated, the origin answers 304, CloudFront serves the cached body again (X-Cache: RefreshHit, same response id)" \
  "after the 5 s lifetime a RefreshHit with the original id is observed"
if [ "$ENABLE_TEST_BEHAVIORS" != "true" ]; then emit T5f INCONCLUSIVE "$skip_tb"
else
  ei=-1; i=0
  while [ "$i" -lt "$N_CELLS" ]; do [ "${CELL_GRP[$i]}" = "T5f" ] && ei=$i; i=$((i + 1)); done
  if [ "$ei" -ge 0 ]; then
    first_id=$(awk 'NR == 1 { print $5 }' "$TMP/cell.$ei")
    rh=$(awk -v id="$first_id" '$3 == "RefreshHit" && $5 == id { c++ } END { print c + 0 }' "$TMP/cell.$ei")
    other=$(awk -v id="$first_id" '$3 == "Miss" && $5 != id { c++ } END { print c + 0 }' "$TMP/cell.$ei")
    if [ "$rh" -gt 0 ]; then emit T5f PASS "$rh RefreshHit sample(s) with the original id"
    else emit T5f INCONCLUSIVE "no RefreshHit with the original id seen ($other full misses): revalidation not observed (informational only)"; fi
  else emit T5f INCONCLUSIVE "cell missing"; fi
fi

hyp T9a "Error caching without a Cache-Control header (docs, HTTP status codes page): 404 and 5xx are cached for the error caching minimum TTL (10 s by default); 400 and 403 are cached only when the origin sends a header" \
  "error-404/500/503 cached about 10 s, error-400/403 not cached"
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ]; then finish_group T9a "errors without a header"; else emit T9a INCONCLUSIVE "$skip_tb"; fi

hyp T9b "Error caching with an origin header (s-maxage=60): CloudFront caches the error for the greater of the error caching minimum TTL (10 s) and the header value, for every listed code including 400 and 403" \
  "every error with s-maxage=60 cached about 60 s"
if [ "$ENABLE_TEST_BEHAVIORS" = "true" ]; then finish_group T9b "errors with a header"; else emit T9b INCONCLUSIVE "$skip_tb"; fi

edge_still_valid() {
  local em2
  em2=$(edge_minute)
  [ "$em2" -ge "$EDGE_WINDOW_START_MIN" ] && [ "$em2" -lt "$EDGE_WINDOW_END_MIN" ] && [ "$EDGE_PHASE" = "in" ] && return 0
  { [ "$em2" -lt "$EDGE_WINDOW_START_MIN" ] || [ "$em2" -ge "$EDGE_WINDOW_END_MIN" ]; } && [ "$EDGE_PHASE" = "out" ] && return 0
  return 1
}
edge_finish() { # id description
  if [ "$EDGE_READY" != 1 ]; then emit "$1" INCONCLUSIVE "edge stack not deployed (DEPLOY_EDGE=true) or EDGE_DOMAIN not set"
  elif ! edge_still_valid; then emit "$1" INCONCLUSIVE "the window boundary (UTC minute $EDGE_WINDOW_START_MIN or $EDGE_WINDOW_END_MIN) passed during the run, so the expected TTL changed; rerun"
  else finish_group "$1" "$2"; fi
}

hyp T2a "Lambda@Edge origin-response rewrite of Cache-Control sets the edge TTL (post, Option B; unconfirmed in the docs): the rewritten s-maxage=${EDGE_TTL:-<in or out TTL>} decides, whatever the origin sent (nothing, no-store, private, max-age=0, max-age=5, max-age=3600)" \
  "each route is cached for the configured TTL (in-window $EDGE_IN_TTL s, out-of-window $EDGE_OUT_TTL s) under the default-TTL-0 policy, not 0 s and not the origin's value"
edge_finish T2a "edge policy default 0"
hyp T2b "Same under a policy whose default TTL is 60: the rewritten header, not the default TTL, decides" \
  "cached for the configured TTL, not 60 s"
edge_finish T2b "edge policy default 60"
hyp T9c "Option B and errors (post): the function skips status 400 and above unless EDGE_REWRITE_ERRORS=true. If a rewritten header counts for error caching, a rewritten 403 becomes cacheable" \
  "REWRITE_ERRORS=false: 403 not cached, 404/503 about 10 s, 403 with the origin's s-maxage=60 cached 60 s; true: all about max(10, ttl) s (this run: $EDGE_REWRITE_ERRORS)"
edge_finish T9c "edge errors"

# ------------------------------------------------------------------ T3 and T4 need the KeyValueStore
kvs_missing=""
if ! command -v aws >/dev/null 2>&1; then kvs_missing="aws CLI not found (T3 and T4 write the KeyValueStore)"
elif [ -z "$KVS_ARN" ]; then kvs_missing="set KVS_ARN (deploy.env has it)"
elif [ ! -x ./seed-kvs.sh ]; then kvs_missing="seed-kvs.sh not found next to verify.sh"; fi

# seed ARGS...  writes the window record through seed-kvs.sh, logging only the error code on failure
seed() {
  KVS_ARN="$KVS_ARN" AWS_REGION="$REGION" ./seed-kvs.sh "$@" > "$TMP/seed.out" 2> "$TMP/seed.err"
  local rc=$?
  if [ "$rc" -eq 0 ]; then log "# seed-kvs.sh $*: ok ($(grep '^SEEDED' "$TMP/seed.out"))"
  else
    local code
    code=$(sed -n 's/.*(\([A-Za-z0-9]*\)).*/\1/p' "$TMP/seed.err" | head -1)
    log "# seed-kvs.sh $*: FAILED exit=$rc error-code=${code:-none} (message withheld on purpose)"
    SEED_CODE=${code:-none}
  fi
  return "$rc"
}
fn_stamp() {
  [ -n "$FUNCTION_NAME" ] && aws cloudfront describe-function --region "$REGION" --name "$FUNCTION_NAME" --stage LIVE \
    --query 'FunctionSummary.FunctionMetadata.LastModifiedTime' --output text 2>/dev/null
}

# t3 stats over the sample file ($TMP/t3.tsv: epoch tag code x-cache age id slot)
# t3_stat TAG FROM TO SLOT_REGEX -> "n distinct-ids distinct-slots hits max-age first-id first-t last-t"
t3_stat() {
  awk -v tag="$1" -v lo="$2" -v hi="$3" -v pat="$4" '
    $2 == tag && $3 == 200 && $1 >= lo && $1 <= hi && $7 ~ pat {
      n++; if (!(($6) in ids)) { ids[$6] = 1; ni++ }; if (!(($7) in sl)) { sl[$7] = 1; ns++ }
      if ($4 == "Hit") { h++; if ($5 + 0 > ma) ma = $5 + 0 }
      if (n == 1) { fid = $6; ft = $1 }; lt = $1 }
    END { printf "%d %d %d %d %d %s %s %s\n", n, ni, ns, h, ma, (fid == "" ? "-" : fid), (ft == "" ? 0 : ft), (lt == "" ? 0 : lt) }' "$TMP/t3.tsv"
}
t3_other() { # TAG FROM TO SLOT_REGEX -> number of 200 samples in the range whose slot does NOT match
  awk -v tag="$1" -v lo="$2" -v hi="$3" -v pat="$4" '$2 == tag && $3 == 200 && $1 >= lo && $1 <= hi && $7 !~ pat { n++ } END { print n + 0 }' "$TMP/t3.tsv"
}

t3_sample() { # tag url
  local t age id sl
  t=$(now)
  req "T3 $1" "$2"
  age=$(hdr age); id=$(jget id); sl=$(jget "$SLOT_FIELD")
  echo "$t $1 $R_CODE $(xc_word) ${age:-0} ${id:--} ${sl:--}" >> "$TMP/t3.tsv"
}

T3_IDS="T3a T3b T3c T3d"
t3_inconclusive() { local x; for x in $T3_IDS; do emit "$x" INCONCLUSIVE "$1"; done; }

hyp T3a "Option A, before the open: all requests share one cache entry (key pre-<date>-r<rev>)" \
  "after the seeded record is visible and until the window opens: one response id, the same slot value pre-<date>-r<rev>, hits"
hyp T3b "Option A, in the window: the slot length is the lifetime. A new slot is a new cache key, so the origin sees about one fetch per slot, and a repeated request in the same slot is a hit" \
  "per 10 s slot exactly one response id, one distinct id per slot, hits within a slot, hit Age at most the slot length"
hyp T3c "Option A, after the close (the corrected closed-period key): the response is NOT the pre-open body; all later requests share one post-<date>-r<rev> entry" \
  "slot post-<date>-r<rev>, a response id different from the pre-open id, one id for the rest of the run"
hyp T3d "The first key closed-<date> is the same before the open and after the close, so an entry cached before the open is still served after the close (the flaw the post describes). Run through the test-only /legacy/ behavior" \
  "legacy path: the response after the close has the SAME id as the pre-open response (flaw reproduced); PASS means the flaw is confirmed"
if [ -n "$kvs_missing" ]; then
  t3_inconclusive "not run: $kvs_missing"
else
  : > "$TMP/t3.tsv"
  s_now=$(now)
  day=$(( s_now - s_now % 86400 ))
  nowmin=$(( (s_now % 86400) / 60 ))
  t3_start=$(( nowmin + 2 )); t3_end=$(( t3_start + T3_LENGTH ))
  if [ $(( t3_end + 3 )) -gt 1440 ]; then
    t3_inconclusive "too close to midnight UTC: the seeded window would cross 00:00 UTC, which part 1 does not support. Rerun after 00:05 UTC"
  else
    rev=$(( s_now % 900000 + 100 ))
    echo
    echo "[T3] seeding a window: opens at UTC minute $t3_start, closes at $t3_end, 10 s slots, rev $rev. This takes about $(( (t3_end - nowmin) * 60 + T3_POST_SECS )) seconds."
    if ! seed --start-min "$t3_start" --end-min "$t3_end" --slot-seconds 10 --rev "$rev"; then
      t3_inconclusive "seeding the window failed (error code ${SEED_CODE:-?}): needs AWS CLI v2 with SigV4A and permission cloudfront-keyvaluestore:PutKey and DescribeKeyValueStore"
    else
      seeded_at=$(now)
      open_ep=$(( day + t3_start * 60 )); close_ep=$(( day + t3_end * 60 )); stop_ep=$(( close_ep + T3_POST_SECS ))
      log "# T3 timeline (epoch seconds): seeded=$seeded_at open=$open_ep close=$close_ep stop=$stop_ep rev=$rev"
      legacy=0; [ "$ENABLE_TEST_BEHAVIORS" = "true" ] && legacy=1
      while [ "$(now)" -le "$stop_ep" ]; do
        t3_sample win "$SCHEME://$DOMAIN/t3/$RUN/none"
        [ "$legacy" = 1 ] && t3_sample leg "$SCHEME://$DOMAIN/legacy/$RUN/none"
        vsleep 2
      done
      M=12
      pre_pat="^pre-[0-9-]+-r$rev\$"
      post_pat="^post-[0-9-]+-r$rev\$"
      # propagation: first window sample that carries the new record's pre key
      read -r _ _ _ _ _ _ first_pre _ <<EOF
$(t3_stat win 0 99999999999 "$pre_pat")
EOF
      log "# T3 first sample with the seeded record's pre key at epoch $first_pre (seeded at $seeded_at)"
      pre_hi=$(( open_ep - 8 ))
      # ---- T3a
      if [ "$first_pre" = 0 ] || [ "$first_pre" -gt "$pre_hi" ]; then
        emit T3a INCONCLUSIVE "the seeded record was not visible before the window opened (first pre key at ${first_pre}s, open at $open_ep): propagation slower than the pre-open period; rerun"
        PRE_ID=""
      else
        read -r n ni _ h _ PRE_ID _ _ <<EOF
$(t3_stat win "$first_pre" "$pre_hi" "$pre_pat")
EOF
        other=$(t3_other win "$first_pre" "$pre_hi" "$pre_pat")
        if [ "$n" -ge 5 ] && [ "$ni" = 1 ] && [ "$other" = 0 ]; then
          emit T3a PASS "$n samples, 1 response id, $h hits, record visible $((first_pre - seeded_at))s after the write, pre key pre-<date>-r$rev"
        else
          emit T3a FAIL "$n samples, $ni distinct ids (expected 1), $other samples with another slot, $h hits"
        fi
      fi
      # ---- T3b
      in_lo=$(( open_ep + M )); in_hi=$(( close_ep - M ))
      read -r n ni ns h ma _ _ _ <<EOF
$(t3_stat win "$in_lo" "$in_hi" "^w[0-9]+\$")
EOF
      other=$(t3_other win "$in_lo" "$in_hi" "^w[0-9]+\$")
      read -r _ _ _ _ _ _ w_first _ <<EOF
$(t3_stat win "$(( open_ep - 8 ))" "$close_ep" "^w[0-9]+\$")
EOF
      want_slots=$(( (in_hi - in_lo) / 10 - 2 ))
      lat="first in-window slot ${w_first:-0}"
      [ "${w_first:-0}" -gt 0 ] && lat="first in-window slot $(( w_first - open_ep ))s after the nominal open"
      if [ "$n" -lt 10 ]; then
        emit T3b INCONCLUSIVE "only $n usable in-window samples ($other with another slot)"
      elif [ "$ns" -ge "$want_slots" ] && [ "$ni" = "$ns" ] && [ "$other" = 0 ] && [ "$h" -gt 0 ] && [ "$ma" -le 13 ]; then
        emit T3b PASS "$ns slots, $ni distinct response ids (one origin fetch per slot), $n samples, $h hits, max hit Age ${ma}s (slot 10s); $lat"
      else
        emit T3b FAIL "slots=$ns (expected at least $want_slots), distinct ids=$ni (expected equal to slots), other-slot samples=$other, hits=$h, max hit Age=${ma}s; $lat"
      fi
      # ---- T3c
      post_lo=$(( close_ep + M ))
      read -r n ni _ h _ POST_ID _ _ <<EOF
$(t3_stat win "$post_lo" "$stop_ep" "$post_pat")
EOF
      other=$(t3_other win "$post_lo" "$stop_ep" "$post_pat")
      read -r _ _ _ _ _ _ p_first_any _ <<EOF
$(t3_stat win "$(( close_ep - 2 ))" "$stop_ep" "$post_pat")
EOF
      plat=""; [ "${p_first_any:-0}" -gt 0 ] && plat="; first post key $(( p_first_any - close_ep ))s after the nominal close"
      if [ "$n" -lt 5 ]; then
        emit T3c INCONCLUSIVE "only $n usable post-close samples ($other with another slot)"
      elif [ -z "${PRE_ID:-}" ]; then
        emit T3c INCONCLUSIVE "no pre-open id to compare with (T3a was inconclusive); post-close: $n samples, $ni id(s), slot post-<date>-r$rev$plat"
      elif [ "$ni" = 1 ] && [ "$other" = 0 ] && [ "$POST_ID" != "$PRE_ID" ]; then
        emit T3c PASS "$n samples after the close, 1 new response id (not the pre-open id), $h hits$plat"
      else
        emit T3c FAIL "post-close: ids=$ni (expected 1), other-slot samples=$other, same id as pre-open: $([ "$POST_ID" = "$PRE_ID" ] && echo yes || echo no)$plat"
      fi
      # ---- T3d
      if [ "$legacy" != 1 ]; then
        emit T3d INCONCLUSIVE "needs the /legacy/ behavior (EnableTestBehaviors=true)"
      else
        read -r pn pni _ _ _ LPRE _ _ <<EOF
$(t3_stat leg "$first_pre" "$pre_hi" "^closed-[0-9-]+\$")
EOF
        read -r qn qni _ qh _ LPOST _ _ <<EOF
$(t3_stat leg "$post_lo" "$stop_ep" "^closed-[0-9-]+\$")
EOF
        if [ "$first_pre" = 0 ] || [ "$pn" -lt 3 ] || [ "$qn" -lt 3 ]; then
          emit T3d INCONCLUSIVE "too few legacy samples (pre-open $pn, post-close $qn)"
        elif [ "$pni" = 1 ] && [ "$qni" = 1 ] && [ "$LPRE" = "$LPOST" ]; then
          emit T3d PASS "flaw reproduced: the legacy key served the pre-open response (same id) $qn times after the close ($qh hits)"
        else
          emit T3d FAIL "flaw NOT reproduced: legacy pre-open ids=$pni, post-close ids=$qni, same id: $([ "$LPRE" = "$LPOST" ] && echo yes || echo no)"
        fi
      fi
    fi
  fi
fi

# ------------------------------------------------------------------ T4: KeyValueStore propagation
# The window record is changed by seed-kvs.sh; the function is never republished. A closed window is used so that the
# slot carries rev: the origin echoes pre-<date>-r<rev> or post-<date>-r<rev>, and every poll uses a fresh path so the cache never answers.
hyp T4 "A changed KeyValueStore value is live at the edge without republishing the function, within seconds (AWS launch blog: 'a few seconds')" \
  "after the write, the slot at the origin carries the new rev within about 10 seconds; the function is never republished"
hyp T4b "A missing or unreadable window record fails closed to the short fallback slot f<n>, not to a shared cache key" \
  "after writing an invalid record the origin sees a slot like f<n> within T4_MAX seconds"
if [ -n "$kvs_missing" ]; then
  emit T4 INCONCLUSIVE "not run: $kvs_missing"
  emit T4b INCONCLUSIVE "not run: $kvs_missing"
else
  # poll_for REGEX MAX -> sets POLL_SECONDS, POLL_POP; returns 0 when the slot matches
  poll_for() {
    local pat=$1 max=$2 start n=0
    start=$(now)
    while :; do
      n=$((n + 1))
      req "T4 poll $n" "$SCHEME://$DOMAIN/t4/$RUN/$n/none"
      POLL_POP=$(hdr x-amz-cf-pop)
      POLL_SECONDS=$(( $(now) - start ))
      if [ "$R_CODE" = "200" ] && printf '%s' "$(jget "$SLOT_FIELD")" | grep -Eq "$pat"; then return 0; fi
      [ "$POLL_SECONDS" -ge "$max" ] && return 1
      vsleep 1
    done
  }
  n4=$(now); m4=$(( (n4 % 86400) / 60 ))
  if [ "$m4" -lt 700 ]; then c_start=1300; c_end=1301; else c_start=100; c_end=101; fi   # a one-minute window far from now: always closed
  r0=$(( n4 % 900000 + 100 )); r1=$(( r0 + 1 ))
  stamp_before=$(fn_stamp)
  if ! seed --start-min "$c_start" --end-min "$c_end" --slot-seconds 10 --rev "$r0"; then
    emit T4 INCONCLUSIVE "writing the record failed (error code ${SEED_CODE:-?}): needs AWS CLI v2 with SigV4A and permission cloudfront-keyvaluestore:PutKey and DescribeKeyValueStore"
    emit T4b INCONCLUSIVE "depends on T4 setup"
  elif ! poll_for "^(pre|post)-[0-9]{4}-[0-9]{2}-[0-9]{2}-r$r0\$" 180; then
    emit T4 INCONCLUSIVE "baseline record (rev $r0) not visible after 180s (last status $R_CODE); cannot time an update"
    emit T4b INCONCLUSIVE "depends on T4 setup"
  else
    create_s=$POLL_SECONDS
    if ! seed --start-min "$c_start" --end-min "$c_end" --slot-seconds 10 --rev "$r1"; then
      emit T4 INCONCLUSIVE "update write failed (error code ${SEED_CODE:-?})"
    elif poll_for "^(pre|post)-[0-9]{4}-[0-9]{2}-[0-9]{2}-r$r1\$" "$T4_MAX"; then
      stamp_after=$(fn_stamp)
      if [ -n "$stamp_before" ] && [ "$stamp_before" = "$stamp_after" ]; then
        repub="function LIVE LastModifiedTime unchanged ($stamp_before): not republished"
      elif [ -n "$stamp_before" ]; then
        repub="function LastModifiedTime CHANGED ($stamp_before -> $stamp_after)"
      else
        repub="function stamp not checked (FUNCTION_NAME unset); this script never publishes"
      fi
      detail="new rev seen after ${POLL_SECONDS}s at pop ${POLL_POP:-?} (single vantage point); first write took ${create_s}s; $repub"
      if [ "$POLL_SECONDS" -le 10 ]; then emit T4 PASS "$detail"; else emit T4 FAIL "slower than 10s: $detail"; fi
    else
      emit T4 FAIL "new rev NOT seen within ${T4_MAX}s without republishing (last status $R_CODE slot '$(jget "$SLOT_FIELD")')"
    fi
    # T4b: an invalid record
    if seed --raw '{"startMin":"x"}'; then
      if poll_for '^f[0-9]+$' "$T4_MAX"; then
        emit T4b PASS "fail-closed slot f<n> seen ${POLL_SECONDS}s after writing an invalid record"
      else
        emit T4b FAIL "no fail-closed slot within ${T4_MAX}s of writing an invalid record (last slot '$(jget "$SLOT_FIELD")')"
      fi
    else
      emit T4b INCONCLUSIVE "writing the invalid record failed (error code ${SEED_CODE:-?})"
    fi
    # leave a valid closed record behind (best effort)
    seed --start-min "$c_start" --end-min "$c_end" --slot-seconds 10 --rev "$r1" || true
  fi
fi

# ------------------------------------------------------------------ summary
echo
echo "================ which post claim each test settles ================"
cat <<'EOF'
T0   (sample)  origin locked to CloudFront by OAC            Safety of this sample, not a post claim
T2a  T2b       Lambda@Edge rewrite sets the edge TTL         "Option B: Lambda@Edge rewrites Cache-Control on the origin response"; "Which edge mechanisms can change the edge TTL"
T3a  T3b  T3c  slot key before / in / after the window       "Option A: a CloudFront Function adds a time slot to the cache key" (corrected closed-period key)
T3d            the first key closed-<date> had a flaw        "Option A" (the closed-period identifier needs care); "What is solved and what is not"
T4   T4b       KeyValueStore propagation, no republish       "Limits of Option A" (window change takes effect when KVS data reaches the edge); fail-closed is this sample's design
T5a            documented precedence table                   "How a cache policy clamps origin lifetimes"
T5b  T5c  T5d  s-maxage only, public only, no-store at min 0 "Three cases are not documented" (and the Cache-Control: public case)
T5e            default TTL above maximum TTL                 "Three cases are not documented"
T5f            ETag revalidation                             informational, no post claim
T9a  T9b  T9c  error caching, with and without header        "Option B" (errors of 400 and above, stamping s-maxage on an error)
T10a T10b      slot reaches the origin; origin tolerance     "Limits of Option A" (the slot reaches the origin; each origin ignores the unknown parameter)
T10c           viewer cannot pick its cache key              sample design property (not a post claim)
T10d T10e      request collapsing                            "Option A" step 3 (collapsing; the size of the saving is not yet confirmed)
EOF
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
echo "Send that file back as described in the README. Review it first: it contains your distribution domain and the test origin host."
echo "AWS error text is never written to it, and 12-digit numbers and arn:aws... strings are masked, but check anyway."
[ "$N_FAIL" -eq 0 ]
