# No cache in business hours, long cache outside, with one Lambda@Edge function

**The problem.** Your content changes during the working day and you want visitors to see it at once, but at night and at
weekends nobody edits anything and you would rather serve from the cache for hours. Different parts of a site have different
hours (prices are edited 08:00-17:00, rates 10:00-11:00). CloudFront has no schedule for TTLs. This sample sets the cache
lifetime per response from the time of day and the request path: a Lambda@Edge origin-response function reads one small JSON
object from S3 with a window per path pattern, finds the rule for the request, and sets
`Cache-Control: public, max-age=0, s-maxage=<ttl>`. Inside the rule's window `inTtl` applies (0 = CloudFront does not cache).
Outside it, `outTtl` (4 hours here) applies **but never longer than the time until the window opens next**, so an object cached
shortly before the opening expires at the opening. Changing a window is a one-object S3 upload, not a deploy.

`run-test.sh` builds a temporary stack, **measures** whether this really behaves that way (Hit/Miss, Age, how often the origin is
reached, what the viewer sees, two paths with different windows at the same moment, an object that must expire at the opening)
and deletes the stack again.

## The config object

```json
{
  "rules": [
    {"path": "/prices/*", "startMin": 480, "endMin": 1020, "inTtl": 0, "outTtl": 14400},
    {"path": "/rates/*",  "startMin": 600, "endMin": 660,  "inTtl": 0, "outTtl": 14400},
    {"path": "/rates/archive/*", "startMin": 0, "endMin": 1, "inTtl": 0, "outTtl": 86400}
  ],
  "default": {"startMin": 0, "endMin": 1440, "inTtl": 0, "outTtl": 0}
}
```

- `startMin`, `endMin`: minutes since 00:00 UTC, `0 <= startMin < endMin <= 1440`, `startMin` inclusive, `endMin` exclusive. One window per rule, same UTC day.
- `inTtl`, `outTtl`: integer seconds, `0` to `86400`. **86400 is the cache policy's MaxTTL** (CloudFront would cut a longer TTL down to it), so a rule with a larger value is treated as malformed and skipped. Keep the config object under 256 KB and 1000 rules, or it is refused as a whole (`s-maxage=0`, the log says only "config too large"). A UTF-8 byte order mark at the start is ignored.
- `path`: an exact path (`/prices/gold`) or a prefix ending in `*` (`/prices/*`, which matches `/prices/` and everything below it, not `/prices`; `/*` matches everything). A `*` anywhere else is a malformed rule.
- **Matching** uses the request URI of the origin-response event (`event.Records[0].cf.request.uri`) with the query string stripped, **case-sensitive**, not URL-decoded. An **exact** path beats any prefix; among prefixes the **longest** wins; of identical patterns the first in the file wins. The order of the rules otherwise does not matter.
- `default` is optional. **No matching rule and no default: `s-maxage=0`** (fail safe). **Every request that matches no rule gets `default`**, including look-alikes such as `/Prices/a` (case) or `/prices` (no slash; it does not match `/prices/*`), so make `default` the **most restrictive window** (as above: all day, never cached) or leave it out. An empty URI matches no rule.
- **URI variants are never cached.** The function does not decode or normalise paths. A request whose URI contains `//`, `/./`, `/../`, ends in `/.` or `/..`, or contains `%` (for example `//prices/a`, `/x/../prices/a`, `/%70rices/a`, `/prices%2fa`) could be the same page as a rule's path, so it gets **no window at all, not even `default`: `s-maxage=0`**. Everything else is matched raw and case-sensitive. Whether CloudFront already normalises such a URI before the function sees it is not documented here: T-F records what the viewer and the origin see.
- **Malformed rules are skipped** (bad window, bad numbers, bad pattern, not an object); the others keep working. The log line names only the rule's index, never its content. A malformed `default` is skipped the same way. A config that is not JSON, or whose `rules` is not an array, is unusable: `s-maxage=0` for everything.
- The whole parsed config is cached in memory for 30 seconds (not per-path results). The time-dependent part (in the window, seconds until the next opening) is computed on every invocation from the current time, per matched rule.

