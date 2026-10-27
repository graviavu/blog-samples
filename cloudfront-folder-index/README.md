# Why a CloudFront folder URL returns 403 on a private S3 bucket

**The problem.** You build a static site. Locally `/posts/x/` opens `posts/x/index.html`. You upload it to a private S3 bucket behind
CloudFront with Origin Access Control (OAC), and the same URL returns 403. The post "Why my CloudFront site returned 403 on a folder"
explains why and fixes it with one CloudFront Function. Four statements in that post had never been run. This sample runs them and
prints PASS or FAIL for each, with the raw HTTP status and the `X-Cache` and `Age` headers.

## What it proves

| Check | Statement in the post | How it is measured |
|---|---|---|
| C1 | A folder URL such as `/posts/x/` returns 403, and S3 receives the key `posts/x/` with no `index.html` appended. | `posts/x/index.html` exists. `GET /posts/x/index.html` must give 200 (OAC works, the object is there). `GET /posts/x/` on the same distribution must give 403. If CloudFront appended `index.html` the second call would give 200. |
| C2 | An object stored under the key `posts/x/` (zero bytes, or html, `Content-Type` text/html) is served through the REST endpoint with OAC and block public access on. | Two keys that end in a slash are uploaded: `posts/y/` (zero bytes) and `posts/z/` (a small html page). Both must come back with 200 and `text/html`. The script also reads the bucket's public access block (all four switches on) and makes an anonymous request straight to S3 (must be 403). Because the folder URL is served by exactly that key, this also shows what key S3 receives. |
| C3 | A viewer-request CloudFront Function that rewrites URIs ending in `/` to `/index.html` fixes it. | The post's rewrite function (copied from the blog stack, old-domain part switched off) is attached to a second distribution. `GET /posts/x/` must give 200 with the content of `posts/x/index.html`. As extra information, `GET /posts/x` is checked for the 301 to the slash form. |
| C4 | A custom error response that maps 403 to `/404.html` with a 60 second error-caching time behaves as the post says. | A key that does not exist: the plain distribution must answer 403 (S3 without list rights answers 403 for a missing key). The fixed distribution must answer 404 with the `/404.html` page. Then the missing key is uploaded and requested again right away and at about 45 seconds after the first error: both must still be 404 with `X-Cache: Error from cloudfront` (served from the error cache). At about 75 seconds it must be 200 with the new content. All requests to this distribution go to one edge address (`curl --resolve`) and the `X-Amz-Cf-Pop` of each is recorded. This shows that the error is held for at least about 45 seconds and gone by about 75; it does not pin the TTL to exactly 60. |

If a check fails, the line says which expected value was off. A failure is a result, not a bug in the sample: send it back as it is.

## Run it

```
./run-test.sh --run
```

That is the whole thing. Without `--run` the script only prints the plan and the cost note and makes no AWS call (`./run-test.sh --dry-run`
does the same). With `--run` it asks you to type `create folder test stack`, then creates one CloudFormation stack, runs the checks
and deletes the stack again. It takes 15 to 25 minutes, almost all of it CloudFront deploying and deleting two distributions.

Needs the AWS CLI v2, `jq`, `curl` and bash. It uses region us-east-1 and whatever profile your shell already uses. To refuse the wrong
account, set `EXPECT_ACCOUNT_LAST4` to the last four digits of the account you mean.

## What to send back

The file `results-<run id>.md` that the script writes in the folder of the script (git ignores `results-*.md`). Read it first: account ids, ARNs, distribution domains and
the bucket name are replaced by placeholders, but the redaction is best effort. It holds the PASS or FAIL table, every request with
status, `X-Cache`, `Age`, `X-Amz-Cf-Pop`, `Content-Type`, `Content-Length` and `Location`, and the teardown result.

## What it creates

One stack named `cfi-<run id>`, every resource named with the run id, tagged `RunId` and `Purpose=sample`:

- an S3 bucket: private, block public access on, encrypted, TLS-only, and only `s3:GetObject` granted to CloudFront (no list right, which
  is why a missing key is a 403);
- one origin access control;
- one CloudFront Function with the post's rewrite logic;
- distribution "plain": S3 REST origin with OAC, no function, no error response;
- distribution "fixed": same origin, the function on viewer-request, and the 403 to `/404.html` (status 404, error caching 60 seconds).

Both distributions use the managed caching-optimized cache policy and price class 100 (US, Canada, Europe). The plain one is what C1 and C2
need (nothing between the viewer and the bucket); the fixed one is what C3 and C4 need.

## Cost

Pennies. A few dozen requests, a few kilobytes in S3, CloudFront and CloudFront Functions inside their free monthly tiers. Nothing is left
running at the end.

## Teardown and leftovers

The script deletes everything at the end, also after an error or Ctrl-C (an exit trap). While the teardown runs, Ctrl-C and kill signals are ignored (the script says so once); wait for it. It empties the bucket, then deletes the stack, and
it refuses to touch a stack unless it carries the tags `RunId` (this run) and `Purpose=sample` and its bucket has this run's name. If a
teardown could not finish, the screen and the results file say so and give the command:

```
./run-test.sh --cleanup <run id>
```

It asks you to type `delete folder test stack`. `--cleanup <run id> --dry-run` only prints what it would do and makes no AWS call.

## Tests of the script itself

No AWS, no network: `tests/run.sh` runs `run-test.sh` against a fake `aws`, `curl`, `sleep` and `date` (folder `tests/bin`). It covers the
dry run, the typed phrase, the account check, a full run with four PASS, each claim failing on its own (and the clean-up that follows),
a slow start of the distributions, a failing create, a failing upload, Ctrl-C, a stuck delete, a create that ends in ROLLBACK_COMPLETE, a first delete that ends in DELETE_FAILED, a stack that never leaves its in-progress state, a bucket listing that fails, a stack name that already exists, `--cleanup` (also for a stack that
belongs to another run), and that screen output and the results file contain no account id, ARN, key or CloudFront domain.
`tests/function.test.mjs` extracts the function code from the template and runs it with node against sample events.

```
tests/run.sh
```

CI also runs cfn-lint on the template, shellcheck on the scripts and the secret scan.

## What the tests cannot tell you

The stubs mimic what the post says CloudFront and S3 do. They cannot show that CloudFront really behaves that way. That is what the run is for.
Known limits of the real run:

- C4 reads the error-caching behaviour at one edge address, pinned with `curl --resolve`. If a request still lands on another edge
  location (the `X-Amz-Cf-Pop` differs, or a probe inside the window comes back 200), the script says so in a note and C4 fails; a
  rerun is then the right step.
- The old-domain redirect, certificates and flat-rate plan quotas from the post are not covered.
- The CloudFront Function is not run by CloudFront in the unit test, only by node.

## Files

- `run-test.sh`: the one script (plan, create, test, results, teardown, cleanup mode)
- `cfn/stack.yaml`: the CloudFormation template
- `tests/`: stub tests and the function test
