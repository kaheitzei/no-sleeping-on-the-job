#!/bin/bash
# Claude Code hook (Stop, SessionEnd): release this session's caffeinate.
#
# - SessionEnd (or any event other than Stop): kill this session's watcher,
#   then kill the PID in /tmp/claude_caffeinate/<session_id>.pid and remove
#   that file.
# - Stop: do not release right away. Start one detached watcher for this
#   session (`allow-sleep.sh --watch <id>`, pid in <id>.watch) and return.
#   The watcher keeps the lock alive while the Claude desktop app holds its
#   "keep awake while Claude works" assertion, and releases once it is gone.
#   If the assertion is absent at the first check (CLI-only session, setting
#   off, assertion renamed) it releases at once, as the old Stop did.
# - `allow-sleep.sh --signal` runs the signal check alone: exit 0 and print
#   the matched assertion line when work is running, exit 1 otherwise.
# - The hook never prints anything, never blocks, always exits 0.
#
# Env (tests): CLAUDE_SLEEP_HOOK_POLL (s, default 20), CLAUDE_SLEEP_HOOK_CAP
# (s, default 21600), CLAUDE_SLEEP_HOOK_SIGNAL_CMD (bash command, exit 0 =
# work running, replaces the pmset check).

exec 2>/dev/null

DIR=/tmp/claude_caffeinate
DEBUG_FLAG="$HOME/.claude/hooks/.sleep-debug"
POLL=${CLAUDE_SLEEP_HOOK_POLL:-20}
CAP=${CLAUDE_SLEEP_HOOK_CAP:-21600}
SELF=${BASH_SOURCE[0]}
[[ $SELF == /* ]] || SELF="$PWD/$SELF"
ACQUIRE="${SELF%/*}/prevent-sleep.sh"

# Owner exactly "(Claude)" (not "Claude Helper"), type NoIdleSleepAssertion.
SIGNAL_RE='^[[:space:]]*pid [0-9]+\(Claude\): .*[[:space:]]NoIdleSleepAssertion named:'

# Exit 0 while the Claude app says work is running; prints the matched line.
work_running() {
  if [ -n "$CLAUDE_SLEEP_HOOK_SIGNAL_CMD" ]; then
    /bin/bash -c "$CLAUDE_SLEEP_HOOK_SIGNAL_CMD" </dev/null >/dev/null
    return
  fi
  local line
  while IFS= read -r line; do
    if [[ $line =~ $SIGNAL_RE ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(/usr/bin/pmset -g assertions)
  return 1
}

sanitize_sid() {
  sid=${sid//[!A-Za-z0-9_-]/}
  sid=${sid:0:128}
  [ -n "$sid" ] || sid=unknown
}

mode=hook
case $1 in
  --signal)
    work_running
    exit $?
    ;;
  --watch)
    mode=watch
    sid=$2
    event=Watcher
    ;;
  *)
    parsed=$(/usr/bin/awk '
      { s = s $0 }
      END {
        sid = ""; ev = ""
        if (match(s, /"session_id"[ \t]*:[ \t]*"[^"]*"/)) {
          m = substr(s, RSTART, RLENGTH); sub(/^"session_id"[ \t]*:[ \t]*"/, "", m); sub(/"$/, "", m); sid = m
        }
        if (match(s, /"hook_event_name"[ \t]*:[ \t]*"[^"]*"/)) {
          m = substr(s, RSTART, RLENGTH); sub(/^"hook_event_name"[ \t]*:[ \t]*"/, "", m); sub(/"$/, "", m); ev = m
        }
        print sid "\t" ev
      }')
    sid=${parsed%%$'\t'*}
    event=${parsed#*$'\t'}
    event=${event//[!A-Za-z0-9_-]/}
    ;;
esac
sanitize_sid

PID_FILE="$DIR/$sid.pid"
WATCH_FILE="$DIR/$sid.watch"

log() {
  if [ "$CLAUDE_SLEEP_HOOK_DEBUG" = 1 ] || [ -e "$DEBUG_FLAG" ]; then
    [ -d "$DIR" ] || /bin/mkdir -p -m 700 "$DIR"
    printf '%s release event=%s session=%s %s\n' \
      "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "${event:-?}" "$sid" "$*" >>"$DIR/hooks.log"
  fi
}

is_pid() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -gt 1 ]; }

# Kill this session's caffeinate (only if the PID still is one), drop the file.
release() {
  local pid= comm
  if [ ! -f "$PID_FILE" ]; then
    log "nothing-held $*"
    return
  fi
  read -r pid <"$PID_FILE"
  if is_pid "$pid"; then
    comm=$(/bin/ps -p "$pid" -o comm=)
    if [ "${comm##*/}" = caffeinate ]; then
      kill "$pid"
      log "killed pid=$pid $*"
    else
      log "stale pid=$pid $*"
    fi
  fi
  /bin/rm -f "$PID_FILE"
}

