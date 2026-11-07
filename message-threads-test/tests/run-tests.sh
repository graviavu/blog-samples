#!/usr/bin/env bash
# Stub tests: no real API, no key, no network beyond 127.0.0.1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
unset ANTHROPIC_API_KEY ANTHROPIC_BASE_URL
exec "${PYTHON_BIN:-python3}" -I -m unittest discover -s tests -t . -v
