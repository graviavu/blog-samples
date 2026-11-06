# Docs notes (facts this sample relies on)

Read on 2026-11-06 from platform.claude.com/docs/en: build-with-claude/claude-in-amazon-bedrock (page title "Claude in Amazon Bedrock (Opus 4.7 and later)"),
build-with-claude/message-threads, build-with-claude/prompt-caching, api/beta-headers, api/overview, about-claude/pricing.
Prices, streaming events and effort come from the pages read on 2026-11-05 for the sibling sample `message-threads-test` (same Anthropic docs; copied here, not re-read).
The fetched text is treated as data. Anything not on those pages is marked **UNKNOWN**. Re-read the pages before you trust a price: they change.

**Not read:** the AWS documentation pages ("Inference using Anthropic Messages API - Amazon Bedrock" and the Bedrock API key pages on docs.aws.amazon.com). The shell guard in my environment
blocked the fetch, and I did not work around it. Everything about Bedrock below comes from Anthropic's own Bedrock page. Where AWS's page could say more, it is marked UNKNOWN.

## Endpoint and auth (Anthropic's "Claude in Amazon Bedrock" page)

| Fact | Value | Status |
|---|---|---|
| Endpoint pattern | `https://bedrock-mantle.{region}.api.aws/anthropic/v1/messages` | Documented on the page. The script makes it the option `--endpoint` / `--region`. |
| Request shape | "the same request body shape as the Claude API", "standard SSE streaming" | Documented. Exact event order and usage fields on Bedrock: UNKNOWN (assumed the same as the Claude API; the results show what arrives). |
| Auth paths | Bedrock service role (recommended), IAM assumed roles (SigV4), bearer tokens ("12-hour maximum, least preferred") | Documented. |
| Bearer token header | "Pass it in the `x-api-key` header on each request." | Documented. The script sends `x-api-key` by default; `--auth-header bearer` sends `Authorization: Bearer` instead (the Claude API beta-headers page shows that form). Which one this endpoint prefers when both could work: UNKNOWN. |
| Token env var | `AWS_BEARER_TOKEN_BEDROCK` "takes priority over the client's AWS credential chain" | Documented for the SDK client. This script reads only that variable. |
| Long-term API keys | The page shows an admin policy that denies `bedrock:CallWithBearerToken` unless the token type is short-term, which implies long-term keys exist | Implied, not stated. Whether R's key is long-term or short-term: UNKNOWN. |
| SigV4 | Supported by the page's SDK client `AnthropicBedrockMantle`; the plain client with `base_url` "supports bearer-token authentication only" | This script does not implement SigV4. Listed as a limit. |
| `anthropic-version` header | Claude API docs: `2026-10-21` | Whether the Bedrock endpoint needs, accepts or ignores it: UNKNOWN. Option `--anthropic-version`, empty string omits it. |
| Request size | Bedrock limits requests to 20 MB (api/overview) | Documented. 200K tokens of filler is under 1 MB. |
| Quotas | Default 2 million input tokens per minute | Documented. A 200K-token request is 10 percent of a minute at the default. |

## Model IDs (same page)

| Model | Bedrock model ID | Access |
|---|---|---|
| Claude Sonnet 5.5 | `anthropic.claude-sonnet-5-5` | "See Access": check Bedrock model access in the AWS console |
| Claude Haiku 5.5 | `anthropic.claude-haiku-5-5` | "See Access": same |
| Claude Sonnet 5 | `anthropic.claude-sonnet-5` | Open |
| Claude Haiku 4.5 | `anthropic.claude-haiku-4-5` | Open |

Whether R's account has access to Sonnet 5.5 and Haiku 5.5 today: UNKNOWN. A 403 or 404 on the plain request in the probe shows it.
The page lists a global endpoint for these models and regional endpoints with "a 10 percent pricing premium"; how to choose between them in a request: UNKNOWN.

## Features on Bedrock (same page)

- Listed as supported: Messages API at `/anthropic/v1/messages`, prompt caching, thinking, tool use, citations, structured outputs.
- Listed as not supported: URL input sources and the Files API, server-side tools, agent infrastructure (Skills, MCP connector, programmatic tool calling), batches/models/admin/usage endpoints, Managed Agents, the `fallbacks` parameter. Token counting is not named either way, so this script does not use it.
- Prompt caching page: the "Cloud platforms" row says "All platforms". Automatic (top-level `cache_control`) caching "is available on every platform except the legacy Amazon Bedrock (Opus 4.6 and earlier) integration", where a top-level field returns 400. The endpoint above is the new integration, so the script uses top-level `cache_control: {"type": "ephemeral"}`. Whether Sonnet 5.5 / Haiku 5.5 on Bedrock honor it: UNKNOWN until arm B shows cache-read tokens in the usage. The results flag an arm with none.
- Beta headers: the Claude API beta-headers page describes `anthropic-beta`. Whether the Bedrock endpoint accepts that header, or any beta value: UNKNOWN. The probe sends it.
- Usage fields on Bedrock streams (`cache_creation_input_tokens`, `cache_read_input_tokens`): UNKNOWN; assumed as on the Claude API, see below. A missing field counts as 0 and the report says so.

