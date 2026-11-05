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

- `--dry-run` prints the plan, the number of requests per arm and an ESTIMATED WORST-CASE cost, and shows the estimate for 100K and 500K tokens. No network call, no file.
- The estimate is an upper bound: every prompt token is billed at the dearer of the input and cache-write price, there is no cache-read credit, and every reply is assumed to hit `--max-tokens`. Real spend is far lower in arms 2 and 3, because a cache read costs a fraction of a write.
- `--max-usd` (default 10). If the estimate is over it, the run refuses to start. During the run it checks the possible cost of the next request before sending it, adds the actual cost from the usage fields after each response, and stops cleanly when the total passes the cap. A stream that is cut off is charged at its bound, because billing for it is unknown.
- It checks the first full-size answer: if the prompt is bigger than `--tokens` times `--token-margin` (1.25), the bound no longer holds and the run stops.
- Before any paid call you must type `SPEND UP TO $<cap>` exactly, for example `SPEND UP TO $10`. Anything else makes no call. There is no `--yes`.
- Arm 1 is the dearest (no cache, full context each time), so it has few requests by default: `--nocache-reps 2 --nocache-turns 2`. Arms 2 to 4 use `--reps 3 --turns 5`. All of these are flags.
- At `--tokens 500000` the default plan does not fit under $10 in the worst case (the dry run prints the number). Reduce `--reps`, `--turns`, `--nocache-reps`, or raise `--max-usd`, and look at the dry run again.

## Run it

You need Python 3 (standard library only) and an API key in your environment. The key is read from `ANTHROPIC_API_KEY`, never printed, never written to a file, never in argv.

```bash
./run-test.sh --dry-run                      # the plan and the worst-case cost, no calls
./run-test.sh --dry-run --tokens 500000      # see what 500K needs
export ANTHROPIC_API_KEY=...                 # your own key
./run-test.sh --run                          # asks you to type SPEND UP TO $10
./run-test.sh --run --tokens 500000 --reps 2 --turns 3 --nocache-reps 1 --max-usd 10
./run-test.sh --run --expiry-test            # adds the 5-minute idle check (slow, cheap)
```

`ANTHROPIC_BASE_URL` overrides the endpoint (the tests point it at a local stub). Plain `http` is refused unless the host is loopback.
Ctrl-C or an error flushes the partial results, prints the spend so far and removes its temp files. There are no cloud resources to tear down.

## What the output means

`results/<timestamp>/results.json` (every request: status, TTFT, total time, usage, cost split) and `results.md` (the summary). No key, no account or org id, no request ids and no message ids are written.

| Column | Meaning |
|---|---|
| TTFT | seconds from sending the request to the first content token of the stream (a thinking token counts; Haiku 5.5 thinks adaptively, so `--effort low` is on by default and the kind of first token is recorded). The upload of the body is inside TTFT, which is where threads should help |
| p90 | nearest-rank; under 10 samples it is the maximum |
| cost/turn | computed from the usage fields and the list prices, with the cache-write and cache-read parts split in `results.json`. An estimated usage value, not an invoice |
| TTFT / cost saving | percent below arm 1's median. Negative means worse than arm 1 (a cold reload pays the cache-write premium) |
| first-turn cost | arms 2 and 3 pay a cold write on their first turn. The second table shows the average per request including it |
| Token parity | whether arms sent the same number of prompt tokens at the same turn, within 3%. Differences come from each model reply |
| Thread vs resend | thread median TTFT divided by cached-resend median TTFT. This is the number to hold against the vendor's 35% |

## Limits

- One machine, one network, one day. With 15 samples per arm, a few points of difference are noise. Run it again on another day before you quote a number.
- The vendor claim of about 35% lower median TTFT at 500K to 1M tokens is what is being checked. The docs page I read only says TTFT "stays lower and steadier" and gives no figure; see `DOCS-NOTES.md`.
- The history is synthetic text and log lines. Token counts depend on the tokenizer; the first answer shows the actual size, and `results.md` notes it if it is far from `--tokens`.
- Threads are best-effort, in beta, and **not ZDR eligible** (and not HIPAA eligible). Do not run this on an organization that needs either.
- Haiku 5.5 may emit a thinking block before text. Whether `effort: low` is accepted on Haiku 5.5 is not stated in the docs text I read. If the API rejects it, run with `--effort none`.
- The stub server is written from the docs, not from the service. Real event ordering, error bodies and usage fields can differ in detail. Nothing here has been run against the real API yet.

## Tests

```bash
./run-test.sh --self-test     # 49 stub tests, no key, no network beyond 127.0.0.1
```

The stub emulates create and continue with the `thread` parameter, SSE streaming, 404 for unknown ids, the single-continue rule, cache accounting and usage numbers, and can inject 500s, cut streams, inflated usage and expiry. Tests cover: a dry run makes no connection; the estimate is an upper bound on what the stub bills; the spend guard stops at the cap and refuses a request that could cross it; the confirmation phrase is enforced and a wrong phrase makes no call; the key never appears in output or files; the 404 replay path; the single-continue rule; the cold-prefix salt (unique per arm and repetition, first in the system prompt, cache read 0); the savings math; median and p90; Ctrl-C flushes partial results.

## Layout

```
run-test.sh              the one script you run
threads_test/            cli, runner (arms, checks, guard), client (HTTP + SSE), pricing, convo, stats, report, redact
tests/                   stub API server and the tests
DOCS-NOTES.md            the facts and prices relied on, with the read date and the UNKNOWNs
```
