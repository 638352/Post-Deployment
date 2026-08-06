#Requires -Version 5.1
<#
.SYNOPSIS
    PROD deploy for the shared XML + DBQ outbound tree on VESEMSEGRESS02.
.DESCRIPTION
    Derived from "4.7 Rollout Instructions" (Deployment Instructions.pdf),
    VESEMSEGRESS02 / "XML & DBQ":

      1. back up c:\vler_outbound_and_dbq\processors\ves.outboundprocessor
      2. stop the VES.OutboundDBQProcessor.exe instances running from that directory
      3. delete all files EXCEPT the exe.config files
      4. copy the release in
      5. start scheduled task VLER_EM_Real_Time_DBQ_Processor
      6. start scheduled task VLER_EM_Real_Time_Outbound_Processor
      7. confirm activity under E:\VLER_OUTBOUND_AND_DBQ\Logs\VES.OutboundProcessor

    ONE TREE, TWO PROCESSORS. XML and DBQ are two instances of the same executable
    launched from the SAME folder with different mode arguments (RTP and RTPDP),
    so this is one deployment unit with two scheduled tasks -- not two units. Three
    consequences worth knowing before running it:

      * The stop phase kills every instance under TargetRoot, so deploying this
        tree takes BOTH processors down. That is what the runbook does too; it is
        not a way to deploy one of them in isolation.
      * Both tasks must be listed, or the mirror runs while the unlisted
        processor still holds files open and that processor is never restarted.
      * Both write to the same log directory, so the fresh-log probe proves only
        that SOMETHING in this tree is alive. The task last-run result and the
        per-mode process match are what distinguish them; do not read a fresh log
        alone as proof that both came back.

    Passing two scheduled tasks used to fail this deploy's health stage outright:
    the child stages run under `powershell.exe -File`, which cannot bind an array.
    Multi-values now travel joined (module: ConvertTo-VesList / Expand-VesList).

    Step 3's "except the exe.config files" is why PreserveFiles is '*.config'.

    UNCONFIRMED, marked # CONFIRM: baseline/contract/backup paths follow this
    repository's conventions -- 4.7 names none of them.
.EXAMPLE
    .\Deploy-OutboundDBQ-vesemsegress02.ps1 -StagedRoot D:\stage\OutboundDBQ `
      -StagedCommit abc1234 -ReleaseTag OutboundDBQ/v4.7.0 -BaselineRepo D:\baselines\archive `
      -ConfirmedRunbookValues -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$BaselineRepo,
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
    Processor              = 'OutboundDBQ'
    TargetRoot             = 'C:\VLER_OUTBOUND_AND_DBQ\Processors\VES.OutboundProcessor'
    ManifestPath           = 'D:\baselines\OutboundDBQ.json'                 # CONFIRM baseline path
    ConfigContract         = 'D:\baselines\OutboundDBQ.config.json'          # CONFIRM contract path
    ConfigPath             = 'C:\VLER_OUTBOUND_AND_DBQ\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe.config'
    BackupRoot             = 'C:\VLER_OUTBOUND_AND_DBQ\Processors\BackUp'    # CONFIRM backup location
    # 4.7 step 3: "delete all files except the exe.config files" -> robocopy /XF
    PreserveFiles          = @('*.config')
    # BOTH, in the runbook's start order. Listing only one leaves the other
    # holding the tree open through the mirror and never restarts it.
    ScheduledTasks         = @('VLER_EM_Real_Time_DBQ_Processor', 'VLER_EM_Real_Time_Outbound_Processor')
    KillProcesses          = $true
    StartTasksAfter        = $true
    # Matches BOTH instances in this shared folder: RTPDP is DBQ, RTP is XML.
    ProcessArgumentPattern = '\bRTP(DP)?\b'
    # Shared by both processors -- see the header: freshness here is not per-processor.
    FreshLogDir            = 'E:\VLER_OUTBOUND_AND_DBQ\Logs\VES.OutboundProcessor'
    RequiredAssemblies     = @('C:\VLER_OUTBOUND_AND_DBQ\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe')
    ServiceName            = ''
    HealthUrl              = ''
}

$unverified = @(Test-VesRunbookValues -ExpectedServer 'VESEMSEGRESS02' -TargetRoot $fixed.TargetRoot `
        -ScheduledTasks $fixed.ScheduledTasks -FreshLogDir $fixed.FreshLogDir -BackupRoot $fixed.BackupRoot)
if ($unverified.Count) {
    throw ("Runbook values do not match this server, so -ConfirmedRunbookValues cannot be true: {0}. Correct them in this wrapper from the current deployment runbook." -f ($unverified -join '; '))
}

# Only after the server check: creating the audit folder first means a wrapper run
# on the wrong box fails with a missing-drive error instead of the refusal that
# actually explains what went wrong.
$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_OutboundDBQ_egress02_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment 'prod' -LogFile $log
# Hardcoded prod: this wrapper names VESEMSEGRESS02's XML+DBQ tree and nothing else.
exit $LASTEXITCODE
