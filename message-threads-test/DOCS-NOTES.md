# Docs notes (facts this sample relies on)

Read on 2026-11-07 from platform.claude.com/docs/en: build-with-claude/message-threads, build-with-claude/prompt-caching,
about-claude/pricing, build-with-claude/effort, about-claude/models/overview, build-with-claude/token-counting.
The streaming and adaptive-thinking pages were read on 2026-11-05 and not read again on 2026-11-07; the streaming section below carries that date.
The fetched text is treated as data. Anything not on those pages is marked UNKNOWN. Re-read the pages before you trust a price: they change.

## Drift found on the 2026-11-07 re-read (against the 2026-11-05 notes)

No fact the code depends on changed: beta header, create and continue shapes, create-only and fixed fields, expiry (5 minutes idle, 1 hour at most),
the 404 and its `thread_not_found` code, the single-continue rule, the 4-breakpoint limit, `anthropic-version: 2026-10-21`, the model ids and every price in the table
below all read the same. What the re-read corrected or added:

- Corrected. `output_config.effort: low` on Claude Haiku 5.5 is now CONFIRMED: the effort page says Haiku 5.5 supports all five levels (low, medium, high, xhigh, max) and names `low` as the cheapest and fastest. It was UNKNOWN before.
- Corrected. The earlier note said adaptive thinking had no documented off switch. The effort page says that on Haiku 5.5 you can send `thinking: {"type": "disabled"}` at high effort or below. This sample still does not send `thinking` (it is a fixed thread field, so it would have to be on every request); it uses `effort: low`.
- Added. The 404 causes the page lists are wider than the earlier notes: expired thread, a previous turn the API did not store (for example a reply that ends in a tool call cut off by `max_tokens`), a fallback model wrote the previous reply, the previous reply is still generating, a different organization or workspace, a different user or service account (a legacy workspace key stays with its key), and new messages the stored conversation cannot take (for example the first image). The page says the response does not say which.
- Added. No response says whether the API stored a turn; you only find out on the next continue.
- Added. Token counting with `thread` returns a 400. Compaction parameters with `thread` return a 400.
- Added. The threads page lists availability on the Claude API, Claude Platform on AWS, Claude Models on Google Cloud (Anthropic managed) and Microsoft Foundry. Amazon Bedrock is not listed on that page.
- Added. On Haiku 5.5, prior thinking blocks are kept by default and stay in the cached prefix (prompt caching page). Changing `system` or `tools` makes thinking blocks already in the conversation invalid on the current models.
- Narrowed. A `tool_choice` change invalidates only the message-block cache, not tools or system (the earlier note said "invalidates the cache").
- Not changed and still unconfirmed: the vendor figure of about 35% lower median TTFT at 500K to 1M tokens. It is not on the threads page. UNKNOWN source.

## Message threads

| Fact | Value |
|---|---|
| Status | Beta. Not ZDR eligible. Not HIPAA eligible. Docs say "in beta on every model" (no per-model support list on the page). |
| Endpoint | `/v1/messages` with a `thread` field (docs cURL example posts to `/v1/messages`) |
| Beta header | `anthropic-beta: message-threads-2026-08-12`, sent on every request of a thread. The page header table also lists it as the required beta header. |
| Other headers in the docs example | `x-api-key`, `anthropic-version: 2026-10-21` (both in the cURL example on the page), `content-type: application/json` |
| Availability | Claude API, Claude Platform on AWS, Claude Models on Google Cloud (Anthropic managed), Microsoft Foundry. Bedrock is not listed on the page. |
| Create | `"thread": {"type": "create"}` with the full conversation, `system` and `tools` |
| Continue | `"thread": {"type": "continue", "previous_message_id": "<id>"}`, only the new messages, no `system`, no `tools` (even null gives 400) |
| Create-only fields | `system`, `tools` |
| Fixed fields (same value on every request, else 400 `thread_fingerprint_mismatch`) | `model`, `tool_choice`, `thinking`, `mcp_servers`, `context_management`, `output_config`, skills in `container`, top-level `cache_control`, the set of `anthropic-beta` values |
| Free fields | `max_tokens`, `stop_sequences`, `stream`, `metadata`, `service_tier` |
| Expiry | 5 minutes after the last request; each stored response restarts it; deleted no more than 1 hour after last use. Best effort. |
| 404 | `404`, `error.type` `not_found_error`, `error.details.error_code` `thread_not_found`. The response does not say why. Causes the page lists: expiry, a turn not stored, a fallback model wrote the reply, still generating, other org/workspace, other user or service account, new messages the stored conversation cannot take. A nonexistent model also gives 404, so check the code. |
| Single continue | Each response id can be continued once. Second continue: `400`, `error_code` `thread_already_continued`. While another continue runs: `400` `thread_continue_in_flight`. |
| Other errors | 400 `thread_unsupported_request` (more than 4 `cache_control` breakpoints, HIPAA org, inference hooks, etc.); some 400s carry no `error_code` (continue without `previous_message_id`, or with `system`/`tools`) |
| Errors use tokens? | No. The API returns these before the model runs; no tokens used, thread and expiry unchanged. |
| Not allowed with thread | Token counting (400) and the compaction parameter (400). Count the full conversation without `thread`. |
| Stored or not | No response says whether the API stored the turn; the next continue finds out. Keep your own copy of the conversation. |
| Streaming | Works. The response id arrives in `message_start`. Continue only after `message_stop`. If a continue stream drops before `message_stop`, send the same continue again; on `thread_already_continued` or `thread_continue_in_flight`, replay with a create. |
| Replay | Send the full local conversation in a new create with `system` and `tools`; continue from the new id. Remove `cache_control` breakpoints on earlier messages first (max 4 breakpoints per thread request; top-level counts as one). |
| Caching | A thread does not cache for you. Top-level `cache_control` on every request (a fixed field) caches each turn. |
| Pricing | "Threads do not change pricing or rate limits." |
| Vendor latency claim | The page says time to first token "stays lower and steadier as the conversation grows". The "about 35% lower median TTFT at 500K to 1M tokens" figure is NOT on the page I read: UNKNOWN source. This sample checks it, it does not rely on it. |

