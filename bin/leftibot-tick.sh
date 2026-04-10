#!/usr/bin/env bash
# leftibot-tick.sh — one tick of the leftibot autonomous issue-fixer + PR-reviewer
#
# Each tick picks up ONE task, in priority order:
#   1. PR reviews: leftibot's own open PRs where @lefticus @-mentioned @leftibot
#   2. Comment replies: @lefticus asked @leftibot a question (contains ?)
#   3. New issues: @lefticus told @leftibot to fix something
#
# DESIGNED TO BE RUN MANUALLY FIRST. Try:
#   ~/leftibot/bin/leftibot-tick.sh --verbose --dry-run
#   ~/leftibot/bin/leftibot-tick.sh --verbose --issue https://github.com/foo/bar/issues/42 --dry-run
#   ~/leftibot/bin/leftibot-tick.sh --verbose --pr https://github.com/foo/bar/pull/99 --dry-run
#   ~/leftibot/bin/leftibot-tick.sh
#
# Flags:
#   --verbose, -v         print debug info
#   --dry-run             do not fork, push, open PRs, post comments, mark notifications read
#   --issue <URL>         skip notification poll, work on this specific issue URL
#   --pr <URL>            skip notification poll, address review on this specific PR URL
#   --skip-trigger-check  bypass the "must be @-mentioned by lefticus" filter (TESTING ONLY)
#   --no-cleanup          leave the workdir behind for inspection (default: rm -rf at end)
#
# Cron entry (install once, after manual testing):
#   */15 * * * * flock -n ~/leftibot/state/tick.lock ~/leftibot/bin/leftibot-tick.sh >> ~/leftibot/logs/tick-$(date +\%Y-\%m-\%d).log 2>&1

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
LEFTIBOT_HOME="${LEFTIBOT_HOME:-$HOME/leftibot}"
STATE_DIR="$LEFTIBOT_HOME/state"
WORK_DIR="$LEFTIBOT_HOME/work"
LOG_DIR="$LEFTIBOT_HOME/logs"
ISSUE_PROMPT_FILE="$LEFTIBOT_HOME/prompts/fix-issue.md"
REVIEW_PROMPT_FILE="$LEFTIBOT_HOME/prompts/address-review.md"
COMMENT_PROMPT_FILE="$LEFTIBOT_HOME/prompts/comment-reply.md"
SEEN_FILE="$STATE_DIR/seen-issues.json"

TRIGGER_USER="lefticus"
BOT_USER="leftibot"
COOLDOWN_SECONDS=$((24 * 60 * 60))
CLAUDE_TIMEOUT="45m"

# ============================================================================
# CLI parsing
# ============================================================================
DRY_RUN=0
VERBOSE=0
ISSUE_OVERRIDE=""
PR_OVERRIDE=""
SKIP_TRIGGER_CHECK=0
NO_CLEANUP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)            DRY_RUN=1; shift ;;
    --verbose|-v)         VERBOSE=1; shift ;;
    --issue)              ISSUE_OVERRIDE="${2:-}"; shift 2 ;;
    --pr)                 PR_OVERRIDE="${2:-}"; shift 2 ;;
    --skip-trigger-check) SKIP_TRIGGER_CHECK=1; shift ;;
    --no-cleanup)         NO_CLEANUP=1; shift ;;
    -h|--help)
      sed -n '2,/^set -e/p' "$0" | sed 's/^# \?//' | sed '$d'
      exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2 ;;
  esac
done

# ============================================================================
# Logging
# ============================================================================
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
vlog() { if (( VERBOSE )); then log "DEBUG $*"; fi; }
die()  { log "FATAL $*"; exit 1; }

# ============================================================================
# Preflight
# ============================================================================
preflight() {
  local cmd
  for cmd in gh git claude jq cmake flock timeout python3; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
  done
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
  local current_user
  current_user=$(gh api user --jq .login 2>/dev/null) || die "gh api user failed"
  if [[ "$current_user" != "$BOT_USER" ]]; then
    die "gh authenticated as '$current_user', expected '$BOT_USER'"
  fi
  mkdir -p "$STATE_DIR" "$WORK_DIR" "$LOG_DIR" "$LEFTIBOT_HOME/prompts"
  [[ -f "$SEEN_FILE" ]] || echo '{}' > "$SEEN_FILE"
  [[ -f "$ISSUE_PROMPT_FILE" ]] || die "prompt template missing: $ISSUE_PROMPT_FILE"
  [[ -f "$REVIEW_PROMPT_FILE" ]] || die "prompt template missing: $REVIEW_PROMPT_FILE"
  [[ -f "$COMMENT_PROMPT_FILE" ]] || die "prompt template missing: $COMMENT_PROMPT_FILE"
}

# ============================================================================
# State helpers (seen-issues.json: { "<url>": { status, attempted_at, pr_url } })
# ============================================================================
seen_status() {
  jq -r --arg u "$1" '.[$u].status // ""' "$SEEN_FILE"
}

seen_attempted_at() {
  jq -r --arg u "$1" '.[$u].attempted_at // 0' "$SEEN_FILE"
}

mark_seen() {
  local url="$1" status="$2" pr_url="${3:-}"
  if (( DRY_RUN )); then
    vlog "[dry-run] would mark $url as $status (pr=$pr_url)"
    return
  fi
  local tmp
  tmp=$(mktemp)
  jq --arg u "$url" --arg s "$status" --arg p "$pr_url" --argjson t "$(date +%s)" \
    '.[$u] = {status:$s, attempted_at:$t, pr_url:$p}' \
    "$SEEN_FILE" > "$tmp"
  mv "$tmp" "$SEEN_FILE"
}

is_dedup_skip() {
  local url="$1" status now at
  status=$(seen_status "$url")
  case "$status" in
    done|draft-pr-opened) return 0 ;;
    in-progress|attempted-failed)
      at=$(seen_attempted_at "$url")
      now=$(date +%s)
      if (( now - at < COOLDOWN_SECONDS )); then return 0; else return 1; fi
      ;;
    *) return 1 ;;
  esac
}

