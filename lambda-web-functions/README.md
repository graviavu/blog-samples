# Lambda Web Functions or a Function URL behind CloudFront or Cloudflare: test it, do not guess

**The problem.** Lambda has a new way to serve HTTP, Lambda Web Functions (launched 2026-10-12): you run an ordinary
Node HTTP server, one execution environment serves many requests at once, responses stream. You already put Lambda behind
CloudFront with a Function URL, and your DNS may sit on Cloudflare. Which of the two Lambda endpoints belongs behind
CloudFront, does the new one change the choice, and what happens if Cloudflare is the CDN in front instead? The
documentation answers part of this and leaves the rest open: whether a Web Function endpoint can really be locked to your
distribution, whether the app's own `Authorization` header (a JWT) still arrives, whether one environment really serves
many slow requests at once, whether streaming stays progressive through each hop, whether Cloudflare can reach an IAM-protected
Lambda at all. This sample deploys both endpoints behind one CloudFront distribution and a Cloudflare Worker, runs eight tests
against them, writes the results to a JSON and a markdown file, and deletes everything.

This is the deployable companion to the blog post on this topic (link goes live when the post is published).
Everything below is "as read 2026-10-18". The feature is days old: CloudFormation types, CLI commands and limits may change.
The script checks what it can before it creates anything and says so when something differs (see "Not verified").

## What it deploys

One run, one run id `yymmddhhmm-xxxx`, every resource named `lwf-<run id>...`.

| Where | What | Why |
|---|---|---|
| AWS us-east-1, stack `lwf-<run>-art` | S3 bucket (versioned, TLS only, private) with the two code zips | the web function revision needs its code in S3 first |
| AWS us-east-1, stack `lwf-<run>-app` (`cfn/app.yaml`) | CloudFront distribution, two origin access controls (`always-amz-auth` for the Web Function, `always` for the Function URL), cache policy (honours origin `Cache-Control`, `Authorization` in the key), Server-Timing on | the thing being compared |
| same stack | Web Function endpoint, auth `IamAuth` (**never** `ApplicationManaged`), `rateLimit` 200 rps, `maxEnvironments` 2, 64 concurrent requests per environment | behaviour, lock-down, concurrency |
| same stack | Event Function (arm64, 512 MB) + Function URL, auth `AWS_IAM`, response streaming, reserved concurrency 130 (lowered to fit the account, see below) | the comparison baseline |
| same stack | IAM user `lwf-<run>-worker` that may only invoke those two endpoints (`lambda:InvokeFunction` only with `lambda:InvokedViaFunctionUrl`) | the Worker signs with it |
| same stack | kill switch: a Lambda, a one-time EventBridge schedule at deploy + 6 h, an alarm `lwf-<run>-kill-failed` (optional email: `LWF_ALERT_EMAIL`) | a brake for a run you forget; it limits how long abuse can run, not what it costs while it runs (see Cost) |
| AWS CLI | the Web Function resource policy that lets this distribution in | no CloudFormation resource for it was found |
| Cloudflare | one Worker (`worker/worker.mjs` + `worker/sigv4.mjs`, no dependency) on the custom domain `lwf-w.<your zone>` | Cloudflare cannot sign SigV4 itself, so a Worker does it |
| O1, on by default | ACM certificate, two aliases on the distribution, `lwf-g` (DNS only) and `lwf-o` (proxied) CNAMEs to CloudFront | how you would run it today (grey), and does orange in front of CloudFront break? |
| O2, on by default | stack `lwf-<run>-probe` in eu-west-1: one tiny Event Function, no URL | latency from a second place |
| O3, on by default | `lwf-x` proxied CNAME straight to the Web Function endpoint | negative control: a plain proxy without a Worker cannot work |

Turn the extras off with `--no-alias`, `--no-probe`, `--no-negative`. The script never changes a Cloudflare zone setting
(SSL mode, cache rules, WAF); it reads the plan and SSL mode and records them. It never overwrites a record: if any
`lwf-*` DNS record or an `lwf-w` Workers domain exists, it refuses.

## What the tests settle

