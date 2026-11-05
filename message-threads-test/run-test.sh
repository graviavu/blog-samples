#!/usr/bin/env bash
# Latency and cost of message threads vs prompt cache vs full resend vs reload.
#
#   ./run-test.sh --dry-run                 print the plan and the worst-case cost; no network, no files
#   ./run-test.sh --dry-run --tokens 500000
#   ./run-test.sh --run                     paid: needs ANTHROPIC_API_KEY, asks you to type  SPEND UP TO $<cap>
#   ./run-test.sh --self-test               stub tests, no network beyond 127.0.0.1, no key
#
# Python 3 standard library only. The key is read from the environment, never printed or stored.
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
exec "$PY" "$ROOT/threads_test/cli.py" "$@"
