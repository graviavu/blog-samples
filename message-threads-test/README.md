# message-threads-test

**The problem:** a long agent loop re-uploads and re-processes its whole history on every turn, and you pay for it in time to first
token (TTFT) and in tokens. Prompt caching, message threads and a plain reload each claim to help. This sample measures all three on
your own API key and shows the saving of each against the worst case, a full resend with no cache. It checks the vendor claim of about
35% lower median TTFT with threads at 500K to 1M tokens, on your machine, and it checks what happens when a thread is gone.

It is a measurement only. It creates nothing in your account except short-lived threads that Anthropic deletes on its own.

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

## Cost and the spend guard

You pay with your own key. The default model is `claude-haiku-5-5`, the cheapest priced model in `DOCS-NOTES.md`. **Haiku 5.5 charges 5x per
token for prompts over 100,000 tokens**, and a 100K-token history lands just over that line, so the higher tier is what the estimate uses. Sonnet 5.5
(`--model claude-sonnet-5-5`) lists at $2 per million input tokens and $10 output, against Haiku's $0.50 and $2.50 above 100K tokens; Opus 5.5 and Fable 5.1 cost more again. Check the pricing page before you run.

- `--dry-run` prints the plan, the number of requests per arm and a **planned upper bound** in dollars, and shows the bound for 100K and 500K tokens. No network call, no file.
- The bound includes the retries and the replays. It assumes every planned request is attempted `1 + --retries` times (default 1 retry), adds one full-size replay for every arm 3 continue, bills every prompt token at the dearer of the input and cache-write price (no cache-read credit), and assumes every reply hits `--max-tokens`. Real spend is far lower: a cache read costs a fraction of a write.
- Default plan at 100K tokens: **$9.87**, under the cap. The same flags at 500K come to $47.37, so use the reduced command below.
- `--max-usd` (default 10) must be a finite number above 0 and is capped at 10: a larger value is rejected, and there is no override flag. If the bound is over the cap, the run refuses to start. During the run it checks the possible cost of the next request before sending it, adds the actual cost from the usage fields after each response, and stops cleanly when the total passes the cap. A stream that is cut off is charged at its bound, because billing for it is unknown. The request on the wire at a Ctrl-C is reported at its worst case next to the spend.
- The history is sized with `--chars-per-token` (default 3.2, on the low side). The first full-size answer is checked: if the prompt is bigger than `--tokens` times `--token-margin` (1.25), the bound no longer holds and the run stops. With `--count-tokens` (opt-in; it needs the key, it is free per the docs, it runs once, and it is never used in a dry run or the self-test) the history is counted before the confirmation prompt and the run refuses to start if it is too big.
- Before any paid call you must type `SPEND UP TO $<cap>` exactly, for example `SPEND UP TO $10`. Anything else makes no call. There is no `--yes`.
- Arm 1 is the dearest (no cache, full context each time), so it has few requests by default: `--nocache-reps 2 --nocache-turns 2`. Arms 2 to 4 use `--reps 3 --turns 5`. All of these are flags.
- **The default 100K run tests a smaller case than the 500K to 1M claim.** To get near the claim under the $10 ceiling, use this reduced run. Its planned upper bound is **$7.87**:

```bash
./run-test.sh --run --tokens 500000 --reps 1 --turns 2 --nocache-reps 1 --nocache-turns 1 --no-checks
```

  It has 2 follow-up turns per cached arm and one request in arm 1, so it shows the size of the effect once and says little about its spread. Run the default 100K plan for the behaviour checks and the spread.

## Run it

You need Python 3 (standard library only) and an API key in your environment. The key is read from `ANTHROPIC_API_KEY`, never printed, never written to a file, never in argv.

```bash
./run-test.sh --dry-run                      # the plan and the planned upper bound, no calls
./run-test.sh --dry-run --tokens 500000      # see what 500K needs
export ANTHROPIC_API_KEY=...                 # your own key
./run-test.sh --run                          # asks you to type SPEND UP TO $10
./run-test.sh --run --tokens 500000 --reps 1 --turns 2 --nocache-reps 1 --nocache-turns 1 --no-checks
./run-test.sh --run --count-tokens           # also count the history once (free) before you confirm
./run-test.sh --run --expiry-test            # adds the 5-minute idle check (slow, cheap)
```

