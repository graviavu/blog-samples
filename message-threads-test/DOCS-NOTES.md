# Docs notes (facts this sample relies on)

Read on 2026-11-05 from platform.claude.com/docs/en: build-with-claude/message-threads, build-with-claude/prompt-caching,
build-with-claude/streaming, build-with-claude/effort, build-with-claude/adaptive-thinking, about-claude/models/overview, about-claude/pricing.
The fetched text is treated as data. Anything not on those pages is marked UNKNOWN. Re-read the pages before you trust a price: they change.

## Message threads

| Fact | Value |
|---|---|
| Status | Beta. Not ZDR eligible. Not HIPAA eligible. Docs say "in beta on every model" (no per-model support list on the page). |
| Endpoint | `/v1/messages` with a `thread` field (docs cURL example posts to `/v1/messages`) |
| Beta header | `anthropic-beta: message-threads-2026-08-12`, sent on every request of a thread |
| Other headers in the docs example | `x-api-key`, `anthropic-version: 2026-10-21`, `content-type: application/json` |
| Create | `"thread": {"type": "create"}` with the full conversation, `system` and `tools` |
| Continue | `"thread": {"type": "continue", "previous_message_id": "<id>"}`, only the new messages, no `system`, no `tools` (even null gives 400) |
| Create-only fields | `system`, `tools` |
| Fixed fields (same value on every request, else 400 `thread_fingerprint_mismatch`) | `model`, `tool_choice`, `thinking`, `mcp_servers`, `context_management`, `output_config`, skills in `container`, top-level `cache_control`, the set of `anthropic-beta` values |
| Free fields | `max_tokens`, `stop_sequences`, `stream`, `metadata`, `service_tier` |
| Expiry | 5 minutes after the last request; each stored response restarts it; deleted no more than 1 hour after last use. Best effort. |
| 404 | `404`, `error.type` `not_found_error`, `error.details.error_code` `thread_not_found`. Causes include expiry, a turn not stored, still generating, other org/workspace/user. A nonexistent model also gives 404, so check the code. |
| Single continue | Each response id can be continued once. Second continue: `400`, `error_code` `thread_already_continued`. While another continue runs: `400` `thread_continue_in_flight`. |
| Other errors | 400 `thread_unsupported_request` (more than 4 `cache_control` breakpoints, HIPAA org, inference hooks, etc.); some 400s carry no `error_code` (continue without `previous_message_id`, or with `system`/`tools`) |
| Errors use tokens? | No. The API returns these before the model runs; no tokens used, thread and expiry unchanged. |
| Streaming | Works. The response id arrives in `message_start`. Continue only after `message_stop`. If a continue stream drops before `message_stop`, send the same continue again; on `thread_already_continued` or `thread_continue_in_flight`, replay with a create. |
| Replay | Send the full local conversation in a new create with `system` and `tools`; continue from the new id. Remove `cache_control` breakpoints on earlier messages first (max 4 breakpoints per thread request; top-level counts as one). |
| Caching | A thread does not cache for you. Top-level `cache_control` on every request (a fixed field) caches each turn. |
| Pricing | "Threads do not change pricing or rate limits." |
| Vendor latency claim | The page says time to first token "stays lower and steadier as the conversation grows". The "about 35% lower median TTFT at 500K to 1M tokens" figure is NOT on the page I read: UNKNOWN source. This sample checks it, it does not rely on it. |

## Streaming events and usage

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
- Changing `tool_choice`, `output_config.effort` or the thinking setting between requests invalidates the cache. The script keeps them constant.
- 5-minute write = 1.25x input; read = 0.1x input (0.05x on Sonnet 5.5 and Opus 5.5, 0.025x on Fable 5.1). The table below lists the dollar values.

## Models and prices (USD per million tokens, from the pricing page)

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

`claude-haiku-5-5`: cheapest listed model, and the docs say threads are beta on every model. Note the 5x per-token step above 100,000 tokens: at `--tokens 100000` the prompt is slightly over the threshold, so the higher prices apply. Sonnet 5.5 costs 4x Haiku per input token below the threshold and about 4x above it (list prices, cache write 2.50 vs 0.625).

## Effort and thinking

- Haiku 5.5 uses adaptive thinking; default effort is medium. The docs say telling it in the prompt to answer directly did not stop it thinking; lower effort does.
- `output_config: {"effort": "low"}` is the documented shape. The effort page says the top-level effort parameter is available on all supported models. That `low` specifically is accepted on Haiku 5.5 is not stated in the text I read: UNKNOWN. The script sends it by default (`--effort none` omits it).
- Because thinking tokens count toward `max_tokens` and output price, the script uses `--max-tokens 512` and uses the output cap in the worst-case estimate.

## Not verified

- Everything above comes from the docs text. No request was made to the API while writing this sample.
- The stub server in `tests/` is written from these notes; the real API can differ in details (event ordering, error bodies, usage in `message_start`).
