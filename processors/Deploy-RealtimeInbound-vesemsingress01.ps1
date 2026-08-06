#Requires -Version 5.1
<#
.SYNOPSIS
    PROD deploy for the real-time inbound event service on VESEMSINGRESS01.
.DESCRIPTION
    Derived from "4.7 Rollout Instructions" (Deployment Instructions.pdf), the
    VESEMSINGRESS01 section. That runbook's manual sequence is:

      1. back up C:\vler\processors\ves.realtimeinboundeventservice
      2. stop service VES.RealtimeInboundEventService
      3. delete all files EXCEPT the exe.config files
      4. copy the release in
      5. start the service
      6. confirm activity under C:\VLER\Logs\VES.InboundProcessor

    Deploy-Processor performs exactly that, with the gate in front of it and a
    file/config/health proof behind it. Step 3's "except the exe.config files" is
    why PreserveFiles is '*.config' below: the server keeps its own config across
    the deploy (robocopy /XF), so the staged package does not have to carry it.
    The config is still proven -- Verify-Config checks the live file against its
    contract, and *.config is outside the byte-hash baseline by design.

    This is the ONE unit in 4.7 that runs as a Windows service rather than a
    scheduled task, so ServiceName is set and ScheduledTasks is empty. There is no
    console-EXE instance to kill; Stop-Service releases the file handles.

    UNCONFIRMED, marked # CONFIRM below: the baseline/contract/backup paths follow
    this repository's D:\baselines and ...\Processors\BackUp conventions -- 4.7
    names neither. -ConfirmedRunbookValues is not taken on trust: the values are
    checked against this server and the script refuses to run on a mismatch.

    NOTE on the rollback half of 4.7: its VESEMSINGRESS01 step 2 says to clear
    C:\VLER\Processors\VES.OutboundProcessor, which is the OUTBOUND tree and does
    not belong to this service. Treat that as a copy/paste error in the document;
    rollback here is Invoke-Rollback against the backup this deploy takes.
.EXAMPLE
    .\Deploy-RealtimeInbound-vesemsingress01.ps1 -StagedRoot D:\stage\RealtimeInbound `
      -StagedCommit abc1234 -ReleaseTag RealtimeInbound/v4.7.0 -BaselineRepo D:\baselines\archive `
      -ConfirmedRunbookValues -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    # The anchor: this deploy's release tag and the baseline archive checkout it is
    # recorded in. Both mandatory because Deploy-Processor refuses an unanchored
    # deploy, and a wrapper that let them default would fail later, less clearly.
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$BaselineRepo,
    # Required until the # CONFIRM values below are checked against the current
    # deployment runbook for this server.
    [switch]$ConfirmedRunbookValues,
    [string]$AuditLogDir
)
$ErrorActionPreference = 'Stop'
$core = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $core 'module\VesVerify.psm1') -Force
if (-not $ConfirmedRunbookValues) {
    throw 'Refusing to run: confirm the baseline, contract and backup paths against the current deployment runbook, then pass -ConfirmedRunbookValues.'
}

$fixed = @{
    Processor          = 'RealtimeInbound'
    TargetRoot         = 'C:\VLER\Processors\VES.RealtimeInboundEventService'
    ManifestPath       = 'D:\baselines\RealtimeInbound.json'                 # CONFIRM baseline path
    ConfigContract     = 'D:\baselines\RealtimeInbound.config.json'          # CONFIRM contract path
    ConfigPath         = 'C:\VLER\Processors\VES.RealtimeInboundEventService\VES.RealtimeInboundEventService.exe.config'  # CONFIRM exact config leaf
    BackupRoot         = 'C:\VLER\Processors\BackUp'                         # CONFIRM backup location
    # 4.7 step 3: "delete all files except the exe.config files" -> robocopy /XF
    PreserveFiles      = @('*.config')
    # A Windows service, not a Task Scheduler job: this is the only such unit in 4.7.
    ServiceName        = 'VES.RealtimeInboundEventService'
    ScheduledTasks     = @()
    # No console-EXE instance to kill -- Stop-Service releases the handles. There
    # is nothing for StartTasksAfter to start either; the service restart is
    # handled by Start-VesProcessorTarget from ServiceName.
    KillProcesses      = $false
    StartTasksAfter    = $false
    FreshLogDir        = 'C:\VLER\Logs\VES.InboundProcessor'
    RequiredAssemblies = @()                                                 # CONFIRM service exe name if an assembly-load probe is wanted
    HealthUrl          = ''
}

# -ConfirmedRunbookValues is an operator's word for it; this makes it falsifiable
# against the box, read-only, before anything is copied.
$unverified = @(Test-VesRunbookValues -ExpectedServer 'VESEMSINGRESS01' -TargetRoot $fixed.TargetRoot `
        -ServiceName $fixed.ServiceName -FreshLogDir $fixed.FreshLogDir -BackupRoot $fixed.BackupRoot)
if ($unverified.Count) {
    throw ("Runbook values do not match this server, so -ConfirmedRunbookValues cannot be true: {0}. Correct them in this wrapper from the current deployment runbook." -f ($unverified -join '; '))
}

# Only after the server check: creating the audit folder first means a wrapper run
# on the wrong box fails with a missing-drive error instead of the refusal that
# actually explains what went wrong.
$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_RealtimeInbound_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment 'prod' -LogFile $log
# Hardcoded prod: this wrapper names VESEMSINGRESS01's paths and nothing else.
exit $LASTEXITCODE
