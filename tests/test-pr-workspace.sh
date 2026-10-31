#!/usr/bin/env bash
# test-pr-workspace.sh — regression tests for setup_pr_workspace (PR-review flow checkout).
#
# Uses local bare repos as remotes, so no network access or authentication is needed.
# Covers the same-repo PR case (head repo == base repo, e.g. leftibot/leftibot#3), where
# `origin` and `upstream` both carry the PR branch and a plain `git checkout <branch>`
# fails with "matched multiple (2) remote tracking branches".
#
# Usage: tests/test-pr-workspace.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICK_SCRIPT="$TESTS_DIR/../bin/leftibot-tick.sh"

FAILURES=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

BRANCH="fix/issue-1-add-a-readme"

# Creates a bare repo at $1 with a main commit and a $BRANCH commit on top.
make_remote() {
  local bare="$1" seed
  seed=$(mktemp -d)
  git init --quiet -b main "$seed"
  git -C "$seed" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m base
  git -C "$seed" checkout --quiet -b "$BRANCH"
  git -C "$seed" -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m "pr work"
  git -C "$seed" checkout --quiet main   # remote HEAD → main, like a real GitHub repo
  git clone --quiet --bare "$seed" "$bare"
  rm -rf "$seed"
}

# Runs one test case in a subshell with the tick script sourced.
#   $1 = test name, $2 = function holding the test body
run_case() {
  local name="$1" body="$2"
  local tmp
  tmp=$(mktemp -d)
  if (
    export LEFTIBOT_HOME="$tmp"
    TMP="$tmp"
    set --
    # shellcheck source=../bin/leftibot-tick.sh
    source "$TICK_SCRIPT"
    set +e
    trap - EXIT
    "$body"
  ); then
    pass "$name"
  else
    fail "$name"
  fi
  rm -rf "$tmp"
}

expect_on_pr_branch() {
  local workdir="$1" expected_sha="$2" head
  head=$(git -C "$workdir" symbolic-ref --short HEAD 2>/dev/null)
  [[ "$head" == "$BRANCH" ]] || { echo "  HEAD is '$head', expected '$BRANCH'"; return 1; }
  [[ "$(git -C "$workdir" rev-parse HEAD)" == "$expected_sha" ]] \
    || { echo "  HEAD sha does not match origin/$BRANCH"; return 1; }
  [[ "$(git -C "$workdir" rev-parse --abbrev-ref '@{upstream}')" == "origin/$BRANCH" ]] \
    || { echo "  branch does not track origin/$BRANCH"; return 1; }
}

case_fork_pr_checks_out_branch() {
  make_remote "$TMP/fork.git"
  make_remote "$TMP/base.git"
  git -C "$TMP/base.git" branch --quiet -D "$BRANCH"   # base repo lacks the PR branch
  setup_pr_workspace "$TMP/work" "$TMP/fork.git" "$TMP/base.git" "$BRANCH" || return 1
  expect_on_pr_branch "$TMP/work" "$(git -C "$TMP/fork.git" rev-parse "$BRANCH")"
}

case_same_repo_pr_checks_out_branch() {
  make_remote "$TMP/repo.git"
  # origin and upstream are the same repo, so both carry the PR branch
  setup_pr_workspace "$TMP/work" "$TMP/repo.git" "$TMP/repo.git" "$BRANCH" || return 1
  expect_on_pr_branch "$TMP/work" "$(git -C "$TMP/repo.git" rev-parse "$BRANCH")"
}

case_sets_bot_identity() {
  make_remote "$TMP/repo.git"
  setup_pr_workspace "$TMP/work" "$TMP/repo.git" "$TMP/repo.git" "$BRANCH" || return 1
  [[ "$(git -C "$TMP/work" config user.name)" == "leftibot" ]] || { echo "  user.name not set"; return 1; }
  [[ "$(git -C "$TMP/work" config user.email)" == "leftibot@users.noreply.github.com" ]] \
    || { echo "  user.email not set"; return 1; }
}

run_case "fork PR: checks out the PR branch from origin"           case_fork_pr_checks_out_branch
run_case "same-repo PR: checks out despite branch on both remotes" case_same_repo_pr_checks_out_branch
run_case "workspace gets the leftibot commit identity"             case_sets_bot_identity

if (( FAILURES )); then
  printf '\n%d test(s) failed\n' "$FAILURES"
  exit 1
fi
printf '\nall tests passed\n'
