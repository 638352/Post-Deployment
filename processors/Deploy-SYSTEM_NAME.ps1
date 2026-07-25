#Requires -Version 5.1
<#
.SYNOPSIS
    Per-processor deploy script. TEMPLATE - copy once per confirmed system.
.DESCRIPTION
    One of these exists per manual-copy system (the brief's "one deploy script
    per VLER/VEMS outbound processor"). It pins everything that is fixed for the
    system - paths, SSM parameter names, service name, health probe - so the
    operator only supplies what changes per release: the staged tree and its
    commit. Everything else routes through ..\Deploy-Processor.ps1
    (gate -> copy -> verify -> health).

    To onboard a system:
      1. copy this file to Deploy-<System>.ps1
      2. replace every SYSTEM_NAME and fill in the stop/health section
      3. capture its baseline (Invoke-Verification -Mode Capture) and pin
         /ves/<system>/approved-commit in SSM
      4. pilot on the UAT egress (vesemsegressuat) with -WhatIf first, then
         for real, before touching a PROD egress server

    Two shapes to fill in, pick the one that matches the system:
      - Outbound .exe processor (VESEMSEGRESS0x): set ScheduledTasks to the Task
        Scheduler jobs on THIS server (e.g. VLER_EM_Real_Time_Outbound_Processor),
        FreshLogDir to its C:\VLER_Test\Logs\... folder, leave ServiceName/HealthUrl
        empty. There is no actuator endpoint.
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
    # Release tag of the approved baseline (e.g. SYSTEM_NAME/v1.4.0); recorded
    # in every stage's run log. With -BaselineRepo the gate/verify also
    # cross-check the manifest archived under that tag.
    [string]$ReleaseTag,
    [string]$BaselineRepo,
    [ValidateSet('dev','qa','uat','prod','production')][string]$Environment = 'uat',
    [string]$AuditLogDir,
    [string]$Region = 'us-gov-west-1'
)
$ErrorActionPreference = 'Stop'
$core = Split-Path -Parent $PSScriptRoot

$logDir = if ($AuditLogDir) { $AuditLogDir } elseif ($env:VES_AUDIT_LOG_DIR) { $env:VES_AUDIT_LOG_DIR } else { 'D:\ves-verify\logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir ('deploy_SYSTEM_NAME_{0}.jsonl' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))

# ---- fixed per system: edit these when copying the template -----------------
# Values below are shaped for an outbound .exe processor on an egress server.
$fixed = @{
    Processor           = 'SYSTEM_NAME'                                   # e.g. OutboundDBQProcessor
    TargetRoot          = 'C:\VLER_Test\Processors\SYSTEM_NAME'           # where the .exe lives on the box
    ManifestPath        = 'D:\baselines\SYSTEM_NAME.json'
    TrustParam          = '/ves/SYSTEM_NAME/baseline-hash'
    ApprovedCommitParam = '/ves/SYSTEM_NAME/approved-commit'
    ConfigContract      = 'D:\baselines\SYSTEM_NAME.config.json'
    ConfigPath          = 'C:\VLER_Test\Processors\SYSTEM_NAME\VES.OutboundDBQProcessor.exe.config'
    # dated backup of the current prod files before overwrite (runbook convention)
    BackupRoot          = 'C:\VLER_Test\Processors\BackUp'
    # stop/restart: the outbound processors run as Task Scheduler jobs on THIS
    # server. List only the jobs that live here (see VEMS-5346 note in header).
    ScheduledTasks      = @('VLER_EM_Real_Time_Outbound_Processor')
    # console EXEs hold their files open even with the task disabled: kill the
    # running instance (matched by exe path under TargetRoot, audited by PID +
    # command line) and relaunch via the task right after a clean copy
    KillProcesses       = $true
    StartTasksAfter     = $true
    # Match the processor mode argument as well as the executable path.
    ProcessArgumentPattern = '\bRTPDP\b'
    # health for an endpoint-less .exe: a fresh line in today's log proves life
    FreshLogDir         = 'C:\VLER_Test\Logs\VES.OutboundProcessor'
    # .NET assembly load check (defect UAT may have signed off on)
    RequiredAssemblies  = @('C:\VLER_Test\Processors\SYSTEM_NAME\VES.OutboundDBQProcessor.exe')
    # --- Java/Spring Boot variant instead of the two lines above: ---
    # ServiceName       = 'oms-vems-pagecount-prod'
    # HealthUrl         = 'http://localhost:9191/actuator/health'
    ServiceName         = ''
    HealthUrl           = ''
}
# ------------------------------------------------------------------------------

# -WhatIf propagates via $WhatIfPreference; Deploy-Processor then runs gate-only
$passthru = @{}
if ($ReleaseTag)   { $passthru['ReleaseTag'] = $ReleaseTag }
if ($BaselineRepo) { $passthru['BaselineRepo'] = $BaselineRepo }
& (Join-Path $core 'Deploy-Processor.ps1') @fixed @passthru `
    -StagedRoot $StagedRoot -StagedCommit $StagedCommit -Environment $Environment -Region $Region -LogFile $log
exit $LASTEXITCODE
