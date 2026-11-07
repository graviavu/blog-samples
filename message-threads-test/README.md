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

## Order: dry run, then one command

1. `./run-test.sh` is a dry run. It sends nothing and writes nothing. It prints the plan, the request counts and the planned upper bound.
2. `./run-test.sh --all` does everything else in one go. It prints the plan, asks you to type `SPEND UP TO $4.5` **once** (at a terminal), then runs the probe and stops unless it says ACCEPTED, then counts the history with the free `count_tokens` endpoint and refuses or adjusts the history size before any full-size request, then runs the arms, then writes the summary. If the credit runs out or the key is refused, it stops at once and saves what it has (see below).

The same steps one at a time, if you prefer:

1. `./run-test.sh --probe` is step 1 and costs well under one cent. It sends at most four tiny requests on `claude-haiku-5-5`: one plain request, one thread `create` and one thread `continue` with the beta header `message-threads-2026-08-12` (plus one plain retry without `output_config.effort` if the endpoint refuses that field). It prints whether your key accepted the beta header and the create and continue. The create carries a random codeword and the continue asks for it, so a 200 that ignored the `thread` field is not counted. Verdicts:

| Verdict | Meaning |
|---|---|
| ACCEPTED | the plain request worked, create and continue returned 200, and the continue reply used the codeword that only the create carried |
| REJECTED | the plain request worked and the API refused the thread create (or a continue without a `thread_*` code) with a 4xx. Status, error type and code are printed |
| INCONCLUSIVE | the plain request failed (key, model id, access), or a 5xx, 429 or network error, or a 200 whose reply did not show the thread context, or a continue that got a `thread_*` error code |

2. `./run-test.sh --run` repeats the probe, stops there unless it says ACCEPTED, and then runs the arms at **20K and 100K tokens of history**, smallest first, so you can see latency against context size. `--skip-probe` leaves the repeat out if you have just seen ACCEPTED.

The probe writes `probe.json` (no key; ids matching known patterns are redacted). Every paid mode asks you to type `SPEND UP TO $<cap>` (default `SPEND UP TO $4.5`). The probe asks for it too, like the Bedrock sample.

## After the first run: `--tune` (three experiments, one timeline)

Run this after `--all` has finished and you have looked at `results.md`. It is a separate paid mode with its own typed phrase, `SPEND UP TO $2` (default and highest cap **2.0**, no override), and a **planned upper bound of $1.44 including the probe**, so it fits in what is left of a $5 credit after a first run. The default `--all` is unchanged.

```bash
./run-test.sh --tune --dry-run      # the plan, the timeline and the bound; nothing is sent
./run-test.sh --tune                # asks for SPEND UP TO $2, then the probe (stops unless ACCEPTED), the free token count, the experiments
```

Order: `./run-test.sh` (dry run) then `--all` then `--tune`. `--tune` does not go with `--run`, `--probe`, `--all`, `--resume` or `--skip-probe`. **It cannot be resumed**: the timeline (the waits) is the point. If it stops (credit, key, cap, Ctrl-C) it saves a PARTIAL `tune.md` and `tune.json` with whatever was measured, prints the spend, and a new `--tune` starts from the beginning.

All three run on `claude-haiku-5-5` with `effort: low` and `max_tokens` 100 on one timeline, so the waits overlap (about 9 minutes in all). Every experiment has its own prefix salt, so none shares cache with another. A countdown line is printed every 10 seconds while waiting.