# ============================================================================
# Notification helpers
# ============================================================================
mark_notification_read() {
  local thread_id="$1"
  if (( DRY_RUN )); then
    vlog "[dry-run] would mark notification thread $thread_id read"
    return
  fi
  gh api -X PATCH "notifications/threads/$thread_id" >/dev/null 2>&1 || true
}

# Check if lefticus @-mentioned leftibot in issue comments or issue body.
has_lefticus_mention_in_issue() {
  local issue_json="$1" comments_url="$2"
  local body_author body_text
  body_author=$(echo "$issue_json" | jq -r .user.login)
  body_text=$(echo "$issue_json" | jq -r '.body // ""')
  if [[ "$body_author" == "$TRIGGER_USER" ]] && grep -qiE "@$BOT_USER\\b" <<<"$body_text"; then
    return 0
  fi
  local comments hits
  comments=$(gh api "$comments_url" --paginate 2>/dev/null) || comments='[]'
  hits=$(echo "$comments" | jq --arg u "$TRIGGER_USER" --arg b "@$BOT_USER" \
    '[.[] | select(.user.login == $u and (.body | test($b + "\\b"; "i")))] | length')
  [[ "$hits" -gt 0 ]]
}

# Check if lefticus @-mentioned leftibot in PR comments (issue comments, review comments, or reviews).
has_lefticus_mention_in_pr() {
  local owner="$1" repo="$2" pr_number="$3"
  # Check issue comments on the PR
  local issue_comments
  issue_comments=$(gh api "repos/$owner/$repo/issues/$pr_number/comments" --paginate 2>/dev/null) || issue_comments='[]'
  local hits
  hits=$(echo "$issue_comments" | jq --arg u "$TRIGGER_USER" --arg b "@$BOT_USER" \
    '[.[] | select(.user.login == $u and (.body | test($b + "\\b"; "i")))] | length')
  if [[ "$hits" -gt 0 ]]; then return 0; fi
  # Check review comments (inline)
  local review_comments
  review_comments=$(gh api "repos/$owner/$repo/pulls/$pr_number/comments" --paginate 2>/dev/null) || review_comments='[]'
  hits=$(echo "$review_comments" | jq --arg u "$TRIGGER_USER" --arg b "@$BOT_USER" \
    '[.[] | select(.user.login == $u and (.body | test($b + "\\b"; "i")))] | length')
  if [[ "$hits" -gt 0 ]]; then return 0; fi
  # Check top-level reviews
  local reviews
  reviews=$(gh api "repos/$owner/$repo/pulls/$pr_number/reviews" --paginate 2>/dev/null) || reviews='[]'
  hits=$(echo "$reviews" | jq --arg u "$TRIGGER_USER" --arg b "@$BOT_USER" \
    '[.[] | select(.user.login == $u and (.body | test($b + "\\b"; "i")))] | length')
  [[ "$hits" -gt 0 ]]
}

# ============================================================================
# Candidate emission
# ============================================================================
emit_issue_candidate() {
  local thread_id="$1" issue="$2"
  local repo_full owner repo number title issue_url
  repo_full=$(echo "$issue" | jq -r '.repository_url | sub("https://api.github.com/repos/"; "")')
  owner=$(echo "$repo_full" | cut -d/ -f1)
  repo=$(echo "$repo_full" | cut -d/ -f2)
  number=$(echo "$issue" | jq -r .number)
  title=$(echo "$issue" | jq -r .title)
  issue_url=$(echo "$issue" | jq -r .html_url)
  jq -n --arg type "new-issue" --arg t "$thread_id" --arg u "$issue_url" \
        --arg o "$owner" --arg r "$repo" --argjson n "$number" --arg ti "$title" \
    '{type:$type, thread_id:$t, issue_url:$u, owner:$o, repo:$r, number:$n, title:$ti}'
}

emit_pr_review_candidate() {
  local thread_id="$1" pr="$2"
  local owner repo pr_number title pr_url head_branch head_repo
  owner=$(echo "$pr" | jq -r '.base.repo.owner.login')
  repo=$(echo "$pr" | jq -r '.base.repo.name')
  pr_number=$(echo "$pr" | jq -r .number)
  title=$(echo "$pr" | jq -r .title)
  pr_url=$(echo "$pr" | jq -r .html_url)
  head_branch=$(echo "$pr" | jq -r .head.ref)
  head_repo=$(echo "$pr" | jq -r '.head.repo.full_name')
  jq -n --arg type "pr-review" --arg t "$thread_id" --arg u "$pr_url" \
        --arg o "$owner" --arg r "$repo" --argjson n "$pr_number" --arg ti "$title" \
        --arg hb "$head_branch" --arg hr "$head_repo" \
    '{type:$type, thread_id:$t, pr_url:$u, owner:$o, repo:$r, number:$n, title:$ti, head_branch:$hb, head_repo:$hr}'
}

# Emit a comment-only candidate. context_type is "issue" or "pr".
emit_comment_candidate() {
  local thread_id="$1" context_type="$2" owner="$3" repo="$4" number="$5" title="$6" html_url="$7"
  jq -n --arg type "comment-only" --arg t "$thread_id" --arg ct "$context_type" \
        --arg o "$owner" --arg r "$repo" --argjson n "$number" --arg ti "$title" \
        --arg u "$html_url" \
    '{type:$type, thread_id:$t, context_type:$ct, owner:$o, repo:$r, number:$n, title:$ti, url:$u}'
}

