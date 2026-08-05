#Requires -Version 5.1
<#
.SYNOPSIS
    Register (or remove) the scheduled drift runner and heartbeat watchdog tasks.
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
    # Baked into the registered task: the git checkout holding archived release
    # records. Without it the scheduled drift check runs UNANCHORED -- it compares
    # production against a manifest sitting next to production, which catches an
    # accidental edit but not a deliberate one that rewrote both.
    [string]$BaselineRepo,
    # Passed through so retention is set once at registration rather than by editing
    # the task's argument string later. 0 disables pruning.
    [int]$LogRetentionDays = 0,
    [string]$Environment = 'prod',
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

# Registering a SYSTEM/Highest task needs elevation. Without this check the failure
# surfaces as a raw Access Denied from Register-ScheduledTask, several steps after
# the log dir has already been created.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Install-DriftTask.ps1 must run elevated: it registers scheduled tasks that run as SYSTEM.'
}

Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force

# -Uninstall path: remove the runner and its independent watchdog. Audited too --
# silently deleting the drift check is indistinguishable from "no drift" afterwards,
# which is precisely the gap the watchdog exists to close.
if ($Uninstall) {
    $uninstallLog = New-VesLogFile -Prefix 'install-drift-task' -LogDir $LogDir
    foreach ($name in @($TaskName,$WatchdogTaskName)) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
            Write-VesLog WARN "DRIFT TASK REMOVED: $name" `
                -Data @{script='Install-DriftTask.ps1'; taskName=$name; removedBy="$env:USERNAME@$env:COMPUTERNAME"} `
                -LogFile $uninstallLog
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

# action: pin Windows PowerShell 5.1 (powershell.exe), not pwsh — prod scripts
# target 5.1 only and must not silently run under a different engine.
$runnerArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -TargetsFile "{1}" -LogDir "{2}"' -f $runner, $TargetsFile, $LogDir
# Only append what the caller actually set, so the task line stays the runner's own
# defaults otherwise rather than freezing today's defaults into Task Scheduler.
if ($BaselineRepo) { $runnerArgs += ' -BaselineRepo "{0}"' -f $BaselineRepo }
if ($LogRetentionDays -gt 0) { $runnerArgs += ' -LogRetentionDays {0}' -f $LogRetentionDays }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $runnerArgs
$watchdogAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
    '-NoProfile -ExecutionPolicy Bypass -File "{0}" -HeartbeatPath "{1}" -MaxAgeMinutes {2} -Environment "{3}" -LogFile "{4}"' -f `
        $watchdog, $heartbeatPath, $HeartbeatMaxAgeMinutes, $Environment, $watchdogLog)

# -Once + repetition rather than a daily trigger so the cadence is a single knob.
# Fixed long duration instead of [TimeSpan]::MaxValue, which serializes badly on
# older hosts (2012R2-era) that these legacy systems may still run on.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
# Watchdog starts ~one interval later so the first runner pass can write a
# heartbeat before the watchdog's first check alarms on a missing file.
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

# Registering these tasks changes what runs on this box unattended, as SYSTEM.
# Write-Host alone leaves no evidence of that, so mirror it into the JSONL audit
# trail the rest of the suite writes -- who registered what, when, against which
# targets file and region.
$installLog = New-VesLogFile -Prefix 'install-drift-task' -LogDir $LogDir
Write-VesLog OK 'DRIFT TASKS REGISTERED' -Data @{
    script                 = 'Install-DriftTask.ps1'
    taskName               = $TaskName
    watchdogTaskName       = $WatchdogTaskName
    intervalMinutes        = $IntervalMinutes
    heartbeatMaxAgeMinutes = $HeartbeatMaxAgeMinutes
    targetsFile            = $TargetsFile
    logDir                 = $LogDir
    baselineRepo           = $BaselineRepo
    logRetentionDays       = $LogRetentionDays
    environment            = $Environment
    registeredBy           = "$env:USERNAME@$env:COMPUTERNAME"
} -LogFile $installLog

Write-Host ("Registered '{0}': every {1} min as SYSTEM, targets={2}" -f $TaskName, $IntervalMinutes, $TargetsFile)
Write-Host ("Registered '{0}': alerts when heartbeat exceeds {1} min, heartbeat={2}" -f `
    $WatchdogTaskName, $HeartbeatMaxAgeMinutes, $heartbeatPath)
Write-Host "Point monitoring/log shipping at $LogDir; production watchdog failures exit 2."
Write-Host "Registration recorded in $installLog"