| # | Experiment | What it does | What it reports |
|---|---|---|---|
| 1 | Warm-cache reload (100K tokens) | A normal request writes a 1-hour cache entry (`cache_control: {"type": "ephemeral", "ttl": "1h"}` at the top level). Then a thread is created from the same history at t0. At t0+340 s (over the 5-minute idle limit) a continue must return 404 `thread_not_found`; that is the check that the thread is gone. Then the same prefix is replayed as a new thread create with the same `cache_control`. The existing cold reload (fresh salt, the arm 4 request with the default 5-minute `cache_control`) follows as the comparison | cache read and cache write tokens, cost and TTFT of the prime, the replay and the cold reload, and one plain sentence: did the replay read the 1-hour cache (YES, NO, PARTLY or UNKNOWN) |
| 2 | Keep-alive (20K) | A thread is created at t0, a tiny continue ("ping, reply OK") goes out at t0+240 s, a real continue at t0+480 s | RESET (the real continue answered 200 although 480 s passed since the create), NOT RESET (or the thread expired anyway) on 404, or UNKNOWN; plus the tokens the keep-alive added to the stored history |
| 3 | Growth (20K) | 15 turns in one thread against 15 turns of cached full resend, small user messages, the two arms interleaved turn by turn | TTFT per turn for both arms, thread / resend ratio per turn, cost per turn, the median of the first 5 and the last 5 turns for each arm, and the plain numbers behind the docs' claim that TTFT "stays lower and steadier as the conversation grows"; no more |

The report is `results/<timestamp>/tune.md` plus `tune.json` (no key, no message or request ids; files 0600, folders 0700), with the same one-machine, one-day caveat and the exact n: experiments 1 and 2 are single requests per step (n = 1, not a rate), experiment 3 has 15 turns per arm. Anything the replies do not settle is reported UNKNOWN, not guessed: a thread that is still alive at the expiry check, a keep-alive that already got 404, a response that does not report the 1-hour split of the cache write, a real continue that came inside the 5-minute limit even without a reset.

Rules that differ from `--all`:

- There are **no automatic replays** in this mode. A continue that fails is a result. If one experiment cannot go on, the others still run, the report says which stopped, and the exit code is 4.
- The bound counts every request attempted twice (`--retries 1`), prices the 1-hour cache write at 2x the base input price, takes the 100K step on the dearer side (over 100,000 tokens: input 0.50, 1-hour write 1.00, 5-minute write 0.625 per million), counts the replay and the 404 check at full price as if it succeeded, and assumes every reply fills `--tune-max-tokens`. Typical cost is far lower: about $0.05 to $0.20 (a model, not a measurement; it depends on which side of the 100K step the history lands).
- Every guard of the other modes holds: the phrase must be typed at a terminal and nothing is sent before it; the host allowlist; the margin and ratio bounds, and the free token count before any full-size request (it rebuilds or refuses); the per-request check against the cap before each request; credit, billing and auth errors stop at once with PARTIAL files; the results are flushed after every request; redaction.
- Options (all optional): `--tune-big 100000`, `--tune-small 20000`, `--tune-turns 15`, `--tune-max-tokens 100`, `--tune-keepalive-at 240`, `--tune-expiry-at 340`, `--tune-final-at 480` (seconds after t0), `--tune-idle-limit 300` (only for the wording of the verdicts), `--retries`, `--effort`, `--max-usd` (at most 2). The dry run shows the bound for any change; a bound above the cap refuses to start.

### More samples at 20K (no new code)

The 20K arms are cheap, so more repetitions need no new mode. This gives 20 samples per cached arm and 20 cold reloads, 2 no-cache requests and no behaviour checks, and its planned upper bound is **$0.88** (the dry run prints it; typical about $0.18). Cap it at $1 so it can never come near the credit left:

```bash
./run-test.sh --sizes 20000 --reps 20 --turns 1 --no-checks --nocache-reps 2 --nocache-turns 1 --max-usd 1     # dry run: prints the bound
./run-test.sh --all --sizes 20000 --reps 20 --turns 1 --no-checks --nocache-reps 2 --nocache-turns 1 --max-usd 1   # asks for SPEND UP TO $1
```

The bound is under the default cap too, so `--max-usd 1` is only the tighter cap. If you change the counts and the dry run prints a bound above your cap, lower `--reps` or `--nocache-reps`, or the run refuses to start.

## Cost and the spend guard

