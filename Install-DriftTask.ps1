#Requires -Version 5.1
<#
.DESCRIPTION
    Creates a task running as SYSTEM that re-verifies every target in the
    targets file. The runner writes a timestamped JSONL log per target under its
    log dir; point your monitoring at those logs so a dead task gets noticed -
    the task dying silently is otherwise indistinguishable from "no drift". A
    missing or stale run log for the current interval means the task is not firing.

    Exit codes from the runner (0 clean, 1 drift, 2 trust failure) also end up in
    Task Scheduler's "Last Run Result", which a monitor can read directly.
.EXAMPLE
    .\Install-DriftTask.ps1 -TargetsFile D:\ves-verify\targets.json -IntervalMinutes 30
.EXAMPLE
    .\Install-DriftTask.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$TargetsFile = 'D:\ves-verify\targets.json',
    [int]$IntervalMinutes = 30,
    [string]$TaskName = 'ves-verify-drift',
    [string]$WatchdogTaskName = 'ves-verify-drift-watchdog',
    [string]$LogDir = 'D:\ves-verify\logs',
    # 0 derives a threshold of three intervals (minimum 15 minutes).
    [int]$HeartbeatMaxAgeMinutes = 0,
    [string]$Environment = 'prod',
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

# -Uninstall path: remove the runner and its independent watchdog.
if ($Uninstall) {
    foreach ($name in @($TaskName,$WatchdogTaskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-Host "Removed scheduled task '$name'."
        }
    }
    return
}
if ($IntervalMinutes -le 0) { throw 'IntervalMinutes must be greater than zero.' }
if ($HeartbeatMaxAgeMinutes -le 0) {
    $HeartbeatMaxAgeMinutes = [math]::Max(15, ($IntervalMinutes * 3))
}
if ($HeartbeatMaxAgeMinutes -le $IntervalMinutes) {
    throw 'HeartbeatMaxAgeMinutes must be greater than IntervalMinutes.'
}

# locate the runner this task will invoke; warn (don't fail) if targets aren't in place yet
$runner = Join-Path $PSScriptRoot 'Start-DriftRunner.ps1'
$watchdog = Join-Path $PSScriptRoot 'Test-DriftHeartbeat.ps1'
if (-not (Test-Path $runner)) { throw "Start-DriftRunner.ps1 not found next to this script: $runner" }
if (-not (Test-Path $watchdog)) { throw "Test-DriftHeartbeat.ps1 not found next to this script: $watchdog" }
if (-not (Test-Path $TargetsFile)) {
    Write-Warning "Targets file $TargetsFile does not exist yet; task will fail until it does."
}
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$heartbeatPath = Join-Path $LogDir 'ves-verify-drift.heartbeat.json'
$watchdogLog = Join-Path $LogDir 'drift-heartbeat-watchdog.jsonl'

# action: run the drift runner under Windows PowerShell against the targets file
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -ExecutionPolicy Bypass -File "{0}" -TargetsFile "{1}" -LogDir "{2}"' -f $runner, $TargetsFile, $LogDir)
$watchdogAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -ExecutionPolicy Bypass -File "{0}" -HeartbeatPath "{1}" -MaxAgeMinutes {2} -Environment "{3}" -LogFile "{4}"' -f `
        $watchdog, $heartbeatPath, $HeartbeatMaxAgeMinutes, $Environment, $watchdogLog)

# -Once + repetition rather than a daily trigger so the cadence is a single knob.
# Fixed long duration instead of [TimeSpan]::MaxValue, which serializes badly on
# older hosts (2012R2-era) that these legacy systems may still run on.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$watchdogTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($IntervalMinutes + 5) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

# run as SYSTEM (elevated); skip overlapping runs and catch up if a run was missed
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

# register (or overwrite) the task from the pieces above
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Register-ScheduledTask -TaskName $WatchdogTaskName -Action $watchdogAction -Trigger $watchdogTrigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ("Registered '{0}': every {1} min as SYSTEM, targets={2}" -f $TaskName, $IntervalMinutes, $TargetsFile)
Write-Host ("Registered '{0}': alerts when heartbeat exceeds {1} min, heartbeat={2}" -f `
    $WatchdogTaskName, $HeartbeatMaxAgeMinutes, $heartbeatPath)
Write-Host "Point monitoring/log shipping at $LogDir; production watchdog failures emit Datadog error events and exit 2."
