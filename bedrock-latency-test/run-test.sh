#!/usr/bin/env bash
# Latency of long conversations on Amazon Bedrock: full resend vs prompt cache vs message thread, Sonnet 5.5 vs Haiku 5.5.
#
#   ./run-test.sh                  dry run (the default): plan, request counts, worst-case cost; no network, no files
#   ./run-test.sh --probe          step 1: are message threads accepted here? A few cents at most
#   ./run-test.sh --run            probe, then the latency arms
#   ./run-test.sh --self-test      stub tests, no key, no network beyond 127.0.0.1
#
# Python 3 standard library only. The Bedrock API key is read from AWS_BEARER_TOKEN_BEDROCK, never printed or stored.
# Paid modes ask you to type  SPEND UP TO $<cap>  (default cap 5). All options: ./run-test.sh --help
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON_BIN:-python3}"

if [ "${1:-}" = "--self-test" ]; then
  exec "$ROOT/tests/run-tests.sh"
fi

# exec: Ctrl-C and SIGTERM go straight to python, which writes the partial results.json/results.md, prints the spend
# and removes its temp files. No cloud resources are created, so there is nothing else to tear down.
exec "$PY" -I "$ROOT/bedrock_latency/cli.py" "$@"
