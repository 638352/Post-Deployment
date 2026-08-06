#Requires -Version 5.1
<#
.SYNOPSIS
    PROD deploy for the XML / outbound request processor on VESEMSEGRESS01.
.DESCRIPTION
    Derived from "4.7 Rollout Instructions" (Deployment Instructions.pdf). NOTE:
    that section is headed "Vesemsingress01", but it is unambiguously
    VESEMSEGRESS01 -- it deploys VES.OutboundDBQProcessor.exe, its logs are under
    E:\VLER\Logs\VES.OutboundProcessor, and its own config-replacement share
    folder is named "Vesemsegress01 OutboundProcessor Config Replacement". Treat
    the heading as a typo in the document.

      1. back up C:\VLER\Processors\VES.OutboundProcessor
      2. stop the VES.OutboundDBQProcessor.exe instance running from that directory
      3. delete all files INCLUDING the exe.config file
      4. copy the release in
      5. ALSO copy a pre-edited VES.OutboundDBQProcessor.exe.config
      6. start scheduled task VLER_EM_Real_Time_Outbound_Processor
      7. confirm activity under E:\VLER\Logs\VES.OutboundProcessor

    THIS UNIT REPLACES ITS CONFIG, and it is the only one in 4.7 that does. Step 3
    says "including the exe.config file" because 4.7 adds a new entry to it, and
    step 5 copies a pre-edited file rather than having an operator hand-edit the
    live one. So PreserveFiles stays EMPTY here (the mirror installs the package's
    config), which in turn makes the gate require that config in the staged tree:
    a package that shipped without it is blocked before anything is copied.

    STAGE IT AS ONE TREE. The runbook's steps 4 and 5 are two copies from two
    share locations; stage the release and the pre-edited config together into a
    single -StagedRoot first, so what the gate hashes and approves is exactly what
    lands on the server. Two separate copies would put an unverified file into
    production after the gate had already passed.

    Same executable name, several folders: the running instance is identified by
    its exe path under TargetRoot, and ProcessArgumentPattern additionally matches
    the RTP mode argument (SERVERS.md).

    UNCONFIRMED, marked # CONFIRM: baseline/contract/backup paths follow this
    repository's conventions -- 4.7 names none of them.
.EXAMPLE
    .\Deploy-Outbound-vesemsegress01.ps1 -StagedRoot D:\stage\Outbound `
      -StagedCommit abc1234 -ReleaseTag Outbound/v4.7.0 -BaselineRepo D:\baselines\archive `
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
    Processor              = 'Outbound'
    TargetRoot             = 'C:\VLER\Processors\VES.OutboundProcessor'
    ManifestPath           = 'D:\baselines\Outbound.json'                    # CONFIRM baseline path
    ConfigContract         = 'D:\baselines\Outbound.config.json'             # CONFIRM contract path
    ConfigPath             = 'C:\VLER\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe.config'
    BackupRoot             = 'C:\VLER\Processors\BackUp'                     # CONFIRM backup location
    # DELIBERATELY EMPTY: 4.7 step 3 is "delete all files INCLUDING the exe.config
    # file", so the mirror installs the package's config. That also makes the gate
    # demand it in the staged tree -- see the header.
    PreserveFiles          = @()
    ScheduledTasks         = @('VLER_EM_Real_Time_Outbound_Processor')
    KillProcesses          = $true
    StartTasksAfter        = $true
    # RTP = Ack and XML/Outbound share this mode arg; the folder distinguishes them.
    ProcessArgumentPattern = '\bRTP\b'
    FreshLogDir            = 'E:\VLER\Logs\VES.OutboundProcessor'
    RequiredAssemblies     = @('C:\VLER\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe')
    ServiceName            = ''
    HealthUrl              = ''
}

$unverified = @(Test-VesRunbookValues -ExpectedServer 'VESEMSEGRESS01' -TargetRoot $fixed.TargetRoot `
        -ScheduledTasks $fixed.ScheduledTasks -FreshLogDir $fixed.FreshLogDir -BackupRoot $fixed.BackupRoot)
if ($unverified.Count) {
    throw ("Runbook values do not match this server, so -ConfirmedRunbookValues cannot be true: {0}. Correct them in this wrapper from the current deployment runbook." -f ($unverified -join '; '))
}

# Only after the server check: creating the audit folder first means a wrapper run
# on the wrong box fails with a missing-drive error instead of the refusal that
# actually explains what went wrong.
$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_Outbound_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment 'prod' -LogFile $log
# Hardcoded prod: this wrapper names VESEMSEGRESS01's paths and nothing else.
exit $LASTEXITCODE
