# Claude Code hook (Stop, SessionEnd): release this session's keep-awake holder.
# Windows port of macos/hooks/allow-sleep.sh.
#
# - SessionEnd (or any event other than Stop): kill this session's watcher,
#   then the holder, under the session lock.
# - Stop: do not release right away. Start one hidden watcher
#   (`allow-sleep.ps1 -Watch -SessionId <id>`) and return. The watcher keeps
#   the holder alive while the Claude desktop app holds a power request, and
#   releases once it is gone. If there is no request at the first check it
#   releases at once.
#   The app's request is read from `powercfg /requests`, which needs an
#   elevated (administrator) process; unelevated, the first check finds
#   nothing and Stop releases at once.
# - `allow-sleep.ps1 -Signal` runs the signal check alone: exit 0 and print the
#   matched line when work is running, exit 1 otherwise.
# - The hook never prints anything, never blocks, always exits 0.
#
# Env (tests): CLAUDE_SLEEP_HOOK_POLL (s, default 20), CLAUDE_SLEEP_HOOK_CAP
# (s, default 21600), CLAUDE_SLEEP_HOOK_SIGNAL_CMD (cmd.exe command, exit 0 =
# work running, replaces the powercfg check).
param([switch]$Watch, [switch]$Signal, [string]$SessionId)

$ErrorActionPreference = 'SilentlyContinue'
$SelfPath = $PSCommandPath

# Returns the matched line while the Claude app says work is running, else $null.
function Find-WorkSignal {
  $cmd = $env:CLAUDE_SLEEP_HOOK_SIGNAL_CMD
  if ($cmd) {
    & cmd.exe /d /c $cmd *> $null
    if ($LASTEXITCODE -eq 0) { return 'signal-cmd' }
    return $null
  }
  $out = & powercfg.exe /requests 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  $section = ''
  foreach ($line in $out) {
    if ($line -match '^([A-Z]+):\s*$') { $section = $Matches[1]; continue }
    if ($section -in @('DISPLAY', 'SYSTEM', 'EXECUTION', 'AWAYMODE') -and
        $line -match '^\[PROCESS\]\s.*\\claude\.exe\s*$') {
      return $line.Trim()
    }
  }
  $null
}

function Invoke-LockedRelease([string]$SessionId, [string]$HookEvent, [string]$Reason) {
  $lock = Enter-SessionLock $SessionId 2000
  try { Invoke-Release $SessionId $HookEvent $Reason } finally { Exit-SessionLock $lock }
}

function Invoke-Watcher([string]$SessionId) {
  $poll = Get-EnvInt 'CLAUDE_SLEEP_HOOK_POLL' 20
  $cap = Get-EnvInt 'CLAUDE_SLEEP_HOOK_CAP' 21600
  $watchFile = Join-Path $NoSleepDir "$SessionId.watch"
  Write-HookLog 'release' 'Watcher' $SessionId "watcher start pid=$PID poll=${poll}s cap=${cap}s"

  $clock = [Diagnostics.Stopwatch]::StartNew()
  $first = $true
  $on = $false
  try {
    while ($true) {
      $elapsed = [int]$clock.Elapsed.TotalSeconds
      if ($elapsed -ge $cap) {
        Write-HookLog 'release' 'Watcher' $SessionId "cap reached after ${elapsed}s"
        Invoke-LockedRelease $SessionId 'Watcher' 'reason=cap'
        return
      }
      # Second call: re-check once before treating the app as idle.
      if ((Find-WorkSignal) -or (Find-WorkSignal)) {
        if (-not $on) {
          Write-HookLog 'release' 'Watcher' $SessionId "signal on after ${elapsed}s"
          $on = $true
        }
        Invoke-Acquire $SessionId 'Watcher'
      } else {
        if ($first) {
          Write-HookLog 'release' 'Watcher' $SessionId 'signal off at first check, releasing now'
          Invoke-LockedRelease $SessionId 'Watcher' 'reason=no-signal'
        } else {
          Write-HookLog 'release' 'Watcher' $SessionId "signal off after ${elapsed}s, releasing"
          Invoke-LockedRelease $SessionId 'Watcher' 'reason=app-idle'
        }
        return
      }
      $first = $false
      Start-Sleep -Seconds $poll
    }
  } finally {
    $rec = Read-ProcRecord $watchFile
    if ($rec -and $rec.Id -eq $PID) { Remove-Item -LiteralPath $watchFile -Force }
  }
}

function Invoke-StopHook([string]$SessionId) {
  $pidFile = Join-Path $NoSleepDir "$SessionId.pid"
  $watchFile = Join-Path $NoSleepDir "$SessionId.watch"
  if (-not (Test-Path -LiteralPath $pidFile)) {
    # Nothing held: do not start a watcher that would create a holder.
    Write-HookLog 'release' 'Stop' $SessionId 'nothing-held'
    return
  }
  $w = Get-RecordProcess (Read-ProcRecord $watchFile)
  if ($w) {
    Write-HookLog 'release' 'Stop' $SessionId "watcher already running pid=$($w.Id)"
    return
  }
  $w = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $SelfPath), '-Watch', '-SessionId', $SessionId)
  if ($w) {
    Write-ProcRecord $watchFile $w
    Write-HookLog 'release' 'Stop' $SessionId "spawned watcher pid=$($w.Id)"
  }
}

# Holding the lock while killing the watcher means it cannot be halfway
# through starting a holder that would outlive this release.
function Invoke-EndHook([string]$SessionId, [string]$HookEvent) {
  $watchFile = Join-Path $NoSleepDir "$SessionId.watch"
  $lock = Enter-SessionLock $SessionId 3000
  try {
    $w = Get-RecordProcess (Read-ProcRecord $watchFile)
    if ($w) {
      Stop-Process -Id $w.Id -Force
      Write-HookLog 'release' $HookEvent $SessionId "killed watcher pid=$($w.Id)"
    }
    Remove-Item -LiteralPath $watchFile -Force
    Invoke-Release $SessionId $HookEvent ''
  } finally {
    Exit-SessionLock $lock
  }
}

try {
  . (Join-Path $PSScriptRoot 'common.ps1')
  if ($Signal) {
    $line = Find-WorkSignal
    if ($line) { $line; exit 0 }
    exit 1
  }
  if ($Watch) {
    Invoke-Watcher (ConvertTo-SessionId $SessionId)
    exit 0
  }
  $payload = Read-HookPayload
  if ($payload.HookEvent -eq 'Stop') {
    Invoke-StopHook $payload.SessionId
  } else {
    Invoke-EndHook $payload.SessionId $payload.HookEvent
  }
} catch {}
exit 0