# Given a JSON array of comments, find the lefticus @leftibot mention and return the body.
# Returns empty string if not found.
get_lefticus_trigger_text() {
  local comments_json="$1"
  echo "$comments_json" | jq -r --arg u "$TRIGGER_USER" --arg b "@$BOT_USER" \
    '[.[] | select(.user.login == $u and (.body | test($b + "\\b"; "i")))]
     | sort_by(.created_at) | last | (.body // "")' 2>/dev/null
}

# Returns 0 if the text looks like a question (contains ?), 1 otherwise.
is_question() {
  local text="$1"
  grep -q '?' <<<"$text"
}

# ============================================================================
# Notification scanning
# ============================================================================
# Returns JSON for the next task, or nothing.
# Priority: 1) PR reviews on own PRs  2) comment-only questions  3) new issue fixes
find_next_task() {
  local notifications
  notifications=$(gh api 'notifications?all=false' --paginate 2>/dev/null) \
    || die "failed to fetch notifications"
  local count
  count=$(echo "$notifications" | jq 'length')
  vlog "fetched $count unread notifications"

  # Accumulate candidates by type; emit highest priority at the end.
  local pr_review_cand="" comment_cand="" issue_cand=""

  local notif thread_id subject_url subject_type
  while IFS= read -r notif; do
    [[ -z "$notif" ]] && continue
    thread_id=$(echo "$notif" | jq -r .id)
    subject_url=$(echo "$notif" | jq -r .subject.url)
    subject_type=$(echo "$notif" | jq -r .subject.type)
    vlog "examining thread $thread_id → $subject_url ($subject_type)"

    if [[ "$subject_type" == "PullRequest" ]]; then
      local pr
      pr=$(gh api "$subject_url" 2>/dev/null) || { vlog "fetch failed"; continue; }
      local pr_state pr_author
      pr_state=$(echo "$pr" | jq -r .state)
      pr_author=$(echo "$pr" | jq -r .user.login)
      if [[ "$pr_state" != "open" ]]; then
        vlog "PR closed/merged, marking read"
        mark_notification_read "$thread_id"
        continue
      fi

      local pr_owner pr_repo pr_number pr_title pr_html_url
      pr_owner=$(echo "$pr" | jq -r '.base.repo.owner.login')
      pr_repo=$(echo "$pr" | jq -r '.base.repo.name')
      pr_number=$(echo "$pr" | jq -r .number)
      pr_title=$(echo "$pr" | jq -r .title)
      pr_html_url=$(echo "$pr" | jq -r .html_url)

      # Check for lefticus @-mention
      if (( ! SKIP_TRIGGER_CHECK )) && ! has_lefticus_mention_in_pr "$pr_owner" "$pr_repo" "$pr_number"; then
        vlog "no @$BOT_USER mention from $TRIGGER_USER in PR, marking read"
        mark_notification_read "$thread_id"
        continue
      fi

      if [[ "$pr_author" == "$BOT_USER" ]]; then
        # Leftibot's own PR → address review feedback
        if [[ -z "$pr_review_cand" ]]; then
          vlog "→ classified as pr-review (own PR)"
          pr_review_cand=$(emit_pr_review_candidate "$thread_id" "$pr")
        fi
      else
        # Someone else's PR → comment-only
        if [[ -z "$comment_cand" ]]; then
          vlog "→ classified as comment-only (other's PR)"
          comment_cand=$(emit_comment_candidate "$thread_id" "pr" "$pr_owner" "$pr_repo" "$pr_number" "$pr_title" "$pr_html_url")
        fi
      fi

    elif [[ "$subject_type" == "Issue" ]]; then
      local issue issue_url issue_state
      issue=$(gh api "$subject_url" 2>/dev/null) || { vlog "fetch failed"; continue; }
      issue_url=$(echo "$issue" | jq -r .html_url)
      issue_state=$(echo "$issue" | jq -r .state)
      if [[ "$issue_state" != "open" ]]; then
        vlog "issue closed, marking read"
        mark_notification_read "$thread_id"
        continue
      fi

      if (( ! SKIP_TRIGGER_CHECK )) && ! has_lefticus_mention_in_issue "$issue" "$subject_url/comments"; then
        vlog "no trigger from $TRIGGER_USER, marking read"
        mark_notification_read "$thread_id"
        continue
      fi

      if is_dedup_skip "$issue_url"; then
        vlog "issue already handled (status=$(seen_status "$issue_url")), marking read"
        mark_notification_read "$thread_id"
        continue
      fi

      # Classify: question (?) → comment-only, else → new-issue fix
      local issue_comments trigger_text
      issue_comments=$(gh api "$subject_url/comments" --paginate 2>/dev/null || echo '[]')
      trigger_text=$(get_lefticus_trigger_text "$issue_comments")
      # Also check the issue body if lefticus authored it
      if [[ -z "$trigger_text" || "$trigger_text" == "null" ]]; then
        local body_author
        body_author=$(echo "$issue" | jq -r .user.login)
        if [[ "$body_author" == "$TRIGGER_USER" ]]; then
          trigger_text=$(echo "$issue" | jq -r '.body // ""')
        fi
      fi

      local issue_owner issue_repo issue_number issue_title
      local repo_full
      repo_full=$(echo "$issue" | jq -r '.repository_url | sub("https://api.github.com/repos/"; "")')
      issue_owner=$(echo "$repo_full" | cut -d/ -f1)
      issue_repo=$(echo "$repo_full" | cut -d/ -f2)
      issue_number=$(echo "$issue" | jq -r .number)
      issue_title=$(echo "$issue" | jq -r .title)

      if is_question "$trigger_text"; then
        if [[ -z "$comment_cand" ]]; then
          vlog "→ classified as comment-only (question in trigger text)"
          comment_cand=$(emit_comment_candidate "$thread_id" "issue" "$issue_owner" "$issue_repo" "$issue_number" "$issue_title" "$issue_url")
        fi
      else
        if [[ -z "$issue_cand" ]]; then
          vlog "→ classified as new-issue"
          issue_cand=$(emit_issue_candidate "$thread_id" "$issue")
        fi
      fi
    fi
  done < <(echo "$notifications" | jq -c '.[] | select(.reason=="mention" or .reason=="comment" or .reason=="review_requested")')

  # Emit highest priority candidate
  if [[ -n "$pr_review_cand" ]]; then
    echo "$pr_review_cand"
  elif [[ -n "$comment_cand" ]]; then
    echo "$comment_cand"
  elif [[ -n "$issue_cand" ]]; then
    echo "$issue_cand"
  fi
}

# Manual overrides
fetch_issue_by_url() {
  local html_url="$1"
  local path
  path=$(sed -E 's|https?://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)|repos/\1/\2/issues/\3|' <<<"$html_url")
  local issue
  issue=$(gh api "$path" 2>/dev/null) || die "could not fetch $html_url"
  emit_issue_candidate "manual" "$issue"
}

fetch_pr_by_url() {
  local html_url="$1"
  local path
  path=$(sed -E 's|https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)|repos/\1/\2/pulls/\3|' <<<"$html_url")
  local pr
  pr=$(gh api "$path" 2>/dev/null) || die "could not fetch $html_url"
  emit_pr_review_candidate "manual" "$pr"
}

# ============================================================================
# Build system detection
# ============================================================================
detect_build_block() {
  local dir="$1"
  if [[ -f "$dir/CMakeLists.txt" ]]; then
    cat <<'EOF'
This is a CMake project. Use:
    cmake -B build -S .
    cmake --build build -j
    ctest --test-dir build --output-on-failure
EOF
  elif [[ -f "$dir/Cargo.toml" ]]; then
    echo "This is a Cargo project. Use: cargo test"
  elif [[ -f "$dir/package.json" ]]; then
    echo "This is an npm project. Use: npm install && npm test"
  elif [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
    echo "This is a Python project. Use: pip install -e . && pytest"
  else
    echo "# No build system auto-detected. Examine the README and .github/workflows/ to figure out how to build and test, then proceed."
  fi
}

# ============================================================================
# Prompt rendering (uses python3 for safe substitution — no shell quoting issues)
# ============================================================================
render_template() {
  # Usage: render_template <template_file> KEY1=val1 KEY2=val2 ...
  # All KEY=val pairs become template substitutions for {{KEY}}.
  local template_file="$1"; shift
  local -a env_args=()
  for kv in "$@"; do
    env_args+=("$kv")
  done
  env "${env_args[@]}" python3 - "$template_file" <<'PY'
import os, sys
text = open(sys.argv[1]).read()
# Replace any {{KEY}} with the env var KEY if set
import re
def replacer(m):
    return os.environ.get(m.group(1), m.group(0))
text = re.sub(r'\{\{(\w+)\}\}', replacer, text)
sys.stdout.write(text)
PY
}

# ============================================================================
# Shared helpers
# ============================================================================

# Extract the most recent @leftibot directive from lefticus across multiple comment sources.
# Args: JSON arrays piped in via process substitution or as args.
# Outputs the directive text and sets DIRECTIVE_SOURCE on stdout as two lines.
extract_lefticus_directive() {
  # Args: list of JSON arrays (issue comments, PR comments, reviews)
  # We merge them all and find the most recent one from lefticus mentioning leftibot.
  python3 - "$TRIGGER_USER" "$BOT_USER" "$@" <<'PY'
import json, sys, re

trigger_user = sys.argv[1]
bot_user = sys.argv[2]
files = sys.argv[3:]

all_comments = []
for f in files:
    try:
        data = json.loads(f)
        if isinstance(data, list):
            all_comments.extend(data)
        elif isinstance(data, dict):
            all_comments.append(data)
    except (json.JSONDecodeError, TypeError):
        pass

pattern = re.compile(r'@' + re.escape(bot_user) + r'\b', re.IGNORECASE)
matches = [
    c for c in all_comments
    if c.get('user', {}).get('login') == trigger_user
    and pattern.search(c.get('body', '') or '')
]

if matches:
    matches.sort(key=lambda c: c.get('created_at', ''))
    best = matches[-1]
    print(best.get('body', ''))
    print('---DIRECTIVE_SOURCE---')
    print(f"comment by @{trigger_user} at {best.get('created_at', 'unknown')}")
else:
    print('')
    print('---DIRECTIVE_SOURCE---')
    print('none found')
PY
}

parse_directive_output() {
  # Splits the output of extract_lefticus_directive into directive and source.
  local raw="$1"
  LEFTICUS_DIRECTIVE=$(echo "$raw" | sed '/^---DIRECTIVE_SOURCE---$/,$d')
  DIRECTIVE_SOURCE=$(echo "$raw" | sed -n '/^---DIRECTIVE_SOURCE---$/,$ { /^---DIRECTIVE_SOURCE---$/d; p; }')
  if [[ -z "$LEFTICUS_DIRECTIVE" ]]; then
    LEFTICUS_DIRECTIVE="(no explicit @$TRIGGER_USER directive found — proceed using the issue body and thread)"
    DIRECTIVE_SOURCE="none — fall back to issue body"
  fi
}

# Setup fork + clone + sync. Shared by both flows.
# Sets: workdir, default_branch (via nameref)
setup_workspace() {
  local owner="$1" repo="$2" label="$3"
  local _workdir="$WORK_DIR/$label"
  rm -rf "$_workdir"
  mkdir -p "$_workdir"

  local _default_branch
  _default_branch=$(gh api "repos/$owner/$repo" --jq .default_branch)
  vlog "upstream default branch: $_default_branch"

  local fork_exists=0
  if gh api "repos/$BOT_USER/$repo" >/dev/null 2>&1; then
    fork_exists=1
  fi

  if (( DRY_RUN )); then
    if (( fork_exists )); then
      vlog "[dry-run] fork $BOT_USER/$repo already exists"
    else
      log "[dry-run] would fork $owner/$repo → $BOT_USER/$repo"
    fi
  else
    if (( ! fork_exists )); then
      log "forking $owner/$repo → $BOT_USER/$repo"
      gh repo fork "$owner/$repo" --clone=false >/dev/null || die "fork failed (see stderr above)"
      local i
      for i in 1 2 3 4 5 6; do
        if gh api "repos/$BOT_USER/$repo" >/dev/null 2>&1; then fork_exists=1; break; fi
        sleep 2
      done
      (( fork_exists )) || die "fork did not appear after 12s"
    else
      vlog "fork $BOT_USER/$repo already exists"
    fi
  fi

  local clone_url clone_source
  if (( fork_exists )); then
    clone_url="git@github.com:$BOT_USER/$repo.git"
    clone_source="leftibot fork"
  else
    clone_url="https://github.com/$owner/$repo.git"
    clone_source="upstream (dry-run fallback)"
  fi
  log "cloning $clone_url into $_workdir  ($clone_source)"
  git clone --quiet "$clone_url" "$_workdir" || die "clone failed"
  ( cd "$_workdir"
    git remote add upstream "https://github.com/$owner/$repo.git" 2>/dev/null || true
    git fetch --quiet upstream "$_default_branch"
    # Sync fork's default branch to upstream
    git checkout "$_default_branch"
    git reset --hard "upstream/$_default_branch"
    if (( ! DRY_RUN )); then
      git push --quiet --force origin "$_default_branch"
    fi
    git config user.email "leftibot@users.noreply.github.com"
    git config user.name "leftibot"
  ) || die "workspace setup failed"

  # Return values via stdout (caller captures)
  echo "$_workdir"
  echo "$_default_branch"
}

invoke_claude() {
  local workdir="$1" rendered_prompt="$2" log_label="$3"
  if (( DRY_RUN )); then
    local prompt_dump="$LOG_DIR/dryrun-prompt-${log_label}.md"
    printf '%s' "$rendered_prompt" > "$prompt_dump"
    log "[dry-run] rendered prompt → $prompt_dump"
    log "[dry-run] would invoke: cd $workdir && timeout $CLAUDE_TIMEOUT claude --print --dangerously-skip-permissions"
    log "[dry-run] stopping here — workdir left at $workdir for inspection"
    return 99  # signal dry-run bail
  fi
  local claude_log
  claude_log="$LOG_DIR/claude-${log_label}-$(date +%s).log"
  log "invoking claude (timeout: $CLAUDE_TIMEOUT, log: $claude_log)…"
  set +e
  ( cd "$workdir" && timeout "$CLAUDE_TIMEOUT" claude --print --dangerously-skip-permissions <<<"$rendered_prompt" ) \
    > "$claude_log" 2>&1
  local claude_rc=$?
  set -e
  log "claude exited rc=$claude_rc"
  if (( VERBOSE )); then
    log "--- last 20 lines of claude output ---"
    tail -n 20 "$claude_log" | sed 's/^/  /'
    log "--- end ---"
  fi
  return 0
}

verify_fix() {
  local workdir="$1" base_ref="$2"
  set +e
  ( cd "$workdir"
    if [[ -z "$(git log --oneline "$base_ref..HEAD" 2>/dev/null)" ]]; then
      exit 10
    fi
    local diff_files
    diff_files=$(git diff --name-only "$base_ref...HEAD")
    if ! grep -Eqi 'test|spec' <<<"$diff_files"; then
      exit 11
    fi
    if [[ -f CMakeLists.txt ]]; then
      cmake -B build -S . >/dev/null 2>&1 || exit 12
      cmake --build build -j >/dev/null 2>&1 || exit 12
      ctest --test-dir build --output-on-failure >/dev/null 2>&1 || exit 13
    fi
    exit 0
  )
  local rc=$?
  set -e
  case $rc in
    0)  log "verify: OK"; echo "ok" ;;
    10) log "verify: FAIL — no commits"; echo "no-commit" ;;
    11) log "verify: FAIL — no test files modified"; echo "no-test" ;;
    12) log "verify: FAIL — build broken"; echo "build-fail" ;;
    13) log "verify: FAIL — tests failing"; echo "test-fail" ;;
    *)  log "verify: FAIL — unknown rc=$rc"; echo "unknown" ;;
  esac
}