## What is in this folder

| Path | What |
|---|---|
| `cfn/stack.yaml` | **The CloudFormation template** (YAML, commented). Everything the test needs, in us-east-1. See "The template" below. |
| `edge/index.mjs` | The Lambda@Edge function (Node.js, ES module). The config bucket and key are baked in when `run-test.sh` zips it (Lambda@Edge has no environment variables). |
| `origin/index.js` | Test origin: returns `{now, counter, nonce, path}` and no `Cache-Control`; `/err...` answers 500. CommonJS, because it is pasted inline into the template (a test checks the copy is identical). |
| `run-test.sh`, `lib.sh` | The one script you run: uploads the code, deploys the template, runs the tests, deletes the stack. |
| `tests/run.sh` | Tests of the script against a fake `aws`, `curl`, `date`, `sleep` and `zip` (no AWS, no network); also checks the template. |
| `tests/edge.test.mjs` | Unit tests of the function logic (`node --test`). |

## The template (`cfn/stack.yaml`)

One stack, `bhc-<RunId>`, **in us-east-1** (Lambda@Edge functions can only be created there). Parameters: `RunId`, `ConfigBucketName`, `ConfigKey`, `CodeBucket`, `CodeKey`, `OriginReservedConcurrency` (default 0 = none).

| Resource | What and why |
|---|---|
| `ConfigBucket` (S3) | Holds the window JSON. Public access block, SSE-S3 encryption, no bucket policy. Its name is a parameter because the edge code has it baked in. |
| `EdgeRole`, `OriginRole` (IAM) | Edge role: trusts `lambda` and `edgelambda`, reads the one config object, may list that bucket (so a missing key answers `NoSuchKey`, not `AccessDenied`), writes logs of this run's log groups. Origin role: logs only. Explicit names (`bhc-<RunId>-erole`, `-orole`), so the stack needs `CAPABILITY_NAMED_IAM`. |
| `OriginFunction` (Lambda) + `OriginUrl` + two `Permission`s | The test origin, code inline, behind a **public** function URL (auth `NONE`) for the test only. |
| `EdgeFunction` (Lambda) + `EdgeVersion` | The Lambda@Edge function and the published version CloudFront needs. The code is a zip in S3: it is about 10 KB, and inline code is limited to 4096 characters and cannot use the S3 client. |
| `CachePolicy` | Min TTL 0, default 0, max 86400; no query strings, headers or cookies in the cache key. |
| `Distribution` (CloudFront) | Origin = the function URL, the edge function on origin-response, a 500 is not cached (`ErrorCachingMinTTL: 0`), `PriceClass_100`. |

Why the script uploads the zip first: the stack needs the code to exist when it is created, so `run-test.sh` creates a small artifact bucket `bhc-<RunId>-art` (tagged, private), puts `edge.zip` in it (with `__CONFIG_BUCKET__` and `__CONFIG_KEY__` replaced), and passes it as `CodeBucket`/`CodeKey`. The window JSON is not in the template: the script uploads it after the stack exists, because the tests rewrite it between steps.

### Use the template by itself

```
# 1. zip edge/index.mjs after replacing __CONFIG_BUCKET__ and __CONFIG_KEY__, put the zip in a bucket you own in us-east-1
# 2. deploy (us-east-1):
aws cloudformation create-stack --region us-east-1 --stack-name bhc-<RunId> --template-body file://cfn/stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=RunId,ParameterValue=<RunId> ParameterKey=ConfigBucketName,ParameterValue=<new bucket name> \
               ParameterKey=CodeBucket,ParameterValue=<your code bucket> ParameterKey=CodeKey,ParameterValue=edge.zip
# 3. upload your window JSON to s3://<ConfigBucketName>/window.json
```

