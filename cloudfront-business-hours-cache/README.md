# No cache in business hours, long cache outside, with one Lambda@Edge function

**The problem.** Your content changes during the working day and you want visitors to see it at once, but at night and at
weekends nobody edits anything and you would rather serve from the cache for hours. CloudFront has no schedule for TTLs.
This sample sets the cache lifetime per response from the time of day: a Lambda@Edge origin-response function reads one
small JSON object from S3 (`{"startMin":780,"endMin":1080,"inTtl":0,"outTtl":14400}`), compares the current UTC minute with the
window, and sets `Cache-Control: public, max-age=0, s-maxage=<ttl>`. Inside the window `inTtl` is 0, so CloudFront does not
cache. Outside it, `outTtl` (4 hours here) applies. Changing the window is a one-object S3 upload, not a deploy.

`run-test.sh` builds a temporary stack, **measures** whether this really behaves that way (Hit/Miss, Age, how often the origin is
reached, what the viewer sees) and deletes the stack again. It also measures the one thing that does not work the way people
hope: an object cached before the window opens stays cached after it opens (T-C below).

## What is in this folder

| Path | What |
|---|---|
| `edge/index.mjs` | The Lambda@Edge function (Node.js, ES module). Bucket and key are baked in at packaging time (Lambda@Edge has no environment variables). |
| `origin/index.mjs` | Test origin: a Lambda function URL that returns `{now, counter, nonce, path}` and sends no `Cache-Control`. `/err...` answers 500. |
| `run-test.sh`, `lib.sh` | The one script you run, and its helpers. |
| `tests/run.sh` | Tests of the script against a fake `aws`, `curl`, `date`, `sleep` and `zip` (no AWS, no network). |
| `tests/edge.test.mjs` | Unit tests of the function logic (`node --test`). |

## Function rules

- Minutes since 00:00 UTC `m`. `startMin <= m < endMin` is in the window (`startMin` inclusive, `endMin` exclusive). `inTtl` applies inside, `outTtl` outside.
- One fixed daily window, `startMin < endMin`, same UTC day. A window across midnight is rejected as invalid config (see Limitations).
- Only responses with status 200, 203, 204 and 206 are rewritten. Errors (400 and above), redirects and 304 are left exactly as the origin sent them.
- A response is also left untouched when the origin sends `Cache-Control` with `private`, `no-store` or `no-cache`, or sets a cookie (`Set-Cookie`). The origin knows better than a clock, and a shared cache must not keep per-user content. (The cache policy also keeps cookies out of the cache key, so this guard matters if you reuse the function elsewhere.)
- Config is kept in memory for 30 seconds. If S3 cannot be read, or the JSON is bad or out of range, the function sets `public, max-age=0, s-maxage=0`: never a long TTL, and it does not fall back to an older config either. A failure is remembered for 5 seconds so an S3 outage does not mean one S3 call per request.
- The log line on failure holds the error name only. No config, bucket name or error message is logged.

## Safety, read first

- It creates real resources in your account and **costs cents** (estimate: well under 0.10 USD; a few hundred CloudFront requests, a few hundred Lambda and Lambda@Edge invocations, a handful of S3 requests, and a distribution that lives about 30-40 minutes). Use a throwaway or test account.
- **The origin function URL is public (auth `NONE`) for the test only, while the stack exists.** It returns a timestamp and a counter and nothing else, but anyone who finds the URL can invoke it. The sample sets a small reserved concurrency (5) on the origin function as a best-effort cap on what that could cost; if your account cannot reserve concurrency (the unreserved pool must stay at 100) the script says so and carries on without it. **For real use put the function URL behind CloudFront origin access control with `AuthType AWS_IAM`** and do not use `NONE`. This sample leaves OAC out only to stay small.
- **Confirm you are in the right account.** Before you type the phrase the script shows `AWS_PROFILE`, the region and the **last 4 digits** of the account id (on screen only: never in the results file, the state file or a log). Set `EXPECT_ACCOUNT_LAST4=1234` (4 digits) and the script refuses to start, and refuses `--cleanup`, in any other account.
- Two IAM roles: the edge role (trusts `lambda` and `edgelambda`; reads the one S3 object, may list that bucket so a missing key answers `NoSuchKey`, and writes logs) and a separate origin role (trusts `lambda`; logs only, no S3). Log permissions cover only log groups named for this run.
- Every resource is tagged `RunId=<id>` (the cache policy cannot be tagged, so its name carries the id). **Teardown only deletes what carries this run's id**: before each delete it reads the tag and refuses on a mismatch. It is the last thing that runs, also after an error, Ctrl-C or SIGTERM.
- CloudFront needs the distribution disabled and deployed before it can be deleted, which takes several minutes. **AWS releases the Lambda@Edge function replicas some hours after the distribution is gone**, so the function (and the role it uses) may not be deletable at once. The script then says so and exits with code 4. Run `./run-test.sh --cleanup <run id>` later (it asks for the phrase `delete cloudfront test stack`).
- **State file.** The run id and what to delete are in `state-<run id>.env` (names and ids only) in `RESULTS_DIR`, which defaults to the **current directory**. Run `--cleanup` from the same directory, or set the same `RESULTS_DIR`. If the file is gone, `--cleanup` falls back to a read-only listing by the `RunId` tag (`tag:GetResources`) and then makes the same tag-checked deletes (cache policies cannot be tagged and are looked up by name). Results and state files are git-ignored.
- **Log groups.** Teardown deletes the origin log group and the edge function's log groups (`/aws/lambda/us-east-1.<function>`, which exist in the regions that served your requests; it looks in every region `ec2:DescribeRegions` returns, and only deletes a group whose name is exactly this run's). Log groups carry no tag, so the name is the check. What can remain: edge log groups while the edge function is still held by AWS (`--cleanup` removes them later), a log group written after the delete, or any group whose delete or lookup was refused (the script lists those). A few cents of stored logs at most.
- Output on screen and in the results file is redacted (account ids, ARNs, access key ids, `*.cloudfront.net` and function URL hosts, distribution id, bucket and function names of the run, request ids, long token-like strings). It is best effort: read the results file before you share it.
- Nothing is stored or printed that is a credential. The script uses whatever AWS CLI v2 credentials your shell already has.
- The window tests need room around "now" inside one UTC day (up to 60 minutes either side). A real run refuses to start between 22:00 and 01:30 UTC.
- Region `us-east-1` only (Lambda@Edge requirement). Needs: AWS CLI v2, `jq`, `curl`, `zip`, bash 3.2 or newer. Nothing else is installed.
- Permissions: it creates S3, IAM role, Lambda, CloudFront and cache policy resources and (the first time in an account) the service-linked roles CloudFront and Lambda@Edge use. Run it as an admin of a test account.

