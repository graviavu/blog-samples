#!/usr/bin/env bash
# Stub tests: no real API, no token, no network beyond 127.0.0.1.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
unset AWS_BEARER_TOKEN_BEDROCK AWS_REGION AWS_DEFAULT_REGION
export PYTHONDONTWRITEBYTECODE=1
exec "${PYTHON_BIN:-python3}" -m unittest discover -s tests -t . -v
