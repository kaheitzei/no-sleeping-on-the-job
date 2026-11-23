#!/bin/bash
# Claude Code hook (UserPromptSubmit, PreToolUse): hold a per-session
# `caffeinate -dimsu` so the Mac stays awake while this session works.
#
# - One PID file per session: /tmp/claude_caffeinate/<session_id>.pid
# - Fast path (lock already held, the normal case on PreToolUse): one awk
#   fork to read stdin, one ps fork to check the PID, then exit.
# - Orphan backstop: caffeinate runs with -t TTL (default 3600 s). Any hook
#   call that finds the lock older than REFRESH (default 1800 s) starts a
#   fresh caffeinate, swaps the PID file and kills the old one. A session that
#   crashes without Stop/SessionEnd therefore keeps the Mac awake at most TTL.
# - allow-sleep.sh's Stop watcher calls this hook with event "Watcher" on every
#   poll to keep the lock alive; "held" is not logged for those calls.
# - Never prints anything, never blocks, always exits 0.

exec 2>/dev/null

DIR=/tmp/claude_caffeinate
TTL=${CLAUDE_SLEEP_HOOK_TTL:-3600}
REFRESH=${CLAUDE_SLEEP_HOOK_REFRESH:-1800}
LEGACY_PID_FILE=/tmp/claude_caffeinate.pid
DEBUG_FLAG="$HOME/.claude/hooks/.sleep-debug"

# Read all of stdin (drains it, PreToolUse payloads can be large) and pull the
# first top-level session_id and hook_event_name in a single fork.
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
sid=${sid//[!A-Za-z0-9_-]/}
sid=${sid:0:128}
[ -n "$sid" ] || sid=unknown
event=${event//[!A-Za-z0-9_-]/}

PID_FILE="$DIR/$sid.pid"
LOCK_DIR="$DIR/$sid.lock"

log() {
  if [ "$CLAUDE_SLEEP_HOOK_DEBUG" = 1 ] || [ -e "$DEBUG_FLAG" ]; then
    local pcomm
    pcomm=$(/bin/ps -p "$PPID" -o comm=)
    printf '%s acquire event=%s session=%s ppid=%s(%s) %s\n' \
      "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "${event:-?}" "$sid" "$PPID" "${pcomm##*/}" "$*" \
      >>"$DIR/hooks.log"
  fi
}

is_pid() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -gt 1 ]; }

# Prints the age in seconds of PID $1 if it is a live caffeinate, else nothing.
caffeinate_age() {
  local out etime comm days=0 h=0 m=0 s=0
  is_pid "$1" || return 1
  out=$(/bin/ps -p "$1" -o etime=,comm=) || return 1
  out=${out#"${out%%[! ]*}"}          # trim leading spaces
  etime=${out%% *}
  comm=${out#* }
  [ "${comm##*/}" = caffeinate ] || return 1
  if [[ $etime == *-* ]]; then days=${etime%%-*}; etime=${etime#*-}; fi
  IFS=: read -r a b c <<EOF
$etime
EOF
  if [ -n "$c" ]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  echo $(( 10#$days * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# ---- fast path -------------------------------------------------------------
old_pid=
[ -f "$PID_FILE" ] && read -r old_pid <"$PID_FILE"
age=$(caffeinate_age "$old_pid")
if [ -n "$age" ] && [ "$age" -lt "$REFRESH" ]; then
  [ "$event" = Watcher ] || log "held pid=$old_pid age=${age}s"
  exit 0
fi

# ---- slow path: start or refresh -------------------------------------------
/bin/mkdir -p -m 700 "$DIR" || exit 0

if ! /bin/mkdir "$LOCK_DIR"; then
  # Another acquire for this session is running. Break the lock only if it is
  # stale (left by a killed hook), otherwise let the other call do the work.
  lock_mtime=$(/usr/bin/stat -f %m "$LOCK_DIR")
  now=$(/bin/date +%s)
  if [ -n "$lock_mtime" ] && [ $(( now - lock_mtime )) -gt 10 ]; then
    /bin/rmdir "$LOCK_DIR"
    /bin/mkdir "$LOCK_DIR" || { log "lock-busy"; exit 0; }
  else
    log "lock-busy"
    exit 0
  fi
fi
trap '/bin/rmdir "$LOCK_DIR"' EXIT

# Re-check under the lock: a parallel call may have just started it.
old_pid=
[ -f "$PID_FILE" ] && read -r old_pid <"$PID_FILE"
age=$(caffeinate_age "$old_pid")
if [ -n "$age" ] && [ "$age" -lt "$REFRESH" ]; then
  [ "$event" = Watcher ] || log "held pid=$old_pid age=${age}s (after lock)"
  exit 0
fi

# Start caffeinate detached. Ignoring INT/HUP keeps a terminal Ctrl-C from
# killing it; release uses TERM.
( trap '' INT HUP; exec /usr/bin/caffeinate -dimsu -t "$TTL" ) </dev/null >/dev/null 2>&1 &
new_pid=$!
if is_pid "$new_pid"; then
  echo "$new_pid" >"$PID_FILE.tmp.$$" && /bin/mv -f "$PID_FILE.tmp.$$" "$PID_FILE"
fi

if [ -n "$age" ]; then
  # Refresh: the old caffeinate is still alive, drop it after the swap.
  kill "$old_pid"
  log "refreshed old=$old_pid age=${age}s new=$new_pid ttl=$TTL"
else
  log "started pid=$new_pid ttl=$TTL"
fi

# Legacy migration: the old hooks used one global PID file.
if [ -f "$LEGACY_PID_FILE" ]; then
  read -r legacy_pid <"$LEGACY_PID_FILE"
  if [ -n "$(caffeinate_age "$legacy_pid")" ]; then
    kill "$legacy_pid"
    log "legacy killed pid=$legacy_pid"
  fi
  /bin/rm -f "$LEGACY_PID_FILE"
fi

# Sweep: remove PID files whose process is gone or is no longer caffeinate.
# Only files are removed here, nothing is killed.
pids=
for f in "$DIR"/*.pid; do
  [ -f "$f" ] || continue
  p=
  read -r p <"$f"
  is_pid "$p" && pids="$pids,$p"
done
alive=" "
if [ -n "$pids" ]; then
  while read -r p c; do
    [ "${c##*/}" = caffeinate ] && alive="$alive$p "
  done <<EOF
$(/bin/ps -p "${pids#,}" -o pid=,comm=)
EOF
fi
for f in "$DIR"/*.pid; do
  [ -f "$f" ] || continue
  p=
  read -r p <"$f"
  # Only judge PIDs that were in the ps snapshot: a file written by a parallel
  # acquire after the snapshot is left alone.
  if ! is_pid "$p" || { [[ ",$pids," == *",$p,"* ]] && [[ $alive != *" $p "* ]]; }; then
    /bin/rm -f "$f"
    log "swept $(basename "$f") pid=$p"
  fi
done

# Sweep watcher files (allow-sleep.sh --watch) whose process is gone or is not
# a watcher. A live watcher rewrites its own file at start, so a file removed
# in the moment between spawn and exec comes back.
for f in "$DIR"/*.watch; do
  [ -f "$f" ] || continue
  p=
  read -r p <"$f"
  if is_pid "$p"; then
    args=$(/bin/ps -ww -p "$p" -o args=)
    [[ $args == *" --watch "* ]] && continue
  fi
  /bin/rm -f "$f"
  log "swept $(basename "$f") pid=$p"
done

exit 0