`<RunId>` must look like `2610101200-ab12`. For real use change the origin to your own (and put a Function URL origin behind origin access control with `AuthType AWS_IAM`, not `NONE`). To delete: empty the config bucket, then `delete-stack`. If `delete-stack` ends in `DELETE_FAILED` on `EdgeVersion`/`EdgeFunction`, AWS is still holding the Lambda@Edge replicas; try again some hours later, or delete with `--retain-resources EdgeVersion EdgeFunction EdgeRole` and remove those by hand later.

## Function rules

- Seconds since 00:00 UTC `t` (milliseconds included). `startMin*60 <= t < endMin*60` is in the window (start inclusive, end exclusive): `inTtl` applies.
- Outside the window the TTL is `min(outTtl, seconds until the next opening)`, floored, never below 0. The next opening is today's `startMin` if it is still ahead, otherwise tomorrow's (`86400 - t + startMin*60`). One second before the opening the object gets `s-maxage=1`, in the last half second `0`.
- **Clock skew.** The Lambda clock and the CloudFront edge clock can differ by a few seconds, and CloudFront counts the TTL from when it receives the response. Remaining time is floored, so an object may expire a few seconds early, by design not late. `Age` and the TTL are whole seconds.
- One fixed daily window per rule, `startMin < endMin`, same UTC day. A window across midnight is rejected as invalid (see Limitations).
- Only responses with status 200, 203, 204 and 206 are rewritten. Errors (400 and above), redirects and 304 are left exactly as the origin sent them.
- A response is also left untouched when the origin sends `Cache-Control` with `private`, `no-store` or `no-cache`, or sets a cookie (`Set-Cookie`). The origin knows better than a clock, and a shared cache must not keep per-user content. (The cache policy also keeps cookies out of the cache key, so this guard matters if you reuse the function elsewhere.)
- Config is kept in memory for 30 seconds. If S3 cannot be read, or the JSON is unusable, the function sets `public, max-age=0, s-maxage=0`: never a long TTL, and it does not fall back to an older config either. A failure is remembered for 5 seconds so an S3 outage does not mean one S3 call per request.
- The log line on failure holds the error name only. No config, bucket name or error message is logged.

## Safety, read first

