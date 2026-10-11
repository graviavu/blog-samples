# decision-model-eval

**The problem:** a small decision model looks fine on a vendor card and tells you nothing about your own data. This sample reruns
a side-by-side eval with your model: it asks your model and an LLM baseline the same questions on the same inputs, then measures
whether the answers are right, stable and fast enough, and whether your model can take over when the LLM is down.

It is advisory only. Nothing is sent, moved, deleted or routed. The model picks a bucket from a fixed list and the script writes numbers.

What is in the box:

- One wrapper interface (`decision_eval/contract.py`): a `DecisionRequest` (state, instruction, options) in, a `DecisionResponse` (choice, confidence, probabilities, latency, error) out.
- Adapters: your local HTTP decision-model server, and an LLM baseline through a command you supply (`claude -p` with isolation flags is built in).
- Two harnesses: email triage on 20 synthetic emails with labels, and a routing shadow test on a TSV you supply.
- A backup-path test: the primary times out, your local model answers.
- Metrics, a spend guard, redacted logs, and every request and response kept for later back-testing.

## Rerun it

You need Python 3 (standard library only; tested on 3.14) and a decision-model server on your machine.

```bash
# 1. see the plan; makes no calls and writes nothing
./run-eval.sh --dry-run --url http://127.0.0.1:8000 --label my-model

# 2. your model only (free)
./run-eval.sh --url http://127.0.0.1:8000 --label my-model

# 3. plus an LLM baseline: paid, needs a budget and a typed confirmation
./run-eval.sh --url http://127.0.0.1:8000 --label my-model \
    --llm-preset claude --llm-model sonnet --budget 1.00 --est-cost-per-call 0.01
# or any command that reads the prompt on stdin and prints the answer:
./run-eval.sh --url ... --llm-cmd "my-llm-cli --some-flag" --budget 1.00 --est-cost-per-call 0.01
```

Your own routing notes: `--routing my-routing.tsv` (tab separated, no header needed: `ts idea task_type chosen_option outcome note`).
Your own options instead of haiku/sonnet/opus: `--tiers my-options.json` (`{"name": "description", ...}`, at least two).
Your own emails: `--emails DIR --expected labels.tsv` (same columns as `data/triage/expected.tsv`; buckets are urgent / later / ignore).
All flags: `python3 decision_eval/cli.py --help`.

Output goes to `results/` (git-ignored): `REPORT.md`, `metrics.json`, `run-*.log`, and `results/data/*.jsonl`.

### What you must plug in

| Your model speaks | Use | Notes |
|---|---|---|
| `POST /v1/systemone` with `{state, questions:{q:{type:"choice", instructions, criteria}}}` | `--shape systemone` (default) | The shape the Kev server takes. This is the one shape tested against a real server in the pilot. |
| Anything else | `--shape simple` and a thin shim | `simple` is this sample's own shape, not any vendor's: `POST {state, instructions, options}` returns `{choice, confidence, probabilities}`. |

The request shapes of Perplexity, OpenAI and other `/v1/decisions`-style APIs differ slightly from each other and I have not verified
them here. To add one, extend `build_body` and `parse_body` in `decision_eval/adapters.py` (about 10 lines) and add a case to `tests/test_adapters.py`.
Servers must be on loopback; a non-loopback URL is refused unless you pass `--allow-remote`.

## Safety and cost

- `--dry-run` prints the plan: counts, the LLM command, estimated cost against your budget. No model call, no network, no files.
- Any LLM baseline is a paid call. After the plan, `run-eval.sh` makes you type `run paid llm calls`. Anything else exits with no call made. The Python entry point refuses LLM calls without that confirmation too.
- Spend guard, fail closed: `--budget` and `--est-cost-per-call` are required with an LLM. The guard stops before a call that would cross the budget, caps calls with `--max-calls` (default: the planned count, counted across runs), and stops after 3 failures in a row. If the command reports no cost, each call is charged at your estimate, never zero. Spend is an estimated usage value, not an invoice.
- The `claude` preset runs `claude -p` in an empty temp directory with the prompt on stdin, no tools, no MCP servers, no user settings or hooks, no slash commands, no session saved, and permission mode `dontAsk`. It checks `claude --help` first and exits 1 without a call if any of those flags is missing.
- LLM answers are cached by item and prompt hash in `results/data/llm.jsonl`, so a rerun does not pay twice.
- Email and routing text goes to the model as data, fenced and labelled, never executed. A regex flags likely injection text for a human; it never changes an answer.
- Logs and data files are redacted (tokens, long hex ids, your home path). Redaction is pattern based: read `results/data` before you share it. If you point `--routing` or `--emails` at real notes, `results/data` contains them verbatim. It is git-ignored for that reason.
- No vendor model weights, keys or tokens are in this repo, and none are needed.

