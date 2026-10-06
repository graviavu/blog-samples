# Time-window caching on CloudFront, without changing your origins (part 1: a fixed window)

**The problem.** Some data changes only inside a known window: a price while an exchange is open, a rate that updates once each
morning. One fixed cache lifetime is wrong either way: short means the origins are hammered all night, long means stale values at
the open. The usual fix is for every origin to send a short `Cache-Control` lifetime inside the window and a long one outside it.
That is fine for one origin you own. It fails when the data comes from **many origins owned by different teams**, where each change
is risky, slow to schedule and repeated once per origin. This sample shows how to decide the lifetime **at the CloudFront edge**
instead: a cache policy clamps whatever the origins send, a small CloudFront Function adds a time slot to the cache key, and the
window itself is **data** in a CloudFront KeyValueStore that you can move without a deployment. It is cheap (one function run per
request, no servers) and flexible (one window for every origin behind the distribution). No origin changes.

This is the deployable, testable companion to the blog post
[Time-window caching on CloudFront without changing your origins, part 1: a fixed window](https://blog.ar-logs.com/posts/cloudfront-time-based-caching/)
(link goes live when the post is published). The post says plainly which of its claims no test has confirmed yet. `verify.sh` tests
them against a real deployment, and the results go back to the post.

## What it deploys

Main stack, `template.yaml` (us-east-1):

| Resource | Purpose |
|---|---|
| CloudFront distribution | The default behavior is Option A. `PriceClass_100`, HTTPS only. Optional test behaviors (below). |
| KeyValueStore | Holds the window record under the key `window`: `{"startMin":810,"endMin":1200,"slotSeconds":5,"rev":1}` (UTC minutes since midnight, `startMin` below `endMin`). Written by `seed-kvs.sh`. |
| CloudFront Function (runtime 2.0) | `function/slot.js`, the post's Option A with the corrected closed-period key: reads the window, adds the slot to the cache key. In the window `w<n>` (a new value every `slotSeconds`), before the open `pre-<date>-r<rev>`, after the close `post-<date>-r<rev>`. |
| Cache policy `window` | The slot is the only addition to the cache key (query string `slot`, or header `x-cache-slot`, see `SlotCarrier`). Minimum TTL 600 s (`ClosedMinTtl`), so closed periods are cached long and `no-store` from origins is overridden. |
| Test origin | One Lambda function URL with **IAM auth**, reachable only through this distribution (origin access control). Answers fixed routes with controllable `Cache-Control`/`Expires`, a unique response id and a timestamp. Never reflects request input. |
| Response headers policy | Basic security headers (HSTS, nosniff, frame deny, referrer policy). |

Test-only extras, only when the stack parameter `EnableTestBehaviors` is `true` (the template default is `false`; `deploy.sh` sets `true` for the verify run):

| Path | Policy (min/default/max TTL, seconds) | For |
|---|---|---|
| `/p-orig/*` | 0 / 0 / 31,536,000: the same TTLs as the managed policy `UseOriginCacheControlHeaders` (the post's policy A) | T5, T9, T10 |
| `/p-b/*` | 30 / 60 / 3,600: the post's policy B | T5 |
| `/p-m0/*` | 0 / 20 / 60: small values so the cap and the default show up within a minute | T5 |
| `/p-defhi/*` | 0 / 60 / 20: default above maximum. Only with `TryDefaultAboveMax=true`; CloudFront may refuse it, which is itself the answer | T5e |
| `/legacy/*` | the window policy plus `function/slot-legacy.js`, the flawed first key `closed-<date>` | T3d |

The test origin routes (the last path segment): `none`, `nostore`, `private`, `nocache`, `public-nomax` (`public` without `max-age`),
`maxage-0|5|30|3600`, `smaxage-only`, `both-5` and `both-14400` (`max-age=0, s-maxage=N`, the post's example), `expires-past`,
`maxage-expires`, `etag` (conditional, 304), `slow` (1 s delay, `no-store`, for the collapsing test), `error-400|403|404|500|503` without
a header and `error-<code>-cc` with `s-maxage=60`. Everything before the last segment is ignored, which is how each test gets a fresh cache key.

Optional second stack, `template-lambda-edge.yaml` (**Option B**): a Lambda@Edge **origin-response** function that rewrites
`Cache-Control` to `public, max-age=0, s-maxage=<ttl>` by a **fixed UTC window constant passed at deploy time** (no data store: Lambda@Edge
has no environment variables, so the constants are filled into the code; a window change means a new function version, which is the
limit the post names). Its own distribution reaches the same test origin through its own origin access control. Status 400 and above
is not rewritten unless you ask (`EDGE_REWRITE_ERRORS=true`). **Deleting this stack can take hours** (see Teardown). Needed only for T2 and the edge part of T9.

Everything carries the tags `sample=cloudfront-time-window-caching` and `<CostTagKey>=cloudfront-time-window-caching` (the tag key is a
parameter, default `project`; activate it as a cost allocation tag if you want to see the cost).

### Differences from the code in the post

`function/slot.js` is the post's sketch with these deliberate changes, all explained in the file:

1. **The window record is validated and fails closed.** A missing key, unreadable JSON, wrong types, numbers out of range, or `startMin >= endMin`
   (a window across 00:00 UTC, unsupported in part 1) gives a short **fallback slot** `f<n>` (5 s): data is never older than that and the origin load
   stays bounded. The post's sketch returned the request unchanged, which would put every request on one shared cache key (fail-open).
2. The slot goes into a query string **or** a request header (`SlotCarrier`, default `query` as in the post). Whatever the viewer sent under
   that name is replaced, so a viewer cannot choose its own cache key (test T10c).
3. `rev` is validated (integer 0 to 999,999; missing means 0 as in the post).

The templates deploy exactly the files in `function/` (`node scripts/check-function-sync.mjs` fails if they differ; `--write` regenerates the template blocks).
The deployed test origin is `function/origin.js`.

## Before you deploy (mandatory)

1. **Create an AWS Budgets alert** in the account you will use, before you create anything. `deploy.sh` enforces this: it runs
   `aws budgets describe-budgets` and refuses to deploy if no budget exists or the check is not permitted (it fails closed and prints
   only the error code). If you already have a budget somewhere the script cannot see, set `ACK_BUDGET=true` to confirm. Console: Billing and
   Cost Management, Budgets, Create budget, Cost budget, a small monthly amount you are comfortable losing, an email alert at about 80 percent.
   Or with the CLI (the amount and address are examples; use your own):

   ```bash
   ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
   aws budgets create-budget --account-id "$ACCOUNT" \
     --budget '{"BudgetName":"cftw-sample","BudgetLimit":{"Amount":"5","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
     --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]}]'
   ```

   A budget alert is a warning, not a cap: billing data arrives with a delay of hours, so it will not stop a flood of requests.
2. **The stack should live for hours, not days.** Deploy, run `./verify.sh` (about 15 minutes), run `./teardown.sh` immediately, and check the leftover report.
3. Anyone who learns the distribution domain can send it requests, and you pay for them (next section).

## Estimated cost

**A short, quiet test should cost very little, but a flood of requests costs money.** This is an estimate, not a bill: I have not seen one for this sample.
What drives cost: CloudFront requests and data transfer, a CloudFront Function invocation and a KeyValueStore read on **every request to the default
behavior** (the `/p-*/` behaviors have no function), Lambda invocations for requests that reach the test origin (cache misses), and with the optional edge stack Lambda@Edge
requests and duration. Small standing items while the stack exists: CloudWatch Logs for the test origin (3-day retention), the KeyValueStore, and the cache entries.
A full `verify.sh` run sends roughly 3,000 to 4,000 requests to the distribution (the sampler, the T3 samples, two bursts of 30) and writes the KeyValueStore
a handful of times. At the list prices the post quoted on 2026-10-05 (CloudFront Functions $0.10 per million invocations, KeyValueStore $0.03 per million reads,
Lambda@Edge $0.60 per million requests, each with free tiers or not as the post says) that is a fraction of a cent for the functions, so I expect the whole run to
cost well under a dollar. **Check current pricing** before you start: [CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/pay-as-you-go/),
[Lambda pricing](https://aws.amazon.com/lambda/pricing/). Requests answered with an error are still billed. The numbers above are not a guarantee: a loop that
hammers the domain, or a stack left running for days, changes them. That is why the budget alert and a quick teardown are mandatory.

## Prerequisites

- An AWS account you may use for testing (not production) and permission to create CloudFormation stacks with IAM roles,
  CloudFront, Lambda, CloudWatch Logs and KeyValueStore resources.
- Region **us-east-1** for everything.
- `bash` and `curl` for `verify.sh`. The AWS CLI v2 for `deploy.sh`, `seed-kvs.sh`, `teardown.sh` and tests T3 and T4
  (the KeyValueStore data API needs SigV4A signing, which AWS CLI v2 includes). Without it `verify.sh` reports T3 and T4 as INCONCLUSIVE.
- Node.js 20 or newer only if you want to run the unit tests.

## Deploy

### Option A: scripts (AWS CLI)

```bash
cd cloudfront-time-window-caching
./deploy.sh                          # about 5 to 15 minutes; writes deploy.env (no secrets)
DEPLOY_EDGE=true ./deploy.sh         # optional: also the Lambda@Edge stack (T2, T9c). Slow to delete later.
SLOT_CARRIER=header ./deploy.sh      # optional: carry the slot in the header x-cache-slot instead of the query string
```

`deploy.sh` checks for a budget, runs `aws cloudformation deploy` (with `EnableTestBehaviors=true`, which `verify.sh` needs), then tries a second, harmless
update that adds the default-above-maximum policy (if CloudFront refuses it, CloudFormation rolls that update back, the stack stays healthy and `deploy.env` records
`DEFMAX=rejected`), then `seed-kvs.sh`, then writes `deploy.env` (shell-quoted with `printf %q`). All inputs are validated before they reach a command line.
Settings (environment variables): `STACK_NAME`, `NAME_PREFIX`, `SLOT_CARRIER`, `CLOSED_MIN_TTL`, `COST_TAG_KEY`, `ENABLE_TEST_BEHAVIORS`, `TRY_DEFAULT_ABOVE_MAX`,
`DEPLOY_EDGE`, `EDGE_WINDOW_START_MIN`, `EDGE_WINDOW_END_MIN`, `EDGE_IN_TTL`, `EDGE_OUT_TTL`, `EDGE_REWRITE_ERRORS`, `ACK_BUDGET` (see the header of `deploy.sh`).

### Option B: console

1. CloudFormation console, region us-east-1, **Create stack**, upload `template.yaml`. Set `EnableTestBehaviors` to `true` if you will run `verify.sh`
   (the template default is false). Leave `TryDefaultAboveMax` at `false`. Acknowledge that the stack creates an IAM role. Wait for `CREATE_COMPLETE`.
   Optional: afterwards **Update** the stack with `TryDefaultAboveMax=true` to try the policy for T5e. If it is refused, the update rolls back; keep `DEFMAX=rejected`.
2. Open the stack **Outputs**. Note `DistributionDomain`, `WindowStoreArn`, `OriginHost`.
3. Seed the window record. Console: CloudFront, **Functions**, **KeyValueStores**, open `cftw-window`, **Add key value pair**: key `window`, value
   `{"startMin":810,"endMin":1200,"slotSeconds":5,"rev":1}`. Or with the CLI: `STACK_NAME=<your stack> ./seed-kvs.sh`. The raw equivalent:

   ```bash
   KVS_ARN=<WindowStoreArn output>
   ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$KVS_ARN" --query ETag --output text)
   aws cloudfront-keyvaluestore put-key --kvs-arn "$KVS_ARN" --key window --if-match "$ETAG" \
     --value '{"startMin":810,"endMin":1200,"slotSeconds":5,"rev":1}'
   ```

   CloudFormation can create the store but cannot write items to it without an S3 import file, which would need a bucket. That is why seeding is a separate step.
4. Optional edge stack: create a second stack from `template-lambda-edge.yaml` (us-east-1) with the main stack's `OriginHost` and `OriginFunctionName` outputs as parameters
   (window constants default to the whole UTC day, `InTtl` 15 and `OutTtl` 45 seconds).
5. Run `verify.sh` with the values from the outputs, for example
   `CF_DOMAIN=<DistributionDomain> KVS_ARN=<WindowStoreArn> ORIGIN_HOST=<OriginHost> FUNCTION_NAME=cftw-slot ENABLE_TEST_BEHAVIORS=true DEFMAX=off ./verify.sh`
   (set `DEFMAX=accepted` or `rejected` as it turned out; add `EDGE_DOMAIN=<EdgeDistributionDomain>` and `SLOT_CARRIER=header` if you used them).

### Try it by hand

```bash
D=<DistributionDomain>
curl -si https://$D/hello/none            # JSON with a unique id; X-Cache: Miss, then Hit (same id) on a repeat
curl -si https://$D/hello/none            # the slot value the origin saw is in the body ("slot")
./seed-kvs.sh --starts-in 2 --length 4 --slot-seconds 10    # a short window that opens in about 2 minutes
./seed-kvs.sh --raw '{"startMin":"x"}'                        # an invalid record: the function fails closed (slot f<n>)
```

## Run the verification

```bash
./verify.sh                  # uses deploy.env; or: ./verify.sh <DistributionDomain>
```

**Duration: about 12 to 15 minutes. Keep the terminal open.** It prints PASS, FAIL or INCONCLUSIVE for each test with its hypothesis and expected
result, then one machine-readable line per test (`TEST=T3b RESULT=PASS DETAIL=...`) and a `SUMMARY` line. Where eventual consistency matters it retries with
caps (it waits up to 15 minutes for a fresh stack to answer; T4 waits up to 3 minutes). It writes every raw request and the compact samples to `verify-results-<time>.txt`.

| Phase | What happens | Time |
|---|---|---|
| ready, T0, T10 | wait for the stack, origin lock check, slot at the origin, two bursts of 30 requests | 1 to 2 min |
| sampler (T5, T9, T2) | about 75 cache entries are watched in parallel; lifetimes are inferred from `X-Cache`, `Age` and the unique id | about 2 min |
| T3 | seeds a window that opens in 1 to 2 minutes and stays open 4 minutes; samples every 2 s from before the open to 100 s after the close | 7 to 8 min |
| T4, T4b | change `rev` and time how long the edge takes to follow; write an invalid record | 1 to 2 min |

Safe to run: it only sends GET requests to your distribution and, in T3, T4 and T4b, writes the single key `window` in your own KeyValueStore (through `seed-kvs.sh`).
It never publishes or changes a function or the distribution. It leaves a valid, closed window record behind. Viewer requests must use HTTPS (`https-only`).
Do not run it close to 00:00 UTC (the T3 window must not cross midnight; the script then says so and marks T3 INCONCLUSIVE: rerun after 00:05 UTC).

## How to send back the results

1. Open the newest `verify-results-*.txt` and check it. It contains your distribution domain, the test origin host and the response headers (CloudFront request ids,
   edge location). `verify.sh` never writes AWS CLI error text to it (only the error code, for example `AccessDeniedException`), because those messages can contain account
   ids and IAM ARNs, and as a last step (also when you press Ctrl-C or the script is terminated, through an exit trap) it masks any 12-digit number and any `arn:aws...` string.
   It contains no credentials. Masking is a safety net, not a guarantee: look through the file, and remove anything you do not want to share.
2. Send the whole file (not only the summary lines) to the blog author, together with the console output of `deploy.sh` if `DEFMAX=rejected` (the refusal text is the answer for T5e).
   The raw headers and bodies are what let others check the claims.

## Teardown

```bash
./teardown.sh
```

It prints the stack names and asks you to type `yes` (use `./teardown.sh --yes` to skip the question). It refuses to delete a stack that does not carry the tag
`sample=cloudfront-time-window-caching`, and values you set explicitly in the environment (`STACK_NAME`, `NAME_PREFIX`, `EDGE_STACK_NAME`, `EDGE_NAME_PREFIX`) win over
`deploy.env`. It deletes the optional Lambda@Edge stack first, then the main stack, then checks for leftovers by name prefix (distributions, functions, KeyValueStores, policies,
origin access controls, Lambda functions, log groups, stacks) and exits non-zero if any remain.

- **Deleting a CloudFront distribution takes many minutes** (CloudFormation disables it, waits for the change to deploy everywhere, then deletes it). Expect 10 to 30 minutes. The script waits.
- The KeyValueStore and its data are deleted with the stack.
- **The Lambda@Edge stack can take hours to delete.** AWS removes the function replicas some time after the distribution is gone, and deleting the function fails until then
  (the stack ends in `DELETE_FAILED`). Run `./teardown.sh` again later. This is why the edge stack is optional.

Console steps instead: CloudFormation console, select the Lambda@Edge stack (if any), **Delete**; then the main stack, **Delete**; wait until both are gone. Then check CloudFront
(Distributions, Functions, KeyValueStores, Policies, Origin access), Lambda and CloudWatch log groups for names starting with `cftw`. If you changed `NamePrefix` or `STACK_NAME`, use those.

## Safety notes

- **The test origin is IAM-protected.** It is a Lambda function URL with `AuthType: AWS_IAM`. Its resource policy lets only `cloudfront.amazonaws.com`, only on behalf of this
  distribution (`SourceArn`), invoke it, with both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` (two statements, as the Lambda documentation requires for new function URLs).
  The optional edge stack adds the same two statements for its own distribution. There is no public mode. Test T0 checks it: a direct unsigned call must get 403 while the call
  through CloudFront gets 200. This is the standard documented OAC setup for a function URL (the origin is defined in the distribution), not function-based origin selection.
  It has only been checked with cfn-lint and the local tests, not deployed.
- **The origin copies nothing from the request into its output**, except two booleans and the slot value, and the slot only if it matches a strict pattern
  (`w<n>`, `f<n>`, `pre|post-<date>-r<rev>`, `closed-<date>`). The route is an exact key of a fixed table. It holds no secrets and reads no data store.
- **The IAM role of the origin** may write only to its own log group. The edge function has no permissions and no logging on purpose (Lambda@Edge logs go to many regions, which would need a wildcard).
  No policy in the templates uses a wildcard resource or principal (a unit test checks).
- **Who can edit the window decides the cache behavior.** Restrict `cloudfront-keyvaluestore:PutKey` to the people who may move the window. A bad value fails closed (short fallback slot), not open.
- **Viewers cannot choose their cache key.** The function replaces any viewer-supplied `slot` or `x-cache-slot` (test T10c), and the cache policy keeps the viewer's other query strings out of the key and out of the origin request.
- **TLS.** Viewers must use HTTPS. With the default `*.cloudfront.net` certificate CloudFront does not let you set a minimum TLS version. The origin is reached over TLS 1.2 only.
- **POST and PUT** are not allowed by the behaviors (GET and HEAD only). With OAC for a Lambda function URL a body would need an `x-amz-content-sha256` header, because Lambda does not support unsigned payloads.
- No secrets, account ids or ARNs are in this repository (CI scans for them). `deploy.env` and `verify-results-*.txt` are git-ignored.
- Do not run it in a production account. Delete it when done.

## What each test settles

Test ids follow the numbering in the blog series' claims audit and the post (T1, T6, T7 and T8 belong to the routing post and are not here). T0 and T10c are sample-specific checks, not post claims.
The post: [Time-window caching on CloudFront without changing your origins, part 1](https://blog.ar-logs.com/posts/cloudfront-time-based-caching/).

| Test | Question it settles | Claim in the post (section) | Needs |
|---|---|---|---|
| T0 | Is the origin reachable only through CloudFront (direct unsigned call 403, call through CloudFront 200)? | none; safety of this sample | nothing |
| T2a, T2b | Does a Lambda@Edge rewrite of `Cache-Control` set the edge TTL, whatever the origin sent, and beat the policy default? | "Option B", "Which edge mechanisms can change the edge TTL" (the one point not confirmed in the docs) | edge stack |
| T3a | Before the open, do all requests share one entry (`pre-<date>-r<rev>`)? | "Option A" (closed-period key) | AWS CLI |
| T3b | In the window, does a new slot mean a new cache key, with about one origin fetch per slot, and does the slot length bound the lifetime? | "Option A" (slot length equals in-window lifetime) | AWS CLI |
| T3c | After the close, is the response NOT the pre-open body (the corrected key)? | "Option A", "What is solved and what is not" (boundary expiry) | AWS CLI |
| T3d | Does the first key `closed-<date>` really serve the pre-open body after the close? | "Option A" (the closed-period identifier needs care) | AWS CLI, test behaviors |
| T4 | Is a changed KeyValueStore value live at the edge without republishing, and in how many seconds (one vantage point)? | "Limits of Option A" (propagation "a few seconds", unconfirmed) | AWS CLI |
| T4b | Does a missing or invalid record fail closed to a short fallback slot? | not in the post (this sample's design) | AWS CLI |
| T5a | Does the documented precedence table hold for the managed-style policy, the post's policy B and a 0/20/60 policy? | "How a cache policy clamps origin lifetimes" (both tables) | test behaviors |
| T5b | `s-maxage` without `max-age`: honored (H1) or treated as no header (H2)? | "Three cases are not documented" | test behaviors |
| T5c | `Cache-Control: public` without `max-age`: default TTL (H1)? | "Three cases are not documented" | test behaviors |
| T5d | `no-store`, `no-cache`, `private` with a minimum TTL of 0: not cached? | "Three cases are not documented" | test behaviors |
| T5e | Default TTL above the maximum TTL: clamped to the maximum (H1), or the default? Or refused at creation? | "Three cases are not documented" | test behaviors |
| T5f | ETag revalidation (RefreshHit) after expiry (informational) | none | test behaviors |
| T9a, T9b | Which error codes are cached without and with a header, and for how long? | "Option B" (errors of 400 and above) | test behaviors |
| T9c | Does a Lambda@Edge-rewritten header make an error cacheable? | "Option B" (stamping `s-maxage` on an error) | edge stack |
| T10a | Does the slot reach the origin as the query parameter (or header)? | "Limits of Option A" (the slot reaches the origin) | nothing |
| T10b | Does an origin that knows nothing about the slot return the same content with and without it? | "Limits of Option A" (each origin ignores the unknown parameter) | test behaviors |
| T10c | Can a viewer choose its own cache key by sending a slot? | none; sample design | nothing |
| T10d | With minimum TTL above 0, does a burst for one new key cost the origin about one fetch (request collapsing)? | "Option A", step 3 | nothing |
| T10e | With minimum TTL 0 and `no-store`, is collapsing prevented (documented counter-case)? | "Option A", step 3 | test behaviors |

Each test has a stated hypothesis and expected result in the script output. PASS means the observed behavior matched the expectation (the post's claim, the documented behavior, or for
the undocumented cases the stated hypothesis H1: see the hypothesis text). FAIL means it did not. INCONCLUSIVE means the test could not decide (a missing prerequisite, a window crossing
midnight, too few usable samples, a throttled burst).

### What this sample cannot settle

- **Real origin types.** T10 uses one Lambda origin. Whether a signed-URL origin, S3, API Gateway or your own backend tolerates the extra `slot` parameter needs a test against that origin (add it as a second origin to a copy of the stack).
- **The header carrier.** Whether a header added by a viewer request function enters the cache key through a header allow-list in the cache policy is not something I found documented; running `verify.sh` with `SLOT_CARRIER=header` is the test (T3b fails if it does not).
- **One vantage point.** Cache entries are per edge location, and T3 and T4 observe the edge your connection reaches. T4 is one measurement, not an SLA.
- **Option B out of window.** By default the edge window covers the whole UTC day, so only the in-window TTL is exercised. Pass `EDGE_WINDOW_START_MIN` and `EDGE_WINDOW_END_MIN` for a window that closes during a run; T2 then reports INCONCLUSIVE if the boundary passes mid-run.
- **Part 2 topics** (time zones, daylight saving, holidays, clock skew, boundary expiry of entries cached just before the close, invalidation) are out of scope.
- **Cost at scale.** The run is small. Miss rates and request volumes in production decide the real cost.
- A test shows the behavior on the day it was run.

## Results

*Not run yet.* The deployment test results will be added here after the stack has been deployed and `verify.sh` has been run:
date, parameters, the machine-readable lines, and the conclusion for each claim.

## Development (no AWS needed)

```bash
cd cloudfront-time-window-caching
node --test test/*.test.mjs          # unit tests: slot function, origin, edge function, template checks (no dependencies)
node scripts/check-function-sync.mjs # templates embed exactly function/*.js
test/verify-mock.sh                  # runs verify.sh against a local mock with a faster clock (about 3 minutes); tests the script, not CloudFront
test/deploy-test.sh                  # deploy.sh guards (budget check, validation, two-phase update) with a fake aws CLI
test/teardown-test.sh                # teardown.sh guards (tag check, confirmation, env precedence) with a fake aws CLI
test/seed-test.sh                    # seed-kvs.sh validation and the JSON it writes
cfn-lint template.yaml template-lambda-edge.yaml   # pip install cfn-lint
shellcheck *.sh test/*.sh test/mock/fake-aws ../scripts/*.sh
```

The unit tests cover: pre-open, in-window and post-close slot keys (edges included), a changed `rev` or date changing the closed key, a missing or invalid record failing closed
(21 invalid shapes), windows across midnight being rejected, query and header normalization (viewer-supplied values replaced), the test origin's routes and its allow-listed slot echo,
and the edge function in and out of the window with and without error rewriting. The mock-based test also runs deliberately broken mocks that `verify.sh` must report as FAIL.
CI (`.github/workflows/ci.yml` at the repository root) runs all of the above plus a scan for account ids and keys.

The deploy, teardown and verify patterns (budget check, tag-gated teardown, results redaction and exit trap) are copied from the `cloudfront-request-routing` sample. They could
later move to a shared directory used by both samples.
