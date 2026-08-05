#Requires -Version 5.1
<#
.SYNOPSIS
    Per-processor deploy script. TEMPLATE - copy once per confirmed system.
.DESCRIPTION
    One of these exists per manual-copy system (the brief's "one deploy script
    per VLER/VEMS outbound processor"). It pins everything that is fixed for the
    system - paths, service name, health probe, scheduled tasks - so the
    operator only supplies what changes per release: the staged tree, its
    commit, and the release tag / baseline archive checkout. Everything else
    routes through ..\Deploy-Processor.ps1 (gate -> copy -> verify -> health).

    To onboard a system:
      1. copy this file to Deploy-<System>.ps1
      2. replace every SYSTEM_NAME and fill in the stop/health section
      3. capture its baseline (Invoke-Verification -Mode Capture -ArchiveRepo
         -ReleaseTag <system>/vX.Y.Z -PushRemote) so the Git release tag is
         the approval record
      4. pilot on the UAT egress (vesemsegressuat) with -WhatIf first, then
         for real, before touching a PROD egress server

    STAGE THE CONFIG: the copy mirrors with /MIR, so the staged tree must already
    contain the .exe.config this server is meant to run -- the deploy will not
    preserve the one currently on the box. Because *.config is excluded from hash
    verification, the gate is what enforces this: ConfigPath below is turned into
    a required staged artifact, and a release that shipped without the config is
    blocked before anything is copied.

    Two shapes to fill in, pick the one that matches the system:
      - Outbound .exe processor (VESEMSEGRESS0x): set ScheduledTasks to the Task
        Scheduler jobs on THIS server (e.g. VLER_EM_Realtime_DBQ_Processor),
        FreshLogDir to its log folder under the tier root (UAT example:
        C:\VLER_TEST_OUTBOUND\Logs\...), leave ServiceName/HealthUrl empty.
        There is no actuator endpoint. TargetRoot is the per-tier
        ...\Processors\VES.OutboundProcessor folder (see SERVERS.md), not
        ...\Processors\<name>.
      - Java/Spring Boot service (VESOMSVEMS0x, VESMERA0x): set ServiceName (e.g.
        oms-vems-pagecount-prod) and HealthUrl (e.g.
        http://localhost:9191/actuator/health), leave ScheduledTasks empty.
        NOTE: these services are excluded from the current scope per the brief
        (gateway/MERA = later work); shape kept for that later onboarding.

    SERVER-AWARE: PROD splits the outbound processors across VESEMSEGRESS01/02/03
    (VEMS-5346) while UAT runs all three on one host. Set ScheduledTasks to only
    the jobs that live on the server this script runs on; onboard a separate
    Deploy-<System>-<server>.ps1 where the split differs.

    The in-scope system list is unconfirmed as of 2026-07; the values below are
    documented examples, confirm against the "Outbound Deployment Steps" runbook.
.EXAMPLE
    .\Deploy-SYSTEM_NAME.ps1 -StagedRoot D:\stage\SYSTEM_NAME -StagedCommit abc1234 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    # The anchor: this deploy's release tag (e.g. SYSTEM_NAME/v1.4.0) and the
    # baseline archive checkout it is recorded in. Both mandatory here because
    # Deploy-Processor refuses to run without them -- there is no unanchored
    # deploy -- and a wrapper that let them default would just fail later with a
    # less helpful message.
    [Parameter(Mandatory)][string]$ReleaseTag,
    [Parameter(Mandatory)][string]$BaselineRepo,
    [ValidateSet('dev', 'qa', 'uat', 'prod', 'production')][string]$Environment = 'uat',
    [string]$AuditLogDir
)
$ErrorActionPreference = 'Stop'
$core = Split-Path -Parent $PSScriptRoot

$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_SYSTEM_NAME_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

# ---- fixed per system: edit these when copying the template -----------------
# Backup and rollback wiring for this processor:
# - TargetRoot is the live processor tree that will be backed up before deploy.
# - BackupRoot is the folder where dated restore points are stored for rollback.
# Values below are shaped for an outbound .exe processor on an egress server.
$fixed = @{
    Processor              = 'SYSTEM_NAME'                                   # e.g. OutboundDBQ
    # Per-tier install folder (SERVERS.md): not ...\Processors\SYSTEM_NAME
    TargetRoot             = 'C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor'
    ManifestPath           = 'D:\baselines\SYSTEM_NAME.json'
    ConfigContract         = 'D:\baselines\SYSTEM_NAME.config.json'
    # Live config. Sitting under TargetRoot, it doubles as the gate's required
    # staged artifact, so the staged tree must ship this file (see header).
    ConfigPath             = 'C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe.config'
    # dated backup of the current prod files before overwrite (runbook convention)
    BackupRoot             = 'C:\VLER_TEST_OUTBOUND\Processors\BackUp'
    # stop/restart: the outbound processors run as Task Scheduler jobs on THIS
    # server. List only the jobs that live here (see VEMS-5346 note in header).
    # Name must match the .bat / Task Scheduler entry (e.g. Realtime_DBQ, not Real_Time).
    ScheduledTasks         = @('VLER_EM_Realtime_DBQ_Processor')
    # console EXEs hold their files open even with the task disabled: kill the
    # running instance (matched by exe path under TargetRoot, audited by PID +
    # command line) and relaunch via the task right after a clean copy
    KillProcesses          = $true
    StartTasksAfter        = $true
    # Match the processor mode argument as well as the executable path (RTPDP = DBQ).
    ProcessArgumentPattern = '\bRTPDP\b'
    # health for an endpoint-less .exe: a fresh line in today's log proves life
    FreshLogDir            = 'C:\VLER_TEST_OUTBOUND\Logs\VES.OutboundProcessor'
    # .NET assembly load check (defect UAT may have signed off on)
    RequiredAssemblies     = @('C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe')
    # --- Java/Spring Boot variant instead of the two lines above: ---
    # ServiceName       = 'oms-vems-pagecount-prod'
    # HealthUrl         = 'http://localhost:9191/actuator/health'
    ServiceName            = ''
    HealthUrl              = ''
}
# ------------------------------------------------------------------------------

# -WhatIf propagates via $WhatIfPreference; Deploy-Processor then runs gate-only
$passthru = @{}
$passthru['ReleaseTag'] = $ReleaseTag
$passthru['BaselineRepo'] = $BaselineRepo
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment $Environment -LogFile $log
exit $LASTEXITCODE
