# bedrock-latency-test

**The problem:** a long agent loop resends its whole history on every turn, and the wait before the first token grows with it. On the Claude API there are three levers: prompt caching, message threads, and a smaller model. On Amazon Bedrock I do not know which of them work, or how much each one buys. Anthropic's threads page lists four platforms and Bedrock is not one of them. Not listed is not the same as unsupported, so this sample asks the endpoint instead of guessing, then measures what it finds.

It is a measurement only. No CloudFormation stack is needed: it makes API calls and creates nothing in your AWS account.

## What it measures

Step 1, `--probe` (cents): three tiny requests. A plain request, a thread `create`, and a thread `continue`, both with the beta header `message-threads-2026-08-12`. The verdict is one of:

| Verdict | Meaning |
|---|---|
| ACCEPTED | the plain request worked, create and continue returned 200, and the continue reply used a codeword that only the create request carried |
| REJECTED | the plain request worked and the endpoint refused the thread request with a 4xx. HTTP status, error type and error code are printed verbatim (ids removed) |
| INCONCLUSIVE | the plain request failed (token, endpoint, model access), or a 5xx/429/network error, or a 200 whose reply shows the thread field was ignored |

Step 2, the arms, for each model and context size:

| Arm | What each turn sends |
|---|---|
| A | the whole history again, no cache (the baseline) |
| B | the whole history again, top-level `cache_control` (prompt caching) |
| C | `thread: create` once, then `thread: continue` with only the new message, same `cache_control`. **Skipped unless the probe says ACCEPTED** |

Defaults: models `sonnet-5-5` and `haiku-5-5` (Bedrock IDs `anthropic.claude-sonnet-5-5`, `anthropic.claude-haiku-5-5`), context sizes 20K, 100K and 200K tokens, 3 measured turns per cell, arms run one after the other. The history is synthetic filler built locally. Before the arms, one small request per model measures characters per token, so the filler lands near its target; the real size comes from the usage field and is printed per cell.
For arms B and C the first request primes the cache and is reported apart; the 3 measured turns come after it.

Per cell the report gives the median and p90 of time to first token (TTFT) and of total time, the change against arm A, and the cost.

## Run it

You need Python 3 (standard library only) and a Bedrock API key in your environment. The key is read from `AWS_BEARER_TOKEN_BEDROCK`, never printed, never written to a file, never in argv.

```bash
./run-test.sh                       # dry run (the default): plan, request counts, worst-case cost. No network, no files
export AWS_BEARER_TOKEN_BEDROCK=... # your own key
./run-test.sh --probe               # step 1. Asks you to type  SPEND UP TO $5
./run-test.sh --run --sizes 20000,100000      # probe, then the arms. Same phrase
./run-test.sh --self-test           # stub tests, no key
```

The region comes from `AWS_REGION`, else `us-east-1` (`--region`). The endpoint is the documented pattern `https://bedrock-mantle.{region}.api.aws/anthropic`; set `--endpoint` to change it. Plain `http` is refused unless the host is loopback.
The key is sent in the `x-api-key` header, as Anthropic's Bedrock page shows. If the endpoint answers 401, try `--auth-header bearer`.
Results land in `results/<timestamp>/results.json` and `results.md`: no key, no account id, no request ids, no message ids.

## Cost and the cap

You pay with your own key. The dry run prints the planned worst case. A paid mode refuses to start if that number is above the cap (`--max-usd`, default 5), and needs you to type `SPEND UP TO $<cap>` exactly. There is no `--yes`.

- Worst case: every prompt token billed at the dearer of the input and cache-write price (no cache-read credit), every reply at `--max-tokens` (default 64), a size margin of 1.1. Failed requests are treated as unbilled unless a stream had started; a stream that is cut off is charged at its bound.
- During the run the script checks `spent + this request's worst case` against the cap before every request, and checks the measured spend from the usage fields after every request. It stops at the cap, writes the partial results and exits with code 3. It also stops if the first full-size answer shows a prompt larger than the target times the margin.
- **The default plan does not fit the default cap.** Defaults (both models, 20K/100K/200K) have a worst case of $12.05 and a typical cost near $4.66 if cache reads work. So `./run-test.sh --run` refuses until you cut or raise on purpose. `--sizes 20000,100000` has a worst case of $4.47. Sonnet 5.5 at 200K is the dear cell ($6.07 of the worst case). The dry run lists the worst case per model and size.
- Prices are Anthropic's list prices (see `DOCS-NOTES.md`). Bedrock's own prices are not in this sample. Override them:

