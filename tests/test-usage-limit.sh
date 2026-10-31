#!/usr/bin/env bash
# test-usage-limit.sh — the bot must pause, not post failures, when Claude is out of usage.
#
# Sources leftibot-tick.sh / leftibot-loop.sh (without running main) and replaces `gh`
# with a stub that records every call, so no network access or authentication is needed.
#
# Usage: tests/test-usage-limit.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK_SCRIPT="$TESTS_DIR/../bin/leftibot-tick.sh"
LOOP_SCRIPT="$TESTS_DIR/../bin/leftibot-loop.sh"

FAILURES=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

LIMIT_MSG="You've hit your 5-hour limit · resets 3:10pm (America/Denver)"

run_case() {
  local name="$1" body="$2"
  local tmp
  tmp=$(mktemp -d)
  if (
    export LEFTIBOT_HOME="$tmp"
    GH_LOG="$tmp/gh.log"
    : > "$GH_LOG"
    mkdir -p "$tmp/state" "$tmp/work" "$tmp/logs"
    set --
    # shellcheck source=../bin/leftibot-tick.sh
    source "$TICK_SCRIPT"
    set +e
    gh() {
      printf '%s\n' "$*" >> "$GH_LOG"
      if [[ "$*" == *"-X POST"*"/comments"* ]]; then echo "4242"; fi
      return 0
    }
    "$body"
  ); then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmp"
}

expect_eq() {
  [[ "$1" == "$2" ]] || { printf '  expected %s, got %s (%s)\n' "$2" "$1" "${3:-}"; return 1; }
}
expect_gh_contains() {
  grep -qF -- "$1" "$GH_LOG" || { printf '  expected gh call: %s\n  got:\n' "$1"; sed 's/^/    /' "$GH_LOG"; return 1; }
}
expect_gh_lacks() {
  ! grep -qF -- "$1" "$GH_LOG" || { printf '  unexpected gh call: %s\n  got:\n' "$1"; sed 's/^/    /' "$GH_LOG"; return 1; }
}
epoch() { TZ="$1" date -d "$2" +%s; }

# --- detection ---------------------------------------------------------------

case_detects_limit_message() {
  expect_eq "$(detect_usage_limit "some noise
$LIMIT_MSG")" "$LIMIT_MSG" "5-hour limit line" || return 1
  detect_usage_limit "Claude AI usage limit reached|1793470000" >/dev/null || { echo "  legacy format missed"; return 1; }
  detect_usage_limit "You've hit your weekly limit · resets Nov 3, 9am (America/Denver)" >/dev/null \
    || { echo "  weekly limit missed"; return 1; }
}

case_ignores_normal_output() {
  ! detect_usage_limit "RESULT: fixed — added a rate limiter and documented usage limits in README" >/dev/null \
    || { echo "  false positive on normal output"; return 1; }
}

# --- reset time --------------------------------------------------------------

case_reset_later_today() {
  local now; now=$(epoch America/Denver "2026-10-31 12:00")
  expect_eq "$(usage_limit_reset_epoch "$LIMIT_MSG" "$now")" \
    "$(( $(epoch America/Denver "2026-10-31 15:10") + 60 ))" "3:10pm today + 1m buffer"
}

case_reset_rolls_to_tomorrow() {
  # Reset window crosses midnight (and the Nov 1 DST change): 3am is tomorrow.
  local now; now=$(epoch America/Denver "2026-10-31 23:00")
  expect_eq "$(usage_limit_reset_epoch "You've hit your 5-hour limit · resets 3am (America/Denver)" "$now")" \
    "$(( $(epoch America/Denver "2026-11-01 03:00") + 60 ))" "3am seen at 11pm → tomorrow"
}

case_reset_just_passed_is_imminent_not_tomorrow() {
  # Claude rounds to the minute; "resets 3:10pm" seen at 3:13pm means "now", not in 24h.
  local now; now=$(epoch America/Denver "2026-10-31 15:13")
  expect_eq "$(usage_limit_reset_epoch "$LIMIT_MSG" "$now")" "$((now + 300))" "recent past → 5m retry"
}

case_reset_with_date() {
  local now; now=$(epoch America/Denver "2026-10-31 12:00")
  expect_eq "$(usage_limit_reset_epoch "You've hit your weekly limit · resets Nov 3, 9am (America/Denver)" "$now")" \
    "$(( $(epoch America/Denver "2026-11-03 09:00") + 60 ))" "dated reset"
}

case_reset_legacy_epoch() {
  expect_eq "$(usage_limit_reset_epoch "Claude AI usage limit reached|1793470000" 1793460000)" \
    "$((1793470000 + 60))" "legacy epoch format"
}

case_reset_unparseable_falls_back() {
  expect_eq "$(usage_limit_reset_epoch "You've hit your limit" 1000)" "$((1000 + 1800))" "30m fallback"
}

# --- pausing a tick ----------------------------------------------------------

