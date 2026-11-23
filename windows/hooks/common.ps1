# Shared helpers, dot-sourced by prevent-sleep.ps1 and allow-sleep.ps1.
#
# State lives in %TEMP%\claude_awake:
#   <sid>.pid    keep-awake.ps1 holder for that session
#   <sid>.watch  allow-sleep.ps1 -Watch process for that session
# Each file holds "<pid> <start-time-ticks-utc>"; the start time guards
# against PID reuse, so a record only counts while that exact process lives.
# A named mutex per session serializes start/refresh/release.

$NoSleepDir = Join-Path $env:TEMP 'claude_awake'
$NoSleepDebugFlag = Join-Path $env:USERPROFILE '.claude\hooks\.sleep-debug'
$NoSleepKeepAwake = Join-Path $PSScriptRoot 'keep-awake.ps1'

function Get-EnvInt([string]$Name, [int]$Default) {
  $v = 0
  if ([int]::TryParse([Environment]::GetEnvironmentVariable($Name), [ref]$v) -and $v -gt 0) { return $v }
  $Default
}

function ConvertTo-SessionId([string]$Raw) {
  $s = $Raw -replace '[^A-Za-z0-9_-]', ''
  if ($s.Length -gt 128) { $s = $s.Substring(0, 128) }
  if (-not $s) { $s = 'unknown' }
  $s
}

# Reads all of stdin and pulls the first session_id and hook_event_name.
function Read-HookPayload {
  $raw = [Console]::In.ReadToEnd()
  $sid = ''
  $ev = ''
  if ($raw -match '"session_id"\s*:\s*"([^"]*)"') { $sid = $Matches[1] }
  if ($raw -match '"hook_event_name"\s*:\s*"([^"]*)"') { $ev = $Matches[1] }
  [pscustomobject]@{
    SessionId = ConvertTo-SessionId $sid
    HookEvent = $ev -replace '[^A-Za-z0-9_-]', ''
  }
}

function Write-HookLog([string]$Kind, [string]$HookEvent, [string]$SessionId, [string]$Message) {
  if ($env:CLAUDE_SLEEP_HOOK_DEBUG -ne '1' -and -not (Test-Path -LiteralPath $NoSleepDebugFlag)) { return }
  [void](New-Item -ItemType Directory -Path $NoSleepDir -Force)
  if (-not $HookEvent) { $HookEvent = '?' }
  $line = '{0} {1} event={2} session={3} {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Kind, $HookEvent, $SessionId, $Message
  Add-Content -LiteralPath (Join-Path $NoSleepDir 'hooks.log') -Value $line -Encoding ASCII
}

function ConvertFrom-ProcRecord([string]$Text) {
  $parts = @($Text.Trim() -split '\s+')
  $id = 0
  $ticks = [long]0
  if ($parts.Count -ne 2) { return $null }
  if (-not [int]::TryParse($parts[0], [ref]$id)) { return $null }
  if (-not [long]::TryParse($parts[1], [ref]$ticks)) { return $null }
  [pscustomobject]@{ Id = $id; Ticks = $ticks }
}

function Read-ProcRecord([string]$Path) {
  try { ConvertFrom-ProcRecord ([IO.File]::ReadAllText($Path)) } catch { $null }
}

function Get-StartTicks($Process) {
  try { $Process.StartTime.ToUniversalTime().Ticks } catch { $null }
}

# The live process a record points to, or $null.
function Get-RecordProcess($Record) {
  if (-not $Record -or $Record.Id -le 4) { return $null }
  $p = Get-Process -Id $Record.Id -ErrorAction SilentlyContinue
  if (-not $p) { return $null }
  if ((Get-StartTicks $p) -ne $Record.Ticks) { return $null }
  $p
}

function Get-ProcessAge($Process) {
  try { ((Get-Date) - $Process.StartTime).TotalSeconds } catch { [double]::MaxValue }
}

# Readers hold the file only for a moment; retry instead of losing the record.
function Write-ProcRecord([string]$Path, $Process) {
  $text = '{0} {1}' -f $Process.Id, (Get-StartTicks $Process)
  for ($i = 0; $i -lt 25; $i++) {
    try { [IO.File]::WriteAllText($Path, $text); return } catch { Start-Sleep -Milliseconds 20 }
  }
}

