# Windows stand-in for `caffeinate -dimsu -t <Seconds>`: holds
# ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED for -Seconds, then exits.
# The request is tied to this process, so killing it drops the request at once.
# Closing the lid still follows the Windows lid-close action.
param([int]$Seconds = 3600)

try {
  Add-Type -Namespace NoSleep -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
} catch {
  # Typically Constrained Language Mode (AppLocker/WDAC). Hooks are silent, so
  # this log line is the only trace.
  $flag = Join-Path $env:USERPROFILE '.claude\hooks\.sleep-debug'
  if ($env:CLAUDE_SLEEP_HOOK_DEBUG -eq '1' -or (Test-Path -LiteralPath $flag)) {
    $line = '{0} keep-awake pid={1} cannot call SetThreadExecutionState (language mode {2}): {3}' -f `
      (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $ExecutionContext.SessionState.LanguageMode, $_.Exception.Message
    Add-Content -LiteralPath (Join-Path $env:TEMP 'claude_awake\hooks.log') -Value $line -Encoding ASCII
  }
  exit 1
}

# ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1) | ES_DISPLAY_REQUIRED (0x2)
[void][NoSleep.Power]::SetThreadExecutionState([uint32]2147483651)
[System.Threading.Thread]::Sleep([TimeSpan]::FromSeconds($Seconds))
