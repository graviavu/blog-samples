#!/usr/bin/env bash
# Shared state for the fake aws and curl. State lives in files under $STUB_DIR.
# enabled (true|false), pending (polls left until Deployed), alarm (OK|ALARM), reason, alarm_ok_after, lambda_fired, calls.log
S="${STUB_DIR:?STUB_DIR not set}"
get() { cat "$S/$1" 2>/dev/null || printf '%s' "${2:-}"; }
put() { printf '%s' "$2" > "$S/$1"; }
# Names like the real stack: the Lambda FunctionName output is auto-generated, the log group is fixed by the template.
FN_NAME="${STUB_FN_NAME:-fake-stack-BrakeFunction-AbC123xyz}"
LOG_GROUP_REAL="${STUB_LOG_GROUP:-/aws/lambda/fake-stack-brake}"
now_ms() { echo $(( $(date +%s) * 1000 )); }
add_event() { printf '%s\t%s\n' "$(now_ms)" "$1" >> "$S/events"; }
# What the real stack would do when the alarm goes to ALARM (only with STUB_LAMBDA=on).
# STUB_REVERT=N: the first N forced alarms revert to OK before the Lambda checks, so it logs "not confirmed" and does nothing.
lambda_runs() {
  if [ "${STUB_LAMBDA:-on}" != on ]; then return 0; fi
  local r; r=$(get reverted 0)
  if [ "$r" -lt "${STUB_REVERT:-0}" ]; then
    put reverted $((r + 1)); put alarm OK
    add_event "[INFO] trigger not confirmed by AWS, nothing done (alarm fake-stack-RequestsAlarm-X)"
    return 0
  fi
  put lambda_fired 1
  local D="${STUB_DIST:-EFAKETEST1234}"
  if [ "${STUB_ACTION:-Disable}" = Disable ] || [ "${STUB_BREAK:-0}" = 1 ]; then
    put enabled false; put pending 2
    add_event "[INFO] disabled distribution $D (alarm fake-stack-RequestsAlarm-X)"
  else
    add_event "[INFO] AlertOnly: would disable $D (alarm fake)"
  fi
  if [ -n "${STUB_LOG_LINES:-}" ]; then   # many lines: the script's "first 15" pipe closes early (SIGPIPE)
    awk -v ts="$(now_ms)" -v n="$STUB_LOG_LINES" 'BEGIN { for (k = 0; k < n; k++) printf "%s\t[INFO] filler line %d with some padding text\n", ts, k }' >> "$S/events"
  fi
}
trip_alarm() { # state ALARM as a real request flood would cause
  put alarm ALARM; put reason "Threshold Crossed (real)"; put alarm_ok_after 3
  lambda_runs
}