| Test | Question | Expected (the documented behaviour) |
|---|---|---|
| A1 lock-down | Is each endpoint reachable only with a signature? | unsigned to the Web Function and Function URL: 403; signed: 200; through CloudFront: 200; through the Worker with its run token: 200, without: 403. The O3 record is an observation, not a control (a plain CNAME cannot sign, so it can only be refused): A1 records who refuses it (AWS 403 or a Cloudflare error page), and only a 2xx would fail A1 |
| A2 headers | Does the app's JWT arrive? (the app returns only presence and a SHA-256 prefix, never a value) | CloudFront to Web Function: `Authorization` passes unchanged; CloudFront to Function URL: overwritten by the OAC; Worker: the viewer `Authorization` is replaced by the SigV4 header (Lambda strips it), so the token must travel in `x-app-auth`, which arrives; Host seen = the endpoint domain |
| A3 latency | TTFB per path, from here and from eu-west-1 | MEASURED only (30 warm GETs per path: p50, p90, point of presence, Server-Timing) |
| A4 concurrency | Does one Web Function environment serve many requests at once? | `/slow?ms=2000` with N = 64 and 128, twice each through CloudFront. The app reports how many requests were in flight in its environment: PASS when a Web Function environment had more than one and a Function URL environment never more than one. The number of Web Function environments is capped at `MaxEnvironments` 2 by configuration, so it is reported against that cap and is not a finding by itself (more than 2 is a FAIL). 429/503 are reported, not hidden; CloudWatch `AWS/Lambda/Web` metrics are attached |
| A5 streaming | Is a 10-chunk, 300 ms response progressive through each hop? | first byte < 1 s and total >= 2.5 s with >= 5 data events: direct signed, CloudFront, Worker, Worker baseline, `lwf-o` |
| A6 cache | Second request a CloudFront hit? What do Cloudflare (orange) and the Worker cache do? | CloudFront Hit with the same body on the second request; others MEASURED |
| A7 cost per 10M | Extrapolation from this run | MEASURED and labelled an extrapolation. Event Function: a separate batch of 50 light GETs (`/fu/ping` through CloudFront), so the 2 to 3 s `/slow` and `/stream` requests of A4 and A5 do not set the figure; billed duration from its REPORT lines at the **arm64** rate. Web Function: request fee plus active CPU plus memory for the environments' lifetime (2 GB each), from the `AWS/Lambda/Web` metrics of the whole run divided by the Web Function requests the script sent. That figure is **skewed high**: the lifetime includes the pauses between tests and the 2 s sleeps of A4, which a steady load would not have. List prices as read 2026-10-18 |
| A8 brake | Does the kill switch work? | invoked at the end; each outcome checked on its own: distribution disabled, Worker key inactive, Function URL function at reserved concurrency 0 (throttled), Web Function unreachable through CloudFront and through the Worker. Whether the Web Function was also throttled is reported, not required (see Not verified). A raised kill switch is a FAIL; a distribution still serving after 10 minutes is INCONCLUSIVE |

Statuses: **PASS**, **FAIL** (the documented expectation did not hold: that is a finding, not a script error),
**MEASURED**, **INCONCLUSIVE** (for example more than 5% of the requests were throttled), **SKIPPED** (A8 with `--keep`).
A5 retries a stream once when the first try is not progressive (a cold start can delay the first byte) and labels it `second-try`.
The run exits 0 whatever the test results; the exit code is about the run and the teardown (0 clean, 2 error, 3 leftovers,
130/143/129 interrupted).

## Before you run (about 10 minutes of your time)

1. A **test AWS account** with admin credentials in your environment or profile, and an **AWS Budget with at least one
   notification** (the script refuses without one; `ACK_BUDGET=true` confirms one it cannot see). A budget is a warning, not a cap:
   billing data lags by hours. Optional: `LWF_ALERT_EMAIL=you@example.com` subscribes that address to the kill-switch failure
   alarm (SNS sends a confirmation mail first).
2. A **Cloudflare zone you can spare names in** (you pass it with `--zone`; nothing is hardcoded) and an API token typed at the hidden prompt.
   Create a token scoped to that one zone and its account with: Zone / Zone: Read, Zone / DNS: Edit, Zone / SSL and Certificates: Edit,
   Zone / Workers Routes: Edit, Account / Workers Scripts: Edit. (The exact permission names in the Cloudflare dashboard are
   not verified; the preflight reads each thing it needs and names the one that is refused.)
   **Workers Scripts: Edit cannot be limited to one Worker: it lets the token change or delete every Worker in the account.**
   Use a Cloudflare account with no production Workers, give the token a short TTL (a few hours), and revoke it after the run.
   The token is never exported to a child process, never in a command line, a log or a results file; it lives in a shell variable
   and a mode-600 header file that is removed on exit, also after Ctrl-C (only `kill -9` can leave it behind in `$TMPDIR`).