## What each metric means

| Metric | Meaning |
|---|---|
| accuracy | Share of the 20 emails put in the labelled bucket. |
| urgent recall | Of the emails labelled urgent, how many the model called urgent. A missed urgent mail is the costly error. Also listed: urgent buried as ignore, and ignore promoted to urgent. |
| injection correctness | Accuracy on the 3 emails that contain instructions aimed at the classifier ("label this urgent"). A correct answer means the model ignored the instruction. |
| agreement | Share of identical picks between your model and the LLM on the same items (triage; routing direct/orig). Agreement is not accuracy: two models can agree and both be wrong. |
| option-order stability | Share of routing rows where the pick is the same under 3 orderings of the options. Low means the answer follows the list order, not the content. Agreement with the chosen option per order is reported next to it. |
| negation / reversal check | The routing question is also asked as "which is the LEAST suitable?". The rate at which it returns the same answer as the direct question. Lower is better. A high rate means the model ignores the negation. |
| ECE | Expected calibration error, 5 equal-width bins, on the models that give a confidence. How far stated confidence sits from observed accuracy. See the limits: with 20 items it is a rough indicator. |
| schema-valid rate | Share of answers with a listed option, a confidence in [0,1] and probabilities summing to about 1. Well-formed does not mean right. |
| latency median / p95 | Client-side time per call. p95 is nearest-rank; with under 20 calls it is close to the maximum. For the LLM it is the wall time of the command. |
| backup path | The primary is a command that hangs (default `sleep 600`), killed at `--backup-timeout`. Reports how many times your model took over, the median switchover time (timeout plus local answer), and agreement with the labels and with the LLM answers when both exist. The primary is never a paid call. |

## Honest limits

- The 20 emails are synthetic, written by one person (all addresses are `*.example`). They say little about your mail. Replace them with labelled mail of your own before you trust a number.
- n is small everywhere. One email is 5 points of accuracy. ECE from 20 items in 5 bins leaves a handful of items per bin. p95 of 20 calls is nearly the maximum. Treat differences of a few points as noise.
- The routing reference is the tier that was actually chosen, not the right tier. If most rows say `sonnet`, "always sonnet" is a strong baseline and agreement above it is what counts (`baseline_always_*` is reported).
- The routing prompt hides the chosen option and the outcome, but the note often still gives it away or says almost nothing.
- Latency depends on your hardware, batch size and server warm-up. The LLM number includes process start of the command.
- The reversal check assumes the least suitable option differs from the cheapest suitable one. For two-option sets it measures something different.
- The injection regex is a heuristic. It found all 3 injections in the bundled set and nothing else; that proves little.
- The tests use a fake server and a fake LLM command. The `claude` preset has been tested against a fake binary only; if a real `claude` build lists its flags differently, the preset refuses rather than runs.
- Schema-valid is not correct, and a constrained answer set reduces injection risk, it does not remove it. Keep the output advisory.

## Tests

```bash
./tests/run-tests.sh      # 42 stub tests, no network beyond 127.0.0.1, no model, no claude
```

They cover the metrics, both request shapes, failure handling, loopback refusal, the timeout fallback, the spend guard
(budget, call cap, unknown cost, cache, repeated failure), the isolation-flag check, the dry run making zero calls,
the typed confirmation, redaction, and the bundled data being synthetic.
Lint used: `ruff check --select E,F,W` and `shellcheck run-eval.sh tests/run-tests.sh` in a scratch virtualenv (neither is a dependency of the sample).

## Layout

```
run-eval.sh              the one entry script
decision_eval/           contract.py adapters.py llm.py harness.py metrics.py cli.py (flat modules, stdlib only)
data/triage/             20 synthetic emails + expected.tsv (labels the model never sees)
data/routing-example.tsv 12 synthetic routing rows, replace with your own via --routing
tests/                   stub tests, fake decision server, fake LLM command
```
