# leftibot

leftibot is the automated assistant of Jason Turner ([@lefticus](https://github.com/lefticus)).
It watches the GitHub notifications of the `leftibot` account. When @lefticus
@-mentions `@leftibot` on an issue or pull request, it hands the task to
[Claude Code](https://claude.com/claude-code), checks the result, and publishes
it as a pull request or a comment.

leftibot only acts on mentions from @lefticus. Mentions from anyone else are
ignored and their notifications are marked read.

## What it does

Each run of `bin/leftibot-tick.sh` (a "tick") picks up **one** task, in this
priority order:

1. **PR review**: @lefticus left feedback (not a question) on one of
   leftibot's own open PRs. leftibot addresses the feedback and pushes new
   commits to the PR branch.
2. **Comment reply**: @lefticus asked leftibot a question (the mention contains
   a `?`) on an issue or PR. leftibot answers with a comment and pushes no code.
   Mentions on PRs that leftibot didn't open are always handled this way.
3. **New issue**: @lefticus told leftibot to fix an issue. leftibot forks the
   repository, writes a failing regression test, makes the fix, and opens a PR.

### The issue-fix flow

1. Fork `owner/repo` to `leftibot/repo` if needed, clone it into
   `work/<owner>-<repo>-<number>`, and sync the fork's default branch with
   upstream.
2. Create a branch named `fix/issue-<number>-<slug>`.
3. Fill in the `prompts/fix-issue.md` template with the issue, the thread,
   the latest @lefticus directive, and build instructions for the detected
   build system (CMake, Cargo, npm, or Python), then run Claude Code on it.
4. Check the result:
   - at least one commit was made,
   - the diff touches a test or spec file,
   - for CMake projects, the project configures, builds, and `ctest` passes.
5. Publish:
   - all checks pass → a regular PR;
   - no test, broken build, or failing tests → a **draft** PR that says why;
   - no commits → a comment on the issue saying leftibot gave up.

The @lefticus directive overrides the issue body. The issue body and other
comments go into the prompt as untrusted reference material.

### State and de-duplication

Attempts are recorded in `state/seen-issues.json`. Issues that already ended in
a PR are not retried. Issues that are in progress or failed are retried only
after a 24-hour cooldown.

## Layout

| Path                         | Purpose                                                 |
|------------------------------|---------------------------------------------------------|
| `bin/leftibot-tick.sh`       | Runs one tick: poll notifications, do one task, exit.   |
| `bin/leftibot-loop.sh`       | Runs ticks repeatedly in the foreground.                |
| `prompts/fix-issue.md`       | Prompt template for fixing a new issue.                 |
| `prompts/address-review.md`  | Prompt template for addressing PR review feedback.      |
| `prompts/comment-reply.md`   | Prompt template for answering a question in a comment.  |
| `tests/test-readme.sh`       | Checks that this README matches the scripts.            |
| `logs/`, `work/`, `state/`   | Created at runtime; ignored by git.                     |

Templates use `{{KEY}}` placeholders, which are filled in by `render_template`
in `bin/leftibot-tick.sh`.

## Requirements

The tick script checks for these commands at startup and exits if any are
missing:

- `gh`: the GitHub CLI, logged in **as the `leftibot` user**
- `git`, with SSH push access to leftibot's forks
- `claude`: the Claude Code CLI
- `jq`
- `cmake`: used to check CMake projects
- `flock`
- `timeout`
- `python3`: used to fill in prompt templates

## Installation

leftibot expects to live in `~/leftibot`. Set `LEFTIBOT_HOME` to use a
different location.

```sh
git clone git@github.com:leftibot/leftibot.git ~/leftibot
gh auth login        # log in as leftibot
```

## Usage

Try a dry run first. It renders the prompt into `logs/` and stops before
invoking Claude, forking, pushing, or commenting:

```sh
~/leftibot/bin/leftibot-tick.sh --verbose --dry-run
~/leftibot/bin/leftibot-tick.sh --verbose --issue https://github.com/foo/bar/issues/42 --dry-run
~/leftibot/bin/leftibot-tick.sh --verbose --pr https://github.com/foo/bar/pull/99 --dry-run
```

### `bin/leftibot-tick.sh` flags

| Flag                   | Effect                                                                 |
|------------------------|------------------------------------------------------------------------|
| `--verbose`, `-v`      | Print debug info, including the end of Claude's output.                |
| `--dry-run`            | Don't fork, push, open PRs, post comments, or mark notifications read. |
| `--issue <URL>`        | Skip the notification poll and work on this issue.                     |
| `--pr <URL>`           | Skip the notification poll and address review on this PR.              |
| `--skip-trigger-check` | Skip the "must be @-mentioned by @lefticus" check (**testing only**).  |
| `--no-cleanup`         | Keep the workdir for inspection (it is deleted by default).            |
| `-h`, `--help`         | Print usage.                                                           |

Exit codes: `0` means no work was found, `10` means a task was processed, and
any other value is an error.

### Continuous operation

Run ticks in a loop in the foreground:

```sh
~/leftibot/bin/leftibot-loop.sh                  # default 15 minute interval
~/leftibot/bin/leftibot-loop.sh 5m -v            # custom interval; later args go to the tick
```

When a tick processes a task, the loop starts the next tick right away. When
there is no work, or the tick fails, it sleeps for the interval.

Or install a cron entry:

```cron
*/15 * * * * flock -n ~/leftibot/state/tick.lock ~/leftibot/bin/leftibot-tick.sh >> ~/leftibot/logs/tick-$(date +\%Y-\%m-\%d).log 2>&1
```

The loop and the cron entry share `state/tick.lock`, so both can be installed
at once without running two ticks together.

## Testing

```sh
tests/test-readme.sh
```
