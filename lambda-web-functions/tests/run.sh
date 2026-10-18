#!/usr/bin/env bash
# run.sh - stub tests for lwf-sample.sh. No AWS, no Cloudflare, no network: the script runs against a fake aws, curl, node (the
# probe) and sleep in tests/bin. The Worker, the SigV4 signer, the probe and the app are tested with `node --test` (test/*.test.mjs);
# the templates with cfn-lint (run here when it is installed). Usage: tests/run.sh      Exit 0 only if every check passes.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
REAL_NODE="$(command -v node || true)"   # the fake node comes first on PATH below; the node unit tests need the real one
export PATH="$here/bin:$PATH"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lwft.XXXXXX")"; if [ -z "${KEEP_TMP:-}" ]; then trap 'rm -rf "$TMP"' EXIT; else echo "keeping $TMP"; fi
PASS=0 FAIL=0
RUN_A=2610181200-ab12
RUN_OTHER=9999999999-ffff
ZONE=example.test
TOKEN=cftoken_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345   # fake, 40 characters
PHRASE="deploy lwf sample"
SCRIPT="$root/lwf-sample.sh"
ACCT12="$(STUB_DIR="$TMP" bash -c '. "$1/bin/stub-lib.sh"; acct' _ "$here")"   # the fake account id, built at run time

check() { # description, then a command; passes when the command succeeds
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then PASS=$((PASS + 1)); echo "  ok   $d"; else
    FAIL=$((FAIL + 1)); echo "  FAIL $d"
    if [ -n "${VERBOSE:-}" ]; then echo "       command: $*"; "$@" 2>&1 | head -5 | sed 's/^/       /'; fi
  fi
}
has()    { grep -q -- "$2" "$1"; }
hasnot() { ! grep -q -- "$2" "$1"; }
is()     { [ "$1" = "$2" ]; }
count()  { grep -c -- "$2" "$1" 2>/dev/null || true; }

