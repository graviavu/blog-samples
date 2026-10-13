# A short cache window and a long cache outside it, with one CloudFront Function

**The problem.** Your content changes during the working day and you want visitors to see changes within a minute, but at night nobody
edits anything and you would rather serve from the cache for hours. The origin is S3 and it sends no `Cache-Control` or `Expires`, and
you cannot change that. CloudFront has no schedule for TTLs, and a cache policy has one TTL for the whole behavior.

This sample uses the one thing a CloudFront Function can change on a request: the cache key. A viewer-request function runs on every
request. Inside a daily UTC window it sets a header `x-cache-bust` to the current time bucket (the epoch divided by `BucketSeconds`,
60 by default). The cache policy has that header in the cache key and a long default TTL (24 hours). Inside the window the key changes
every minute, so an object is fetched from S3 at most once a minute per edge cache; the cache lifetime inside the window is the bucket
length, always more than zero. Outside the window the function sets nothing, the key is the plain one, and the object stays cached for
the long TTL. A function is much cheaper than Lambda@Edge ($0.10 per million invocations, price list read 2026-10-10), and everything
is one distribution with no change at the origin.

`run-sample.sh` builds a temporary stack, **measures** this with curl (Miss/Hit, Age, content after an overwrite) while the window
contains the current hour, moves the window away and back with a stack update, and deletes the stack again.

## What you get, in one picture

```
viewer --> CloudFront --[viewer-request function]--> cache lookup (key = path + x-cache-bust) --> S3 (OAC, private bucket)
                              |
              in window:      sets x-cache-bust = floor(now / BucketSeconds)    -> new key every bucket
              outside:        deletes any x-cache-bust the viewer sent, sets nothing -> one key, cached LongTtl seconds
              always:         a viewer-supplied x-cache-bust is deleted first, so a client cannot pick its own key
```

## Files

| Path | What |
|---|---|
| `cfn/stack.yaml` | **The CloudFormation template.** Bucket, bucket policy, origin access control, the function (code inline via `!Sub`), cache policy, distribution. |
| `function/time-bucket.js` | The same function code as in the template, with the three `${...}` placeholders. A test checks the two are identical. |
| `run-sample.sh` | The one script you run: deploys, tests, writes `results-<runid>.md`, deletes. Has `--dry-run` and `--cleanup RUNID`. |
| `tests/run.sh` | Stub tests of the script (fake `aws`, `curl`, `date`, `sleep`), the node unit tests, cfn-lint and shellcheck when installed, mutation checks. |
| `tests/function.test.mjs` | Unit tests of the function and of the template text (node, no dependencies). |
| `tests/bin/` | The fakes. `fake-cloudfront.mjs` is a small cache simulation that runs the real function code from the template. |

## Run it (one command)

Needs aws CLI v2, jq, curl, bash, in a throwaway account with rights to create CloudFront distributions, CloudFront functions, S3 buckets
and CloudFormation stacks. Region `us-east-1` unless `SAMPLE_REGION` is set (CloudFront itself is global).

```
./run-sample.sh --dry-run     # read-only: identity, template validation, the plan and the windows. Changes nothing.
./run-sample.sh               # asks you to type DELETE-SAMPLE, then runs for about 15-20 minutes
```

It prints PASS/FAIL lines as it goes and writes `results-<runid>.md` (redacted: no account id, ARN, host, bucket name or token; read it
before you share it). If a run is cut off (Ctrl-C, error), the exit trap deletes the stack; if that fails the screen says so, and
`./run-sample.sh --cleanup <runid>` finishes the job (also asks for the phrase). Exit codes: 0 all passed, 1 a check failed, 2 bad
input, 3 phrase not typed, 4 teardown incomplete, 130/143 interrupted.

Knobs (environment): `BUCKET_SECONDS` (default 60, 20 to 600), `PROP_WAIT` (default 300 s: how long to wait for a function update to show
at the edge), `POLL_GAP` (10 s), `SAMPLE_REGION`.

## What the run does

The windows are computed from the UTC hour when the script starts: the first window is the previous hour up to the hour after next
(it contains the current hour and the next), the second starts three hours ahead and lasts two hours (it excludes both).

1. **Deploy** with the window that contains now. Wait for CloudFront.
2. **In window.** Same object four times inside one bucket: expect Miss, then Hits. Wait for the next bucket: expect a Miss. Overwrite the S3
   object: the same bucket still shows the old content (reported as information), the next bucket shows the new one.
3. **Viewer-supplied header, in window.** A request with `x-cache-bust: attacker-...` must be a Hit on the entry of the current bucket (the
   function overwrote the value).
4. **Window moved out** (stack update). Poll until a Hit with an Age larger than the bucket length shows up: only a key that does not
   change with time can do that, so the function update is live. That wait is bounded by `PROP_WAIT` and its length is reported. Then: hits
   continue across a bucket boundary; a viewer-supplied `x-cache-bust` does not cause a Miss (it is deleted); an object cached long out of
   window is overwritten in S3 and still served old (long cache works). **Window moved back in:** the long-cached copy must NOT be served,
   the new content must appear (the in-window key differs), as Miss then Hit.