# Build a rich PR body from the commit log and diff stats.
build_pr_body_content() {
  local workdir="$1" base_ref="$2"
  ( cd "$workdir"
    echo "### What changed"
    echo ""
    git log --format='%B' "$base_ref..HEAD" | sed '/^$/d' | sed 's/^/> /'
    echo ""
    echo "### Files"
    echo '```'
    git diff --stat "$base_ref...HEAD"
    echo '```'
  )
}

cleanup_workdir() {
  local workdir="$1"
  if (( ! NO_CLEANUP )); then
    rm -rf "$workdir"
  else
    log "leaving workdir at $workdir (--no-cleanup)"
  fi
}

# ============================================================================
# PR / comment helpers
# ============================================================================
open_pr() {
  local workdir="$1" owner="$2" repo="$3" number="$4" title="$5" branch="$6" base="$7" draft="$8" reason="${9:-}"
  local default_base_ref="upstream/$base"

  if (( DRY_RUN )); then
    log "[dry-run] would push and open $([[ $draft == 1 ]] && echo draft || echo regular) PR for $owner/$repo#$number"
    echo "https://example.invalid/dry-run-pr"
    return
  fi
  ( cd "$workdir" && git push --quiet --set-upstream origin "$branch" ) || die "push failed"

  local change_body
  change_body=$(build_pr_body_content "$workdir" "$default_base_ref")

  local pr_title pr_body
  if [[ "$draft" == "1" ]]; then
    pr_title="[WIP] Issue #$number — $title"
    local reason_text=""
    case "$reason" in
      no-test)     reason_text="no test files were detected in the diff" ;;
      build-fail)  reason_text="the project did not build successfully after the fix" ;;
      test-fail)   reason_text="one or more tests failed after the fix" ;;
      *)           reason_text="$reason" ;;
    esac
    pr_body="Automated attempt by @leftibot. Opening as **draft** — verification failed.

