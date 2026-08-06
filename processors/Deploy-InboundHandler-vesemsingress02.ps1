#Requires -Version 5.1
<#
.SYNOPSIS
    PROD deploy for the inbound request handler on VESEMSINGRESS02.
.DESCRIPTION
    Derived from "4.7 Rollout Instructions" (Deployment Instructions.pdf), the
    VESEMSINGRESS02 section:

      1. back up C:\VLER\Processors\VES.InboundProcessor
      2. disable scheduled task "VLER EM Inbound _ Request _ Handler"
      3. run five SQL rollout scripts, in order            <-- NOT done by this script
      4. delete all files EXCEPT the exe.config files
      5. copy the release in (the zip nests a folder -- flatten it when staging)
      6. start the scheduled task
      7. confirm activity under C:\VLER\Logs\VES.InboundProcessor

    DATABASE STEP IS OUT OF SCOPE FOR THIS SCRIPT. Step 3 -- TableModifications,
    EM_VAFTPContentions_Insert, EM_VAFTPDependentInfo_Insert,
    EM_VAFTPInboundStack_Update, EM_VAFTPVeteran_Insert, in that order -- is a
    database change, and database objects are excluded from the current effort per
    the brief's Scope. This script deploys files only. Run the SQL step by hand
    BEFORE invoking this wrapper, and record it separately: nothing here can reach
    the database, so -ConfirmedSqlRolloutComplete is the operator's word for it.

    "Out of scope" is NOT "unrelated". This unit is DATABASE-COUPLED: the 4.7
    procedures take parameters that have no defaults and that the prior binaries do
    not pass, so file state and database state have to move together in BOTH
    directions. That is why Invoke-Rollback.ps1 refuses to restore this processor
    without -ConfirmedSqlRollbackComplete (or -SqlRollbackDeferred, which records
    the debt), and why the rollback order is the REVERSE of the list above --
    retire the procedures first, or TableModifications Rollback drops columns they
    still reference. See docs/RUNBOOK.md 7.1.1.

    STAGING NOTE from the runbook: "there is a folder in the zip folder -- ensure
    that the effective files are in the directory above, not the folder containing
    the files". Stage the flattened tree as -StagedRoot. If the nested folder is
    left in place the gate blocks the deploy, because the staged tree then has one
    extra directory and no top-level files the baseline manifest knows about.

    Step 4's "except the exe.config files" is why PreserveFiles is '*.config': the
    server keeps its own config across the deploy (robocopy /XF), so the package
    does not have to carry it. The live config is still proven by Verify-Config
    against its contract.

    UNCONFIRMED, marked # CONFIRM: baseline/contract/backup paths follow this
    repository's conventions -- 4.7 names none of them. The task name below is
    copied verbatim from the runbook INCLUDING its spaces around the underscores.
.EXAMPLE
    .\Deploy-InboundHandler-vesemsingress02.ps1 -StagedRoot D:\stage\InboundHandler `
      -StagedCommit abc1234 -ReleaseTag InboundHandler/v4.7.0 -BaselineRepo D:\baselines\archive `
      -ConfirmedRunbookValues -ConfirmedSqlRolloutComplete -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$BaselineRepo,
    [switch]$ConfirmedRunbookValues,
    # The runbook runs five SQL scripts before the file copy. They are out of
    # scope here, so this switch is the operator stating they have been run in the
    # documented order. It is deliberately a separate acknowledgement from
    # -ConfirmedRunbookValues: they are different claims about different systems,
    # and this one cannot be checked from here.
    [switch]$ConfirmedSqlRolloutComplete,
    [string]$AuditLogDir
)
$ErrorActionPreference = 'Stop'
$core = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $core 'module\VesVerify.psm1') -Force
if (-not $ConfirmedRunbookValues) {
    throw 'Refusing to run: confirm the baseline, contract and backup paths against the current deployment runbook, then pass -ConfirmedRunbookValues.'
}
if (-not $ConfirmedSqlRolloutComplete) {
    throw 'Refusing to run: the runbook runs five SQL rollout scripts (TableModifications, EM_VAFTPContentions_Insert, EM_VAFTPDependentInfo_Insert, EM_VAFTPInboundStack_Update, EM_VAFTPVeteran_Insert) BEFORE this file copy. Run them in that order, then pass -ConfirmedSqlRolloutComplete. This script does not deploy database objects and cannot verify them.'
}

$fixed = @{
    Processor              = 'InboundHandler'
    TargetRoot             = 'C:\VLER\Processors\VES.InboundProcessor'
    ManifestPath           = 'D:\baselines\InboundHandler.json'              # CONFIRM baseline path
    ConfigContract         = 'D:\baselines\InboundHandler.config.json'       # CONFIRM contract path
    ConfigPath             = 'C:\VLER\Processors\VES.InboundProcessor\VES.InboundProcessor.exe.config'  # CONFIRM exact config leaf
    BackupRoot             = 'C:\VLER\Processors\BackUp'                     # CONFIRM backup location
    # 4.7 step 4: "delete all files except the exe.config files" -> robocopy /XF
    PreserveFiles          = @('*.config')
    # Verbatim from the runbook, spaces around the underscores included.
    ScheduledTasks         = @('VLER EM Inbound _ Request _ Handler')
    KillProcesses          = $true
    StartTasksAfter        = $true
    FreshLogDir            = 'C:\VLER\Logs\VES.InboundProcessor'
    RequiredAssemblies     = @()                                             # CONFIRM handler exe name if an assembly-load probe is wanted
    ProcessArgumentPattern = ''                                              # single processor in this tree; path match is enough
    ServiceName            = ''
    HealthUrl              = ''
}

$unverified = @(Test-VesRunbookValues -ExpectedServer 'VESEMSINGRESS02' -TargetRoot $fixed.TargetRoot `
        -ScheduledTasks $fixed.ScheduledTasks -FreshLogDir $fixed.FreshLogDir -BackupRoot $fixed.BackupRoot)
if ($unverified.Count) {
    throw ("Runbook values do not match this server, so -ConfirmedRunbookValues cannot be true: {0}. Correct them in this wrapper from the current deployment runbook." -f ($unverified -join '; '))
}

# Only after the server check: creating the audit folder first means a wrapper run
# on the wrong box fails with a missing-drive error instead of the refusal that
# actually explains what went wrong.
$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_InboundHandler_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment 'prod' -LogFile $log
# Hardcoded prod: this wrapper names VESEMSINGRESS02's paths and nothing else.
exit $LASTEXITCODE
