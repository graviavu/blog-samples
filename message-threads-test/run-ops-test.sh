#!/usr/bin/env bash
# Operations tests for message threads: B+ body bytes and upload time at 1 and 5 Mbps, E dropped-stream retry, A client-side savepoint.
#
#   ./run-ops-test.sh                 dry run (the default): the plan and the estimate; no network, no files
#   ./run-ops-test.sh --run           the paid run: asks once for SPEND UP TO $0.6 (at a terminal), probe, free token counts, tests B+, E, A
#   ./run-ops-test.sh --run --tests E only some of the tests (comma separated from B,E,A)
#   ./run-ops-test.sh --self-test     stub tests, no network beyond 127.0.0.1, no key
#
# Estimate and cap: the run refuses to start when the estimate is over the cap (default $0.60). --max-usd raises the cap on purpose.
# Python 3 standard library only. The key is read from ANTHROPIC_API_KEY, never printed or stored. The send throttle is inside the
# program (it paces the request body); no firewall, traffic shaper or network setting is touched, so nothing needs restoring.
# Results: results/<timestamp>/ops.md and ops.json (local, git-ignored, never committed). All options: ./run-ops-test.sh --help
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PYTHON_BIN:-python3}"

if [ "${1:-}" = "--self-test" ]; then
  exec "$ROOT/tests/run-tests.sh"
fi

# exec: this shell becomes the program, so Ctrl-C (SIGINT from the terminal) and SIGTERM go straight to python, which stops,
# flushes a PARTIAL ops.md / ops.json and prints the spend. Do not start it as a background job: a non-interactive shell would make
# it ignore SIGINT. The program removes its own temp files; this script deletes nothing.
exec "$PY" -I "$ROOT/threads_test/ops_cli.py" "$@"
