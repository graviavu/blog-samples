# bedrock-latency-test

**The problem:** a long agent loop resends its whole history on every turn, and the wait before the first token grows with it. On the Claude API there are three levers: prompt caching, message threads, and a smaller model. On Amazon Bedrock I do not know which of them work, or how much each one buys. Anthropic's threads page lists four platforms and Bedrock is not one of them. Not listed is not the same as unsupported, so this sample asks the endpoint instead of guessing, then measures what it finds.

It is a measurement only. No CloudFormation stack is needed: it makes API calls and creates nothing in your AWS account.

## What it measures

Step 1, `--probe` (cents): up to four tiny requests. A plain request (sent once more without `output_config.effort` if the endpoint refuses that field), a thread `create`, and a thread `continue`, both with the beta header `message-threads-2026-08-12`. The verdict is one of:

| Verdict | Meaning |
|---|---|
| ACCEPTED | the plain request worked, create and continue returned 200, and the continue reply used a codeword that only the create request carried |
| REJECTED | the plain request worked and the endpoint refused the thread request with a 4xx. HTTP status, error type and error code are printed verbatim (ids removed) |
| INCONCLUSIVE | the plain request failed (key, endpoint, model access), or a 5xx/429/network error, or a 200 whose reply shows the thread field was ignored, or the continue got a 4xx with a `thread_*` error code (threads are recognized, but the continue was not usable) |

Step 2, the arms, for each model and context size:

| Arm | What each turn sends |
|---|---|
| A | the whole history again, no cache (the baseline) |
| B | the whole history again, top-level `cache_control` (prompt caching) |
| C | `thread: create` once, then `thread: continue` with only the new message, same `cache_control`. **Skipped unless the probe says ACCEPTED** |

Defaults: models `sonnet-5-5` and `haiku-5-5` (Bedrock IDs `anthropic.claude-sonnet-5-5`, `anthropic.claude-haiku-5-5`), context sizes 20K and 100K tokens (200K is opt-in, see the cost section), 3 measured turns per cell, arms run one after the other. The history is synthetic filler built locally. Before the arms, one small request per model measures characters per token, so the filler lands near its target; the real size comes from the usage field and is printed per cell.
For arms B and C the first request primes the cache and is reported apart; the 3 measured turns come after it.

Per cell the report gives the median and p90 of time to first token (TTFT) and of total time, the change against arm A, and the cost.
In arm C every `continue` must report at least 90 percent of the primed prompt's tokens. If it reports fewer, the endpoint probably ignored the thread and answered from the new message alone, which would look like a speed-up. The run prints CONTEXT MISMATCH, leaves that turn out of the timings and says so in the notes.

## Run it

You need Python 3 (standard library only) and a Bedrock API key. Export your key in the variable `AWS_BEARER_TOKEN_BEDROCK` before a paid mode. The script reads it from the environment only; it is never printed, never written to a file, never in argv.

Run `--probe` first. It costs a fraction of a cent and tells you whether the endpoint, key and model access work, and whether threads are accepted. Then run `--run`.

```bash
./run-test.sh                       # dry run (the default): plan, request counts, worst-case cost. No network, no files
./run-test.sh --probe               # step 1, first. Asks you to type  SPEND UP TO $5
./run-test.sh --run                 # then the probe again plus the arms at 20K and 100K. Same phrase
./run-test.sh --self-test           # stub tests, no key
```

The region comes from `AWS_REGION`, else `us-east-1` (`--region`). The endpoint is the documented pattern `https://bedrock-mantle.{region}.api.aws/anthropic`; set `--endpoint` to change it. Plain `http` is refused unless the host is loopback. The key is only sent to a host that ends in `.api.aws` (loopback is allowed for the stub); for any other host, name it on purpose with `--allow-endpoint-host HOST`.
The key is sent in the `x-api-key` header, as Anthropic's Bedrock page shows. If the endpoint answers 401, try `--auth-header bearer`, which sends it in the Authorization header with the Bearer scheme.
Results land in `results/<timestamp>/results.json` and `results.md`: no key, no account id, no request ids, no message ids. The folder and files are readable by your user only.

## Cost and the cap

You pay with your own key. The dry run prints the planned worst case. A paid mode refuses to start if that number is above the cap (`--max-usd`, default 5, at most 2 decimals), and needs you to type `SPEND UP TO $<cap>` exactly. There is no `--yes`.

**The cap applies to the estimated usage value, not to your AWS bill.** The script works out spend from the usage fields and the price table below; Bedrock's real prices for these models are UNKNOWN here. That is why the default `--price-multiplier` is 1.1: the default endpoint looks regional, and the Bedrock page says regional endpoints carry a 10 percent premium.