- It creates real resources in your account and **costs cents** (estimate: well under 0.10 USD; a few hundred CloudFront requests, a few hundred Lambda and Lambda@Edge invocations, a handful of S3 requests and CloudFormation calls, and a distribution that lives about 30-40 minutes; CloudFormation itself is free for these resource types). Use a throwaway or test account.
- **Everything the test needs is ONE CloudFormation stack in us-east-1** (see "The template"). A real CloudFormation deploy of this template has not been run by the author yet: the first run is also the first test of the template (cfn-lint is clean, and the template was validated by the tests' stub only).
- **The origin function URL is public (auth `NONE`) for the test only, while the stack exists.** It returns a timestamp and a counter and nothing else, but anyone who finds the URL can invoke it. After the stack is up the script tries to set a small reserved concurrency (5) on the origin function as a best-effort cap (if your account cannot reserve concurrency the script says so and carries on; in the template it is the parameter `OriginReservedConcurrency`). **For real use put the function URL behind CloudFront origin access control with `AuthType AWS_IAM`** and do not use `NONE`.
- **Confirm you are in the right account.** Before you type the phrase the script shows `AWS_PROFILE`, the region and the **last 4 digits** of the account id (on screen only: never in the results file, the state file or a log). Set `EXPECT_ACCOUNT_LAST4=1234` (4 digits) and the script refuses to start, and refuses `--cleanup`, in any other account.
- **Teardown only touches this run.** Every name is derived from the run id (`bhc-<id>`, `bhc-<id>-cfg`, `-art`, ...) and before deleting the stack or a bucket the script reads its `RunId` tag and refuses on a mismatch. The stack and the resources in it are deleted by CloudFormation (it disables and deletes the distribution itself); the script empties the config bucket first and deletes the artifact bucket and the log groups afterwards. It runs last, also after an error, Ctrl-C or SIGTERM. If you interrupt while the stack is still being created, the teardown waits for the creation to settle (CloudFront needs several minutes) before it deletes.
- **Lambda@Edge replicas.** AWS releases the Lambda@Edge function replicas some hours after the distribution is gone, so deleting the function can fail and the stack ends in `DELETE_FAILED` on `EdgeVersion`/`EdgeFunction`. The script says so, retries with `--retain-resources EdgeVersion EdgeFunction EdgeRole` (those three only, and only when they are the only ones that failed; any other failure leaves the stack as it is and is reported), then tries to delete the function and role directly. If AWS still holds the replicas, the script exits with code 4 and tells you to run `./run-test.sh --cleanup <run id>` later (it asks for the phrase `delete cloudfront test stack`). This retain-and-retry path has not been exercised against real CloudFormation.
- **State file.** `state-<run id>.env` (run id and two flags, no names of resources) is written in `RESULTS_DIR`, which defaults to the **current directory**. `--cleanup` does not need it: every name is derived from the run id (the file only records that the artifact bucket was created by this run, which lets an untagged bucket of exactly that name be deleted). Results and state files are git-ignored.
- **Log groups.** Teardown deletes the origin log group and the edge function's log groups (`/aws/lambda/us-east-1.<function>`, which exist in the regions that served your requests; it looks in every region `ec2:DescribeRegions` returns, and only deletes a group whose name is exactly this run's). Log groups carry no tag, so the name is the check. What can remain: edge log groups while the edge function is still held by AWS (`--cleanup` removes them later), a log group written after the delete, or any group whose delete or lookup was refused (the script lists those). A few cents of stored logs at most.
- Output on screen and in the results file is redacted (account ids, ARNs, access key ids, `*.cloudfront.net` and function URL hosts, distribution id, bucket and function names of the run, request ids, long token-like strings). It is best effort: read the results file before you share it.
- Nothing is stored or printed that is a credential. The script uses whatever AWS CLI v2 credentials your shell already has.
- The window tests need room around "now" inside one UTC day (up to 60 minutes either side). A real run refuses to start between 22:00 and 01:30 UTC.
- Region `us-east-1` only (Lambda@Edge requirement). Needs: AWS CLI v2, `jq`, `curl`, `zip`, bash 3.2 or newer. Nothing else is installed.
- Permissions: CloudFormation, S3, IAM role, Lambda, CloudFront and cache policy resources, and (the first time in an account) the service-linked roles CloudFront and Lambda@Edge use. Run it as an admin of a test account, or see the policy example below.

## How to run

```
./run-test.sh --dry-run     # prints the plan and runs cloudformation validate-template. Only read-only calls (sts get-caller-identity, validate-template).
./run-test.sh               # asks you to type: create cloudfront test stack
```

The run takes roughly 15-25 minutes: CloudFormation needs 5-15 minutes to create the stack (CloudFront deploys the distribution), the tests need about 8 minutes of
waiting (the function keeps its config in memory for up to 30 seconds, so every window change is followed by a 40 second pause, and T-C waits for a window to open), and deleting the stack waits again for CloudFront.

Exit codes, in this order of precedence: **4** the teardown is incomplete (always wins, whatever happened before, so leftovers are never hidden); otherwise 130/143 interrupted by Ctrl-C or SIGTERM (teardown still runs); 2 refused to start (usage, missing tool, wrong account, bad time of day); 1 at least one FAIL; 3 no FAIL but something INCONCLUSIVE; 0 all PASS.

You get a table on screen and `results-<UTC date>.md` in the current directory, ready to read before you paste any of it into a post.

## What each result means

Every test uses its own URL path, so an earlier test cannot leave a cached object behind. The origin puts a unique `nonce` in every response: a repeated nonce means CloudFront answered from its cache, a new one means the origin was reached. The origin counter is reported too.