`ANTHROPIC_BASE_URL` overrides the endpoint (the tests point it at a local stub). Plain `http` is refused unless the host is loopback.
Ctrl-C or an error flushes the partial results, prints the spend so far and removes its temp files. There are no cloud resources to tear down.

## What the output means

`results/<timestamp>/results.json` (every request: status, TTFT, total time, usage, cost split) and `results.md` (the summary). No key, no account or org id, no request ids and no message ids are written.

| Column | Meaning |
|---|---|
| TTFT | time from the start of the request to the first content token of the stream. It includes connection setup (a fresh connection per request, the same for every arm) and the upload of the body, which is where threads should help. A thinking token counts; Haiku 5.5 thinks adaptively, so `--effort low` is on by default and the kind of first token is recorded |
| p90 | nearest-rank; under 10 samples it is the maximum. Arm 1 has few samples by design, so its p90 is its maximum |
| cost/turn | computed from the usage fields and the list prices, with the cache-write and cache-read parts split in `results.json`. An estimated usage value, not an invoice |
| TTFT / cost saving | percent below arm 1's median. Negative means worse than arm 1 (a cold reload pays the cache-write premium) |
| first-turn cost | arms 2 and 3 pay a cold write on their first turn. The second table shows the average per request including it |
| Token parity | whether arms sent the same number of prompt tokens at the same turn, within 3%. Differences come from each model reply |
| Thread vs resend | thread median TTFT divided by cached-resend median TTFT. This is the number to hold against the vendor's 35% |

## Limits

- Thinking blocks are left out of the history the resend arms send, while a thread may keep the thinking blocks of its own earlier turns. That can make the arms differ in tokens and TTFT for reasons unrelated to threads, so read the token-usage comparison before you trust a TTFT difference. The docs text I read offers effort as the lever for thinking (adaptive thinking, no documented off switch), so every request uses `--effort low`.
- One machine, one network, one day. With 15 samples per arm, a few points of difference are noise. Run it again on another day before you quote a number.
- The vendor claim of about 35% lower median TTFT at 500K to 1M tokens is what is being checked. The docs page I read only says TTFT "stays lower and steadier" and gives no figure; see `DOCS-NOTES.md`.
- The history is synthetic text and log lines. Token counts depend on the tokenizer; the first answer shows the actual size, and `results.md` notes it if it is far from `--tokens`.
- Threads are best-effort, in beta, and **not ZDR eligible** (and not HIPAA eligible). Do not run this on an organization that needs either.
- Haiku 5.5 may emit a thinking block before text. Whether `effort: low` is accepted on Haiku 5.5 is not stated in the docs text I read. If the API rejects it, run with `--effort none`.
- The stub server is written from the docs, not from the service. Real event ordering, error bodies and usage fields can differ in detail. Nothing here has been run against the real API yet.

## Tests

```bash
./run-test.sh --self-test     # 59 stub tests, no key, no network beyond 127.0.0.1
```

The stub emulates create and continue with the `thread` parameter, SSE streaming, 404 for unknown ids, the single-continue rule, cache accounting and usage numbers, and can inject 500s, cut streams, inflated usage and expiry. Tests cover: a dry run makes no connection; the estimate is an upper bound on what the stub bills; the spend guard stops at the cap and refuses a request that could cross it; the confirmation phrase is enforced and a wrong phrase makes no call; the key never appears in output or files; the 404 replay path; the single-continue rule; back-to-back requests on the real client against an HTTP/1.1 chunked keep-alive stub (exactly one server request per call, no duplicate billing); the cap validation (nan, inf, 0, negative, above 10); the cold-prefix salt (unique per arm and repetition, first in the system prompt, cache read 0); the savings math; median and p90; Ctrl-C flushes partial results.

## Layout

```
run-test.sh              the one script you run
threads_test/            cli, runner (arms, checks, guard), client (HTTP + SSE), pricing, convo, stats, report, redact
tests/                   stub API server and the tests
DOCS-NOTES.md            the facts and prices relied on, with the read date and the UNKNOWNs
```
