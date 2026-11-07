# message-threads-test

**The problem:** a long agent loop re-uploads and re-processes its whole history on every turn, and you pay for it in time to first
token (TTFT) and in tokens. Prompt caching, message threads and a plain reload each claim to help. This sample measures all three on
your own API key and shows the saving of each against the worst case, a full resend with no cache. It checks the vendor claim of about
35% lower median TTFT with threads at 500K to 1M tokens, on your machine, and it checks what happens when a thread is gone.

The default run uses 20K and 100K tokens of history, which shows how latency grows with context but does not reach the 500K to 1M range of that claim; the reduced 500K command under Cost says how to get near it.

It is a measurement only. It creates nothing in your account except short-lived threads that Anthropic deletes on its own (best effort, within 1 hour of last use).

## The four arms

| Arm | What it sends each turn |
|---|---|
| 1 No cache | the whole history again, no `cache_control` (the baseline) |
| 2 Prompt cache | the whole history again, top-level `cache_control`, cache warm |
| 3 Thread + cache | one `thread: create`, then `thread: continue` with only the new message, same `cache_control` |
| 4 Reload | the thread is gone or the cache is cold, so the loop sends a create with the full history. A unique salt at the very start of the system prompt makes the prefix cold: cache read is 0 and the cache write is paid |

The history is a deterministic, seeded, synthetic agent transcript (tool_use / tool_result turns about a fictional shop; no real data).
Every arm sends the same prefix. The repetitions are interleaved and the arm order rotates each repetition to spread network drift.
It also checks: (a) a continue with a made-up `previous_message_id` returns 404 and a create with the full local history recovers,
(b) continuing the same response id twice fails as the docs say, (c) with `--expiry-test`, an idle wait just over 5 minutes and then a continue.
Exact status codes and redacted error bodies go in the results.

## Order: dry run, probe, run

1. `./run-test.sh` is a dry run. It sends nothing and writes nothing. It prints the plan, the request counts and the planned upper bound.
2. `./run-test.sh --probe` is step 1 and costs well under one cent. It sends at most four tiny requests on `claude-haiku-5-5`: one plain request, one thread `create` and one thread `continue` with the beta header `message-threads-2026-08-12` (plus one plain retry without `output_config.effort` if the endpoint refuses that field). It prints whether your key accepted the beta header and the create and continue. The create carries a random codeword and the continue asks for it, so a 200 that ignored the `thread` field is not counted. Verdicts:

| Verdict | Meaning |
|---|---|
| ACCEPTED | the plain request worked, create and continue returned 200, and the continue reply used the codeword that only the create carried |
| REJECTED | the plain request worked and the API refused the thread create (or a continue without a `thread_*` code) with a 4xx. Status, error type and code are printed |
| INCONCLUSIVE | the plain request failed (key, model id, access), or a 5xx, 429 or network error, or a 200 whose reply did not show the thread context, or a continue that got a `thread_*` error code |

3. `./run-test.sh --run` repeats the probe, stops there unless it says ACCEPTED, and then runs the arms at **20K and 100K tokens of history**, smallest first, so you can see latency against context size. `--skip-probe` leaves the repeat out if you have just seen ACCEPTED.

The probe writes `probe.json` (no key; ids matching known patterns are redacted). Paid modes ask you to type `SPEND UP TO $<cap>`. The probe asks for it too, like the Bedrock sample.

## Cost and the spend guard

You pay with your own key. The default model is `claude-haiku-5-5`, the cheapest priced model in `DOCS-NOTES.md`. **Haiku 5.5 charges 5x per token for prompts over 100,000 tokens.** The 100K history can land either side of that line (UNKNOWN: the characters-per-token ratio of 3.2 is a guess; `--count-tokens` measures it for free), and the bound assumes the dearer side. Run `--count-tokens` on your first `--run`. Sonnet 5.5 (`--model claude-sonnet-5-5`) lists at $2 per million input tokens and $10 output, against Haiku's $0.50 and $2.50 above 100K tokens; Opus 5.5 and Fable 5.1 cost more again. Check the pricing page before you run.

**Default plan: planned upper bound $4.44, cap $5.** That is the worst case with every request retried once, one full-size replay for every thread continue, and the probe. Typical cost is about $0.58 (modelled, not measured: the cache works as documented, the 100K prompt prices at the over-100K tier, replies are short). If the 100K history lands under 100,000 tokens, the 100K part is roughly 5x cheaper. Per size: the 20K part is under $0.25 of the bound, the 100K part is $4.23.

