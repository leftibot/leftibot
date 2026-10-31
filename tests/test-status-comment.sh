#!/usr/bin/env bash
# test-status-comment.sh — regression tests for the "I've started work" status comment (issue #2).
#
# Sources leftibot-tick.sh (without running main) and replaces `gh` with a stub that
# records every invocation, so no network access or authentication is needed.
#
# Usage: tests/test-status-comment.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK_SCRIPT="$TESTS_DIR/../bin/leftibot-tick.sh"

FAILURES=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# Runs one test case in a subshell with a fresh stub log.
#   $1 = test name, $2 = function holding the test body
run_case() {
  local name="$1" body="$2"
  local tmp
  tmp=$(mktemp -d)
  if (
    export LEFTIBOT_HOME="$tmp"
    GH_LOG="$tmp/gh.log"
    : > "$GH_LOG"
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

expect_log_contains() {
  if ! grep -qF -- "$1" "$GH_LOG"; then
    printf '  expected gh call containing: %s\n  got:\n' "$1"
    sed 's/^/    /' "$GH_LOG"
    return 1
  fi
}

expect_log_empty() {
  if [[ -s "$GH_LOG" ]]; then
    printf '  expected no gh calls, got:\n'
    sed 's/^/    /' "$GH_LOG"
    return 1
  fi
}

case_begin_posts_comment_and_remembers_id() {
  begin_status_comment "octo" "widgets" "7" "working on it" || return 1
  expect_log_contains "-X POST repos/octo/widgets/issues/7/comments" || return 1
  expect_log_contains "body=working on it" || return 1
  [[ "$STATUS_COMMENT_ID" == "4242" ]] || { echo "  STATUS_COMMENT_ID='$STATUS_COMMENT_ID'"; return 1; }
}

case_finish_edits_same_comment() {
  begin_status_comment "octo" "widgets" "7" "working on it" || return 1
  finish_status_comment "all done" || return 1
  expect_log_contains "-X PATCH repos/octo/widgets/issues/comments/4242" || return 1
  expect_log_contains "body=all done" || return 1
  [[ -z "$STATUS_COMMENT_ID" ]] || { echo "  STATUS_COMMENT_ID not cleared"; return 1; }
}

case_finish_without_begin_is_noop() {
  finish_status_comment "all done" || return 1
  expect_log_empty
}

case_dry_run_posts_nothing() {
  DRY_RUN=1
  begin_status_comment "octo" "widgets" "7" "working on it" || return 1
  finish_status_comment "all done" || return 1
  expect_log_empty
}

case_unexpected_exit_marks_comment_stopped() {
  begin_status_comment "octo" "widgets" "7" "working on it" || return 1
  on_exit_finalize_status_comment
  expect_log_contains "-X PATCH repos/octo/widgets/issues/comments/4242" || return 1
  [[ -z "$STATUS_COMMENT_ID" ]] || return 1
}

case_exit_trap_is_installed() {
  [[ "$(trap -p EXIT)" == *on_exit_finalize_status_comment* ]] \
    || { echo "  EXIT trap: $(trap -p EXIT)"; return 1; }
}

run_case "begin_status_comment posts a comment and remembers its id" case_begin_posts_comment_and_remembers_id
run_case "finish_status_comment edits the same comment"               case_finish_edits_same_comment
run_case "finish_status_comment without begin is a no-op"             case_finish_without_begin_is_noop
run_case "dry-run posts and edits nothing"                            case_dry_run_posts_nothing
run_case "unexpected exit marks the status comment as stopped"        case_unexpected_exit_marks_comment_stopped
run_case "EXIT trap finalizes a dangling status comment"              case_exit_trap_is_installed

if (( FAILURES )); then
  printf '\n%d test(s) failed\n' "$FAILURES"
  exit 1
fi
printf '\nall tests passed\n'