| Test | What it does | PASS means |
|---|---|---|
| T-A | One config for T-A, T-B and T-D: `/prices/*` has now inside its window (now-5 .. now+30 min), `/rates/*` and `/err*` are outside theirs (now-60 .. now-30 min). 5 requests to `/prices/a`, one second apart, then one to `/rates/a`. | Never a Hit on `/prices/a` (if the side request to `/rates/a` gets no answer the result is INCONCLUSIVE, not FAIL); five different nonces; the origin counter went up by one each time; the viewer sees `Cache-Control: public, max-age=0, s-maxage=0`, exactly what the function set. At the same moment `/rates/a` (outside its window) gets `s-maxage=14400`: two paths, two windows, one clock. |
| T-B | Same config. 5 requests to `/rates/b`, 3 seconds apart. | First request Miss, the next four Hit; same nonce and flat origin counter; `Age` grows; the viewer sees `s-maxage=14400` (the next opening is far away, so the cap does not bite). One stray Miss among the Hits while the origin was not reached again (same nonce, flat counter) is reported INCONCLUSIVE, not FAIL: a POP with several cache servers can answer from another layer. |
| T-D | Same config (`/err*` is outside its window, so a normal response would get 14400). The origin answers 500 on `/err`. 3 requests. | HTTP 500 each time, never a Hit, a new nonce each time, and no `s-maxage=14400` in the header: errors are not rewritten and not cached for `outTtl`. (The distribution sets the 500 error caching minimum TTL to 0, otherwise CloudFront would hold the error for 10 seconds on its own.) |
| T-F | Same config as T-A (its `default` is the never-cache window). During the `/prices/*` window, `//prices/a`, `/Prices/a` and `/%70rices/a` are requested twice each (raw, `curl --path-as-is`). | No Hit and no positive `s-maxage` for any of them. The results file records for each variant the Cache-Control, X-Cache and the path the origin saw, so the real run also shows what CloudFront forwards for such a URI. |
| T-E | Two cases on `/rates/e` and `/rates/e2` (3 requests each): **E1** the config object is deleted from S3 (a missing key, `NoSuchKey`); **E2** the object is replaced by text that is not JSON. | In both cases Cache-Control is `s-maxage=0` on all requests and no Hit, although a working config would have given 14400: the fail-safe fallback works. |
| T-C | A `/c/*` rule that opens about 80-140 seconds after the first request (the start minute is fixed before the 40 second settle, so the lead time varies). `/c/old` is requested (Miss; `s-maxage` must be a small number, at most the time left until the opening, not 14400), then again (Hit). 10 seconds before the opening it is requested again; 5 seconds after the opening again; `/c/new` is requested twice after the opening. | The cap works: the object cached before the opening is **gone 5 seconds after the opening** (Miss, new nonce, `s-maxage=0`), the Age 10 seconds before the opening was a Hit with an Age not above its TTL (INCONCLUSIVE if it is not measurable, FAIL if above), and the new object `/c/new` is not cached. If it is still a Hit after the opening, that is a FAIL and the report says how many seconds late. |

`PASS` = measured as expected. `FAIL` = measured something else. `INCONCLUSIVE` = the test could not run cleanly (no answer, too close to midnight, too little time before the opening in T-C), so it says nothing either way. T-C allows 5 seconds of clock skew between your machine and the Lambda clock when it checks the cap, and it checks 5 seconds after the opening, not at the exact second: expiry is whole seconds and the edge clocks differ.

The tests prove the behavior of `s-maxage` plus Lambda@Edge with a Function URL origin and this cache policy. They do not measure how long CloudFront needs to pick up a changed window across all edge locations, and the edge location your requests reach is not necessarily the one a visitor elsewhere reaches.

## Running it as a person with limited rights (starting point, not tested)

