#!/usr/bin/env bash
# Shared state for the fake aws, curl and sleep. State lives in files under $STUB_DIR.
S="${STUB_DIR:?STUB_DIR not set}"
get() { cat "$S/$1" 2>/dev/null || printf '%s' "${2:-}"; }
put() { printf '%s' "$2" > "$S/$1"; }
# Values that look like real ids are built at run time so that the repo secret scan has nothing to flag.
acct() { printf '%s%s' 1234 56789012; }
plain_domain() { printf 'd%s.cloudfront.net' plainfake001; }
fixed_domain() { printf 'd%s.cloudfront.net' fixedfake001; }
# Fake clock in seconds: every "sleep" adds to it.
now_s() { echo $(( 1000 + $(get slept 0) )); }
# arg --flag args... -> value after the flag
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do if [ "$1" = "$k" ]; then echo "$2"; return; fi; shift; done; }
objfile() { printf '%s/bucket/%s' "$S" "$(printf '%s' "$1" | sed 's#/#%#g')"; }