## How to run

```
./run-test.sh --dry-run     # prints the plan (names, tests, cost, time). Only sts get-caller-identity is called.
./run-test.sh               # asks you to type: create cloudfront test stack
```

The run takes roughly 15-25 minutes: CloudFront needs 5-15 minutes to deploy the new distribution, the tests need about 8 minutes of
waiting (the function keeps its config in memory for up to 30 seconds, so every window change is followed by a 40 second pause, and T-C waits for a window to open), and the teardown waits again for CloudFront.

Exit codes, in this order of precedence: **4** the teardown is incomplete (always wins, whatever happened before, so leftovers are never hidden); otherwise 130/143 interrupted by Ctrl-C or SIGTERM (teardown still runs); 2 refused to start (usage, missing tool, wrong account, bad time of day); 1 at least one FAIL; 3 no FAIL but something INCONCLUSIVE; 0 all PASS.

You get a table on screen and `results-<UTC date>.md` in the current directory, ready to read before you paste any of it into a post.

## What each result means

Every test uses its own URL path, so an earlier test cannot leave a cached object behind. The origin puts a unique `nonce` in every response: a repeated nonce means CloudFront answered from its cache, a new one means the origin was reached. The origin counter is reported too.

| Test | What it does | PASS means |
|---|---|---|
| T-A | Window set to now-5 min .. now+30 min. 5 requests, one second apart. | Never a Hit; five different nonces; the origin counter went up by one each time; the viewer sees `Cache-Control: public, max-age=0, s-maxage=0`, exactly what the function set. |
| T-B | Window moved to now-60 .. now-30 min. 5 requests, 3 seconds apart. | First request Miss, the next four Hit; same nonce and flat origin counter; `Age` grows; the viewer sees `s-maxage=14400`. One stray Miss among the Hits while the origin was not reached again (same nonce, flat counter) is reported INCONCLUSIVE, not FAIL: a POP with several cache servers can answer from another layer. |
| T-D | The origin answers 500 on `/err` (window still in the past, so a normal response would get 14400). 3 requests. | HTTP 500 each time, never a Hit, a new nonce each time, and no `s-maxage=14400` in the header: errors are not rewritten and not cached for `outTtl`. (The distribution sets the 500 error caching minimum TTL to 0, otherwise CloudFront would hold the error for 10 seconds on its own.) |
| T-E | Two cases, 3 requests each: **E1** the config object is deleted from S3 (a missing key, `NoSuchKey`); **E2** the object is replaced by text that is not JSON. | In both cases Cache-Control is `s-maxage=0` on all requests and no Hit, although the window in the past would have given 14400: the fail-safe fallback works. |
| T-C | Window set to open in about 2-3 minutes. `/c` is requested (Miss, cached for 14400 s), then again (Hit). After the window has opened, `/c` is requested again, and a new path `/c2` is requested twice. | The known boundary-expiry limitation is reproduced: `/c` is **still served from cache after the window opened** (the report states how many seconds after the opening and how long it will stay), while the new object `/c2` is not cached. |

`PASS` = measured as expected. `FAIL` = measured something else. `INCONCLUSIVE` = the test could not run cleanly (no answer, too close to midnight, the object was refreshed in T-C), so it says nothing either way. A T-C result of PASS is not a success of the design: it records honestly that the limitation exists.