Default flags: sizes 20000 and 100000; arms 2 to 4 use `--reps 2 --turns 3` (so 6 follow-up samples per cached arm and size); arm 1, the dearest because nothing is cached, uses `--nocache-reps 1 --nocache-turns 2`; the behaviour checks run once, at 20K. Six samples is thin: it shows the size of an effect, not its spread. Raise the counts and the dry run shows the new bound.

- A dry run prints the plan, the number of requests per arm and size, the **planned upper bound** in dollars and the modelled typical cost. No network call, no file.
- The bound includes the retries and the replays. It assumes every planned request is attempted `1 + --retries` times (default 1 retry), adds one full-size replay for every arm 3 continue, bills every prompt token at the dearer of the input and cache-write price (no cache-read credit), assumes every reply hits `--max-tokens`, and adds the probe. Real spend is far lower: a cache read costs a fraction of a write.
- `--max-usd` (default **5**) must be a finite number above 0 and at most 10: a larger value is rejected and there is no override flag. If the bound is over the cap, a paid run refuses to start. During the run the possible cost of the next request is checked before it is sent, the actual cost from the usage fields is added after each response, and the run stops cleanly when the total passes the cap. The request check uses the larger of the planned bound and a bound taken from the size of the request body actually built, so one request cannot cross the cap. **The cap holds only with `--token-margin` and `--chars-per-token` at their defaults** (they are validated: margin at least 1.0, chars per token 2.0 to 4.5; other values change the bound). A 200 reply with no usage block is charged at its worst case. One request is outside the bound: if the API accepted the second continue of the same id (`check_double_continue`), it could cost one more request, about $0.004 at 20K tokens. One cap covers the probe and all sizes together. A stream that is cut off is charged at its bound, because billing for it is unknown. The request on the wire at a Ctrl-C is reported at its worst case next to the spend.
- The history is sized with `--chars-per-token` (default 3.2, UNKNOWN real ratio, a guess on the low side). The first full-size answer of each size is checked: if the prompt is bigger than the size times `--token-margin` (1.25), the bound no longer holds and the run stops. With `--count-tokens` (opt-in; needs the key, free per the docs, once per size, never in a dry run or the self-test) the history is counted before the confirmation and the run refuses to start if it is too big.
- Before any paid call you must type `SPEND UP TO $<cap>` exactly, for example `SPEND UP TO $5`. Anything else makes no call. There is no `--yes`, and the phrase must be typed at a terminal: piped or redirected stdin is refused.
- **Raising the size.** `--tokens N` runs one size instead of the two defaults. A bigger size costs about linearly more. The default 5-dollar cap refuses it, so you raise the cap on purpose (up to the ceiling of 10) and type the new phrase. To get near the vendor claim of 500K to 1M tokens under the ceiling, use this reduced run. Its planned upper bound is **$7.87**:

```bash
./run-test.sh --run --tokens 500000 --reps 1 --turns 2 --nocache-reps 1 --nocache-turns 1 --no-checks --max-usd 10
# asks you to type: SPEND UP TO $10
```

  It has 2 follow-up turns per cached arm and one request in arm 1, so it shows the size of the effect once and says little about its spread. The default plan gives the behaviour checks and the 20K and 100K comparison.

## Run it

You need Python 3 (standard library only) and an API key in your environment. The key is read from `ANTHROPIC_API_KEY`, never printed, never written to a file, never in argv.

```bash
./run-test.sh                                # dry run: the plan and the planned upper bound, no calls
export ANTHROPIC_API_KEY=...                 # your own key
./run-test.sh --probe                        # step 1, under 1 cent: are threads accepted? asks you to type SPEND UP TO $5
./run-test.sh --run                          # the probe again, then the arms at 20K and 100K; same phrase
./run-test.sh --run --count-tokens           # also count each history once (free) before you confirm
./run-test.sh --run --expiry-test            # adds the 5-minute idle check at 20K (slow, cheap)
```

`ANTHROPIC_BASE_URL` overrides the endpoint (the tests point it at a local stub). Only `https://api.anthropic.com` or a loopback stub is accepted; any other host is refused unless you name it exactly with `--base-url-host` (the key is sent there). Plain `http` is refused unless the host is loopback.
Ctrl-C or an error flushes the partial results, prints the spend so far and removes its temp files. There are no cloud resources to tear down.

## What the output means

`results/<timestamp>/` holds `probe.json`, then one folder per size (`20000/`, `100000/`) with `results.json` (every request: status, TTFT, total time, usage, cost split) and `results.md` (the summary), and a top-level `results.md` with TTFT and cost by context size side by side. `spent_usd` in each size's file is cumulative for the whole run. With `--tokens N` there is one size and its files sit directly in the timestamp folder. No key is written, and ids matching known patterns are redacted. The results folders are created 0700 and the files 0600.

