#Requires -Version 5.1
<#
.SYNOPSIS
    Per-processor deploy for the shared XML + DBQ outbound tree on UAT VESMSEGRESSUAT.
    Copied from Deploy-SYSTEM_NAME.ps1 and filled in for this box.
.DESCRIPTION
    ONE TREE, TWO PROCESSORS. On UAT, XML and DBQ are two instances of
    VES.OutboundDBQProcessor.exe launched from the SAME folder
    (C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor) with different mode
    args (RTP and RTPDP). See SERVERS.md. This wrapper is therefore one deployment
    unit with two scheduled tasks -- not a DBQ-only deploy.

      * The stop phase kills every instance under TargetRoot, so deploying this
        tree takes BOTH processors down. That is what the runbook does too.
      * Both tasks must be listed, or the mirror runs while the unlisted
        processor still holds files open and that processor is never restarted.
      * Both write to the same log directory, so the fresh-log probe proves only
        that SOMETHING in this tree is alive. Task last-run and the per-mode
        process match distinguish them.

    PROD lives on VESEMSEGRESS02/03 and needs its own wrappers with the
    runbook's PROD paths (and Real_Time task names, not Realtime).

    CONFIRM before a real run: the values tagged # CONFIRM are not in SERVERS.md
    (scheduled-task names, log dir). Pull them from the Outbound Deployment Steps
    runbook. -ConfirmedRunbookValues is not taken on trust: Test-VesRunbookValues
    checks hostname, target, both tasks, log dir, and backup parent, and refuses
    to run if any check fails.

    STAGE THE CONFIG: the copy mirrors with /MIR, so StagedRoot must already
    contain VES.OutboundDBQProcessor.exe.config with this box's values -- the
    deploy replaces the one on the server rather than preserving it. The gate
    enforces it (ConfigPath below becomes a required staged artifact), so a
    package without the config is blocked before anything is copied.
.EXAMPLE
    .\Deploy-OutboundDBQ-uat.ps1 -StagedRoot D:\stage\OutboundDBQ `
      -StagedCommit abc1234 -ReleaseTag OutboundDBQ/v1.4.0 -BaselineRepo D:\ves-baselines `
      -ConfirmedRunbookValues -WhatIf
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
    # Required until the values marked CONFIRM below have been checked
    # against the current Outbound Deployment Steps runbook.
    [switch]$ConfirmedRunbookValues,
    [string]$AuditLogDir
)
$ErrorActionPreference = 'Stop'
$core = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $core 'module\VesVerify.psm1') -Force
# Fail closed until an operator has checked the # CONFIRM values against the
# current Outbound Deployment Steps runbook (task names / log dir not in SERVERS.md).
if (-not $ConfirmedRunbookValues) {
    throw 'Refusing to run: confirm the scheduled-task names and fresh-log directory, then pass -ConfirmedRunbookValues.'
}

# Backup and rollback wiring for this shared UAT outbound tree:
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
    # BOTH. SERVERS.md: XML and DBQ share this folder on UAT. Listing only DBQ
    # leaves the XML instance holding files open through the mirror and never
    # restarted. Task Scheduler names are assumed to match the .bat leaf names;
    # UAT uses Realtime (PROD uses Real_Time) -- do not copy these into a PROD
    # wrapper.
    ScheduledTasks         = @(
        'VLER_EM_Realtime_DBQ_Processor',                 # CONFIRM task name
        'VLER_EM_Realtime_Outbound_Request_Processor'     # CONFIRM task name (XML / RTP)
    )
    FreshLogDir            = 'C:\VLER_TEST_OUTBOUND\Logs\VES.OutboundProcessor'  # CONFIRM log dir
    # kill every running console-exe instance under TargetRoot before copy;
    # relaunch BOTH via their scheduled tasks after a clean copy
    KillProcesses          = $true
    StartTasksAfter        = $true
    # Matches BOTH instances in this shared folder: RTPDP is DBQ, RTP is XML.
    ProcessArgumentPattern = '\bRTP(DP)?\b'
    RequiredAssemblies     = @('C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe')
    # Shared tree has no actuator endpoint; leave these empty
    ServiceName            = ''
    HealthUrl              = ''
}

# -ConfirmedRunbookValues is an operator's word for it; these checks make it
# falsifiable against the box itself. Left unchecked, a wrong task name surfaces
# in the stop stage and a wrong log dir as a health failure after the copy --
# both of them after production has already been opened. Read-only, so it costs
# nothing to run before every deploy rather than only the first.
$unverified = @(Test-VesRunbookValues -ExpectedServer 'VESMSEGRESSUAT' -TargetRoot $fixed.TargetRoot `
        -ScheduledTasks $fixed.ScheduledTasks -FreshLogDir $fixed.FreshLogDir -BackupRoot $fixed.BackupRoot)
if ($unverified.Count) {
    throw ("Runbook values do not match this server, so -ConfirmedRunbookValues cannot be true: {0}. Correct them in this wrapper from the current Outbound Deployment Steps runbook." -f ($unverified -join '; '))
}

# Only after the server check: creating the audit folder first means a wrapper run
# on the wrong box fails with a missing-drive error instead of the refusal that
# actually explains what went wrong.
$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_OutboundDBQ_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment 'uat' -LogFile $log
# Hardcoded uat: PROD paths/hosts live on VESEMSEGRESS02/03 and need a separate wrapper.
exit $LASTEXITCODE
