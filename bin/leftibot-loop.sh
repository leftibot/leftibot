#!/usr/bin/env bash
# leftibot-loop.sh — run leftibot-tick.sh repeatedly in the foreground.
#
# Usage:
#   ~/leftibot/bin/leftibot-loop.sh                  # idle backoff 1m → 15m cap
#   ~/leftibot/bin/leftibot-loop.sh 30m              # custom idle cap (s/m/h suffix)
#   ~/leftibot/bin/leftibot-loop.sh 30m -v           # cap + flags passed to tick
#   ~/leftibot/bin/leftibot-loop.sh 30m -v --dry-run # any flags after the cap
#                                                    #   are passed straight to the tick
#
# Pacing (graduated idle backoff):
#   - tick did work (rc=10)  → loop again immediately, reset the backoff
#   - tick found no work     → wait 1m, then 2m, 4m, 8m, ... capped at 15m
#   - tick failed (other rc) → same backoff as idle, so a persistent failure
#                              doesn't hammer GitHub
# An idle tick costs roughly one notifications API call, so even the 1m floor
# stays far below GitHub's 5000 requests/hour limit; the cap keeps a quiet bot
# down to a handful of calls per hour.
#
# Ctrl-C to stop. Uses the same flock as the cron entry, so it's safe to run
# this in a shell window even while a cron is also installed — neither will
# step on the other.

MIN_IDLE_SECONDS=60
MAX_IDLE_SECONDS=900

# Converts a duration like 90, 45s, 5m or 2h to seconds.
parse_duration() {
  local d="$1"
  [[ "$d" =~ ^([0-9]+)([smh]?)$ ]] || { echo "invalid duration: $d" >&2; return 1; }
  local n="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    *) echo "$n" ;;
  esac
}

# Next idle wait: start at min, double each idle tick, never exceed max.
#   $1 = previous delay (0 after a tick that did work), $2 = min, $3 = max
next_idle_delay() {
  local prev="$1" min="$2" max="$3" next
  if (( prev <= 0 )); then next="$min"; else next=$((prev * 2)); fi
  (( next > max )) && next="$max"
  echo "$next"
}

format_duration() {
  local s="$1"
  if (( s % 60 == 0 )); then echo "$((s / 60))m"; else echo "${s}s"; fi
}

main() {
  set -u
  if [[ "${1:-}" =~ ^[0-9] ]]; then
    MAX_IDLE_SECONDS=$(parse_duration "$1") || exit 2
    shift
  fi

  local leftibot_home="${LEFTIBOT_HOME:-$HOME/leftibot}"
  local tick="$leftibot_home/bin/leftibot-tick.sh"
  local lock="$leftibot_home/state/tick.lock"

  [[ -x "$tick" ]] || { echo "tick script not found or not executable: $tick" >&2; exit 1; }

  trap 'echo; echo "[loop] caught signal, exiting."; exit 0' INT TERM

  local count=0 delay=0 tick_rc
  while true; do
    count=$((count + 1))
    echo
    echo "============================================================"
    echo "[loop] tick #$count at $(date '+%F %T')"
    echo "============================================================"
    flock -n "$lock" "$tick" "$@"
    tick_rc=$?
    if [[ $tick_rc -eq 10 ]]; then
      delay=0
      echo "[loop] work done — looping immediately"
      continue
    fi
    delay=$(next_idle_delay "$delay" "$MIN_IDLE_SECONDS" "$MAX_IDLE_SECONDS")
    if [[ $tick_rc -eq 0 ]]; then
      echo "[loop] no work — sleeping $(format_duration "$delay") (Ctrl-C to stop)"
    else
      echo "[loop] tick #$count exited rc=$tick_rc — sleeping $(format_duration "$delay") (Ctrl-C to stop)"
    fi
    sleep "$delay"
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