- Worst case per request: every prompt token billed at the dearer of the input and cache-write price (no cache-read credit), every reply at `--max-tokens` (default 64), a size margin of 1.1, times the multiplier.
- What a request is charged during the run. A complete answer with `input_tokens` and `output_tokens` in its usage: the cost from the usage. A complete answer without them: its worst case. A read timeout, a reset or a cut-off stream after the request was sent: its worst case (the model may have run). An HTTP 500, 502 or 504: its worst case. Only a failure before anything was sent (DNS, connection refused, TLS setup) and a clean 4xx, 429, 503 or 529 refusal count as $0.
- The script checks `spent + this request's worst case` against the cap before every request, and the counted spend after every request. It stops at the cap, writes the partial results and exits with code 3. It also stops (status `stopped_size`) if the first full-size answer of a cell shows a prompt larger than the target times the margin, or has no usage fields to check.
- **The default plan fits the default cap.** Both models at 20K and 100K have a worst case of $4.92 at multiplier 1.1 ($4.47 at 1.0) and a typical cost near $1.90 if cache reads work. So a plain `./run-test.sh --run` starts.
- 200K is opt-in. `--sizes 20000,100000,200000` has a worst case of $13.26 at multiplier 1.1 and a typical cost near $5.13, so it needs `--max-usd 14` or more on purpose. Sonnet 5.5 at 200K is the dear cell ($6.67 of the worst case). The dry run lists the worst case per model and size.
- Prices are Anthropic's list prices (see `DOCS-NOTES.md`). Bedrock's own prices are not in this sample. Override them:

```bash
cat > prices.json <<'EOF'
{"sonnet-5-5": [{"up_to_prompt_tokens": null, "input": 2.0, "output": 10.0, "cache_write": 2.5, "cache_read": 0.1}]}
EOF
./run-test.sh --dry-run --prices prices.json --price-multiplier 1.1
```

Each model takes a list of tiers (`up_to_prompt_tokens` ascending, last one `null`). `--price-multiplier` scales everything (default 1.1); set 1.0 only once you know the endpoint is billed at list price.
Costs in the report are an estimated usage value from the usage fields, not an invoice.

## Retries, timeouts, cleanup

- Timeout 600 seconds per request (`--timeout`). One retry (`--retries`) on clear transient errors only: a network failure before anything was sent (DNS, connection refused, TLS setup), or a complete HTTP 408, 429, 500, 502, 503, 504 or 529 response. A read timeout or a reset after the request was sent is never retried, because the first attempt may already be billed. A 4xx such as 400 or 403 is never retried.
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
- One machine, one network, one run. Run it again on another day before you quote a number. 200K and above are not in the defaults; larger sizes cost more and the 100K step on Haiku 5.5 changes its price tier.
- A cell can miss the cache (lookback window, 5-minute lifetime, a cache that is not honored). The report then shows zero cache-read tokens for that cell, and its cost is higher than the typical figure.

## UNKNOWN

- Whether Bedrock accepts message threads or the beta header `message-threads-2026-08-12` (the probe answers this).
- Which auth header the endpoint prefers, the `x-api-key` header or the Authorization header with the Bearer scheme, and whether it needs `anthropic-version`.
- Whether your account has access to Sonnet 5.5 and Haiku 5.5 (model access is "See Access" on the page).
- Whether `output_config.effort` is accepted on Bedrock.
- Whether the usage fields on Bedrock streams include the cache fields, and whether top-level `cache_control` works on these models there.
- Bedrock's prices for these models, including whether Haiku 5.5 has the same long-prompt step, and how to choose a global or regional endpoint.
- The vendor figure of about 35% lower median TTFT at 500K to 1M tokens. Its source is not on the threads page. This sample does not test that size by default.

## Tests

```bash
./run-test.sh --self-test     # 85 stub tests, no key, no network beyond 127.0.0.1
```

The stub is a local HTTP server written from `DOCS-NOTES.md`, not from the service. It emulates the endpoint path, both auth headers, SSE streaming, prompt-cache accounting, thread create/continue, and injected failures, including "no usage" (a 200 stream with no usage fields), "hang then reset" (the body is read, then the connection is dropped with a reset or left to time out) and a silently ignored continue. Tests cover: the dry run makes no call and writes nothing; the typed phrase gate (every wrong phrase makes no call, no `--yes`, cap amounts with more than 2 decimals refused); the default plan fits the default cap and 200K is refused under it; the cap stop on measured spend, on a prompt larger than the target, and on requests with no usage, a reset or a read timeout (each charged its worst case and never retried, while a refused connection is retried and free); the key only goes to `.api.aws`, loopback or the host named with `--allow-endpoint-host`; a thread continue that reports less than the primed prompt is flagged and left out of the timings; results are readable by the owner only; the key is not in the process arguments; the probe verdicts ACCEPTED, REJECTED (code verbatim), INCONCLUSIVE (server error, ignored thread field, no response id, bad token, plain request refused); thread arm skipped unless ACCEPTED; replay after a lost thread; retries only on transient errors; no token, account id, ARN or request id in stdout, stderr or any file even when the stub echoes them; results format; SIGINT writes partial results and leaves no temp files.
`shellcheck` and `cfn-lint` are not installed here and were not run (there is no template); `bash -n` passes on both shell scripts.
Nothing here has been run against the real endpoint.

## Layout

```
run-test.sh              the one script you run
bedrock_latency/         cli, runner (calibration, arms, guard), probe, client (HTTP + SSE), pricing, plan, fill, stats, report, redact
tests/                   stub Bedrock server and the tests
DOCS-NOTES.md            the facts relied on, with page and read date, and every UNKNOWN
```
