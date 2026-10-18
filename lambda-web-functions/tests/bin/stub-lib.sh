#!/usr/bin/env bash
# Shared state for the fake aws, curl, node and sleep. State lives in files under $STUB_DIR.
S="${STUB_DIR:?STUB_DIR not set}"
get() { cat "$S/$1" 2>/dev/null || printf '%s' "${2:-}"; }
put() { printf '%s' "$2" > "$S/$1"; }
# Values that look like real ids are built at run time so that the repo secret scan has nothing to flag.
acct() { if [ -n "${STUB_OTHER_ACCOUNT:-}" ]; then printf '%s%s' 9876 54321098; else printf '%s%s' 1234 56789012; fi; }
# the Cloudflare token must never be in a child's environment (the script un-exports it)
[ -z "${CF_API_TOKEN:-}" ] || echo "$0" >> "$S/leak.log"
# children that need no AWS access (curl, node) must not get the AWS secrets of the environment
case "$(basename "$0")" in curl|node) [ -z "${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}${AWS_ACCESS_KEY_ID:-}" ] || echo "$0" >> "$S/awsleak.log" ;; esac
fake_akid() { printf '%s%s%s' AK IA ABCDEFGHIJKLMNOP; }
fake_key() { printf '%s%s%s' abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMN 0123; }
fake_cfd() { printf 'd%s.cloudfront.net' faketest12345; }
fake_wfh() { printf '%s.lambda-web.us-east-1.on.aws' fakewf12345; }
fake_fuh() { printf '%s.lambda-url.us-east-1.on.aws' abcdefghijklmnopqrstuvwxyz012345; }
fake_dist() { printf 'E%s' FAKETEST1234; }
fake_zid() { printf '%s' 0123456789abcdef0123456789abcdef; }
fake_cfacc() { printf '%s' fedcba9876543210fedcba9876543210; }
zone() { printf '%s' "${STUB_ZONE:-example.test}"; }
# arg --flag args... -> value after the flag
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do if [ "$1" = "$k" ]; then echo "$2"; return; fi; shift; done; }
# reg KIND NAME [content] : registry in files "res/KIND__NAME" ("/" written as "%")
reg() { mkdir -p "$S/res"; printf '%s' "${3:-}" > "$S/res/$1__$(printf '%s' "$2" | tr '/' '%')"; }
unreg() { rm -f "$S/res/$1__$(printf '%s' "$2" | tr '/' '%')"; echo "DELETE $1 $2" >> "$S/deleted.log"; }
has() { [ -e "$S/res/$1__$(printf '%s' "$2" | tr '/' '%')" ]; }
# textlist KIND PREFIX [REGION]: like names, but prints "None" for an empty result, as the real CLI's text output does for a
# null query result (for example DistributionList.Items in an account without distributions)
textlist() { local r; r="$(names "$@")"; if [ -n "$r" ]; then printf '%s\n' "$r"; else echo None; fi; }
names() { # KIND PREFIX [REGION] -> names (space separated) of registered resources whose name starts with PREFIX (and whose content is REGION)
  local f n
  for f in "$S"/res/"$1"__*; do
    [ -e "$f" ] || continue
    n="$(basename "$f")"; n="${n#"$1"__}"; n="$(printf '%s' "$n" | tr '%' '/')"
    if [ -n "${3:-}" ] && [ "$(cat "$f")" != "$3" ]; then continue; fi
    case "$n" in "$2"*) printf '%s ' "$n" ;; esac
  done
}
