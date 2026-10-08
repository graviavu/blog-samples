#!/usr/bin/env bash
# Shared state for the fake aws and curl. State lives in files under $STUB_DIR.
# enabled (true|false), pending (polls left until Deployed), alarm (OK|ALARM), reason, alarm_ok_after, lambda_fired, calls.log
S="${STUB_DIR:?STUB_DIR not set}"
get() { cat "$S/$1" 2>/dev/null || printf '%s' "${2:-}"; }
put() { printf '%s' "$2" > "$S/$1"; }
# What the real stack would do when the alarm goes to ALARM (only with STUB_LAMBDA=on).
lambda_runs() {
  if [ "${STUB_LAMBDA:-on}" != on ]; then return 0; fi
  put lambda_fired 1
  if [ "${STUB_ACTION:-Disable}" = Disable ] || [ "${STUB_BREAK:-0}" = 1 ]; then
    put enabled false; put pending 2
  fi
}
trip_alarm() { # state ALARM as a real request flood would cause
  put alarm ALARM; put reason "Threshold Crossed (real)"; put alarm_ok_after 3
  lambda_runs
}
