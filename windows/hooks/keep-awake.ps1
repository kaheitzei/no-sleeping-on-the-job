# Windows stand-in for `caffeinate -dimsu -t <Seconds>`: holds
# ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED for -Seconds, then exits.
# The request is tied to this process, so killing it drops the request at once.
# Closing the lid still follows the Windows lid-close action.
param([int]$Seconds = 3600)

Add-Type -Namespace NoSleep -Name Power -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint esFlags);
'@

# ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1) | ES_DISPLAY_REQUIRED (0x2)
[void][NoSleep.Power]::SetThreadExecutionState([uint32]2147483651)
[System.Threading.Thread]::Sleep([TimeSpan]::FromSeconds($Seconds))