5. **S3 and OAC.** The very first in-window request is the answer to "does S3 accept the extra forwarded header". 200 = yes. A 403 is
   diagnosed: the script moves the window out (no header) and requests again; 200 then means S3/OAC rejected the header, 403 again means a
   bucket policy / OAC problem that has nothing to do with the header.
6. **Teardown.** Bucket keys the script wrote are deleted, the stack is deleted, then the script checks that the stack and the bucket are gone.

## The template

Parameters: `RunId`, `StartHour` (0-23), `EndHour` (0-24, exclusive, must differ from `StartHour`; smaller than `StartHour` = window across
midnight), `BucketSeconds` (1-86400, default 60), `LongTtl` (default 86400). Change the window with a stack update; the function code is
re-rendered and published (`AutoPublish`). Use it alone:

```
aws cloudformation create-stack --stack-name cftb-<RunId> --template-body file://cfn/stack.yaml \
  --parameters ParameterKey=RunId,ParameterValue=<RunId> ParameterKey=StartHour,ParameterValue=8 ParameterKey=EndHour,ParameterValue=17
```

`<RunId>` looks like `2610101200-ab12`. For your own origin, replace the S3 origin and keep the cache policy and the function.
Cache policy: min TTL 0, default and max TTL `LongTtl`, header `x-cache-bust` in the key (so also forwarded to the origin), no cookies, no query strings.
Min TTL 0 means that if your origin ever does send `no-store`/`private`/`no-cache`, CloudFront obeys it and no long caching happens; with
min TTL above 0 CloudFront would cache anyway.

## Function rules

- Window `[StartHour, EndHour)` in UTC hours, start inclusive, end exclusive. The hour comes from `Date` (CloudFront Functions return the time
  the function started).
- Bucket = `floor(epoch seconds / BucketSeconds)`, a decimal string, never empty and never 0 in practice.
- Unusable settings (not whole numbers, out of range, start equal to end) give "no bucket": the long cache applies and the viewer header is
  still deleted. CloudFormation limits stop these values before they reach the code.
- Only the header `x-cache-bust` is touched; the URI and other headers are left alone.

## What is tested and what is not

Tested here, with no AWS and no network:

- The function logic (window edges, a window across midnight, up to midnight, one-hour windows, bucket boundaries, BucketSeconds, overwrite
  and delete of the viewer header, malformed settings): `node --test tests/*.test.mjs`.
- The template text (runtime, header in the key, TTLs, OAC, parameter limits match the function checks, function file identical to the
  template block).
- `run-sample.sh` against fakes: dry run changes nothing, bad inputs, the typed phrase (several wrong answers, closed stdin, `--cleanup`),
  a full run, a window across midnight, errors and Ctrl-C/SIGTERM at several points, a delete that fails, a stack with another run's tag
  (not deleted), S3 rejecting the header, a function update that never shows (bounded), a slow one, two runs in a row, `--cleanup`.
- Redaction: a fake account id, key, token, host and distribution id are injected into error text and must not appear on screen or in the
  results file.
- Mutations (tests/run.sh): with the phrase gate disabled, the header delete removed, the viewer value kept, the bucket made constant, or a
  redaction rule removed, the tests fail.

**Not tested until you run it (everything on the AWS side):** that the template deploys, that S3 accepts the extra header through OAC, that
CloudFront honors `x-cache-bust` from a function in the cache key, how long a function update takes to reach the edge, and the real `x-cache`
values. The fake CloudFront is my model of those, not a measurement. cfn-lint and shellcheck run in CI; `tests/run.sh` says NOT RUN when
they are not installed locally.

## Cost

Pennies: one distribution for under an hour, a few hundred requests (inside the always-free allowance), one function (first 2 million
invocations a month are free), a few S3 requests, CloudFormation is free. Teardown is part of the script.

## Limitations

- **Staleness is bounded by the bucket, not zero.** An object changed in S3 is visible after the next bucket boundary at that edge cache.
  Every edge cache fetches once per bucket, so origin traffic is (objects x edge locations x buckets), not one per request.
- **Browsers.** Nothing here sets browser cache headers (the origin sends none), so a browser may apply its own heuristics. A
  viewer-response function could add `Cache-Control`; it is out of scope.
- **Window switch is not instant.** A function update takes time to reach all edges (the run measures it for one location) and entries cached
  just before the window starts stay under the plain key, unused while the window is on.
- **UTC hours only.** No time zones, no daylight saving, no weekdays or holidays. Whole hours only.
- **Cache pollution.** Each bucket stores another copy of an in-window object for up to `LongTtl` (the origin sends no headers to shorten it).
  Whether those copies push other objects out of the cache early is not measured.
- The forwarded `x-cache-bust` header also reaches the origin. S3 is expected to ignore it; other origins and anything in front of them need their own test.
