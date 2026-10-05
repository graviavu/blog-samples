# CloudFront as a reverse proxy for many backends, without a change per route

**The problem.** You run several backends behind one domain and the list keeps changing: a new tenant, a new
service, a backend that moves. The usual answers are one CloudFront cache behavior per route (every new route is a
distribution change, which rolls out edge by edge and needs someone with permission to edit the distribution) or a
separate proxy tier in front of or behind CloudFront (servers to run, patch and pay for). This sample shows a third way:
**CloudFront itself is the reverse proxy.** One catch-all behavior, a small CloudFront Function, and a route table
in a CloudFront KeyValueStore. Adding or moving a backend is a data update. No distribution change, no extra proxy.

This is the deployable, testable companion to the blog post
[Route to many backends with CloudFront alone](https://blog.ar-logs.com/posts/cloudfront-request-routing/)
(link goes live when the post is published). The post makes several claims that the AWS documentation does not settle.
`verify.sh` tests them against a real deployment.

## What it deploys

Main stack, `template.yaml` (us-east-1):

| Resource | Purpose |
|---|---|
| CloudFront distribution | One catch-all default behavior. Default origin is a custom origin (HTTPS only, port 443). `PriceClass_100`. |
| KeyValueStore | The route table: route key to backend domain name. Seeded by `seed-kvs.sh`. |
| CloudFront Function (runtime 2.0) | `function/route.js`: normalizes the key, checks the table, calls `updateRequestOrigin()`. Unknown key gives 404, bad value gives 500, never a fall-through to the default origin. |
| Cache policy and origin request policy | The routing attribute (`x-backend` or `host`) is in the cache key. The origin request policy forwards one harmless test header and not `Host`. |
| Three Lambda functions with function URLs | Test origins (default origin, backend A, backend B). Each returns JSON that echoes the Host it saw, the path, three test headers and its own name. By default (`OriginAuth=AWS_IAM`) all three require IAM auth and are reachable only through this distribution (origin access control); `OriginAuth=NONE` makes them public. |
| Response headers policy | Basic security headers (HSTS, nosniff, frame deny, no-referrer) on routed responses. |
| Test-only behaviors `/control/*` and `/probe/*` | Optional. The template default for `EnableTestBehaviors` is **false**; `deploy.sh` sets it to true because `verify.sh` needs them. `/control/*` has a cache key with only the path (test T1a). `/probe/*` shows the raw Host seen by a function (test T8). Without them T1a and T8 report INCONCLUSIVE. |
| Log groups, one IAM role | Three log groups (3-day retention) and one role that can only write to them. No wildcard permissions. No S3 buckets. |

Optional second stack, `template-lambda-edge.yaml`: the Lambda@Edge origin request variant from the post, with its own
distribution (test T7). It reuses the main stack's test origins, which must then be public (`OriginAuth=NONE`) because Lambda@Edge cannot sign
requests to a retargeted origin. Deleting it is slow (see Teardown).

Everything carries the tags `sample=cloudfront-request-routing` and `<CostTagKey>=cloudfront-request-routing` (the tag
key is a parameter, default `project`; activate it as a cost allocation tag if you want to see the cost).

### How the tests work on a `*.cloudfront.net` domain, and why Host tests need an alias

The post routes on the viewer `Host` header. A `*.cloudfront.net` domain gives you exactly one host name, so you
cannot send two different valid hosts to it. The sample therefore routes on a request header, `x-backend`
(`ROUTE_ATTRIBUTE=x-backend`, the default), which curl can set freely. The function code is otherwise the post's code.
That is enough to settle the cache key, KeyValueStore, inheritance and failure-handling questions.

To test real Host-based routing, deploy with `ROUTE_ATTRIBUTE=host`, two alias domain names, and an ACM certificate in
us-east-1 that covers both. `verify.sh` reaches the alias without DNS changes by using curl `--connect-to`. The alias and
certificate are optional parameters, are never committed, and cost nothing extra beyond the certificate being yours.

### Differences from the code in the post

`function/route.js` is the post's function with four small changes, all marked in the file:
(1) `ROUTE_ATTRIBUTE` chooses which request header is the key (`host` is the post's behavior);
(2) a missing or empty attribute returns 404 instead of throwing;
(3) an empty key after normalization returns 404;
(4) a stored value must also end with `BACKEND_SUFFIX` (allow-list, see Safety notes). The template deploys exactly this file (`node scripts/check-function-sync.mjs`
fails if they differ; `--write` regenerates the template block).

## Before you deploy (mandatory)

1. **Create an AWS Budgets alert** in the account you will use, before you create anything. Console: Billing and Cost Management,
   Budgets, Create budget, Cost budget, set a small monthly amount you are comfortable losing, add an email alert at about
   80 percent. Or with the CLI (the amount and address are examples; use your own):

   ```bash
   ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
   aws budgets create-budget --account-id "$ACCOUNT" \
     --budget '{"BudgetName":"cfrouting-sample","BudgetLimit":{"Amount":"5","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
     --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"you@example.com"}]}]'
   ```

   A budget alert is a warning, not a cap: billing data arrives with a delay of hours, so it will not stop a flood of requests.
2. **The stack should live for hours, not days.** Deploy, run `./verify.sh`, run `./teardown.sh` immediately, and check the leftover report.
3. Anyone who learns the distribution domain can send it requests, and you pay for them (see the next section).

## Estimated cost

**A short, idle test usually costs little, but a flood of requests costs money.** CloudFront bills requests and data transfer,
CloudFront Function invocations and KeyValueStore reads are billed per use (beyond the free tiers), and so are Lambda invocations for
requests that reach a test origin. **Requests that the function answers with a 404 or 500 at the edge are still billed** as CloudFront
requests plus a function invocation. Anyone who finds the `*.cloudfront.net` name can generate that traffic, which is why the budget
alert and a quick teardown are mandatory. There are also small standing items while the stack exists (CloudWatch Logs with 3-day
retention, the KeyValueStore). The T4 test makes a handful of KeyValueStore API calls (non-read API calls are billed per request).
No amounts are quoted here because they change. **Check current pricing** before you start:
[CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/pay-as-you-go/),
[Lambda pricing](https://aws.amazon.com/lambda/pricing/). No numbers are quoted here because they change.

## Prerequisites

- An AWS account you may use for testing (not production) and permission to create CloudFormation stacks with IAM roles,
  CloudFront, Lambda, CloudWatch Logs and KeyValueStore resources.
- Region **us-east-1** for everything.
- `bash` and `curl` for `verify.sh`. The AWS CLI v2 for `deploy.sh`, `seed-kvs.sh`, `teardown.sh` and test T4
  (the KeyValueStore data API needs SigV4A signing, which AWS CLI v2 includes).
- Node.js 20 or newer only if you want to run the unit tests.

## Deploy

### Option A: scripts (AWS CLI)

```bash
cd cloudfront-request-routing
./deploy.sh                      # about 5 to 15 minutes; writes deploy.env (no secrets)
DEPLOY_EDGE=true ./deploy.sh     # optional: also deploy the Lambda@Edge stack (needed for T7); forces PUBLIC test origins
```

`deploy.sh` runs `aws cloudformation deploy` (with `EnableTestBehaviors=true`, which `verify.sh` needs), then `seed-kvs.sh`, then writes
`deploy.env` (shell-quoted with `printf %q`) for `verify.sh` and `teardown.sh`. It rejects alias names that are not lower-case letters,
digits, dots and hyphens.
It reads these optional environment variables: `STACK_NAME`, `NAME_PREFIX`, `ROUTE_ATTRIBUTE`, `CACHE_KEY_ATTRIBUTE`,
`ALIAS_A`, `ALIAS_B`, `CERT_ARN`, `COST_TAG_KEY`, `ENABLE_TEST_BEHAVIORS`, `ORIGIN_AUTH` (`AWS_IAM` default, or `NONE`).

### Option B: console

1. CloudFormation console, region us-east-1, **Create stack**, upload `template.yaml`. Keep the default parameters, except set
   `EnableTestBehaviors` to `true` if you will run `verify.sh` (the template default is false). Acknowledge
   that the stack creates an IAM role. Wait for `CREATE_COMPLETE`.
2. Open the stack **Outputs**. Note `DistributionDomain`, `RouteStoreArn`, `OriginAHost`, `OriginBHost`.
3. Seed the route table. Console: CloudFront, **Functions**, **KeyValueStores**, open `cfrouting-routes`, **Add key value pair**
   for these entries (the first two use the output hosts as values):

   | Key | Value |
   |---|---|
   | `route-a` | the `OriginAHost` output |
   | `route-b` | the `OriginBHost` output |
   | `bad-colon` | `example.net:8443` |
   | `bad-ip` | `192.0.2.10` |
   | `bad-upper` | `Origin-A.example.net` |
   | `bad-suffix` | `origin-a.example.net` |

   Or with the CLI: `STACK_NAME=<your stack> ./seed-kvs.sh`. The equivalent raw commands are:

   ```bash
   KVS_ARN=<RouteStoreArn output>
   ETAG=$(aws cloudfront-keyvaluestore describe-key-value-store --kvs-arn "$KVS_ARN" --query ETag --output text)
   aws cloudfront-keyvaluestore update-keys --kvs-arn "$KVS_ARN" --if-match "$ETAG" \
     --puts '[{"Key":"route-a","Value":"<OriginAHost>"},{"Key":"route-b","Value":"<OriginBHost>"}]'
   ```

   CloudFormation can create the store but cannot write items to it without an S3 import file, which would need a bucket.
   That is why seeding is a separate step.
4. For `verify.sh`, run it with the values from the outputs, for example
   `CF_DOMAIN=<DistributionDomain> ORIGIN_A_HOST=<OriginAHost> ORIGIN_B_HOST=<OriginBHost> KVS_ARN=<RouteStoreArn> ./verify.sh`.
5. Optional Lambda@Edge variant: set the main stack's `OriginAuth` parameter to `NONE` (public test origins), then create a second stack from `template-lambda-edge.yaml` (us-east-1) with the three host
   outputs as parameters, then add `EDGE_DOMAIN=<EdgeDistributionDomain>` to the `verify.sh` command.

### Try it by hand

```bash
D=<DistributionDomain>
curl -s -H 'x-backend: route-a' https://$D/hello      # JSON from origin-a
curl -s -H 'x-backend: route-b' https://$D/hello      # JSON from origin-b
curl -s -o /dev/null -w '%{http_code}\n' -H 'x-backend: nope' https://$D/hello   # 404
```

## Run the verification

```bash
./verify.sh                  # uses deploy.env; or: ./verify.sh <DistributionDomain>
```

It prints PASS, FAIL or INCONCLUSIVE for each test with its hypothesis and expectation, then one machine-readable line per test
(`TEST=T1b RESULT=PASS DETAIL=...`) and a `SUMMARY` line. It retries with caps for eventual consistency (it waits up to 15
minutes for a fresh stack to answer). It writes every raw request, header and body to `verify-results-<time>.txt`.
Safe to run: it only sends GET requests to your distribution and, in T4, writes and deletes one key (`t4-probe`) in your own
route table. It never publishes or changes the function or the distribution. Typical run time is a few minutes.
Viewer requests must use HTTPS (`https-only`); plain `http://` gets a 403.

A first run also exercises the "no alias" path. For the Host-based run, redeploy with
`ROUTE_ATTRIBUTE=host CACHE_KEY_ATTRIBUTE=host ALIAS_A=... ALIAS_B=... CERT_ARN=... ./deploy.sh` and run `./verify.sh` again.
To see the cache-key hazard on the default behavior itself, redeploy with `CACHE_KEY_ATTRIBUTE=none` and run it again
(T1b then expects the shared entry).

## How to send back the results

1. Open the newest `verify-results-*.txt` and check it. It contains your distribution domain, the test origin hosts and the
   response headers (CloudFront request ids, edge location). `verify.sh` never writes AWS CLI error text to it (only the error code,
   for example `AccessDeniedException`), because those messages can contain account ids and IAM ARNs, and as a last step it masks
   any 12-digit number and any `arn:aws...` string. It contains no credentials. Masking is a safety net, not a guarantee: look
   through the file, and remove anything you do not want to share.
2. Send the whole file (not only the summary lines) to the blog author. The raw headers and bodies are what let others check the claims.
3. Do not post results with an alias domain you want to keep private.

## Teardown

```bash
./teardown.sh
```

It prints the stack names and asks you to type `yes` (use `./teardown.sh --yes` to skip the question). It refuses to delete a stack that
does not carry the tag `sample=cloudfront-request-routing`, and values you set explicitly in the environment (`STACK_NAME`, `NAME_PREFIX`,
`EDGE_STACK_NAME`, `EDGE_NAME_PREFIX`) win over `deploy.env`. It deletes the optional Lambda@Edge stack, then the main stack, then checks for
leftovers by name prefix (distributions, functions, KeyValueStores, policies, origin access controls, Lambda functions, log groups, stacks)
and exits non-zero if any remain.

- **Deleting a CloudFront distribution takes many minutes** (CloudFormation disables it, waits for the change to deploy everywhere,
  then deletes it). Expect 10 to 30 minutes. The script waits.
- The KeyValueStore and its data are deleted with the stack.
- **The Lambda@Edge stack can take hours to delete.** AWS removes the function replicas some time after the distribution is gone, and
  deleting the function fails until then (the stack ends in `DELETE_FAILED`). Run `./teardown.sh` again later.

Console steps instead: CloudFormation console, select the Lambda@Edge stack (if any), **Delete**; then the main stack, **Delete**;
wait until both are gone. Then check CloudFront (Distributions, Functions, KeyValueStores, Policies), Lambda and CloudWatch log groups
for names starting with `cfrouting`. If you changed `NamePrefix` or `STACK_NAME`, use those.

## Safety notes

- **Exposure of the test origins.** By default (`OriginAuth=AWS_IAM`) all three test origins are Lambda function URLs with IAM auth,
  and each function's resource policy lets only `cloudfront.amazonaws.com` invoke it, only on behalf of this distribution (`SourceArn`),
  with both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` (two permission statements per function, as the Lambda documentation
  requires for new function URLs). They echo only non-secret request data (Host header, path, query string, three test headers,
  origin name, request id) and are deleted by teardown. Do not put real backends, credentials or secrets in this sample.
  **Public mode:** with `OriginAuth=NONE` the three function URLs are public: anyone who learns a URL can call it directly and you pay for
  those calls. `deploy.sh` forces this mode when you ask for the Lambda@Edge variant (`DEPLOY_EDGE=true`), because Lambda@Edge cannot sign
  requests to an origin it retargets.
- **How the lock works, and what is and is not documented.** `route.js` passes
  `originAccessControlConfig: { enabled: true, signingBehavior: 'always', signingProtocol: 'sigv4', originType: 'lambda' }` on every
  `updateRequestOrigin()` call. The AWS documentation for `updateRequestOrigin()` lists these properties and lists Lambda function URLs as a
  supported origin type, and says an OAC set on the call applies to the new origin (its only worked example is S3). The documentation
  also describes the Lambda function URL OAC setup (auth `AWS_IAM`, two permissions, HTTPS-only origin). **But AWS has no Lambda-specific
  example of the combination "function-based origin selection plus OAC for a Lambda function URL", and the docs are ambiguous about how
  the signing is bound when the origin is not defined in the distribution.** So this is unproven until the first deployment. Tests
  **T6a** (routed call returns 200 from the right backend) and **T6i** (a direct, unsigned call to each function URL returns 403 while the
  routed call through CloudFront returns 200) confirm or refute it. The template itself has only been checked with cfn-lint, not deployed.
- **If T6a or T6i fails, fallback.** If the routed call fails (403 from the backend) the combination does not work as assumed. Then either
  (a) redeploy with `ORIGIN_AUTH=NONE` (public test origins) and accept the exposure for the short life of the stack, optionally also
  setting reserved concurrency on the three Lambda functions in the console to bound abuse, or (b) keep IAM auth only for backends defined
  as origins in the distribution and select them with `selectRequestOriginById()` (the documented way to use an OAC attached to a configured
  origin). If the direct call returns 200, the resource policy is too open: tear down and do not use the sample until that is understood.
- **POST and PUT.** With OAC for a Lambda function URL, a client that sends a request body must send its SHA256 in the
  `x-amz-content-sha256` header, because Lambda does not support unsigned payloads. This sample uses GET only, so it does not matter here;
  it matters as soon as you proxy POST or PUT to a function URL.
- **TLS.** Viewers must use HTTPS. With the default `*.cloudfront.net` certificate CloudFront does not let you set a minimum TLS version;
  `MinimumProtocolVersion: TLSv1.2_2021` applies only when you bring an alias and a certificate. Backends are reached over TLS 1.2 only.
- **Backend allow-list.** Besides the domain pattern, `route.js` accepts a stored value only if it ends with `BACKEND_SUFFIX` (default
  `.lambda-url.us-east-1.on.aws`, which fits this sample's test origins). For your own backends set it to your own suffix. An empty string
  turns the suffix check off.
- **No open proxy.** The function treats the request value only as a key. It forwards to a domain name only if the key is in the
  KeyValueStore *and* the stored value matches a strict pattern (no port, no IP address, lower-case). Anything else is a 404 or 500 generated
  at the edge. Test T6 checks this. Restrict who can write to the store: whoever can edit it decides where traffic goes.
- No secrets, account ids or ARNs are in this repository. `deploy.env` is git-ignored. The certificate ARN, if you use one, is a
  stack parameter you type yourself.
- Do not run it in a production account. Delete it when done.
- Not covered: an S3 (origin access control) default origin. The post's S3 inheritance question (part of T6) stays open.

## What each test settles

Test ids follow the numbering in the blog series' claims audit. T2, T3, T5 and T10 belong to the caching post and are not here.
The post: [Route to many backends with CloudFront alone](https://blog.ar-logs.com/posts/cloudfront-request-routing/).

| Test | Question it settles | Claim in the post | Needs |
|---|---|---|---|
| T1a | With only the path in the cache key, do two routes on the same path share one cache entry? (the documented default key) | "Neither the viewer Host nor the chosen backend is in [the cache key]" | `/control/*` behavior |
| T1b | Does adding the routing attribute to the cache policy separate the routes? Rerun with `CACHE_KEY_ATTRIBUTE=none` to see the hazard. | "Add the Host header (or the attribute you route on) to the cache policy" | nothing |
| T1c | Which Host does the backend see when the function sets `hostHeader` and the attribute is in the cache key? Does the origin request policy reach the backend? | "Which Host the backend then sees ... is not yet confirmed by a test (T1)" | nothing |
| T4 | Is a changed KeyValueStore value live at the edge without republishing, and how many seconds does it take (from one vantage point)? | "AWS says updates reach the edge in a few seconds (not yet confirmed by a test)" | AWS CLI v2 |
| T6i | With IAM-protected origins, is a direct unsigned call to each function URL refused (403) while the routed call through CloudFront works (OAC with function-based origin selection)? | not in the post; confirms the sample's lock-down | `OriginAuth=AWS_IAM` |
| T6a, T6b | Does a routed request work (including the OAC signing) with the settings inherited from the default custom origin, including its custom header? | "settings you omit are inherited from the origin the behavior would have used" | nothing |
| T6c to T6h | Bad stored values (colon, IP address, upper case, valid domain outside the allowed suffix), unknown key and missing key: do they fail closed with no fall-through to the default origin? | "fail closed; never fall back to the default origin" | header routing |
| T7 | Does the Lambda@Edge origin request sample retarget the origin, pass TLS validation, set the Host the backend sees, and avoid fall-through? | "Whether TLS validation and the Host value work as the sample assumes is not yet confirmed (T7)" | optional edge stack |
| T8 | Can the Host value in the function event carry upper case, a port or a trailing dot (probe function)? | "Whether the real value can carry a port or a trailing dot is not yet confirmed (T8)" | `/probe/*` behavior |
| T8b | With Host routing, do those variants still route? | the normalization in the sample | alias + certificate |
| T9 | Viewer request function invocation count on cache hits | "A viewer request function also runs on cache hits" | not implemented (needs metrics) |

Each test has a stated hypothesis and expected result in the script output. PASS means the observed behavior matched the expectation
(the post's claim or the documented behavior), FAIL means it did not, INCONCLUSIVE means the test could not decide (for example a missing
prerequisite). Limits: T4 times a single vantage point, not a global measurement. A test shows behavior on the day it was run.

## Results

*Not run yet.* The deployment test results will be added here after the stack has been deployed and `verify.sh` has been run:
date, parameters, the machine-readable lines, and the conclusion for each claim.

## Development (no AWS needed)

```bash
cd cloudfront-request-routing
node --test test/*.test.mjs          # unit tests for the function code with a stub for the 'cloudfront' module
node scripts/check-function-sync.mjs # templates embed exactly function/*.js
test/verify-mock.sh                  # runs verify.sh against a local mock (tests the script, not CloudFront), including result redaction
test/teardown-test.sh                # teardown.sh guards (tag check, confirmation, env precedence) with a fake aws CLI
cfn-lint template.yaml template-lambda-edge.yaml   # pip install cfn-lint
shellcheck *.sh test/*.sh ../scripts/*.sh
```

The unit tests cover: unknown host (404), valid route, bad backend value with colon or IP (500), header normalization
(case, port, trailing dot), crafted hosts that must not reach another key, the backend suffix allow-list, and errors that must not
fall through to the default origin. The Lambda@Edge variant answers 500 if the origin is not a custom origin.
CI (`.github/workflows/ci.yml` at the repository root) runs all of the above plus a scan for account ids and keys.