reset_env() {
  local v
  for v in $(env | sed -n 's/^\(STUB_[A-Z_0-9]*\)=.*/\1/p'); do unset "$v"; done
  unset ACK_BUDGET LWF_KILL_HOURS
  export STUB_TOKEN="$TOKEN" CF_API_TOKEN="$TOKEN" LWF_RUN_ID="$RUN_A" STUB_ZONE="$ZONE"
  export AWS_PROFILE=testprof NODE_NO_WARNINGS=1
  export READY_TRIES=2 CERT_RECORD_TRIES=2 CERT_ISSUE_TRIES=2 CERT_DELETE_TRIES=5 A4_GAP=1 METRIC_WAIT=1 A8_SETTLE=1 A8_TRIES=2 LAT_N=5
}
# newdir NAME -> STUB_DIR, state and results dirs for that scenario
newdir() {
  STUB_DIR="$TMP/$1/stub"; LWF_STATE_DIR="$TMP/$1/state"; LWF_RESULTS_DIR="$TMP/$1/results"; TMPDIR="$TMP/$1/tmp"
  mkdir -p "$STUB_DIR/res" "$TMPDIR"; OUT="$TMP/$1/out.txt"
  export STUB_DIR LWF_STATE_DIR LWF_RESULTS_DIR TMPDIR STUB_PIDFILE="$TMP/$1/pid"
}
# lwf STDIN-TEXT args... : runs the script, output in $OUT, exit code in $RC
lwf() {
  local input="$1"; shift
  printf '%s\n' "$input" | "$SCRIPT" "$@" > "$OUT" 2>&1; RC=$?
}
# lwfsig STDIN-TEXT args... : same, but the script runs as a known pid so the fake aws can signal it
lwfsig() {
  local input="$1"; shift
  printf '%s\n' "$input" | bash -c 'echo $$ > "$STUB_PIDFILE"; exec "$0" "$@"' "$SCRIPT" "$@" > "$OUT" 2>&1; RC=$?
}
# aws_clean: no resource of this run in the fake registry (the other run's may remain). cf_clean: no Worker, domain, pack; records: only the unrelated one.
aws_clean() { [ "$(find "$STUB_DIR/res" -type f ! -name "*lwf-$RUN_OTHER*" | wc -l | tr -d ' ')" = 0 ]; }
run_clean() { aws_clean && cf_clean; }
cf_clean() { [ -z "$(find "$STUB_DIR/cf/scripts" "$STUB_DIR/cf/domains" "$STUB_DIR/cf/packs" -type f 2>/dev/null)" ] && [ "$(find "$STUB_DIR/cf/records" -type f ! -name foreign1.json 2>/dev/null | wc -l | tr -d ' ')" = 0 ]; }
# only reads: every aws call is describe/get/list/help (or sts, budgets), every curl is a GET
# aws call lines are "<region> <service> <command> <args>"; the CLI "help" probes of the preflight end in " help"
aws_lines() { grep -E '^(us-east-1|eu-west-1) ' "$STUB_DIR/calls.log" | grep -Ev ' help *$'; }
mutating_calls() { # counts calls that change something
  { aws_lines | awk '{print $2" "$3}' | grep -Ev '^(sts get-caller-identity|budgets describe-budgets|[a-z0-9-]+ (describe|get|list)[a-z-]*)$'
    grep -E '^curl (PUT|POST|DELETE)' "$STUB_DIR/calls.log"; } | wc -l | tr -d ' '
}
only_reads() { [ "$(mutating_calls)" = 0 ]; }
seed_foreign() { # resources of ANOTHER run that must never be touched
  local o="lwf-$RUN_OTHER"
  : > "$STUB_DIR/res/cfn__$o-app"; : > "$STUB_DIR/res/dist__$o"; : > "$STUB_DIR/res/user__$o-worker"; : > "$STUB_DIR/res/s3__$o-art-1"
  printf '%s' us-east-1 > "$STUB_DIR/res/lg__%aws%lambda%$o-fu"; printf '%s' us-east-1 > "$STUB_DIR/res/fn__$o-fu"
  mkdir -p "$STUB_DIR/cf/records"; jq -nc '{id:"foreign1",type:"A",name:"www.example.test",content:"192.0.2.1",comment:"mine"}' > "$STUB_DIR/cf/records/foreign1.json"
}
foreign_intact() { [ -e "$STUB_DIR/res/cfn__lwf-$RUN_OTHER-app" ] && [ -e "$STUB_DIR/res/user__lwf-$RUN_OTHER-worker" ] && [ -e "$STUB_DIR/res/s3__lwf-$RUN_OTHER-art-1" ] \
  && [ -e "$STUB_DIR/res/fn__lwf-$RUN_OTHER-fu" ] && [ -e "$STUB_DIR/res/lg__%aws%lambda%lwf-$RUN_OTHER-fu" ] && [ -e "$STUB_DIR/cf/records/foreign1.json" ]; }
result_of() { jq -r --arg i "$2" '.results[] | select(.id == $i) | .status' "$LWF_RESULTS_DIR/$RUN_A/results.json"; }
SECRET_VALUES() { STUB_DIR="$TMP" bash -c '. "$1/bin/stub-lib.sh"; fake_key' _ "$here"; }

