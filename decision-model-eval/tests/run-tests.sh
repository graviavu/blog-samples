#!/usr/bin/env bash
# Stub tests: a fake decision server on 127.0.0.1 and a fake LLM command. No network, no model, no claude call.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec python3 -I -m unittest discover -s tests -v "$@"
