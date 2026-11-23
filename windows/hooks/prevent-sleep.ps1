# Claude Code hook (UserPromptSubmit, PreToolUse): hold one keep-awake.ps1
# process per session so Windows stays awake while the session works.
# Windows port of macos/hooks/prevent-sleep.sh.
#
# - Fast path (holder alive and young, the normal case on PreToolUse): read
#   stdin, one Get-Process, exit.
# - Orphan backstop: the holder exits on its own after TTL (default 3600 s);
#   any call that finds it older than REFRESH (default 1800 s) starts a fresh
#   one and kills the old one. A session that crashes without Stop/SessionEnd
#   therefore keeps the machine awake at most TTL.
# - Never prints anything, never blocks, always exits 0.

$ErrorActionPreference = 'SilentlyContinue'
try {
  . (Join-Path $PSScriptRoot 'common.ps1')
  $payload = Read-HookPayload
  Invoke-Acquire $payload.SessionId $payload.HookEvent
} catch {}
exit 0
