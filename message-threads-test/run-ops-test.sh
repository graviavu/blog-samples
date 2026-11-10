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

child=0
# Ctrl-C reaches the program through the terminal's process group; this shell only has to stay alive until the program has
# flushed its results. SIGTERM (a kill of this script) is passed on so the program still flushes and prints the spend.
on_int() { :; }
on_term() { if [ "$child" -ne 0 ]; then kill -TERM "$child" 2>/dev/null; fi; }
# Whatever happens, remove half-written temp files the program may have left in the default results folder.
cleanup() { if [ -d "$ROOT/results" ]; then find "$ROOT/results" -name '*.tmp' -type f -delete 2>/dev/null; fi; }
trap on_int INT
trap on_term TERM
trap cleanup EXIT

"$PY" -I "$ROOT/threads_test/ops_cli.py" "$@" <&0 &
child=$!
rc=0
while kill -0 "$child" 2>/dev/null; do
  wait "$child"
  rc=$?
done
exit "$rc"
