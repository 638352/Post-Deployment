#Requires -Version 5.1
<#
.SYNOPSIS
    PROD deploy for the acknowledgement processor on VESEMSEGRESS02.
.DESCRIPTION
    Derived from "4.7 Rollout Instructions" (Deployment Instructions.pdf),
    VESEMSEGRESS02 / Ack:

      1. back up c:\vler\processors\VES.OutboundProcessor
      2. stop the VES.OutboundDBQProcessor.exe instance running from that
         directory (the runbook notes there should only be one)
      3. delete all files EXCEPT the exe.config files
      4. copy the release in
      5. start scheduled task VLER_EM_Real_Time_Acknowledgement_Processor
      6. confirm activity under E:\VLER\Logs\VES.OutboundProcessor

    VESEMSEGRESS02 runs TWO deployment units out of two different trees: Ack here,
    and XML+DBQ out of c:\vler_outbound_and_dbq (see
    Deploy-OutboundDBQ-vesemsegress02.ps1). They are separate releases with
    separate baselines -- do not point one wrapper at the other's tree.

    Step 3's "except the exe.config files" is why PreserveFiles is '*.config'.
    The server keeps its own config; Verify-Config still proves it against its
    contract, and *.config is outside the byte-hash baseline by design.

    Ack's mode argument is RTP, the same as XML/Outbound -- the folder is what
    distinguishes the two, which is why TargetRoot is the instance identity here.

    UNCONFIRMED, marked # CONFIRM: baseline/contract/backup paths follow this
    repository's conventions -- 4.7 names none of them.
.EXAMPLE
    .\Deploy-Ack-vesemsegress02.ps1 -StagedRoot D:\stage\Ack -StagedCommit abc1234 `
      -ReleaseTag Ack/v4.7.0 -BaselineRepo D:\baselines\archive -ConfirmedRunbookValues -WhatIf
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
    Processor              = 'Ack'
    TargetRoot             = 'C:\VLER\Processors\VES.OutboundProcessor'
    ManifestPath           = 'D:\baselines\Ack.json'                         # CONFIRM baseline path
    ConfigContract         = 'D:\baselines\Ack.config.json'                  # CONFIRM contract path
    ConfigPath             = 'C:\VLER\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe.config'
    BackupRoot             = 'C:\VLER\Processors\BackUp'                     # CONFIRM backup location
    # 4.7 step 3: "delete all files except the exe.config files" -> robocopy /XF
    PreserveFiles          = @('*.config')
    ScheduledTasks         = @('VLER_EM_Real_Time_Acknowledgement_Processor')
    KillProcesses          = $true
    StartTasksAfter        = $true
    ProcessArgumentPattern = '\bRTP\b'
    FreshLogDir            = 'E:\VLER\Logs\VES.OutboundProcessor'
    RequiredAssemblies     = @('C:\VLER\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe')
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
$log = Join-Path $logDir ('deploy_Ack_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment 'prod' -LogFile $log
# Hardcoded prod: this wrapper names VESEMSEGRESS02's Ack tree and nothing else.
exit $LASTEXITCODE