# Prints the PID from <id>.watch if it is a live watcher for this session.
live_watcher() {
  local p= args
  [ -f "$WATCH_FILE" ] || return 1
  read -r p <"$WATCH_FILE"
  is_pid "$p" || return 1
  args=$(/bin/ps -ww -p "$p" -o args=) || return 1
  [[ $args == *" --watch $sid" ]] || return 1
  echo "$p"
}

# ---- watcher ---------------------------------------------------------------
if [ "$mode" = watch ]; then
  trap '' HUP INT
  sleep_pid=
  trap '[ -n "$sleep_pid" ] && kill "$sleep_pid"; exit 0' TERM

  finish() {
    local p=
    [ -f "$WATCH_FILE" ] && read -r p <"$WATCH_FILE"
    [ "$p" = "$$" ] && /bin/rm -f "$WATCH_FILE"
    exit 0
  }

  echo "$$" >"$WATCH_FILE"
  log "watcher start pid=$$ poll=${POLL}s cap=${CAP}s"

  held=
  [ -f "$PID_FILE" ] && read -r held <"$PID_FILE"
  state=
  first=1
  while :; do
    if [ "$SECONDS" -ge "$CAP" ]; then
      log "cap reached after ${SECONDS}s"
      release "reason=cap"
      finish
    fi

    if work_running >/dev/null || work_running >/dev/null; then
      # (second call: re-check once before treating the app as idle)
      if [ "$state" != on ]; then
        log "signal on after ${SECONDS}s"
        state=on
      fi
      # Acquire is a no-op while the lock is young; it starts a caffeinate if
      # the held one is gone and refreshes it before its TTL runs out.
      printf '{"session_id":"%s","hook_event_name":"Watcher"}' "$sid" | "$ACQUIRE"
      cur=
      [ -f "$PID_FILE" ] && read -r cur <"$PID_FILE"
      if [ "$cur" != "$held" ]; then
        log "re-acquired old=${held:-none} new=${cur:-none}"
        held=$cur
      fi
    else
      if [ -n "$first" ]; then
        log "signal off at first check, releasing now"
        release "reason=no-signal"
      else
        log "signal off after ${SECONDS}s, releasing"
        release "reason=app-idle"
      fi
      finish
    fi
    first=

    /bin/sleep "$POLL" &
    sleep_pid=$!
    wait "$sleep_pid"
    sleep_pid=
  done
fi

# ---- hook ------------------------------------------------------------------
if [ "$event" = Stop ]; then
  if [ ! -f "$PID_FILE" ]; then
    # Nothing held: do not start a watcher that would create a lock.
    log "nothing-held"
    exit 0
  fi
  if wpid=$(live_watcher); then
    log "watcher already running pid=$wpid"
    exit 0
  fi
  /bin/mkdir -p -m 700 "$DIR" || exit 0
  ( trap '' HUP INT; exec /usr/bin/nohup /bin/bash "$SELF" --watch "$sid" ) </dev/null >/dev/null 2>&1 &
  wpid=$!
  is_pid "$wpid" && echo "$wpid" >"$WATCH_FILE"
  log "spawned watcher pid=$wpid"
  exit 0
fi

# SessionEnd (or unknown event): stop the watcher first so it cannot
# re-acquire after the release, then release.
if wpid=$(live_watcher); then
  kill "$wpid"
  # The watcher finishes a running acquire before its TERM trap fires; wait
  # for it (at most ~0.5 s) so that acquire cannot outlive the release.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    kill -0 "$wpid" || break
    /bin/sleep 0.02
  done
  log "killed watcher pid=$wpid"
fi
/bin/rm -f "$WATCH_FILE"
release
exit 0