**Reason:** $reason_text

$change_body

Will close #$number once finalized.

_Triggered by @lefticus._"
    gh pr create --repo "$owner/$repo" --base "$base" --head "$BOT_USER:$branch" \
      --title "$pr_title" --body "$pr_body" --draft
  else
    pr_title="Fix #$number: $title"
    pr_body="Automated fix by @leftibot.

$change_body

Closes #$number

_Triggered by @lefticus._"
    gh pr create --repo "$owner/$repo" --base "$base" --head "$BOT_USER:$branch" \
      --title "$pr_title" --body "$pr_body"
  fi
}

post_giveup_comment() {
  local owner="$1" repo="$2" number="$3"
  if (( DRY_RUN )); then
    vlog "[dry-run] would post give-up comment on $owner/$repo#$number"
    return
  fi
  gh issue comment "$number" --repo "$owner/$repo" --body \
    "Hi @lefticus — I tried to work on this but couldn't make progress. Leaving for human review." \
    >/dev/null 2>&1 || true
}

# ============================================================================
# Flow 1: New issue → fix → PR
# ============================================================================
process_new_issue() {
  local cand="$1"
  local owner repo number title issue_url thread_id
  owner=$(echo "$cand" | jq -r .owner)
  repo=$(echo "$cand" | jq -r .repo)
  number=$(echo "$cand" | jq -r .number)
  title=$(echo "$cand" | jq -r .title)
  issue_url=$(echo "$cand" | jq -r .issue_url)
  thread_id=$(echo "$cand" | jq -r .thread_id)
  log "FLOW: new-issue — $owner/$repo#$number — $title"
  log "  url: $issue_url"

  mark_seen "$issue_url" "in-progress"

  local slug branch label
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-40)
  [[ -z "$slug" ]] && slug="untitled"
  branch="fix/issue-${number}-${slug}"
  label="${owner}-${repo}-${number}"

  local ws_output workdir default_branch
  ws_output=$(setup_workspace "$owner" "$repo" "$label")
  workdir=$(echo "$ws_output" | head -1)
  default_branch=$(echo "$ws_output" | tail -1)

  # Create feature branch
  ( cd "$workdir" && git checkout -b "$branch" "upstream/$default_branch" ) || die "branch create failed"

  # Issue body + comments
  local issue_full issue_body comments_json comments_text
  issue_full=$(gh api "repos/$owner/$repo/issues/$number")
  issue_body=$(echo "$issue_full" | jq -r '.body // "(no body)"')
  comments_json=$(gh api "repos/$owner/$repo/issues/$number/comments" --paginate 2>/dev/null || echo '[]')
  comments_text=$(echo "$comments_json" \
    | jq -r '.[] | "### @" + .user.login + " (" + .created_at + ")\n" + (.body // "")' 2>/dev/null \
    | head -c 32768)
  [[ -z "$comments_text" ]] && comments_text="(no comments)"

  # Directive from lefticus
  local raw_directive
  raw_directive=$(extract_lefticus_directive "$comments_json" \
    "$(echo "$issue_full" | jq -c '[{user: .user, body: .body, created_at: .created_at}]')")
  local LEFTICUS_DIRECTIVE DIRECTIVE_SOURCE
  parse_directive_output "$raw_directive"
  vlog "directive source: $DIRECTIVE_SOURCE"

  local build_block
  build_block=$(detect_build_block "$workdir")

  local rendered_prompt
  rendered_prompt=$(render_template "$ISSUE_PROMPT_FILE" \
    "OWNER=$owner" "REPO=$repo" "N=$number" "TITLE=$title" \
    "ISSUE_BODY=$issue_body" "COMMENTS=$comments_text" \
    "WORKDIR=$workdir" "BRANCH=$branch" "BUILD_BLOCK=$build_block" \
    "LEFTICUS_DIRECTIVE=$LEFTICUS_DIRECTIVE" "DIRECTIVE_SOURCE=$DIRECTIVE_SOURCE")

  invoke_claude "$workdir" "$rendered_prompt" "$label" || { cleanup_workdir "$workdir"; return 0; }

  local verify_status
  verify_status=$(verify_fix "$workdir" "upstream/$default_branch")

  local pr_url=""
  case "$verify_status" in
    ok)
      pr_url=$(open_pr "$workdir" "$owner" "$repo" "$number" "$title" "$branch" "$default_branch" 0)
      log "opened PR: $pr_url"
      mark_seen "$issue_url" "done" "$pr_url"
      ;;
    no-test|build-fail|test-fail)
      pr_url=$(open_pr "$workdir" "$owner" "$repo" "$number" "$title" "$branch" "$default_branch" 1 "$verify_status")
      log "opened DRAFT PR: $pr_url"
      mark_seen "$issue_url" "draft-pr-opened" "$pr_url"
      ;;
    no-commit|*)
      log "nothing committed — not opening PR"
      post_giveup_comment "$owner" "$repo" "$number"
      mark_seen "$issue_url" "attempted-failed"
      ;;
  esac

  mark_notification_read "$thread_id"
  cleanup_workdir "$workdir"
  log "tick complete — flow=new-issue status=$verify_status pr=$pr_url"
}

