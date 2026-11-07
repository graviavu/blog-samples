#!/usr/bin/env bash
# Latency and cost of message threads vs prompt cache vs full resend vs reload.
#
#   ./run-test.sh                  dry run (the default): plan, request counts, worst-case cost; no network, no files
#   ./run-test.sh --probe          step 1: does this key accept message threads? Under 1 cent
#   ./run-test.sh --run            the probe, then the latency arms at 20K and 100K tokens (worst case under $5)
#   ./run-test.sh --self-test      stub tests, no network beyond 127.0.0.1, no key
#
# Python 3 standard library only. The key is read from the environment, never printed or stored.
# Paid modes ask you to type  SPEND UP TO $<cap>  (default cap 5). One size only: --tokens N.
# Env: ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL (default https://api.anthropic.com; for the stub server).
# All options: ./run-test.sh --help
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON_BIN:-python3}"

if [ "${1:-}" = "--self-test" ]; then
  exec "$ROOT/tests/run-tests.sh"
fi

# exec: Ctrl-C and SIGTERM go straight to python, which flushes results.json/results.md and prints the spend.
# No cloud resources exist; message threads expire on Anthropic's side (5 minutes idle, 1 hour at most).
exec "$PY" -I "$ROOT/threads_test/cli.py" "$@"
