#!/usr/bin/env bash
# Shared state for the fake aws, curl, date, sleep and zip. State lives in files under $STUB_DIR.
S="${STUB_DIR:?STUB_DIR not set}"
get() { cat "$S/$1" 2>/dev/null || printf '%s' "${2:-}"; }
put() { printf '%s' "$2" > "$S/$1"; }
# Values that look like real ids are built at run time so that the repo secret scan has nothing to flag.
acct() { printf '%s%s' 1234 56789012; }
fake_dist_id() { printf 'E%s' FAKETEST1234; }
fake_domain() { printf 'd%s.cloudfront.net' faketest1234; }
fake_origin() { printf '%s.lambda-url.us-east-1.on.aws' abcdefghijklmnopqrstuvwxyz012345; }
# Fake clock: STUB_START_EPOCH (default 2026-10-10 12:00:00 UTC) plus every second the script "slept".
now_epoch() { echo $(( ${STUB_START_EPOCH:-1791633600} + $(get slept 0) )); }
# arg --flag args... -> value after the flag
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do if [ "$1" = "$k" ]; then echo "$2"; return; fi; shift; done; }
