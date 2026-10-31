#!/usr/bin/env bash
# test-readme.sh — verify README.md exists and stays in sync with bin/leftibot-tick.sh.
#
# Checks that the README documents every CLI flag the tick script parses,
# every command preflight requires, and every prompt template in prompts/.
#
# Usage:
#   tests/test-readme.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$REPO_ROOT/README.md"
TICK="$REPO_ROOT/bin/leftibot-tick.sh"

failures=0
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

expect_documented() {
  local needle="$1" what="$2"
  grep -qF -- "$needle" "$README" || fail "README.md does not mention $what '$needle'"
}

if [[ ! -f "$README" ]]; then
  fail "README.md is missing"
  exit 1
fi

# CLI flags: every case label in the tick script's argument parser
while IFS= read -r flag; do
  expect_documented "$flag" "flag"
done < <(sed -n '/^while \[\[ \$# -gt 0 \]\]/,/^done/p' "$TICK" \
           | grep -oE '^\s+--[a-z-]+(\|-[a-z])?\)' \
           | grep -oE -- '--[a-z-]+')

# Required commands checked by preflight
while IFS= read -r cmd; do
  expect_documented "$cmd" "required command"
done < <(grep -E '^\s+for cmd in ' "$TICK" | sed -E 's/.*for cmd in (.*); do/\1/' | tr ' ' '\n')

# Prompt templates
for prompt in "$REPO_ROOT"/prompts/*.md; do
  expect_documented "prompts/$(basename "$prompt")" "prompt template"
done

# Scripts
expect_documented "bin/leftibot-tick.sh" "script"
expect_documented "bin/leftibot-loop.sh" "script"

if (( failures )); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi
echo "README checks passed"