You pay with your own key. The default model is `claude-haiku-5-5`, the cheapest priced model in `DOCS-NOTES.md`. **Haiku 5.5 charges 5x per token for prompts over 100,000 tokens.** The 100K history can land either side of that line (UNKNOWN: the characters-per-token ratio of 3.2 is a guess; `--count-tokens` measures it for free), and the bound assumes the dearer side. Run `--count-tokens` on your first `--run`. Sonnet 5.5 (`--model claude-sonnet-5-5`) lists at $2 per million input tokens and $10 output, against Haiku's $0.50 and $2.50 above 100K tokens; Opus 5.5 and Fable 5.1 cost more again. Check the pricing page before you run.

**Default plan: planned upper bound $4.44, cap $4.5.** The cap is $4.5, not $5, so that $0.50 of a $5 credit balance is never touched. That is the worst case with every request retried once, one full-size replay for every thread continue, and the probe. Typical cost is about $0.58 (modelled, not measured: the cache works as documented, the 100K prompt prices at the over-100K tier, replies are short). If the 100K history lands under 100,000 tokens, the 100K part is roughly 5x cheaper. Per size: the 20K part is under $0.25 of the bound, the 100K part is $4.23.

Default flags: sizes 20000 and 100000; arms 2 to 4 use `--reps 2 --turns 3` (so 6 follow-up samples per cached arm and size); arm 1, the dearest because nothing is cached, uses `--nocache-reps 1 --nocache-turns 2`; the behaviour checks run once, at 20K. Six samples is thin: it shows the size of an effect, not its spread. Raise the counts and the dry run shows the new bound.

- With `--all` (and `--resume`) the history is counted for free after the probe, once per size. If it is over `--token-margin` times the size, or under 70% of it, the history is rebuilt once with the measured characters-per-token (kept within 2.0 to 4.5) and counted again; if it still does not fit, the run refuses before any full-size request and tells you the spend (the probe only). The cost bound depends on the size and the margin, not on the ratio, so an adjusted history keeps it. `--count-tokens` on `--run` stays the old opt-in check before the confirmation.
- A dry run prints the plan, the number of requests per arm and size, the **planned upper bound** in dollars and the modelled typical cost. No network call, no file.
- The bound includes the retries and the replays. It assumes every planned request is attempted `1 + --retries` times (default 1 retry), adds one full-size replay for every arm 3 continue, bills every prompt token at the dearer of the input and cache-write price (no cache-read credit), assumes every reply hits `--max-tokens`, and adds the probe. Real spend is far lower: a cache read costs a fraction of a write.
- `--max-usd` (default **4.5**) must be a finite number above 0 and at most 10: a larger value is rejected and there is no override flag. If the bound is over the cap, a paid run refuses to start. During the run the possible cost of the next request is checked before it is sent, the actual cost from the usage fields is added after each response, and the run stops cleanly when the total passes the cap. The request check uses the larger of the planned bound and a bound taken from the size of the request body actually built, so one request cannot cross the cap. **The cap holds only with `--token-margin` and `--chars-per-token` at their defaults** (they are validated: margin at least 1.0, chars per token 2.0 to 4.5; other values change the bound). A 200 reply with no usage block is charged at its worst case. One request is outside the bound: if the API accepted the second continue of the same id (`check_double_continue`), it could cost one more request, about $0.004 at 20K tokens. One cap covers the probe and all sizes together. A stream that is cut off is charged at its bound, because billing for it is unknown. The request on the wire at a Ctrl-C is reported at its worst case next to the spend.
- The history is sized with `--chars-per-token` (default 3.2, UNKNOWN real ratio, a guess on the low side). The first full-size answer of each size is checked: if the prompt is bigger than the size times `--token-margin` (1.25), the bound no longer holds and the run stops. With `--count-tokens` (opt-in; needs the key, free per the docs, once per size, never in a dry run or the self-test) the history is counted before the confirmation and the run refuses to start if it is too big.
- Before any paid call you must type `SPEND UP TO $<cap>` exactly, for example `SPEND UP TO $4.5`. Anything else makes no call. There is no `--yes`, and the phrase must be typed at a terminal: piped or redirected stdin is refused.
- **Raising the size.** `--tokens N` runs one size instead of the two defaults. A bigger size costs about linearly more. The default cap refuses it, so you raise the cap on purpose (up to the ceiling of 10) and type the new phrase. Its bound is more than a $5 balance holds, so it is not for a $5 credit balance. To get near the vendor claim of 500K to 1M tokens under the ceiling, use this reduced run. Its planned upper bound is **$7.87**:

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
./run-test.sh --all                          # the whole test: asks once for SPEND UP TO $4.5, then probe, token count, arms, summary
./run-test.sh --resume results/<folder>      # after a PARTIAL stop: runs only what is not done yet (same flags, same phrase)
./run-test.sh --probe                        # step by step: under 1 cent, are threads accepted?
./run-test.sh --run                          # step by step: the probe again, then the arms at 20K and 100K
./run-test.sh --run --count-tokens           # step by step: also count each history once (free) before you confirm
./run-test.sh --all --expiry-test            # adds the 5-minute idle check at 20K (slow, cheap)
```

`ANTHROPIC_BASE_URL` overrides the endpoint (the tests point it at a local stub). Only `https://api.anthropic.com` or a loopback stub is accepted; any other host is refused unless you name it exactly with `--base-url-host` (the key is sent there). Plain `http` is refused unless the host is loopback.
Ctrl-C or an error flushes the partial results, prints the spend so far and removes its temp files. There are no cloud resources to tear down.