3. Tools: AWS CLI v2 **with the `lambda-web` command**, `curl`, `jq`, `node` 20 or newer, `zip`, `openssl`. Works with the bash 3.2 that ships with macOS.

```bash
cd lambda-web-functions
./lwf-sample.sh --dry-run --zone example.com     # read-only: every check, the plan, no change
./lwf-sample.sh --zone example.com               # asks for the token, then for the phrase: deploy lwf sample
```

Other forms: `--keep` (leave it up for inspection; the kill switch still fires at +6 h), `--resume <run-id>` (continue a run that
stopped hard, for example `kill -9`, a lost terminal or `--keep`; an ordinary failure or Ctrl-C is torn down by the restore trap instead. It asks for the
phrase again, and refuses a run whose kill switch fires within the hour (or already fired) and a run that was torn down: then use `--teardown`
and start fresh. Finished steps are skipped; the AWS key is not recoverable, so the signed tests become INCONCLUSIVE; the Worker gets a new run token),
`--status <run-id>` (state plus a leftover scan, read-only), `--teardown <run-id>` (remove everything of that run).
Never run it with `bash -x`; the script refuses (it would print the token). Waits can be lengthened from the environment:
`READY_TRIES` (default 30; each try 20 s) for CloudFront and the Worker, `CERT_ISSUE_TRIES` (60, 15 s each) for ACM.

What happens, in order: preflight (identity, budget and its notification, the account's Lambda concurrency limit, `lambda-web` CLI,
the three CloudFormation types against the properties the template uses, token, zone, existing records and certificate packs) -> plan -> typed phrase -> artifacts stack and code upload -> ACM certificate (O1) -> app stack
(CloudFront takes 10 to 30 minutes) -> resource policy -> wait for CloudFront -> access key and Worker -> DNS records -> probe stack (O2) -> tests ->
`results/<run-id>/` -> teardown -> leftover scan. About 1.5 hours of wall time, most of it CloudFront deploying and deleting.

## Output

`results/<run-id>/results.json` and `report.md` (one row per test) and `raw/` (one redacted JSON per request or loop). All of
it goes through a redactor (account ids, ARNs, access key ids, your zone name as `<zone>`, distribution and bucket names, hosts,
tokens). It is best effort: read the files before you share them.

## Cost (estimates, not measurements)

| Item | Estimate |
|---|---|
| One run, about 3,000 requests | under $1. Web Function: $0.30 per million requests plus active CPU plus memory for the environment's whole lifetime (about 3 environments for 15 minutes is cents; how long an idle environment is kept is not documented, so it could be several times that). Event Function and the probe: inside the free tier or cents. CloudFront: inside the 10 million free requests. Logs, S3, ACM, scheduler: cents or $0. Cloudflare Free: $0 |
| Left up, idle | cents (Web Functions scale to zero). After +6 h the kill switch has cut access; the resources stay until you run `--teardown` |
| Abused before the kill switch fires | anyone can send requests to the CloudFront domain. Caps: the Web Function by `rateLimit` 200 rps and 2 environments; the Function URL function by reserved concurrency 130 and `/slow` held at most 3 s. A computation from list prices, not a measurement: both functions saturated for the full 6 hours is roughly $20 for the Event Function (130 x 21,600 s x 0.5 GB x $0.0000133334) plus a few dollars for the Web Function (2 environments: memory about $0.32, active CPU at most about $2.40, 200 rps of requests about $1.30), plus Lambda request fees. **CloudFront itself has no cap here**: about $1 per million requests above its free tier, whatever the origin answers. Whether AWS bills a request rejected for a missing signature is not documented. When the account's concurrency limit is too low to reserve 130 (new accounts), the account limit is the cap and the script says so |
| Workers Free | 100,000 requests a day hard cap, 10 ms CPU per request. If SigV4 does not fit in 10 ms the Worker returns errors and the tests say so; the $5/month Workers Paid plan would be a decision for you, the script never buys anything |