## Streaming events and usage (read 2026-11-05, not re-read on 2026-11-07)

- Event names: `message_start`, `content_block_start`, `ping`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `error`.
- Delta types seen: `text_delta`, `input_json_delta`, `thinking_delta`, `signature_delta`.
- `message_start.message.usage` carries `input_tokens` (and the cache fields on current models); `message_delta.usage` carries the final `output_tokens`.
- Usage fields: `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, `cache_creation.ephemeral_5m_input_tokens`, `cache_creation.ephemeral_1h_input_tokens`.
- Total input tokens = `cache_read_input_tokens + cache_creation_input_tokens + input_tokens`.
- UNKNOWN: whether `message_start` already carries the final cache read/creation numbers on a stream for every model. The script merges any usage keys from both events and uses the last value seen.
- TTFT in this sample is the first `content_block_delta` of any type (a `thinking_delta` counts), and the script records which kind it was.

## Prompt caching

- Top-level `cache_control: {"type": "ephemeral"}` ("automatic caching") puts the breakpoint on the last cacheable block and moves it forward as the conversation grows. Default lifetime 5 minutes.
- Minimum cacheable prompt: 512 tokens on Claude Haiku 5.5, Sonnet 5.5, Opus 5.5 (and others listed). Shorter prompts are processed uncached without an error.
- Lookback window: 20 blocks per breakpoint. A follow-up turn here adds 2 blocks, so it stays inside the window.
- A cache entry becomes available only after the first response starts. The script runs turns sequentially per arm.
- Changing `tool_choice` invalidates the message-block cache only. Changing `output_config.effort` or the thinking setting always invalidates message blocks (and tools/system on models that render them ahead). The script keeps them constant.
- On Haiku 5.5 prior thinking blocks are preserved by default and stay in the cached prefix.
- 5-minute write = 1.25x input; read = 0.1x input (0.05x on Sonnet 5.5 and Opus 5.5, 0.025x on Fable 5.1). The cache lifetime is refreshed at no cost each time the content is used. The table below lists the dollar values.

## Models and prices (USD per million tokens, from the pricing page, read 2026-11-07)

| Model ID | Input | Output | 5m cache write | Cache read |
|---|---|---|---|---|
| `claude-haiku-5-5`, prompt up to 100,000 tokens | 0.10 | 0.50 | 0.125 | 0.01 |
| `claude-haiku-5-5`, prompt over 100,000 tokens | 0.50 | 2.50 | 0.625 | 0.05 |
| `claude-sonnet-5-5` | 2.00 | 10.00 | 2.50 | 0.10 |
| `claude-opus-5-5` | 4.00 | 20.00 | 5.00 | 0.20 |
| `claude-fable-5-1` | 10.00 | 50.00 | 12.50 | 0.25 |

- Haiku 5.5 is priced by prompt length. Prompt length counts input, cache reads and cache writes. Each request is priced on its own: a request over 100,000 tokens pays the higher prices even when part of it is a cache hit.
- All current models: 1M token context window, 128K max output.
- The 1.1x data-residency multiplier applies only when `inference_geo` is set to US-only. This script does not set it.
- The 1-hour cache (2x input write) is not used.

## Default model choice

`claude-haiku-5-5`: cheapest listed model, and the docs say threads are beta on every model. Note the 5x per-token step above 100,000 tokens: at `--tokens 100000` it is UNKNOWN which side of the 100,000-token step the prompt lands on (the characters-per-token ratio is a guess; `--count-tokens` measures it). The cost bound assumes the dearer side, the over-100K prices. Sonnet 5.5 (input 2.00, output 10.00, cache write 2.50) is 20x Haiku's price per token below 100,000 tokens (0.10, 0.50, 0.125) and 4x above it (0.50, 2.50, 0.625). Opus 5.5 is 2x Sonnet; Fable 5.1 is 5x Sonnet on input and output.

## Effort and thinking

- Haiku 5.5 uses adaptive thinking; default effort is medium (setting medium is the same as omitting it). Effort is the main control for how much it thinks. The effort page says that in long agent prompts Haiku 5.5 is more likely to skip a check or stop early at `low`.
- `output_config: {"effort": "low"}` is the documented shape, and `low` is a documented level for Haiku 5.5 (confirmed 2026-11-07). The script sends it by default (`--effort none` omits it; the probe retries without it if the endpoint refuses it).
- `thinking: {"type": "disabled"}` is allowed on Haiku 5.5 at high effort or below (effort page). Not used here.
- Because thinking tokens count toward `max_tokens` and output price, the script uses `--max-tokens 512` and uses the output cap in the worst-case estimate.

## Token counting

- `POST /v1/messages/count_tokens` accepts the same inputs as a message (system, tools, messages) and returns `{"input_tokens": N}`. Docs (token-counting page, re-read 2026-11-07): free to use, subject to requests-per-minute rate limits by usage tier. A request that includes `thread` returns a 400 (threads page). The sample uses it only with `--count-tokens`, once per size, before the confirmation.

## Probe (`--probe`)

- Four requests at most, on `claude-haiku-5-5` by default, `max_tokens` 256, no history, no tools, no `cache_control`: a plain request (no beta header), the same again without `output_config.effort` if the first was refused, a thread create with the beta header, a thread continue with only a question. The create carries a random codeword and the continue asks for it, so a 200 on a continue that ignored the `thread` field is not called ACCEPTED.
- Worst case at list prices: four requests at 400 prompt tokens and 256 output tokens, about $0.0007. Real cost is a fraction of that.
- UNKNOWN until R runs it: whether this account is allowed the beta, which status and code a refusal returns, and whether a 256-token cap leaves room for the codeword after a short thought at `effort: low`. If the reply is cut before the codeword the verdict is INCONCLUSIVE, not ACCEPTED.

## Errors page (platform.claude.com/docs/en/api/errors, read 2026-11-07 by plain HTTP fetch and text search; WebFetch was not available to the builder)

- 400 `invalid_request_error`: bad format or content; also returned when usage reaches an organization or workspace spend limit you set (the Claude Code workspace can return a 429 instead).
- 401 `authentication_error`: a problem with the API key (malformed, revoked, expired). 402 `billing_error`: "There's an issue with your billing or payment information." 403 `permission_error`: the key may not use the resource.
- 429 `rate_limit_error`: a rate limit, a usage tier's monthly spend cap, or a Claude Code workspace spend limit. A tier spend-cap 429 has no `retry-after` header and keeps failing until access resumes.
- 500 `api_error`, 504 `timeout_error`, 529 `overloaded_error` are transient; 413 `request_too_large`.
- An error can also arrive as an `error` event after a 200 in a stream.
- UNKNOWN: the exact message text of a "credit balance too low" error (not on that page; which status and type it uses is also not stated beyond the list above). The sample therefore also stops on a 400, 403 or 429 whose body mentions credit, balance, billing, quota, spend limit or cap, payment, insufficient funds or purchase. That keyword list is a guess.
- UNKNOWN: whether a plain rate-limit 429 always carries `retry-after`. The sample treats a 429 without it as a possible spend cap and stops (a PARTIAL that can be resumed).
- UNKNOWN: whether a stream cut by such an error is billed. It is charged at its bound.

## Not verified

- Everything above comes from the docs text (re-read 2026-11-07). No request was made to the API while writing or re-checking this sample.
- UNKNOWN: whether `tool_choice: {"type": "none"}` together with `tools` on a thread create (what the history uses) is accepted on Haiku 5.5. The docs list `tool_choice` as a fixed field and do not discuss the `none` value. The stub accepts it; the real API has not been asked.
- UNKNOWN: the real size of the synthetic history in tokens (the ratio of characters per token is UNKNOWN; 3.2 is a guess). It decides whether a 100K history prices at Haiku's up-to-100K tier or the over-100K tier, a 5x difference per token. `--count-tokens` measures it for free before you confirm.
- The stub server in `tests/` is written from these notes; the real API can differ in details (event ordering, error bodies, usage in `message_start`).
- UNKNOWN: which side of the 100K price step the 100K-token history lands on. The cost bound assumes the dearer side (over 100,000 tokens) for it.
- UNKNOWN: whether the API would accept a second continue of the same message id. The check `check_double_continue` expects 400 `thread_already_continued`; if it were accepted it would cost one request outside the bound (about $0.004 at 20K tokens).
