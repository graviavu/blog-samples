#!/usr/bin/env bash
# Rerun the side-by-side eval with YOUR decision model.
#
#   ./run-eval.sh --dry-run --url http://127.0.0.1:8000 --label my-model      show the plan, make no calls
#   ./run-eval.sh --url http://127.0.0.1:8000 --label my-model                local model only (free)
#   ./run-eval.sh --url ... --llm-preset claude --budget 1.00 --est-cost-per-call 0.01
#   ./run-eval.sh --url ... --llm-cmd "my-llm-cli --flag" --budget 1.00 --est-cost-per-call 0.01
#
# Any LLM baseline is a paid call: you must type the confirmation phrase. --budget (USD) is a hard stop.
# All options: python3 decision_eval/cli.py --help. Output is redacted (tokens, long hex ids, home path).
# Request/response data is kept under results/data on purpose (back-testing) and never deleted here.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON_BIN:-python3}"
PHRASE="run paid llm calls"

redact() { sed -E "s/hf_[A-Za-z0-9]{8,}/hf_<redacted>/g; s/sk-[A-Za-z0-9_-]{10,}/<key>/g; s/[0-9a-fA-F]{40,64}/<hex>/g; s#${HOME}#~#g; s/(Bearer|token=|Authorization:) *[^ ]+/\1 <redacted>/g"; }

DRY=0; LLM=0; RESULTS="$ROOT/results"; ARGS=("$@"); PREV=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1;;
    --llm-cmd|--llm-preset) LLM=1;;
    -h|--help) sed -n 2,12p "$0"; exit 0;;
  esac
  [ "$PREV" = "--results-dir" ] && RESULTS="$a"
  PREV="$a"
done

if [ "$DRY" = 1 ]; then
  "$PY" "$ROOT/decision_eval/cli.py" "${ARGS[@]}" 2>&1 | redact
  exit "${PIPESTATUS[0]}"
fi

if [ "$LLM" = 1 ]; then
  # plan first (no calls), then the typed confirmation, before anything is sent to the LLM
  "$PY" "$ROOT/decision_eval/cli.py" --dry-run "${ARGS[@]}" 2>&1 | redact
  [ "${PIPESTATUS[0]}" = 0 ] || exit 1
  echo
  echo "This will make PAID LLM calls, capped by --budget. Type exactly: $PHRASE"
  read -r reply || reply=""
  if [ "$reply" != "$PHRASE" ]; then echo "not confirmed; no calls made."; exit 1; fi
  ARGS+=(--confirmed-llm)
fi

mkdir -p "$RESULTS"
LOG="$RESULTS/run-$(date -u +%Y%m%dT%H%M%SZ).log"
# restore trap: an interrupt stops the run; data already written stays (append-only), no partial report is left behind
trap 'echo "interrupted; request data kept in $RESULTS/data" | redact; exit 130' INT TERM
"$PY" "$ROOT/decision_eval/cli.py" "${ARGS[@]}" 2>&1 | redact | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