echo "== node tests (worker, signer, probe, app)"
if [ -n "$REAL_NODE" ]; then
  ( cd "$root" && "$REAL_NODE" --test test/*.test.mjs >/dev/null 2>&1 ); rc=$?
  check "node --test test/*.test.mjs" is "$rc" 0
fi
echo "== templates"
if command -v cfn-lint >/dev/null 2>&1; then
  check "cfn-lint cfn/*.yaml" cfn-lint "$root"/cfn/*.yaml
else echo "  skip cfn-lint (not installed; CI runs it)"; fi
check "app.yaml has no ApplicationManaged endpoint and no public function URL" bash -c "! grep -E 'AuthType: (ApplicationManaged|NONE)' '$root/cfn/app.yaml'"
check "app.yaml names IamAuth, AWS_IAM and both OACs" bash -c "grep -q 'AuthType: IamAuth' '$root/cfn/app.yaml' && grep -q 'AuthType: AWS_IAM' '$root/cfn/app.yaml' && grep -q always-amz-auth '$root/cfn/app.yaml'"

echo "== dry run"
reset_env; newdir dry
lwf "" --dry-run --zone "$ZONE"
check "dry run exits 0" is "$RC" 0
check "dry run says nothing was changed" has "$OUT" "all checks passed; nothing was changed"
check "dry run made only read calls (aws and Cloudflare)" only_reads
check "dry run created no state, results or deploy call" bash -c "[ ! -d '$LWF_STATE_DIR' ] && [ ! -d '$LWF_RESULTS_DIR' ] && ! grep -q 'cloudformation deploy' '$STUB_DIR/calls.log'"
check "dry run printed the plan and the zone as <zone>" bash -c "grep -q 'lwf-w.<zone>' '$OUT' && ! grep -q '$ZONE' '$OUT'"
check "dry run checked the three CloudFormation types" bash -c "[ \$(grep -c 'cloudformation describe-type' '$STUB_DIR/calls.log') = 3 ]"
check "no temp dir left behind" bash -c "[ -z \"\$(ls '$TMPDIR')\" ]"

reset_env; newdir dry-notoken; unset CF_API_TOKEN
lwf "" --dry-run --zone "$ZONE"
check "dry run without token and terminal skips Cloudflare and says so" bash -c "grep -q 'Cloudflare checks were skipped' '$OUT'"
check "...and still exits 0 and makes no Cloudflare call" bash -c "[ $RC = 0 ] && ! grep -q '^curl' '$STUB_DIR/calls.log'"

echo "== preflight blockers (dry run lists them and exits 1)"
for scen in "STUB_NO_BUDGET=1|no AWS Budget" "STUB_NO_LAMBDA_WEB=1|has no .lambda-web. command" "STUB_SCHEMA_DRIFT=ThrottleConfig|no longer has the properties" \
            "STUB_SCHEMA_DRIFT=NewRequired|requires properties the template does not set" "STUB_MISSING_CMDS=put-resource-policy|does not exist in this CLI version"; do
  reset_env; newdir pf; export "${scen%%|*}"
  lwf "" --dry-run --zone "$ZONE"
  check "blocker: ${scen%%|*}" bash -c "[ $RC = 1 ] && grep -q '${scen#*|}' '$OUT'"
done
reset_env; newdir pf-budget-ack; export STUB_NO_BUDGET=1 ACK_BUDGET=true
lwf "" --dry-run --zone "$ZONE"; check "ACK_BUDGET=true passes the budget guard" is "$RC" 0
reset_env; newdir pf-zone
lwf "" --dry-run --zone nosuchzone.test; check "unknown zone is a blocker" bash -c "[ $RC = 1 ] && grep -q 'not found for this token' '$OUT'"
reset_env; newdir pf-record
mkdir -p "$STUB_DIR/cf/records"; jq -nc '{id:"r1",type:"CNAME",name:"lwf-w.example.test",content:"x.example.test",comment:"someone else"}' > "$STUB_DIR/cf/records/r1.json"
lwf "" --dry-run --zone "$ZONE"; check "an existing lwf-* record is a blocker (never overwritten)" bash -c "[ $RC = 1 ] && grep -q 'already exist' '$OUT'"
reset_env; newdir pf-badtoken; export CF_API_TOKEN="wrong_token_wrong_token_wrong_token_00000"
lwf "" --dry-run --zone "$ZONE"; check "a token the API rejects is a blocker" bash -c "[ $RC = 1 ]"
reset_env; newdir pf-usage
lwf "" --zone "Bad_Zone"; check "bad zone name refused" is "$RC" 2
lwf "" --teardown not-a-run-id; check "bad run id refused" is "$RC" 2
lwf "" --dry-run --resume "$RUN_A"; check "--dry-run with --resume refused" is "$RC" 2
reset_env; newdir xtrace
printf '' | bash -x "$SCRIPT" --dry-run --zone "$ZONE" > "$OUT" 2>&1; RC=$?
check "refuses to run under bash -x (xtrace would print the token)" bash -c "[ $RC = 2 ] && grep -q 'refusing to run with xtrace' '$OUT'"

echo "== real run refusals change nothing"
reset_env; newdir refuse-budget; export STUB_NO_BUDGET=1
lwf "$PHRASE" --zone "$ZONE"
m="$(mutating_calls)"; check "no budget: exit 2 and no mutating call" bash -c "[ $RC = 2 ] && [ $m = 0 ]"
reset_env; newdir refuse-phrase
lwf "wrong phrase" --zone "$ZONE"
check "wrong confirmation phrase: exit 2, nothing changed" bash -c "[ $RC = 2 ] && grep -q 'phrase did not match' '$OUT'"
m="$(mutating_calls)"; check "...no mutating call at all" bash -c "[ $m = 0 ]"
reset_env; newdir refuse-notoken; unset CF_API_TOKEN
lwf "" --zone "$ZONE"
check "real run without a Cloudflare token refuses" bash -c "[ $RC = 2 ] && grep -q 'no Cloudflare token' '$OUT'"

echo "== full run"
reset_env; newdir full; seed_foreign
lwf "$PHRASE" --zone "$ZONE"
check "exit 0" is "$RC" 0
check "scan says nothing left" has "$OUT" "scan: nothing left"
check "no resource of this run is left (registry empty except the foreign ones)" aws_clean
check "no Cloudflare record, script, domain or pack of this run is left" cf_clean
check "another run's AWS resources and the unrelated DNS record are untouched" foreign_intact
check "A1 to A8 are all in results.json" bash -c "[ \$(jq '[.results[].id] | length' '$LWF_RESULTS_DIR/$RUN_A/results.json') = 8 ]"
for t in A1 A2 A4 A5 A6 A8; do check "$t PASS with the stubbed (documented) behaviour" is "$(result_of x $t)" PASS; done
check "A3 and A7 are MEASURED" bash -c "[ '$(result_of x A3)' = MEASURED ] && [ '$(result_of x A7)' = MEASURED ]"
check "report.md exists and lists the tests" bash -c "grep -q '| A5 |' '$LWF_RESULTS_DIR/$RUN_A/report.md'"
check "app stack was given KillAt about 6 hours ahead (UTC, yyyy-mm-ddThh:mm:ss)" bash -c "grep -Eq 'KillAt=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}' '$STUB_DIR/params-lwf-$RUN_A-app'"
check "the resource policy names the distribution as source" bash -c "jq -e '.Statement[0].Condition.StringEquals[\"aws:SourceArn\"] | test(\"distribution/\")' '$STUB_DIR/policy.json' || true"
check "Worker upload had metadata + both modules; three secrets went through stdin" bash -c "[ \$(grep -c . '$STUB_DIR/stdin.log') = 3 ] && grep -q AWS_SECRET_ACCESS_KEY '$STUB_DIR/stdin.log' && grep -q LWF_TOKEN '$STUB_DIR/stdin.log'"
SECRET="$(SECRET_VALUES)"
check "the AWS secret key reached the Cloudflare API on stdin" has "$STUB_DIR/stdin.log" "$SECRET"
check "the AWS secret key is NOT in any command line" hasnot "$STUB_DIR/calls.log" "$SECRET"
check "the Cloudflare token is NOT in any command line" hasnot "$STUB_DIR/calls.log" "$TOKEN"
check "token and key are not in the output" bash -c "! grep -q '$TOKEN' '$OUT' && ! grep -q '$SECRET' '$OUT'"
check "token and key are not in state, results or raw files" bash -c "! grep -rq -e '$TOKEN' -e '$SECRET' '$LWF_STATE_DIR' '$LWF_RESULTS_DIR'"
check "account id, ARNs and the access key id do not appear in the output or results" bash -c "! grep -rEq '$ACCT12|arn:aws|AKIA[0-9A-Z]{16}' '$OUT' '$LWF_RESULTS_DIR'"
check "the zone name is masked in output and results" bash -c "! grep -rq 'example.test' '$OUT' '$LWF_RESULTS_DIR'"
check "state file is mode 600 and the dir 700" bash -c "[ \"\$(ls -ld '$LWF_STATE_DIR/$RUN_A.env' | cut -c1-10)\" = -rw------- ] && [ \"\$(ls -ld '$LWF_STATE_DIR' | cut -c1-10)\" = drwx------ ]"
check "no temp dir (with the token header file) left behind" bash -c "[ -z \"\$(ls '$TMPDIR')\" ]"
check "teardown order: schedule and Worker go before the app stack, certificate and bucket after" bash -c "
  d='$STUB_DIR/deleted.log'
  s=\$(grep -n 'DELETE sched' \$d | head -1 | cut -d: -f1); w=\$(grep -n 'cf DELETE worker' \$d | head -1 | cut -d: -f1)
  a=\$(grep -n 'DELETE dist' \$d | head -1 | cut -d: -f1); c=\$(grep -n 'DELETE cert' \$d | head -1 | cut -d: -f1); b=\$(grep -n 'DELETE s3 ' \$d | head -1 | cut -d: -f1)
  [ \$s -lt \$a ] && [ \$w -lt \$a ] && [ \$a -lt \$c ] && [ \$a -lt \$b ]"
check "object versions were deleted before the artifacts stack" bash -c "grep -n 'DELETE s3obj' '$STUB_DIR/deleted.log' | head -1 | cut -d: -f1 | xargs -I{} sh -c '[ {} -lt \$(grep -n \"DELETE s3 \" \"$STUB_DIR/deleted.log\" | head -1 | cut -d: -f1) ]'"
check "never an ApplicationManaged call (no public endpoint exists)" hasnot "$STUB_DIR/calls.log" "ApplicationManaged"
check "the Cloudflare token was never in the environment of aws, curl or node" bash -c "[ ! -e '$STUB_DIR/leak.log' ]"
check "A1 recorded the negative control (lwf-x) and it did not answer 200" has "$LWF_RESULTS_DIR/$RUN_A/report.md" "negative control"

echo "== flags turn the extras off"
reset_env; newdir noextras
lwf "$PHRASE" --zone "$ZONE" --no-alias --no-probe --no-negative
check "exit 0 with O1, O2, O3 off" is "$RC" 0
check "no ACM request, no probe stack, no DNS record created" bash -c "! grep -q 'acm request-certificate' '$STUB_DIR/calls.log' && ! grep -q 'deploy.*-probe' '$STUB_DIR/calls.log' && ! grep -q 'curl POST .*dns_records' '$STUB_DIR/calls.log'"
check "results record the extras as off" bash -c "jq -e '.extras.O1_alias == false and .extras.O2_probe == false and .extras.O3_negative == false' '$LWF_RESULTS_DIR/$RUN_A/results.json'"

echo "== failure injected at each stage: the restore trap tears down exactly what exists"
stage() { # name, "svc cmd" or "METHOD substring", N
  local name="$1" what="$2" n="${3:-1}"
  reset_env; newdir "$name"; seed_foreign
  case "$what" in
    GET\ *|PUT\ *|POST\ *|DELETE\ *) export STUB_CF_FAIL="$what" ;;
    *) export STUB_FAIL="$what" STUB_FAIL_N="$n" ;;
  esac
  lwf "$PHRASE" --zone "$ZONE"
  check "$name: exit is not 0" bash -c "[ $RC != 0 ]"
  check "$name: restore ran and the scan is clean" bash -c "grep -q 'RESTORE: the run failed' '$OUT' && grep -q 'scan: nothing left' '$OUT'"
  check "$name: nothing of this run remains" run_clean
  check "$name: the other run and the unrelated record are untouched" foreign_intact
  check "$name: error text is redacted (no account id, key id, token, ARN, CloudFront domain)" bash -c "! grep -Eq '$ACCT12|AKIA[0-9A-Z]{16}|arn:aws|cloudfront.net|$TOKEN|abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ' '$OUT'"
}
stage fail-artifacts "cloudformation deploy" 1
stage fail-upload "s3api put-object" 1
stage fail-cert "acm request-certificate" 1
stage fail-app "cloudformation deploy" 2
stage fail-policy "lambda-web put-resource-policy" 1
stage fail-key "iam create-access-key" 1
stage fail-probe "cloudformation deploy" 3
stage fail-cf-validation-dns "POST /dns_records" 1
stage fail-cf-worker "PUT /scripts/" 1
stage fail-cf-secrets "PUT /secrets" 1
stage fail-cf-domain "PUT /workers/domains" 1
check "a Cloudflare API failure message with a token-like value is redacted" bash -c "! grep -q 'abcdefghijklmnopqrstuvwxyz' '$TMP/fail-cf-worker/out.txt'"

reset_env; newdir kill-invoke-fails; export STUB_FAIL="lambda invoke" STUB_FAIL_N=2
lwf "$PHRASE" --zone "$ZONE"
check "a kill switch that cannot be invoked is a FAIL of A8 (reported), the run is still torn down" bash -c "[ $RC = 0 ] && [ \"\$(jq -r '.results[] | select(.id == \"A8\") | .status' '$LWF_RESULTS_DIR/$RUN_A/results.json')\" = FAIL ] && grep -q 'scan: nothing left' '$OUT'"

echo "== interrupts"
for sig in INT TERM; do
  reset_env; newdir "sig-$sig"; seed_foreign; export STUB_SIG="$sig" STUB_SIG_AT="iam create-access-key"
  lwfsig "$PHRASE" --zone "$ZONE"
  check "$sig: exit code is 130/143 and the scan is clean" bash -c "{ [ $RC = 130 ] || [ $RC = 143 ]; } && grep -q 'scan: nothing left' '$OUT'"
  check "$sig: AWS and Cloudflare are clean and the foreign ones untouched" run_clean
  check "$sig: foreign resources untouched" foreign_intact
done

echo "== leftovers and awkward teardowns"
reset_env; newdir left-dist; export STUB_NODELETE=dist
lwf "$PHRASE" --zone "$ZONE"
check "a distribution that will not delete: exit 3 and LEFTOVER named" bash -c "[ $RC = 3 ] && grep -q 'LEFTOVER cloudfront distribution' '$OUT'"
reset_env; newdir left-stack; export STUB_NODELETE=stack
lwf "$PHRASE" --zone "$ZONE"
check "an app stack that will not delete is reported as a leftover (exit 3)" bash -c "[ $RC = 3 ] && grep -q 'LEFTOVER cloudformation stack' '$OUT'"
reset_env; newdir logs-again; export STUB_RECREATE_ONCE=1 STUB_RECREATE_LOGS=1
lwf "$PHRASE" --zone "$ZONE"
check "log groups Lambda re-creates are removed in a second pass: exit 0" bash -c "[ $RC = 0 ] && grep -q 'second pass' '$OUT' && grep -q 'scan: nothing left' '$OUT'"
reset_env; newdir markers; export STUB_MARKERS=1
lwf "$PHRASE" --zone "$ZONE"; check "bucket with versions and delete markers is emptied" bash -c "[ $RC = 0 ] && grep -q 'scan: nothing left' '$OUT'"
reset_env; newdir cert-busy; export STUB_CERT_BUSY=3
lwf "$PHRASE" --zone "$ZONE"; check "certificate still in use is retried until released" bash -c "[ $RC = 0 ] && grep -q 'scan: nothing left' '$OUT'"
reset_env; newdir cert-pack; export STUB_CERT_PACK=1
lwf "$PHRASE" --zone "$ZONE"
check "the Advanced Certificate pack of the custom domain is deleted" bash -c "[ $RC = 0 ] && grep -q 'cf DELETE pack' '$STUB_DIR/deleted.log' && [ -z \"\$(ls '$STUB_DIR/cf/packs')\" ]"
reset_env; newdir cf-down; export STUB_CF_FAIL="DELETE /workers/scripts"
lwf "$PHRASE" --zone "$ZONE"
check "a Cloudflare delete that fails is reported and the exit is non-zero" bash -c "[ $RC = 3 ] && grep -q 'TEARDOWN problem: Worker delete failed' '$OUT'"

echo "== test failures are reported, not hidden (exit stays 0, the run is still torn down)"
for scen in "STUB_UNLOCKED=1|A1|FAIL" "STUB_AUTH_DROPPED=1|A2|FAIL" "STUB_BUFFERED=1|A5|FAIL" "STUB_NO_CACHE_HIT=1|A6|FAIL" "STUB_THROTTLED=1|A4|INCONCLUSIVE" "STUB_WF_MANY_ENVS=1|A4|FAIL"; do
  reset_env; newdir "t-${scen%%=*}"; export "${scen%%|*}"; rest="${scen#*|}"
  lwf "$PHRASE" --zone "$ZONE"
  check "${scen%%|*} gives ${rest%%|*} ${rest#*|}" bash -c "[ $RC = 0 ] && [ \"\$(jq -r --arg i '${rest%%|*}' '.results[] | select(.id == \$i) | .status' '$LWF_RESULTS_DIR/$RUN_A/results.json')\" = '${rest#*|}' ]"
done
reset_env; newdir t-unlocked-text; export STUB_UNLOCKED=1
lwf "$PHRASE" --zone "$ZONE"; check "an answering unsigned endpoint says LOCK-DOWN BROKEN" has "$OUT" "LOCK-DOWN BROKEN"

echo "== --keep, --status, --teardown, --resume"
reset_env; newdir keep; seed_foreign
lwf "$PHRASE" --zone "$ZONE" --keep
check "--keep exits 0 and leaves the resources" bash -c "[ $RC = 0 ] && [ -e '$STUB_DIR/res/dist__lwf-$RUN_A' ] && grep -q 'kill switch fires at' '$OUT'"
n_deploy="$(count "$STUB_DIR/calls.log" 'cloudformation deploy')"
lwf "" --status "$RUN_A" --zone "$ZONE"
check "--status lists what is still there (exit 3) and hides the Worker token" bash -c "[ $RC = 3 ] && grep -q 'LEFTOVER cloudfront distribution' '$OUT' && ! grep -q WTOKEN '$OUT'"
lwf "" --resume "$RUN_A"
check "--resume skips finished steps, creates nothing twice, signed tests become INCONCLUSIVE, then tears down" bash -c "[ $RC = 0 ] && grep -q 'skip: artifacts' '$OUT' && grep -q 'skip: app stack' '$OUT' && [ \$(grep -c 'cloudformation deploy' '$STUB_DIR/calls.log') = $n_deploy ] && [ '$(result_of x A1)' = INCONCLUSIVE ]"
check "after the resumed run everything of the run is gone" run_clean
reset_env; newdir teardown-sub; seed_foreign
lwf "$PHRASE" --zone "$ZONE" --keep
lwf "" --teardown "$RUN_A" --zone "$ZONE"
check "--teardown removes everything and says so" bash -c "[ $RC = 0 ] && grep -q 'teardown complete, nothing left' '$OUT'"
check "...and nothing of the run remains" run_clean
lwf "" --teardown "$RUN_A" --zone "$ZONE"
check "--teardown a second time is idempotent (exit 0, nothing left)" bash -c "[ $RC = 0 ] && grep -q 'scan: nothing left' '$OUT'"
check "--teardown never touched the other run" foreign_intact
reset_env; newdir wrong-account; seed_foreign
lwf "$PHRASE" --zone "$ZONE" --keep
export STUB_OTHER_ACCOUNT=1
lwf "" --teardown "$RUN_A" --zone "$ZONE"
check "--teardown with credentials of another account is refused (it would look clean)" bash -c "[ $RC = 2 ] && grep -q 'was created in the AWS account ending' '$OUT'"
unset STUB_OTHER_ACCOUNT
lwf "" --teardown "$RUN_A" --zone other.example.test
check "--teardown with another zone than the run's is refused" bash -c "[ $RC = 2 ] && grep -q 'another Cloudflare zone' '$OUT'"
lwf "" --teardown "$RUN_A"
check "--teardown takes the zone from the state file when --zone is not given" bash -c "[ $RC = 0 ] && grep -q 'scan: nothing left' '$OUT'"
reset_env; newdir teardown-notoken; seed_foreign
lwf "$PHRASE" --zone "$ZONE" --keep
unset CF_API_TOKEN
lwf "" --teardown "$RUN_A" --zone "$ZONE"
check "--teardown without a Cloudflare token removes AWS and says the Cloudflare side was NOT handled (exit 3)" bash -c "[ $RC = 3 ] && grep -q 'Cloudflare resources NOT removed' '$OUT'"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