```bash
cat > prices.json <<'EOF'
{"sonnet-5-5": [{"up_to_prompt_tokens": null, "input": 2.0, "output": 10.0, "cache_write": 2.5, "cache_read": 0.1}]}
EOF
./run-test.sh --dry-run --prices prices.json --price-multiplier 1.1
```

Each model takes a list of tiers (`up_to_prompt_tokens` ascending, last one `null`). `--price-multiplier` scales everything, for example 1.1 for a regional endpoint.
Costs in the report are an estimated usage value from the usage fields, not an invoice.

## Retries, timeouts, cleanup

- Timeout 600 seconds per request (`--timeout`). One retry (`--retries`) on clear transient errors only: a network failure before any response, or HTTP 408, 429, 500, 502, 503, 504, 529. A 4xx such as 400 or 403 is never retried.
- Ctrl-C or SIGTERM writes the partial results, prints the spend and removes temp files (results are written through a temp file and renamed). There are no cloud resources to tear down. Threads expire on Anthropic's side after 5 minutes idle.

## Reading the results

| Column | Meaning |
|---|---|
| TTFT | time from sending the request to the first content token. It includes connection setup and the upload of the body, the same for every arm. If the first token is a thinking token the notes say so; `--effort low` is on by default |
| p90 | nearest-rank. With under 10 samples it is the maximum. Three samples per cell is a spot check, not a distribution |
| TTFT vs A, Total vs A | change against arm A at the same model and size. Negative is faster |
| Priming TTFT | the first B or C request, which pays the cache write |
| Prompt tokens (real) | from the usage field of the first request in the cell |

If arm B or C shows no cache-read tokens, the report says so: either caching did not take effect on this endpoint or the usage fields do not report it.

## Limits

- The Bedrock endpoint, header, model IDs and caching come from Anthropic's Bedrock page. I could not read the AWS documentation pages. See `DOCS-NOTES.md`.
- Bearer-token auth only. SigV4 is not implemented. If your account can use only IAM credentials, this sample does not run.
- Message threads are beta, best effort and not ZDR eligible on the Claude API. What applies on Bedrock, if the probe says ACCEPTED, is UNKNOWN.
- Arm C is thread plus cache, not a thread alone, because the threads page says a thread does not cache for you.
- One machine, one network, one run. Run it again on another day before you quote a number. Sizes above 200K are not in the defaults; larger sizes cost more and the 100K step on Haiku 5.5 changes its price tier.
- A cell can miss the cache (lookback window, 5-minute lifetime, a cache that is not honored). The report then shows zero cache-read tokens for that cell, and its cost is higher than the typical figure.

## UNKNOWN

- Whether Bedrock accepts message threads or the beta header `message-threads-2026-08-12` (the probe answers this).
- Which auth header the endpoint prefers, `x-api-key` or `Authorization: Bearer`, and whether it needs `anthropic-version`.
- Whether your account has access to Sonnet 5.5 and Haiku 5.5 (model access is "See Access" on the page).
- Whether `output_config.effort` is accepted on Bedrock.
- Whether the usage fields on Bedrock streams include the cache fields, and whether top-level `cache_control` works on these models there.
- Bedrock's prices for these models, including whether Haiku 5.5 has the same long-prompt step, and how to choose a global or regional endpoint.
- The vendor figure of about 35% lower median TTFT at 500K to 1M tokens: its source is not on the threads page. This sample does not test that size by default.

## Tests

```bash
./run-test.sh --self-test     # 62 stub tests, no key, no network beyond 127.0.0.1
```

The stub is a local HTTP server written from `DOCS-NOTES.md`, not from the service. It emulates the endpoint path, both auth headers, SSE streaming, prompt-cache accounting, thread create/continue, and injected failures. Tests cover: the dry run makes no call and writes nothing; the typed phrase gate (every wrong phrase makes no call); the default plan is refused under the default cap; the cap stop on measured spend and on a prompt larger than the target; the probe verdicts ACCEPTED, REJECTED (code verbatim), INCONCLUSIVE (server error, ignored thread field, no response id, bad token, plain request refused); thread arm skipped unless ACCEPTED; replay after a lost thread; retries only on transient errors; no token, account id, ARN or request id in stdout, stderr or any file even when the stub echoes them; results format; SIGINT writes partial results and leaves no temp files.
`shellcheck` and `cfn-lint` are not installed here and were not run (there is no template); `bash -n` passes on both shell scripts.
Nothing here has been run against the real endpoint.

## Layout

```
run-test.sh              the one script you run
bedrock_latency/         cli, runner (calibration, arms, guard), probe, client (HTTP + SSE), pricing, plan, fill, stats, report, redact
tests/                   stub Bedrock server and the tests
DOCS-NOTES.md            the facts relied on, with page and read date, and every UNKNOWN
```