The tests prove the behavior of `s-maxage` plus Lambda@Edge with a Function URL origin and this cache policy. They do not measure how long CloudFront needs to pick up a changed window across all edge locations, and the edge location your requests reach is not necessarily the one a visitor elsewhere reaches.

## Running it as a person with limited rights (starting point, not tested)

The simplest way is an admin of a test account. If you want less, this is the shape of the policy; adjust and test it in your account, it has not been verified against the real services. Replace `ACCOUNT` with your test account id.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["sts:GetCallerIdentity", "ec2:DescribeRegions", "tag:GetResources"], "Resource": "*"},
    {"Effect": "Allow", "Action": "s3:*", "Resource": ["arn:aws:s3:::bhc-*", "arn:aws:s3:::bhc-*/*"]},
    {"Effect": "Allow",
     "Action": ["iam:CreateRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:TagRole", "iam:ListRoleTags", "iam:GetRole"],
     "Resource": "arn:aws:iam::ACCOUNT:role/bhc-*"},
    {"Effect": "Allow", "Action": "iam:PassRole", "Resource": "arn:aws:iam::ACCOUNT:role/bhc-*",
     "Condition": {"StringEquals": {"iam:PassedToService": "lambda.amazonaws.com"}}},
    {"Effect": "Allow",
     "Action": ["lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction", "lambda:TagResource", "lambda:PublishVersion",
                "lambda:PutFunctionConcurrency", "lambda:ListTags", "lambda:GetFunctionConfiguration", "lambda:CreateFunctionUrlConfig", "lambda:DeleteFunctionUrlConfig", "lambda:AddPermission",
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

`lambda:EnableReplication*` is what lets CloudFront replicate the edge function; `iam:CreateServiceLinkedRole` is needed the first time in an account (Lambda replication and CloudFront logging). `iam:PassRole` is limited to Lambda and to roles named `bhc-*`. CloudFront actions mostly cannot be limited by resource, which is one more reason to use a test account.

## Cache policy

Custom: min TTL 0, default TTL 0, max TTL 86400 (above `outTtl`), no query strings, headers or cookies in the cache key. Min TTL 0 is what allows `s-maxage=0` to mean "do not cache". Default TTL 0 means a response without a `Cache-Control` header is not cached either.

## Limitations

- **UTC only.** The window is minutes since 00:00 UTC. There is no time zone and no daylight saving handling; a business-hours window in a local zone moves by an hour twice a year, in UTC terms. Change the JSON when the clocks change.
- **One window per day.** `startMin < endMin` in the same UTC day. No overnight window, no weekends, no holidays. (A second window or a day-of-week mask would be a change to the config and `cacheControlFor`, not to the architecture.)
- **Boundary expiry (T-C).** The TTL is decided when the object is fetched from the origin and is fixed for that copy. An object cached at 12:55 with a 4 hour TTL is still served at 13:05 although the window (no cache) opened at 13:00. The longer `outTtl`, the longer the gap (at most `outTtl`). Options: a shorter `outTtl`, an invalidation when the window opens, or `outTtl` capped so that it does not reach past the next opening. The function does not do the last one: it would need the time to the next opening and would make the TTL vary per request.
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

`tests/run.sh` covers (see the file for the full list; this is the shape): `--dry-run` makes no call except `sts get-caller-identity`; the typed phrase is required, exact and case sensitive; a full run where everything passes; a CDN that ignores the function (T-A FAIL), a function that rewrites errors (T-D FAIL), a function that keeps a stale config on an S3 failure (T-E FAIL), no answer at all (INCONCLUSIVE); teardown after an injected failure at the first, the middle and the last create call; teardown on SIGINT and SIGTERM, including a signal that arrives while the distribution or cache policy is being created; teardown never touches resources of another run id (and refuses a resource whose tag differs); `--cleanup` after a Lambda@Edge replica error; redaction of account ids, ARNs, access keys, hosts, tokens and the distribution id on screen and in the results file; the baked-in bucket in the packaged edge code; windows and midnight guard; the leftover-bucket case (created but never tagged), error-code based not-found, failed lookups keeping the state file, exit code 4 winning over 130, the account guard, reserved concurrency failing without aborting, the two roles and their policies, log group cleanup with look-alike names left alone, the T-B stray Miss, T-E with a missing key and with bad JSON, `--cleanup` without a state file, and an existing bucket of the same name stopping the run.

`tests/edge.test.mjs` covers: inside, outside, `startMin` inclusive and `endMin` exclusive, 00:00 and 23:59, only 200/203/204/206 rewritten (4xx/5xx, redirects and 304 untouched), origin `private`/`no-store`/`no-cache` and `Set-Cookie` left untouched, S3 failure, bad JSON and out-of-range values, config memory cache of 30 seconds, no stale config after expiry, and that the error message is not logged. The fake `aws` and `curl` model CloudFront and S3 closely enough to exercise the script's logic; **they are not a proof of what real CloudFront does**. That is what the real run is for.