The Worker also needs a per-run token (header `x-lwf-token`, stored as a Worker secret, never in the state file) so that a stranger who
finds `lwf-w.<zone>` cannot spend the AWS side or the Workers quota. It fails closed: a Worker without that secret refuses everything but `/health`.

## Teardown

The script tears down at the end of a normal run, and the restore trap does it when a run fails or you press Ctrl-C (exactly the
resources named `lwf-<run id>*` or commented `lwf-sample <run id>`; another run, and your own records, are never touched).
`--teardown <run-id>` does the same by hand, finds things by name, so it works from a fresh checkout and can be run twice.
Order: Cloudflare custom domain, Worker, the Advanced Certificate packs this run recorded (ids seen after it created the custom domain;
a pack it did not record is reported by the scan, never deleted), DNS records (including the ACM validation records); the IAM access key;
the web function resource policy; the app stack (CloudFront deletion takes 10 to 30 minutes; the kill switch schedule and alarm go with it,
never before it: if the stack does not delete, the script fires the kill switch and reports the problem); the ACM certificate (retried while
CloudFront lets go); every object version and delete marker in the artifacts bucket, then its stack; the probe stack; log groups of both
Regions (Lambda re-creates them, so a second pass runs if the scan finds one).

Ctrl-C (or TERM, HUP) during the teardown does not stop it: the script says `teardown interrupted`, carries on, and tries a step once more if
the signal killed its `aws` or `curl` call. The third one stops it; then run `--teardown <run-id>`. Only after a clean scan is the state file
marked `TORN_DOWN` (and `--resume` refuses that run).

Then the **leftover scan** looks for anything named for the run in CloudFormation, Lambda, Lambda Web, CloudFront (distributions,
origin access controls, cache and response headers policies), S3, IAM roles and users, log groups, EventBridge Scheduler, CloudWatch alarms,
SNS topics, ACM and Cloudflare (records, Worker, custom domain, certificate packs). The CLI's `None` for an empty list is not a name.
Exit code 3 if anything is left or could not be checked (`LEFTOVER ...` and `SCAN-GAP ...` lines). The budget you created is yours and stays.

## Not verified

Written without access to a live account, from documentation and from the schemas bundled with cfn-lint 1.57.2. Nothing was run against AWS or Cloudflare.
Each item below either fails clearly in the preflight, shows up in a test result, or is best effort:

- **Web Function CloudFormation properties** (`AWS::Lambda::WebFunction`, `...Revision`, `...Endpoint`): the preflight compares the names the template uses and the attributes it reads with `describe-type` and stops, naming the difference. Valid `RateLimit` values are 0 and 100 and up (the plan said 20, which is not valid), so the default is 200.
- **The port and start command of a Web Function.** `app/wf-server.mjs` listens on `PORT` or 8080 and `package.json` has `start`; the pages read do not say how Lambda finds the server. A wrong guess shows as 502 / `Application.TimeoutListenError` and the script says so at the wait step.
- **The execution role trust** for web functions is assumed to be `lambda.amazonaws.com`.
- **CLI commands** `lambda-web put-resource-policy` and `delete-web-function` are required (preflight); `get-web-function` and `delete-resource-policy` are used if present (otherwise the scan or the removal is limited and says so). The exact resource-policy document shape (action, resource) follows the documentation sentence read, not a worked example.
- **The kill switch's web-function action** (`lambda:UpdateWebFunctionEndpoint`, and whether the Lambda runtime's boto3 knows `lambda-web` yet). **Known limitation:** without that client the kill switch does not throttle the Web Function and reports `web_function: not-throttled:no-lambda-web-client`; a wrong guess at the API shows as `error:...`. Either way the Web Function is cut off by the other actions: its endpoint is `IamAuth`, so with the distribution disabled and the Worker key inactive nobody outside the account can call it. A8 checks exactly that (not 200 through CloudFront and through the Worker) and does not claim a throttle it did not see.
- **How the kill switch is retried.** EventBridge Scheduler invokes Lambda asynchronously, so an error the function raises is retried by Lambda (`AWS::Lambda::EventInvokeConfig`, 2 retries, the maximum) and the alarm `lwf-<run>-kill-failed` goes off; the schedule's `RetryPolicy` (10 attempts) covers failures to deliver the event. The function raises only when one of the three access-cutting steps fails; the Web Function step is best effort.
- **CloudWatch `AWS/Lambda/Web` dimensions and metric units**; A7 converts only Seconds, Milliseconds and Microseconds, and takes `EnvironmentCPUTime` to be vCPU time and `EnvironmentActiveTime` to be the billed environment lifetime (2 GB per environment).
- **The Arm duration rate** in A7 ($0.0000133334 per GB-s, us-east-1 first tier) is the published Lambda Arm rate as known; the pricing page was not re-read for it on 2026-10-18.
- **`lambda:InvokedViaFunctionUrl`**: the `InvokedViaFunctionUrl` property of `AWS::Lambda::Permission` is in the cfn-lint 1.57.2 schema; the IAM condition key of the same name on the Worker user's `lambda:InvokeFunction` follows the Lambda documentation and was not run.
- **A `+` in a query** is a literal plus: the signer (Worker and probe) decodes the raw query itself and sends exactly the canonical form it signed (`+` as `%2B`, space as `%20`), so what Lambda receives always matches the signature. A client that means a space must send `%20`.
- **Cloudflare API endpoints** (Workers script upload, secrets, custom domains, certificate packs, `workers.dev` switch), the **token permission names**, and that deleting a custom domain leaves an Advanced Certificate behind (the script deletes any pack whose hosts are all `lwf-*` names of this run).
- `lambda:InvokeFunction` is granted to the Worker user next to `lambda:InvokeFunctionUrl` on the one sample function, because the documentation lists both for Function URL callers, and only with the condition `lambda:InvokedViaFunctionUrl` = true (the CloudFront permission has `InvokedViaFunctionUrl: true` too); the plan named two actions, this is three, all on those two resources.
- Streaming and concurrency through CloudFront to Web Functions are undocumented: A4 and A5 are the test.
- Cloudflare's behaviour with an orange cloud in front of CloudFront (TLS errors, loops, blocking) is exactly what `lwf-o` tests.

