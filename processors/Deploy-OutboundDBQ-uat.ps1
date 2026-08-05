#Requires -Version 5.1
<#
.SYNOPSIS
    Per-processor deploy for the DBQ outbound processor on UAT VESMSEGRESSUAT.
    Copied from Deploy-SYSTEM_NAME.ps1 and filled in for this box.
.DESCRIPTION
    DBQ runs as VES.OutboundDBQProcessor.exe under a per-processor folder, launched
    by VLER_EM_Realtime_DBQ_Processor.bat with mode arg RTPDP (see SERVERS.md).
    Paths below are the UAT ones; PROD lives on VESEMSEGRESS02/03 and needs its own
    wrapper with the runbook's PROD paths.

    CONFIRM before a real run: the values tagged # CONFIRM are not in SERVERS.md
    (scheduled-task name, log dir). Pull them from the Outbound Deployment Steps
    runbook. -ConfirmedRunbookValues is not taken on trust: the script checks
    that the named task and log directory actually exist on this server and
    refuses to run if either does not.

    The running console-exe instance is handled: KillProcesses stops the
    instance whose exe lives under TargetRoot (audited by PID + command line) and
    StartTasksAfter relaunches it via its scheduled task after a clean copy.
    Pilot with -WhatIf first, then a real run on this UAT box, before PROD.

    STAGE THE CONFIG: the copy mirrors with /MIR, so StagedRoot must already
    contain VES.OutboundDBQProcessor.exe.config with this box's values -- the
    deploy replaces the one on the server rather than preserving it. The gate
    enforces it (ConfigPath below becomes a required staged artifact), so a
    package without the config is blocked before anything is copied.
.EXAMPLE
    .\Deploy-OutboundDBQ-uat.ps1 -StagedRoot D:\stage\OutboundDBQ -StagedCommit abc1234 -ConfirmedRunbookValues -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    # The anchor: this deploy's release tag (e.g. OutboundDBQ/v1.4.0) and the
    # baseline archive checkout it is recorded in. Both mandatory here because
    # Deploy-Processor refuses to run without them -- there is no unanchored
    # deploy -- and a wrapper that let them default would just fail later with a
    # less helpful message.
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$BaselineRepo,
    # Required until the two values marked CONFIRM below have been checked
    # against the current Outbound Deployment Steps runbook.
    [switch]$ConfirmedRunbookValues,
    [string]$AuditLogDir
)
$ErrorActionPreference = 'Stop'
$core = Split-Path -Parent $PSScriptRoot
# Fail closed until an operator has checked the # CONFIRM values against the
# current Outbound Deployment Steps runbook (task name / log dir not in SERVERS.md).
if (-not $ConfirmedRunbookValues) {
    throw 'Refusing to run: confirm the scheduled-task name and fresh-log directory, then pass -ConfirmedRunbookValues.'
}

$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_OutboundDBQ_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

# Backup and rollback wiring for this processor:
# - TargetRoot is the live processor tree that will be backed up before deploy.
# - BackupRoot is the folder where dated restore points are stored for rollback.
$fixed = @{
    Processor              = 'OutboundDBQ'
    TargetRoot             = 'C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor'
    ManifestPath           = 'D:\baselines\OutboundDBQ.json'
    ConfigContract         = 'D:\baselines\OutboundDBQ.config.json'
    # Live config. Sitting under TargetRoot, it doubles as the gate's required
    # staged artifact, so the staged tree must ship this file (see header).
    ConfigPath             = 'C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe.config'
    BackupRoot             = 'C:\VLER_TEST_OUTBOUND\Processors\BackUp'
    # SERVERS.md documents the DBQ batch file as VLER_EM_Realtime_DBQ_Processor.bat;
    # the Task Scheduler job that launches it is assumed to carry the same name.
    ScheduledTasks         = @('VLER_EM_Realtime_DBQ_Processor')            # CONFIRM task name
    FreshLogDir            = 'C:\VLER_TEST_OUTBOUND\Logs\VES.OutboundProcessor'  # CONFIRM log dir
    # kill the running console-exe instance before copy; relaunch via task after
    KillProcesses          = $true
    StartTasksAfter        = $true
    ProcessArgumentPattern = '\bRTPDP\b'
    RequiredAssemblies     = @('C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe')
    # DBQ has no actuator endpoint; leave these empty
    ServiceName            = ''
    HealthUrl              = ''
}

# -ConfirmedRunbookValues is an operator's word for it; these two checks make it
# falsifiable against the box itself. Left unchecked, a wrong task name surfaces
# in the stop stage and a wrong log dir as a health failure after the copy --
# both of them after production has already been opened. Read-only, so it costs
# nothing to run before every deploy rather than only the first.
$unverified = @()
foreach ($taskName in $fixed.ScheduledTasks) {
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        $unverified += "scheduled task '$taskName' does not exist on $env:COMPUTERNAME"
    }
}
if (-not (Test-Path -LiteralPath $fixed.FreshLogDir)) {
    $unverified += "fresh-log directory '$($fixed.FreshLogDir)' does not exist"
}
if ($unverified.Count) {
    throw ("Runbook values do not match this server, so -ConfirmedRunbookValues cannot be true: {0}. Correct them in this wrapper from the current Outbound Deployment Steps runbook." -f ($unverified -join '; '))
}

$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment 'uat' -LogFile $log
# Hardcoded uat: PROD paths/hosts live on VESEMSEGRESS02/03 and need a separate wrapper.
exit $LASTEXITCODE