# ============================================================================
# Flow 2: PR review feedback → address → push
# ============================================================================
process_pr_review() {
  local cand="$1"
  local owner repo pr_number title pr_url thread_id head_branch head_repo
  owner=$(echo "$cand" | jq -r .owner)
  repo=$(echo "$cand" | jq -r .repo)
  pr_number=$(echo "$cand" | jq -r .number)
  title=$(echo "$cand" | jq -r .title)
  pr_url=$(echo "$cand" | jq -r .pr_url)
  thread_id=$(echo "$cand" | jq -r .thread_id)
  head_branch=$(echo "$cand" | jq -r .head_branch)
  head_repo=$(echo "$cand" | jq -r .head_repo)
  log "FLOW: pr-review — $owner/$repo#$pr_number — $title"
  log "  url: $pr_url"
  log "  branch: $head_branch (on $head_repo)"

  local label="${owner}-${repo}-pr-${pr_number}"
  local workdir="$WORK_DIR/$label"
  rm -rf "$workdir"
  mkdir -p "$workdir"

  # Clone from the fork (where the PR branch lives)
  local clone_url="git@github.com:${head_repo}.git"
  log "cloning $clone_url into $workdir"
  git clone --quiet "$clone_url" "$workdir" || die "clone failed"
  ( cd "$workdir"
    git remote add upstream "https://github.com/$owner/$repo.git" 2>/dev/null || true
    git fetch --quiet upstream
    git checkout "$head_branch" || die "could not check out $head_branch"
    git config user.email "leftibot@users.noreply.github.com"
    git config user.name "leftibot"
  ) || die "workspace setup failed"

  # Gather all review feedback
  local issue_comments review_comments reviews pr_body_text
  issue_comments=$(gh api "repos/$owner/$repo/issues/$pr_number/comments" --paginate 2>/dev/null || echo '[]')
  review_comments=$(gh api "repos/$owner/$repo/pulls/$pr_number/comments" --paginate 2>/dev/null || echo '[]')
  reviews=$(gh api "repos/$owner/$repo/pulls/$pr_number/reviews" --paginate 2>/dev/null || echo '[]')

  local pr_full
  pr_full=$(gh api "repos/$owner/$repo/pulls/$pr_number")
  pr_body_text=$(echo "$pr_full" | jq -r '.body // "(no body)"')

  # Build a unified conversation thread
  local all_comments_text
  all_comments_text=$(
    echo "$issue_comments" | jq -r '.[] | "### [comment] @" + .user.login + " (" + .created_at + ")\n" + (.body // "")' 2>/dev/null
    echo "$review_comments" | jq -r '.[] | "### [inline on " + .path + ":" + (.line // .original_line | tostring) + "] @" + .user.login + " (" + .created_at + ")\n" + (.body // "")' 2>/dev/null
    echo "$reviews" | jq -r '.[] | select(.body != null and .body != "") | "### [review " + .state + "] @" + .user.login + " (" + .submitted_at + ")\n" + .body' 2>/dev/null
  ) | head -c 32768
  [[ -z "$all_comments_text" ]] && all_comments_text="(no review comments)"

  # Directive from lefticus
  local raw_directive
  raw_directive=$(extract_lefticus_directive "$issue_comments" "$review_comments" "$reviews")
  local LEFTICUS_DIRECTIVE DIRECTIVE_SOURCE
  parse_directive_output "$raw_directive"
  vlog "directive source: $DIRECTIVE_SOURCE"

  local build_block
  build_block=$(detect_build_block "$workdir")

  local default_branch
  default_branch=$(echo "$pr_full" | jq -r .base.ref)

  local rendered_prompt
  rendered_prompt=$(render_template "$REVIEW_PROMPT_FILE" \
    "OWNER=$owner" "REPO=$repo" "PR_NUMBER=$pr_number" "TITLE=$title" \
    "PR_BODY=$pr_body_text" "COMMENTS=$all_comments_text" \
    "WORKDIR=$workdir" "BRANCH=$head_branch" "BUILD_BLOCK=$build_block" \
    "LEFTICUS_DIRECTIVE=$LEFTICUS_DIRECTIVE" "DIRECTIVE_SOURCE=$DIRECTIVE_SOURCE")

  invoke_claude "$workdir" "$rendered_prompt" "$label" || { cleanup_workdir "$workdir"; return 0; }

  # For PR reviews: verify there are new commits on the branch
  local has_new_commits=0
  ( cd "$workdir"
    local remote_head local_head
    remote_head=$(git rev-parse "origin/$head_branch")
    local_head=$(git rev-parse HEAD)
    [[ "$remote_head" != "$local_head" ]]
  ) && has_new_commits=1

  if (( has_new_commits )); then
    if (( DRY_RUN )); then
      log "[dry-run] would push new commits to $head_branch"
    else
      ( cd "$workdir" && git push --quiet origin "$head_branch" ) || die "push failed"
      log "pushed review fixes to $pr_url"
      # Post a comment on the PR saying what was addressed
      local commit_summary
      commit_summary=$(cd "$workdir" && git log --oneline "origin/$head_branch..HEAD" | head -5)
      gh pr comment "$pr_number" --repo "$owner/$repo" --body \
        "Addressed review feedback from @lefticus. New commits:
\`\`\`
$commit_summary
\`\`\`" >/dev/null 2>&1 || true
    fi
  else
    log "no new commits after review — Claude may have been unable to address the feedback"
    if (( ! DRY_RUN )); then
      gh pr comment "$pr_number" --repo "$owner/$repo" --body \
        "Hi @lefticus — I tried to address the review feedback but couldn't produce a working change. May need human attention." \
        >/dev/null 2>&1 || true
    fi
  fi

  mark_notification_read "$thread_id"
  cleanup_workdir "$workdir"
  log "tick complete — flow=pr-review has_new_commits=$has_new_commits"
}

# ============================================================================
# Flow 3: Comment-only → read code, think, reply
# ============================================================================
process_comment_request() {
  local cand="$1"
  local owner repo number title url thread_id context_type
  owner=$(echo "$cand" | jq -r .owner)
  repo=$(echo "$cand" | jq -r .repo)
  number=$(echo "$cand" | jq -r .number)
  title=$(echo "$cand" | jq -r .title)
  url=$(echo "$cand" | jq -r .url)
  thread_id=$(echo "$cand" | jq -r .thread_id)
  context_type=$(echo "$cand" | jq -r .context_type)
  log "FLOW: comment-only — $owner/$repo#$number ($context_type) — $title"
  log "  url: $url"

  local label="${owner}-${repo}-comment-${number}"
  local workdir="$WORK_DIR/$label"
  rm -rf "$workdir"
  mkdir -p "$workdir"

  # Clone upstream directly (read-only, no fork needed for commenting)
  log "cloning https://github.com/$owner/$repo.git into $workdir (read-only for comment)"
  git clone --quiet "https://github.com/$owner/$repo.git" "$workdir" || die "clone failed"

  # Gather context based on type
  local context_body comments_text comments_json
  if [[ "$context_type" == "issue" ]]; then
    local issue_full
    issue_full=$(gh api "repos/$owner/$repo/issues/$number")
    context_body=$(echo "$issue_full" | jq -r '.body // "(no body)"')
    comments_json=$(gh api "repos/$owner/$repo/issues/$number/comments" --paginate 2>/dev/null || echo '[]')
    comments_text=$(echo "$comments_json" \
      | jq -r '.[] | "### @" + .user.login + " (" + .created_at + ")\n" + (.body // "")' 2>/dev/null \
      | head -c 32768)
  elif [[ "$context_type" == "pr" ]]; then
    local pr_full
    pr_full=$(gh api "repos/$owner/$repo/pulls/$number")
    context_body=$(echo "$pr_full" | jq -r '.body // "(no body)"')
    local issue_comments review_comments reviews
    issue_comments=$(gh api "repos/$owner/$repo/issues/$number/comments" --paginate 2>/dev/null || echo '[]')
    review_comments=$(gh api "repos/$owner/$repo/pulls/$number/comments" --paginate 2>/dev/null || echo '[]')
    reviews=$(gh api "repos/$owner/$repo/pulls/$number/reviews" --paginate 2>/dev/null || echo '[]')
    comments_json="$issue_comments"
    comments_text=$(
      echo "$issue_comments" | jq -r '.[] | "### [comment] @" + .user.login + " (" + .created_at + ")\n" + (.body // "")' 2>/dev/null
      echo "$review_comments" | jq -r '.[] | "### [inline on " + .path + "] @" + .user.login + " (" + .created_at + ")\n" + (.body // "")' 2>/dev/null
      echo "$reviews" | jq -r '.[] | select(.body != null and .body != "") | "### [review " + .state + "] @" + .user.login + " (" + .submitted_at + ")\n" + .body' 2>/dev/null
    ) | head -c 32768
  fi
  [[ -z "$comments_text" ]] && comments_text="(no comments)"

  # Directive from lefticus
  local raw_directive
  if [[ "$context_type" == "pr" ]]; then
    raw_directive=$(extract_lefticus_directive "$issue_comments" "$review_comments" "$reviews")
  else
    raw_directive=$(extract_lefticus_directive "$comments_json" \
      "$(gh api "repos/$owner/$repo/issues/$number" 2>/dev/null | jq -c '[{user: .user, body: .body, created_at: .created_at}]')")
  fi
  local LEFTICUS_DIRECTIVE DIRECTIVE_SOURCE
  parse_directive_output "$raw_directive"
  vlog "directive source: $DIRECTIVE_SOURCE"

  local build_block
  build_block=$(detect_build_block "$workdir")

  local rendered_prompt
  rendered_prompt=$(render_template "$COMMENT_PROMPT_FILE" \
    "OWNER=$owner" "REPO=$repo" "N=$number" "TITLE=$title" \
    "CONTEXT_TYPE=$context_type" "CONTEXT_BODY=$context_body" \
    "COMMENTS=$comments_text" "WORKDIR=$workdir" "BUILD_BLOCK=$build_block" \
    "LEFTICUS_DIRECTIVE=$LEFTICUS_DIRECTIVE" "DIRECTIVE_SOURCE=$DIRECTIVE_SOURCE")

  if (( DRY_RUN )); then
    local prompt_dump="$LOG_DIR/dryrun-prompt-${label}.md"
    printf '%s' "$rendered_prompt" > "$prompt_dump"
    log "[dry-run] rendered prompt → $prompt_dump"
    log "[dry-run] would invoke claude, extract comment, post to $owner/$repo#$number"
    log "[dry-run] stopping here"
    cleanup_workdir "$workdir"
    return 0
  fi

  local claude_log
  claude_log="$LOG_DIR/claude-${label}-$(date +%s).log"
  log "invoking claude (timeout: $CLAUDE_TIMEOUT, log: $claude_log)…"
  local claude_output
  set +e
  claude_output=$( cd "$workdir" && timeout "$CLAUDE_TIMEOUT" claude --print --dangerously-skip-permissions <<<"$rendered_prompt" 2>"$claude_log" )
  local claude_rc=$?
  set -e
  log "claude exited rc=$claude_rc"

  # Extract comment between markers
  local comment_text
  comment_text=$(echo "$claude_output" | sed -n '/^---BEGIN COMMENT---$/,/^---END COMMENT---$/ { /^---BEGIN COMMENT---$/d; /^---END COMMENT---$/d; p; }')

  if [[ -z "$comment_text" ]]; then
    log "could not extract comment from claude output — no markers found"
    if (( VERBOSE )); then
      log "--- last 30 lines of claude output ---"
      echo "$claude_output" | tail -30 | sed 's/^/  /' >&2
      log "--- end ---"
    fi
    # Fall back: use the last substantial paragraph
    comment_text=$(echo "$claude_output" | tail -20)
    if [[ -z "$comment_text" ]]; then
      log "no output at all — posting fallback"
      comment_text="I looked at this but wasn't able to formulate a clear response. @lefticus may want to take another look."
    fi
  fi

  # Post the comment
  if [[ "$context_type" == "issue" ]]; then
    gh issue comment "$number" --repo "$owner/$repo" --body "$comment_text" >/dev/null 2>&1 \
      || log "WARNING: failed to post issue comment"
  else
    gh pr comment "$number" --repo "$owner/$repo" --body "$comment_text" >/dev/null 2>&1 \
      || log "WARNING: failed to post PR comment"
  fi
  log "posted comment on $owner/$repo#$number"

  mark_notification_read "$thread_id"
  cleanup_workdir "$workdir"
  log "tick complete — flow=comment-only"
}

# ============================================================================
# Main
# ============================================================================
main() {
  preflight
  log "leftibot tick starting (dry_run=$DRY_RUN verbose=$VERBOSE skip_trigger_check=$SKIP_TRIGGER_CHECK)"

  local cand
  if [[ -n "$PR_OVERRIDE" ]]; then
    log "manual PR override: $PR_OVERRIDE"
    cand=$(fetch_pr_by_url "$PR_OVERRIDE")
  elif [[ -n "$ISSUE_OVERRIDE" ]]; then
    log "manual issue override: $ISSUE_OVERRIDE"
    cand=$(fetch_issue_by_url "$ISSUE_OVERRIDE")
  else
    cand=$(find_next_task)
  fi

  if [[ -z "$cand" || "$cand" == "null" ]]; then
    log "no work to do"
    exit 0
  fi

  local task_type
  task_type=$(echo "$cand" | jq -r .type)
  case "$task_type" in
    new-issue)     process_new_issue "$cand" ;;
    pr-review)     process_pr_review "$cand" ;;
    comment-only)  process_comment_request "$cand" ;;
    *)             die "unknown task type: $task_type" ;;
  esac
}

main "$@"