| Column | Meaning |
|---|---|
| TTFT | time from the start of the request to the first content token of the stream. It includes connection setup (a fresh connection per request, the same for every arm) and the upload of the body, which is where threads should help. A thinking token counts; Haiku 5.5 thinks adaptively, so `--effort low` (documented for Haiku 5.5) is on by default and the kind of first token is recorded |
| p90 | nearest-rank; under 10 samples it is the maximum. Arm 1 has few samples by design, so its p90 is its maximum |
| cost/turn | computed from the usage fields and the list prices, with the cache-write and cache-read parts split in `results.json`. An estimated usage value, not an invoice |
| TTFT / cost saving | percent below arm 1's median. Negative means worse than arm 1 (a cold reload pays the cache-write premium) |
| first-turn cost | arms 2 and 3 pay a cold write on their first turn. The second table shows the average per request including it |
| Token parity | whether arms sent the same number of prompt tokens at the same turn, within 3%. Differences come from each model reply |
| Thread vs resend | thread median TTFT divided by cached-resend median TTFT. This is the number to hold against the vendor's 35% |

## Limits

- Thinking blocks are left out of the history the resend arms send, while a thread may keep the thinking blocks of its own earlier turns. That can make the arms differ in tokens and TTFT for reasons unrelated to threads, so read the token-usage comparison before you trust a TTFT difference. The docs offer effort as the main lever for thinking, so every request uses `--effort low`. The effort page also allows `thinking: {"type": "disabled"}` on Haiku 5.5 at high effort or below; this sample does not use it.
- One machine, one network, one day. With 6 follow-up samples per arm and size at the default, a few points of difference are noise. Run it again on another day before you quote a number.
- The vendor claim of about 35% lower median TTFT at 500K to 1M tokens is what is being checked. The docs page I read only says TTFT "stays lower and steadier" and gives no figure; see `DOCS-NOTES.md`.
- The history is synthetic text and log lines. Token counts depend on the tokenizer; the first answer shows the actual size, and `results.md` notes it if it is far from `--tokens`.
- Threads are best-effort, in beta, and **not ZDR eligible** (and not HIPAA eligible). Do not run this on an organization that needs either.
- Haiku 5.5 may emit a thinking block before text. `effort: low` is documented for Haiku 5.5; the probe still retries without it if your endpoint refuses it, and tells you. The effort page warns that at `low` the model is more likely to skip a check in long agent prompts, which does not matter for a latency test with short answers.
- UNKNOWN: whether the real API accepts `tool_choice: none` together with `tools` on a thread create, which is what the history sends. The stub accepts it. The probe does not test it (it sends no tools); the first arm that fails will show it.
- The stub server is written from the docs, not from the service. Real event ordering, error bodies and usage fields can differ in detail. Nothing here has been run against the real API yet.

## Tests

```bash
./run-test.sh --self-test     # 82 stub tests, no key, no network beyond 127.0.0.1
```

The stub emulates create and continue with the `thread` parameter, SSE streaming, 404 for unknown ids, the single-continue rule, cache accounting and usage numbers, and can inject 500s, cut streams, inflated usage and expiry. Tests cover: the default plan's worst case is at most $5 and the 500K command needs `--max-usd 10` and its own phrase; `--probe` makes exactly three requests with the right headers and bodies, costs under a cent, and gives ACCEPTED, REJECTED or INCONCLUSIVE in the right cases (a continue that ignores the thread is not ACCEPTED); `--run` stops after a rejected probe; two sizes run in separate folders under one shared cap with different cold prefixes; a dry run makes no connection; the estimate is an upper bound on what the stub bills; the spend guard stops at the cap and refuses a request that could cross it; the confirmation phrase is enforced and a wrong phrase makes no call; the key never appears in output or files; the 404 replay path; the single-continue rule; back-to-back requests on the real client against an HTTP/1.1 chunked keep-alive stub (exactly one server request per call, no duplicate billing); the cap validation (nan, inf, 0, negative, above 10); the cold-prefix salt (unique per arm and repetition, first in the system prompt, cache read 0); the savings math; median and p90; Ctrl-C flushes partial results.

## Layout

```
run-test.sh              the one script you run
threads_test/            cli, probe, runner (arms, checks, guard), client (HTTP + SSE), pricing, convo, stats, report, redact
tests/                   stub API server and the tests
DOCS-NOTES.md            the facts and prices relied on, with the read date and the UNKNOWNs
```