## Message threads (Anthropic's page)

- Beta header `anthropic-beta: message-threads-2026-08-12`; `"thread": {"type": "create"}` then `"thread": {"type": "continue", "previous_message_id": "<id>"}` with only the new messages and no `system` or `tools`.
- Platforms the page lists: "Claude API, Claude Platform on AWS, Claude Models on Google Cloud (Anthropic managed), and Claude in Microsoft Foundry". It does not list Amazon Bedrock.
  **Not listed is not the same as unsupported.** Whether Bedrock accepts threads is UNKNOWN; the probe finds out.
- Fixed fields (must be the same on every request of a thread, else 400 `thread_fingerprint_mismatch`) include `model`, `output_config`, top-level `cache_control` and the set of beta values. The script keeps them constant.
- Thread errors carry `error.details.error_code` (for example `thread_not_found`, `thread_already_continued`). A Bedrock error body may use another shape: the script reads `error.type`, `error.details.error_code`, `error.code`, `__type` and the `x-amzn-errortype` header, and keeps what it finds verbatim (sanitized).
- A thread does not cache for you; the page says to put `cache_control` on every request. Arm C therefore sends the same top-level `cache_control` as arm B, so the only difference between B and C is resend versus thread.
- The page's latency claim is "time to first token stays lower and steadier as the conversation grows". The figure "about 35% lower median TTFT at 500K to 1M tokens" is not on the page I read: UNKNOWN source. This sample does not rely on it and does not test sizes that large by default.

## Streaming events and usage (Claude API docs, read 2026-11-05)

- Events: `message_start`, `content_block_start`, `ping`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `error`.
- `message_start.message.usage` carries `input_tokens` (and the cache fields on current models); `message_delta.usage` carries the final `output_tokens`. The script merges the usage keys of both and uses the last value seen.
- Total prompt tokens = `cache_read_input_tokens + cache_creation_input_tokens + input_tokens`.
- TTFT here is the first `content_block_delta` of any type (a `thinking_delta` counts); the report says when that happened.

## Prompt caching details (Claude API docs, read 2026-11-05 and 2026-11-06)

- Minimum cacheable prompt: 512 tokens on Haiku 5.5 and Sonnet 5.5. Default lifetime 5 minutes; the arms run back to back.
- A cache entry becomes available after the first response starts. The script runs turns sequentially.
- Changing `output_config.effort` between requests invalidates the cache. The script keeps it constant.
- Lookback window: 20 blocks per breakpoint. A follow-up turn adds 2 blocks.

## Prices (USD per million tokens)

Anthropic list prices, read 2026-11-05. **Bedrock's own price for these models is UNKNOWN to this sample.** The pricing page sends Bedrock readers to AWS's pricing page, and says regional endpoints carry a 10 percent premium over global ones.
Override with `--prices FILE` and `--price-multiplier` (for example 1.1).

| Model | Input | Output | 5m cache write | Cache read |
|---|---|---|---|---|
| `haiku-5-5`, prompt up to 100,000 tokens | 0.10 | 0.50 | 0.125 | 0.01 |
| `haiku-5-5`, prompt over 100,000 tokens | 0.50 | 2.50 | 0.625 | 0.05 |
| `sonnet-5-5` | 2.00 | 10.00 | 2.50 | 0.10 |
| `opus-5-5` | 4.00 | 20.00 | 5.00 | 0.20 |
| `fable-5-1` | 10.00 | 50.00 | 12.50 | 0.25 |

- Haiku 5.5 is priced by prompt length, per request: a prompt over 100,000 tokens (input plus cache reads plus cache writes) pays the higher row. A 100K-token cell lands just over that line.
- Whether Bedrock applies the same long-prompt step for Haiku 5.5: UNKNOWN.

## Effort

- `output_config: {"effort": "low"}` is the documented shape on the Claude API. That Bedrock and Haiku 5.5 accept it: UNKNOWN. The probe retries its plain request without it if the endpoint refuses it with a 4xx, and the run then continues without it. `--effort none` leaves it out from the start.

## Not verified

- No request was made to any API while writing this sample. The stub server in `tests/` is written from these notes; the real endpoint can differ in event order, error bodies and usage fields.