case_abort_pauses_without_failure_comments() {
  local url="https://github.com/octo/widgets/issues/7"
  echo '{}' > "$SEEN_FILE"
  remember_seen_for_restore "$url"
  mark_seen "$url" "in-progress"
  begin_status_comment "octo" "widgets" "7" "👀 started"
  mkdir -p "$WORK_DIR/octo-widgets-7"
  local rc
  ( abort_for_usage_limit "$LIMIT_MSG" "$WORK_DIR/octo-widgets-7" ); rc=$?
  expect_eq "$rc" "20" "exit code" || return 1
  expect_gh_contains "-X DELETE repos/octo/widgets/issues/comments/4242" || return 1
  expect_gh_lacks "-X PATCH" || return 1
  expect_gh_lacks "notifications/threads" || return 1
  expect_eq "$(jq -c --arg u "$url" '.[$u]' "$SEEN_FILE")" "null" "seen entry restored" || return 1
  [[ -s "$USAGE_LIMIT_FILE" ]] || { echo "  pause file not written"; return 1; }
  [[ ! -d "$WORK_DIR/octo-widgets-7" ]] || { echo "  workdir not cleaned"; return 1; }
}

case_abort_restores_previous_seen_status() {
  local url="https://github.com/octo/widgets/issues/7"
  echo "{\"$url\":{\"status\":\"attempted-failed\",\"attempted_at\":5,\"pr_url\":\"\"}}" > "$SEEN_FILE"
  remember_seen_for_restore "$url"
  mark_seen "$url" "in-progress"
  ( abort_for_usage_limit "$LIMIT_MSG" "" )
  expect_eq "$(jq -c --arg u "$url" '.[$u]' "$SEEN_FILE")" \
    '{"status":"attempted-failed","attempted_at":5,"pr_url":""}' "previous entry"
}

case_paused_tick_exits_without_touching_github() {
  echo $(( $(date +%s) + 600 )) > "$USAGE_LIMIT_FILE"
  local rc
  ( check_usage_limit_pause ); rc=$?
  expect_eq "$rc" "20" "exit code while paused" || return 1
  [[ ! -s "$GH_LOG" ]] || { echo "  gh was called while paused"; return 1; }
}

case_expired_pause_is_cleared() {
  echo $(( $(date +%s) - 5 )) > "$USAGE_LIMIT_FILE"
  ( check_usage_limit_pause ) || { echo "  expired pause still blocks"; return 1; }
  [[ ! -e "$USAGE_LIMIT_FILE" ]] || { echo "  expired pause file left behind"; return 1; }
}

case_invoke_claude_detects_limit() {
  claude() { echo "$LIMIT_MSG"; return 1; }
  timeout() { shift; "$@"; }
  mkdir -p "$WORK_DIR/w"
  local rc
  ( invoke_claude "$WORK_DIR/w" "prompt" "octo-widgets-7" ); rc=$?
  expect_eq "$rc" "20" "invoke_claude exit on limit" || return 1
  [[ -s "$USAGE_LIMIT_FILE" ]] || { echo "  pause file not written"; return 1; }
}

# --- loop --------------------------------------------------------------------

case_loop_waits_until_reset() {
  # shellcheck source=../bin/leftibot-loop.sh
  source "$LOOP_SCRIPT"
  expect_eq "$(usage_limit_wait 5000 1000)" 4000 "wait until reset" || return 1
  expect_eq "$(usage_limit_wait 1010 1000)" 60 "at least the idle minimum" || return 1
  expect_eq "$(usage_limit_wait "" 1000)" 900 "no reset time → idle cap"
}

run_case "detects the usage-limit message"                     case_detects_limit_message
run_case "does not flag normal output that mentions limits"    case_ignores_normal_output
run_case "reset time later today"                              case_reset_later_today
run_case "reset time already passed rolls to tomorrow"         case_reset_rolls_to_tomorrow
run_case "reset time that just passed retries in 5m"          case_reset_just_passed_is_imminent_not_tomorrow
run_case "reset time with a date"                              case_reset_with_date
run_case "legacy limit|epoch format"                           case_reset_legacy_epoch
run_case "unparseable reset falls back to 30m"                 case_reset_unparseable_falls_back
run_case "limit hit: delete status comment, keep notification" case_abort_pauses_without_failure_comments
run_case "limit hit: previous dedup state is restored"         case_abort_restores_previous_seen_status
run_case "paused tick exits 20 without calling GitHub"         case_paused_tick_exits_without_touching_github
run_case "expired pause is cleared"                            case_expired_pause_is_cleared
run_case "invoke_claude pauses when claude is out of usage"    case_invoke_claude_detects_limit
run_case "loop sleeps until the reset time"                    case_loop_waits_until_reset

if (( FAILURES )); then
  printf '\n%d test(s) failed\n' "$FAILURES"
  exit 1
fi
printf '\nall tests passed\n'