## Tests of the script itself

```bash
node --test test/*.test.mjs        # SigV4 against the AWS documentation vectors, the Worker (fake fetch and cache), the probe, the app
python3 tests/py/test_kill_switch.py   # the kill switch code inlined in cfn/app.yaml, against a fake boto3 (tests/run.sh runs it too)
tests/run.sh                       # lwf-sample.sh against a fake aws, curl, node and sleep: no cloud call, no network
cfn-lint cfn/*.yaml                # templates (CI pins the version)
```

`tests/run.sh` covers: the dry run makes only read calls; each preflight refusal (budget, CLI, schema drift, existing record, bad token); the typed phrase;
a full run to a clean scan (the fake CLI prints `None` for empty lists, as the real one does for null results); extras off; failures injected at every stage, each tearing down exactly the created set and leaving
another run's resources and an unrelated DNS record alone; SIGINT and SIGTERM during the run, during the normal teardown, during the restore
teardown and during `--teardown` (also when the signal kills the `aws` child, and three times in a row); the kill switch raising, not throttling the
Web Function, and CloudFront still serving; A4 with one request per environment; a cold first stream; low account concurrency; `--resume` without the
phrase, near or past the kill switch, and after teardown; a certificate pack the run did not create; leftovers (a distribution or stack that will not delete, re-created log groups,
delete markers, a certificate still in use, an Advanced Certificate pack, a failing Cloudflare delete); wrong account or zone on teardown; `--keep`, `--status`, `--resume`,
`--teardown` twice; the token and the AWS key never in argv, output, state or results, the token never in a child's environment and the AWS
secrets of the environment never in curl's or node's; redaction of error text.

## Files

| Path | What |
|---|---|
| `lwf-sample.sh`, `lib.sh` | the one script you run, and its helpers |
| `cfn/artifacts.yaml`, `cfn/app.yaml`, `cfn/probe.yaml` | the three templates |
| `app/` | the test application: `core.mjs` (shared), `wf-server.mjs` (Web Function), `fu-handler.mjs` (Function URL) |
| `worker/` | the Cloudflare Worker and the SigV4 signer |
| `tools/probe.mjs` | measurement helper (latency, parallel, streaming, signed GET; the key arrives on stdin) |
| `test/`, `tests/` | node tests; stub tests (`tests/run.sh`, fakes in `tests/bin/`); the kill switch unit test (`tests/py/`) |