function Enter-SessionLock([string]$SessionId, [int]$TimeoutMs) {
  $m = New-Object System.Threading.Mutex($false, "Local\claude_awake_$SessionId")
  try {
    if ($m.WaitOne($TimeoutMs)) { return $m }
  } catch [System.Threading.AbandonedMutexException] {
    # Previous owner died (e.g. hook killed on timeout); we own it now.
    return $m
  }
  $m.Dispose()
  $null
}

function Exit-SessionLock($Lock) {
  if ($Lock) {
    try { $Lock.ReleaseMutex() } catch {}
    $Lock.Dispose()
  }
}

function Start-KeepAwake([int]$Seconds) {
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', ('"{0}"' -f $NoSleepKeepAwake), '-Seconds', $Seconds)
}

# Removes .pid/.watch files whose process is gone. Files touched in the last
# 10 s are skipped so a record being written is never judged half-done.
function Remove-StaleRecords {
  $cutoff = (Get-Date).AddSeconds(-10)
  foreach ($f in @(Get-ChildItem -LiteralPath $NoSleepDir -File -ErrorAction SilentlyContinue)) {
    if ($f.Extension -ne '.pid' -and $f.Extension -ne '.watch') { continue }
    if ($f.LastWriteTime -gt $cutoff) { continue }
    try { $text = [IO.File]::ReadAllText($f.FullName) } catch { continue }
    if (-not (Get-RecordProcess (ConvertFrom-ProcRecord $text))) {
      Remove-Item -LiteralPath $f.FullName -Force
      Write-HookLog 'acquire' '' '' "swept $($f.Name)"
    }
  }
}

# Start a holder for the session, or refresh it once it is older than REFRESH.
function Invoke-Acquire([string]$SessionId, [string]$HookEvent) {
  $refresh = Get-EnvInt 'CLAUDE_SLEEP_HOOK_REFRESH' 1800
  $ttl = Get-EnvInt 'CLAUDE_SLEEP_HOOK_TTL' 3600
  $pidFile = Join-Path $NoSleepDir "$SessionId.pid"

  $old = Get-RecordProcess (Read-ProcRecord $pidFile)
  if ($old -and (Get-ProcessAge $old) -lt $refresh) {
    if ($HookEvent -ne 'Watcher') { Write-HookLog 'acquire' $HookEvent $SessionId "held pid=$($old.Id)" }
    return
  }

  [void](New-Item -ItemType Directory -Path $NoSleepDir -Force)
  $lock = Enter-SessionLock $SessionId 0
  if (-not $lock) {
    Write-HookLog 'acquire' $HookEvent $SessionId 'lock-busy'
    return
  }
  try {
    # Re-check under the lock: a parallel call may have just started it.
    $old = Get-RecordProcess (Read-ProcRecord $pidFile)
    if ($old -and (Get-ProcessAge $old) -lt $refresh) { return }

    $new = Start-KeepAwake $ttl
    if (-not $new) { return }
    Write-ProcRecord $pidFile $new
    if ($old) {
      Stop-Process -Id $old.Id -Force
      Write-HookLog 'acquire' $HookEvent $SessionId "refreshed old=$($old.Id) new=$($new.Id) ttl=$ttl"
    } else {
      Write-HookLog 'acquire' $HookEvent $SessionId "started pid=$($new.Id) ttl=$ttl"
    }
  } finally {
    Exit-SessionLock $lock
  }
  Remove-StaleRecords
}

# Kill the session's holder (only if the record still matches it), drop the file.
function Invoke-Release([string]$SessionId, [string]$HookEvent, [string]$Reason) {
  $pidFile = Join-Path $NoSleepDir "$SessionId.pid"
  if (-not (Test-Path -LiteralPath $pidFile)) {
    Write-HookLog 'release' $HookEvent $SessionId "nothing-held $Reason"
    return
  }
  $p = Get-RecordProcess (Read-ProcRecord $pidFile)
  if ($p) {
    Stop-Process -Id $p.Id -Force
    Write-HookLog 'release' $HookEvent $SessionId "killed pid=$($p.Id) $Reason"
  } else {
    Write-HookLog 'release' $HookEvent $SessionId "stale $Reason"
  }
  Remove-Item -LiteralPath $pidFile -Force
}
