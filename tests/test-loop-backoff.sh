#!/usr/bin/env bash
# test-loop-backoff.sh — tests for leftibot-loop.sh's graduated idle backoff.
#
# Sources leftibot-loop.sh (without running the loop) and checks the duration
# parser and the backoff schedule.
#
# Usage: tests/test-loop-backoff.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_SCRIPT="$TESTS_DIR/../bin/leftibot-loop.sh"

FAILURES=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

run_case() {
  local name="$1" body="$2"
  if (
    set --
    # shellcheck source=../bin/leftibot-loop.sh
    source "$LOOP_SCRIPT"
    "$body"
  ); then
    pass "$name"
  else
    fail "$name"
  fi
}

expect_eq() {
  [[ "$1" == "$2" ]] || { printf '  expected %s, got %s (%s)\n' "$2" "$1" "${3:-}"; return 1; }
}

case_parse_duration() {
  expect_eq "$(parse_duration 90)"  90   "bare seconds" || return 1
  expect_eq "$(parse_duration 45s)" 45   "seconds"      || return 1
  expect_eq "$(parse_duration 5m)"  300  "minutes"      || return 1
  expect_eq "$(parse_duration 2h)"  7200 "hours"        || return 1
  ! parse_duration 5x >/dev/null 2>&1 || { echo "  accepted bad unit"; return 1; }
  ! parse_duration abc >/dev/null 2>&1 || { echo "  accepted non-number"; return 1; }
}

case_backoff_schedule_from_minimum_to_cap() {
  local delay=0 got=()
  for _ in 1 2 3 4 5 6 7; do
    delay=$(next_idle_delay "$delay" 60 900)
    got+=("$delay")
  done
  expect_eq "${got[*]}" "60 120 240 480 900 900 900" "1m doubling, capped at 15m"
}

case_cap_below_minimum_wins() {
  expect_eq "$(next_idle_delay 0 60 30)" 30 "cap smaller than minimum"
}

case_defaults_are_gentle_on_github() {
  expect_eq "$MIN_IDLE_SECONDS" 60  "first idle wait" || return 1
  expect_eq "$MAX_IDLE_SECONDS" 900 "idle cap"
}

run_case "parse_duration handles s/m/h and rejects junk" case_parse_duration
run_case "idle backoff: 1m, doubling, capped"            case_backoff_schedule_from_minimum_to_cap
run_case "a cap below the minimum still caps"            case_cap_below_minimum_wins
run_case "defaults: 1m start, 15m cap"                   case_defaults_are_gentle_on_github

if (( FAILURES )); then
  printf '\n%d test(s) failed\n' "$FAILURES"
  exit 1
fi
printf '\nall tests passed\n'
