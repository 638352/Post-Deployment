#Requires -Version 5.1
<#
.SYNOPSIS
    Registers (or removes) the Task Scheduler job that runs Start-DriftRunner.ps1
    on a fixed cadence. Run elevated on the verification host.
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
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
    return
}

$runner = Join-Path $PSScriptRoot 'Start-DriftRunner.ps1'
if (-not (Test-Path $runner)) { throw "Start-DriftRunner.ps1 not found next to this script: $runner" }
if (-not (Test-Path $TargetsFile)) {
    Write-Warning "Targets file $TargetsFile does not exist yet; task will fail until it does."
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -ExecutionPolicy Bypass -File "{0}" -TargetsFile "{1}"' -f $runner, $TargetsFile)

# -Once + repetition rather than a daily trigger so the cadence is a single knob.
# Fixed long duration instead of [TimeSpan]::MaxValue, which serializes badly on
# older hosts (2012R2-era) that these legacy systems may still run on.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ("Registered '{0}': every {1} min as SYSTEM, targets={2}" -f $TaskName, $IntervalMinutes, $TargetsFile)
Write-Host "Reminder: point monitoring at the runner's JSONL logs (and/or the task's Last Run Result)."