## When the credit or the key runs out (PARTIAL)

The API reports a spent balance in different ways, so the run stops on any of these, in the probe, in the arms, in a stream (an `error` event) and in `count_tokens`:

- HTTP 402 `billing_error`, 401 `authentication_error`, 403 `permission_error`. These come from the errors page of the docs (read 2026-11-07).
- HTTP 400 `invalid_request_error` is also what the docs say the API returns when an organization or workspace spend limit is reached.
- HTTP 429 `rate_limit_error` is also what the docs say a usage tier's monthly spend cap returns, and that one has no `retry-after` header and keeps failing. So a 429 **without** `retry-after`, and any 400, 403 or 429 whose body contains credit, balance or purchase (and the other listed words), stops the run too (a plain rate limit with `retry-after` is still retried once, as before).
- UNKNOWN: the exact message text of a "credit balance too low" error is not on the errors page. So a 400, 403 or 429 whose body mentions credit, balance, billing, quota, spend limit or cap, payment, insufficient funds or purchase also stops the run. This is a guess at wording and errs on the side of stopping; a wrong stop is a PARTIAL you can resume. The same words in an error event inside an open HTTP 200 stream also stop the run. A miss would mean the run keeps going and spends more, which is why the list errs wide.

On such an error nothing is retried or replayed (not even a thread continue, which otherwise replays on some 400s), the refused request is counted as $0 here (what the account is billed for it is UNKNOWN, not on the errors page), and the run saves what it has: `results.json` and `results.md` (per size, and the top level) marked **PARTIAL** with the reason, the stage reached (size, arm, repetition, turn), the spend counted and the completed turns and arms; a probe stopped this way writes `probe.json` with verdict PARTIAL. It prints a clear message and exits non-zero: **5** for credit/billing/quota, **6** for the key. An error inside an open stream is charged at its bound, because billing for a cut stream is unknown. Files are 0600 and folders 0700; no key and no ids.

## Finishing a PARTIAL run (`--resume`)

`./run-test.sh --resume results/<folder>` runs only the arms and sizes that are not complete in that folder, then writes the summary into the same folder. Use the same flags as the first run. It asks for the same typed phrase once. If the saved `probe.json` says ACCEPTED the probe is not repeated; the token count still runs for sizes with work left. `--resume <folder> --dry-run` shows what is left and its bound without sending anything.

