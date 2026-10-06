#!/usr/bin/env bash
# Simple scan for things that must never be in this public repo: AWS account ids, access keys,
# account-scoped ARNs, private keys, real function URL ids and real CloudFront distribution domains.
# Usage: scripts/scan-ids.sh   (run from anywhere; scans tracked and untracked, non-ignored files)
set -u
cd "$(dirname "$0")/.." || exit 2

self="scripts/scan-ids.sh"
status=0
files=$(git ls-files --cached --others --exclude-standard | grep -v -x "$self" || true)
[ -n "$files" ] || { echo "no files to scan"; exit 0; }

check() { # description, extended regex
  local hits
  # shellcheck disable=SC2086
  hits=$(printf '%s\n' $files | xargs grep -n -I -E -- "$2" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "FOUND $1:"
    printf '  %s\n' "${hits//$'\n'/$'\n  '}"
    status=1
  fi
}

check "12-digit number (possible AWS account id)" '(^|[^0-9])[0-9]{12}([^0-9]|$)'
check "AWS access key id" '(AKIA|ASIA)[0-9A-Z]{16}'
check "ARN with an account id" 'arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}:'
check "private key block" 'BEGIN [A-Z ]*PRIVATE KEY'
check "real Lambda function URL id" '[a-z0-9]{32}\.lambda-url\.'
check "real CloudFront distribution domain" '(^|[^A-Za-z0-9])d[a-z0-9]{12,13}\.cloudfront\.net'
check "generic secret assignment" '(secret|password|token)[A-Za-z_]*[ ]*[:=][ ]*["'"'"'][^"'"'"' ]{8,}'

if [ "$status" -eq 0 ]; then echo "scan-ids: clean"; else echo "scan-ids: FAILED"; fi
exit "$status"
