#!/usr/bin/env bash
# leftibot-loop.sh — run leftibot-tick.sh repeatedly in the foreground.
#
# Usage:
#   ~/leftibot/bin/leftibot-loop.sh                  # default 15 min interval
#   ~/leftibot/bin/leftibot-loop.sh 5m               # custom interval (sleep arg)
#   ~/leftibot/bin/leftibot-loop.sh 5m -v            # interval + flags passed to tick
#   ~/leftibot/bin/leftibot-loop.sh 5m -v --dry-run  # any flags after the interval
#                                                    #   are passed straight to the tick
#
# Ctrl-C to stop. Uses the same flock as the cron entry, so it's safe to run
# this in a shell window even while a cron is also installed — neither will
# step on the other.

set -u

INTERVAL="15m"
if [[ "${1:-}" =~ ^[0-9] ]]; then
  INTERVAL="$1"
  shift
fi

LEFTIBOT_HOME="${LEFTIBOT_HOME:-$HOME/leftibot}"
TICK="$LEFTIBOT_HOME/bin/leftibot-tick.sh"
LOCK="$LEFTIBOT_HOME/state/tick.lock"

[[ -x "$TICK" ]] || { echo "tick script not found or not executable: $TICK" >&2; exit 1; }

trap 'echo; echo "[loop] caught signal, exiting."; exit 0' INT TERM

count=0
while true; do
  count=$((count + 1))
  echo
  echo "============================================================"
  echo "[loop] tick #$count at $(date '+%F %T')"
  echo "============================================================"
  flock -n "$LOCK" "$TICK" "$@" || echo "[loop] tick #$count failed or skipped (lock held); rc=$?"
  echo
  echo "[loop] sleeping $INTERVAL — Ctrl-C to stop"
  sleep "$INTERVAL"
done