- The cap covers the whole folder: spent so far plus the planned upper bound of what is left must be at most `--max-usd`. The spent figure is the **highest** of what the saved files claim and what their records add up to, plus the worst case of any request that was on the wire at a Ctrl-C. It is never taken from one field alone.
- The folder is not trusted. It must be yours, 0700, not a symbolic link; each file must be JSON of the expected shape with finite numbers in range; the saved settings (model, sizes, turns, reps, nocache-turns/reps, reload-reps, max-tokens, seed, margin, retries, checks, expiry-test, effort) must equal the current flags; every unit marked done must have a completed request; a partial file from an older version without the unit list is refused. Anything else makes the resume refuse and send nothing.
- A unit (one arm, one repetition) that was cut in the middle is run again from its start with a fresh cold prefix; the cost of its cut requests stays in the spend and is shown as `abandoned_records_usd`. The kept history of each size is rebuilt with the saved characters-per-token, so the finished and the new arms use the same history.
- A rejected probe cannot be resumed. A complete folder says there is nothing left to run.

## What the output means

`--tune` writes `tune.md`, `tune.json` and `probe.json` instead (see the section above). `results/<timestamp>/` holds `probe.json` (verdict ACCEPTED, REJECTED, INCONCLUSIVE, INTERRUPTED or PARTIAL), then one folder per size (`20000/`, `100000/`) with `results.json` (every request: status, TTFT, total time, usage, cost split) and `results.md` (the summary), and a top-level `results.md` with TTFT and cost by context size side by side. `spent_usd` in each size's file is cumulative for the whole run. With `--tokens N` there is one size and its files sit directly in the timestamp folder. No key is written, and ids matching known patterns are redacted. The results folders are created 0700 and the files 0600.

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
./run-test.sh --self-test     # 186 stub tests, no key, no network beyond 127.0.0.1
```

The stub emulates create and continue with the `thread` parameter, SSE streaming, 404 for unknown ids, the single-continue rule, cache accounting and usage numbers, and can inject 500s, cut streams, inflated usage and expiry. Tests cover: the default plan's worst case is at most $5 and the 500K command needs `--max-usd 10` and its own phrase; `--probe` makes exactly three requests with the right headers and bodies, costs under a cent, and gives ACCEPTED, REJECTED or INCONCLUSIVE in the right cases (a continue that ignores the thread is not ACCEPTED); `--run` stops after a rejected probe; two sizes run in separate folders under one shared cap with different cold prefixes; a dry run makes no connection; the estimate is an upper bound on what the stub bills; the spend guard stops at the cap and refuses a request that could cross it; the confirmation phrase is enforced and a wrong phrase makes no call; the key never appears in output or files; the 404 replay path; the single-continue rule; back-to-back requests on the real client against an HTTP/1.1 chunked keep-alive stub (exactly one server request per call, no duplicate billing); the cap validation (nan, inf, 0, negative, above 10); the cold-prefix salt (unique per arm and repetition, first in the system prompt, cache read 0); the savings math; median and p90; Ctrl-C flushes partial results. New: every credit, billing, quota, spend-limit and auth error shape stops at once with exactly one request after the error, no retry and no replay (including a credit 400 on a thread continue and an error event inside a stream), writes PARTIAL files (0600/0700, no key, no ids) and exits 5 or 6; a plain 429 with retry-after is still retried; `--all` runs probe, then the count, then the arms with one typed phrase, stops on REJECTED, adjusts or refuses on the measured ratio, and keeps the tty, margin, ratio and host guards; the default cap is 4.5 with bound 4.44; `--tune` (45 tests in `tests/test_tune.py`: each experiment with success, the expected 404, keep-alive reset and not reset, a warm replay that does and does not read the 1-hour cache, the growth math, bound at most 1.5, cap refusals, a billing stop mid-timeline, Ctrl-C, tty-only phrase, nothing sent before the phrase, private files); `--resume` runs only what is left, carries the spend, applies the cap to the remainder, and refuses malformed, non-private, symlinked, mismatched or out-of-range folders.

## Layout

```
run-test.sh              the one script you run
threads_test/            cli, probe, runner (arms, checks, guard), tune and tune_report (--tune), client (HTTP + SSE, error classes), resume, pricing, convo, stats, report, redact
tests/                   stub API server and the tests
DOCS-NOTES.md            the facts and prices relied on, with the read date and the UNKNOWNs
```