The simplest way is an admin of a test account. If you want less, this is the shape of the policy; adjust and test it in your account, it has not been verified against the real services. CloudFormation acts with YOUR permissions (the script passes no service role), so the person who runs it needs the permissions for the resources in the stack as well as for CloudFormation itself. Replace `ACCOUNT` with your test account id.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["sts:GetCallerIdentity", "ec2:DescribeRegions", "cloudformation:ValidateTemplate"], "Resource": "*"},
    {"Effect": "Allow",
     "Action": ["cloudformation:CreateStack", "cloudformation:DeleteStack", "cloudformation:DescribeStacks", "cloudformation:DescribeStackResources",
                "cloudformation:DescribeStackEvents", "cloudformation:GetTemplate", "cloudformation:TagResource"],
     "Resource": "arn:aws:cloudformation:us-east-1:ACCOUNT:stack/bhc-*/*"},
    {"Effect": "Allow", "Action": "s3:*", "Resource": ["arn:aws:s3:::bhc-*", "arn:aws:s3:::bhc-*/*"]},
    {"Effect": "Allow",
     "Action": ["iam:CreateRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:ListRoleTags", "iam:GetRole"],
     "Resource": "arn:aws:iam::ACCOUNT:role/bhc-*"},
    {"Effect": "Allow", "Action": "iam:PassRole", "Resource": "arn:aws:iam::ACCOUNT:role/bhc-*",
     "Condition": {"StringEquals": {"iam:PassedToService": "lambda.amazonaws.com"}}},
    {"Effect": "Allow",
     "Action": ["lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction", "lambda:TagResource", "lambda:PublishVersion",
                "lambda:PutFunctionConcurrency", "lambda:ListTags", "lambda:GetFunctionConfiguration", "lambda:CreateFunctionUrlConfig", "lambda:DeleteFunctionUrlConfig", "lambda:GetFunctionUrlConfig",
                "lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy",
                "lambda:EnableReplication*", "lambda:DisableReplication*"],
     "Resource": "arn:aws:lambda:*:ACCOUNT:function:bhc-*"},
    {"Effect": "Allow", "Action": "iam:CreateServiceLinkedRole", "Resource": "*",
     "Condition": {"StringEquals": {"iam:AWSServiceName": ["replicator.lambda.amazonaws.com", "logger.cloudfront.amazonaws.com"]}}},
    {"Effect": "Allow",
     "Action": ["cloudfront:CreateDistributionWithTags", "cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution",
                "cloudfront:DeleteDistribution", "cloudfront:ListDistributions", "cloudfront:TagResource", "cloudfront:ListTagsForResource",
                "cloudfront:CreateCachePolicy", "cloudfront:GetCachePolicy", "cloudfront:DeleteCachePolicy", "cloudfront:ListCachePolicies"],
     "Resource": "*"},
    {"Effect": "Allow", "Action": "logs:DescribeLogGroups", "Resource": "*"},
    {"Effect": "Allow", "Action": "logs:DeleteLogGroup", "Resource": "arn:aws:logs:*:ACCOUNT:log-group:/aws/lambda/*bhc-*"}
  ]
}
```

`cloudformation:ValidateTemplate` cannot be limited by resource. `lambda:EnableReplication*` is what lets CloudFront replicate the edge function; `iam:CreateServiceLinkedRole` is needed the first time in an account (Lambda replication and CloudFront logging). `iam:PassRole` is limited to Lambda and to roles named `bhc-*`. CloudFront actions mostly cannot be limited by resource, which is one more reason to use a test account.

## Cache policy

Custom: min TTL 0, default TTL 0, max TTL 86400 (above `outTtl`), no query strings, headers or cookies in the cache key. Min TTL 0 is what allows `s-maxage=0` to mean "do not cache". Default TTL 0 means a response without a `Cache-Control` header is not cached either.

## Limitations

- **UTC only.** The window is minutes since 00:00 UTC. There is no time zone and no daylight saving handling; a business-hours window in a local zone moves by an hour twice a year, in UTC terms. Change the JSON when the clocks change.
- **One window per rule, per day.** `startMin < endMin` in the same UTC day. No overnight window, no weekends, no holidays (day-of-week and date rules would be a change to the config and `ttlSecondsFor`, not to the architecture).
- **Boundary expiry is capped, not exact.** An object cached before the opening gets `s-maxage` = the time left until the opening, so it expires at the opening, give or take a few seconds of clock skew (it can expire early, not late by design). The *other* boundary needs nothing: inside the window nothing is cached. An object cached before you *change* the config keeps the TTL it was given; the new window applies to objects fetched after the change (and only after each edge's 30 second config cache).
- **Path rules match the URI as CloudFront gives it:** no URL decoding, no normalisation, case-sensitive. `/Prices/x` and `/prices/x` are different paths; a URI with `%` is never cached (see the config section), and unmatched look-alikes get `default`. T-F in the report shows the real behaviour.
- **The config is read per edge cache region, at most every 30 seconds** (5 seconds after a failure). A changed window is not live at every location at the same instant.
- Only responses that reach the origin are rewritten (origin-response runs on a cache miss). Objects already cached with another `Cache-Control` keep it until they expire.
- The function sets only `Cache-Control`. Other headers from the origin, including an `Expires` header, are left alone; remove them at the origin.
- The test origin counter is per Lambda execution environment. If the environment restarts mid-test the counter restarts; the verdicts use the nonce and mark such a run INCONCLUSIVE rather than guess.

## Tests

(`RT_RUNID` is a test hook that fixes the run id for the stub tests. It must still look like `2610101200-ab12`; leave it unset for a real run.)

```
tests/run.sh                  # shell tests (fake aws/curl/date/sleep/zip) + node unit tests + shellcheck when available
node --test tests/*.test.mjs  # only the edge function logic
```

`tests/run.sh` covers (see the file for the full list): `--dry-run` makes only read-only calls (identity, `validate-template`); the typed phrase is exact and case sensitive; a full run where everything passes, with ONE `create-stack` call and no hand-rolled resource creation; the stack parameters; a CDN that ignores the function or the cap (T-A, T-C, T-D, T-E, T-F FAIL), no answer at all (INCONCLUSIVE); teardown after an injected failure at the first change, the zip upload, `create-stack` and a stack that does not reach `CREATE_COMPLETE`; teardown on SIGINT and SIGTERM, before the stack exists, during `create-stack` and while waiting for it (the teardown messages must still reach the screen even when the signal arrives during a command whose output goes to `/dev/null`); never touching another run's stack or buckets, or one whose tag differs (and a "does not exist" message about another stack is not "already gone"); the untagged-artifact-bucket case; an existing bucket with a planned name stopping the run; a stack that fails to delete for another reason (reported, not retried); the Lambda@Edge replica case (retain, delete the leftovers, `--cleanup` with and without a state file, a second `--cleanup`); redaction of account ids, ARNs, access keys, hosts, tokens and the distribution id; the account guard; the run id format; leftover log groups; T-B stray Miss, T-E both cases, T-F; and a check that the template is consistent with the README (resource types, inline origin code identical to `origin/index.js` and under 4096 characters, no bucket policy, cache policy numbers) plus `cfn-lint` when it is installed.

`tests/edge.test.mjs` covers: URI variants (`//`, `/./`, `/../`, `%`, trailing dot segments) never cached even with a default, case and no-slash look-alikes getting the default, the 256 KB and 1000 rule limits, the byte order mark, TTLs over 86400 skipped, path rules (longest prefix, exact beats prefix, case sensitivity, query string stripped, no match with and without a default, malformed rules skipped with only the index logged, the whole config cached once for several paths), the seconds-until-opening cap (1 s before the opening, exactly at `startMin`, last second before `endMin`, after the close to tomorrow's opening, midnight wrap, milliseconds floored, never negative or NaN, computed per request), inside, outside, `startMin` inclusive and `endMin` exclusive, 00:00 and 23:59, only 200/203/204/206 rewritten (4xx/5xx, redirects and 304 untouched), origin `private`/`no-store`/`no-cache` and `Set-Cookie` left untouched, S3 failure, bad JSON and out-of-range values, config memory cache of 30 seconds, no stale config after expiry, and that the error message is not logged. The fake `aws` and `curl` model CloudFront and S3 closely enough to exercise the script's logic; **they are not a proof of what real CloudFront does**. That is what the real run is for.
