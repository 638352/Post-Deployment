#Requires -Version 5.1
<#
.DESCRIPTION
    Runs the pre-deploy gate, stops the running processor (Task Scheduler job(s)
    for the outbound .exe processors and/or a Windows service for the Java
    services), backs up the current target to a dated folder, mirrors the staged
    tree into place with robocopy, restarts the processor, verifies the result
    against the trusted baseline, then runs the health check. Any stage failing
    aborts with that stage's exit code. Pilot in QA/UAT egress first.

    Stop/restart uses a try/finally so a failed copy still re-enables the tasks
    and restarts the service rather than leaving the processor down.

    Console-EXE instances: disabling a scheduled task does NOT kill an already
    running instance holding the target files open. Before the copy, any process
    whose ExecutablePath lives under TargetRoot is detected (that is what
    identifies THIS instance -- the same exe name runs 2-3 times per box from
    different folders). Found instances abort the deploy unless -KillProcesses
    is set, in which case each is force-stopped with an audit line (PID +
    command line, so the RTP/RTPDP mode is on record). -StartTasksAfter starts
    the re-enabled tasks immediately after a clean copy, relaunching the
    processor via its own scheduled task rather than waiting for the next
    trigger; a failed deploy is never auto-started.

    Break-glass is intentionally not wired through here (open policy decision).
    -WhatIf runs the gate only and skips stop/backup/copy.

    Server-aware by design: pass only the -ScheduledTasks that live on THIS
    server. PROD splits the outbound processors across VESEMSEGRESS01/02/03
    (VEMS-5346) whereas UAT runs all three on one box, so the per-processor
    wrapper in processors/ sets the right task list per target server.

    Processor names in examples are placeholders. The actual in-scope system
    list is unconfirmed as of 2026-07; do not assume VLER or vemsoutbound naming.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Processor,
    [string]$StagedRoot,
    [string]$TargetRoot,
    [string]$StagedCommit,
    [string]$ManifestPath,
    [string]$TrustParam,
    [string]$ApprovedCommitParam,
    # Release tag of the approved baseline (e.g. OutboundDBQ/v1.4.0). Threaded
    # through the gate, verification, and health stages so every stage's run log
    # names the release it checked. With -BaselineRepo the gate and verification
    # also cross-check the manifest archived under that tag.
    [string]$ReleaseTag,
    [string]$BaselineRepo,
    [string]$ConfigContract,
    [string]$ConfigPath,
    # Relative staged paths that must exist even though they are excluded from
    # byte hashing (for example *.config files or required empty folders).
    [string[]]$RequiredArtifactPaths = @(),
    [string[]]$RequiredAssemblies = @(),
    [string]$ServiceName,
    # Task Scheduler jobs on THIS server to disable before copy / re-enable after,
    # e.g. VLER_EM_Real_Time_Outbound_Processor. Empty for service-only systems.
    [string[]]$ScheduledTasks = @(),
    # kill running instances whose exe lives under TargetRoot (console-EXE
    # processors hold their files open; without this the deploy aborts instead)
    [switch]$KillProcesses,
    # start the re-enabled scheduled tasks right after a clean copy, so the
    # processor relaunches now instead of at its next trigger
    [switch]$StartTasksAfter,
    # dated backup of the current target before overwrite (runbook convention:
    # <BackupRoot>\<yyyyMMdd>_<Initials>_<Processor>). Skipped if not set.
    [string]$BackupRoot,
    # newest N backups to keep for this processor; older ones get pruned after a
    # successful deploy only. 0 keeps everything.
    [int]$KeepBackups = 5,
    [switch]$Rollback,
    [string]$RollbackBackup,
    [string]$Initials = $env:USERNAME,
    [string]$HealthUrl,
    # liveness for endpoint-less .exe processors; passed through to the health check
    [string]$FreshLogDir,
    [int]$FreshLogMaxAgeMinutes = 60,
    [string]$ProcessArgumentPattern,
    [string]$Environment = 'prod',
    [string]$Region = 'us-gov-west-1',
    [string]$LogFile
)
# Backup and rollback capabilities:
# - Deploy mode creates a dated backup of the live TargetRoot before overwriting it.
# - Rollback mode restores a previously created backup tree back into TargetRoot.
# - Each processor wrapper supplies the live target path and backup root used here.
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $LogFile) { $LogFile = New-VesLogFile -Prefix ("deploy-{0}-{1}" -f $Processor, $StagedCommit) }
$runId = [guid]::NewGuid().ToString()
Write-VesLog INFO 'RUN START: deployment' `
    -Data @{runId = $runId; script = 'Deploy-Processor.ps1'; processor = $Processor; environment = $Environment; release = $StagedCommit; releaseTag = $ReleaseTag; target = $TargetRoot } `
    -LogFile $LogFile

# --- DATADOG DISABLED ---------------------------------------------------------
# Low-cardinality tags shared by every deploy event emitted to Datadog.
# $ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag -Environment $Environment))
# ------------------------------------------------------------------------------

function Stop-Deploy([int]$code) {
    $outcome = Get-VesOutcome -ExitCode $code
    Write-VesLog ($(if ($outcome -eq 'PASS') { 'OK' } elseif ($outcome -eq 'FAIL') { 'ERROR' } else { 'ERROR' })) `
        "RUN END: deployment outcome=$outcome exit=$code" `
        -Data @{runId = $runId; outcome = $outcome; exitCode = $code; processor = $Processor; release = $StagedCommit; releaseTag = $ReleaseTag } -LogFile $LogFile
    exit $code
}

# Rollback capability: resolve the backup folder to restore, either from an
# explicit -RollbackBackup path or from the latest dated backup under BackupRoot.
function Get-RollbackSourcePath {
    param([string]$BackupRootPath, [string]$RequestedPath, [string]$TargetProcessor)
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath)) {
            throw "Rollback backup path not found: $RequestedPath"
        }
        return (Get-Item -LiteralPath $RequestedPath).FullName
    }
    if ([string]::IsNullOrWhiteSpace($BackupRootPath)) {
        throw 'Rollback requires -BackupRoot or -RollbackBackup.'
    }
    $pattern = '^\d{8}_.+_' + [regex]::Escape($TargetProcessor) + '$'
    $latest = @(Get-ChildItem -LiteralPath $BackupRootPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object Name -Descending | Select-Object -First 1)
    if (-not $latest) {
        throw "No rollback backup found under $BackupRootPath for $TargetProcessor"
    }
    return $latest[0].FullName
}

# Rollback mode: stop the processor, restore the selected backup tree into
# TargetRoot, and restart the processor so the prior release is live again.
if ($Rollback) {
    try {
        $rollbackSource = Get-RollbackSourcePath -BackupRootPath $BackupRoot -RequestedPath $RollbackBackup -TargetProcessor $Processor
    }
    catch {
        Write-VesLog ERROR $_.Exception.Message -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }

    $disabled = New-Object System.Collections.Generic.List[string]
    $stopFailed = $false
    try {
        foreach ($tn in $ScheduledTasks) {
            try {
                Disable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
                $disabled.Add($tn)
                Write-VesLog INFO "Disabled task: $tn" -LogFile $LogFile
            }
            catch {
                Write-VesLog ERROR "Could not disable task $tn -> $($_.Exception.Message)" -LogFile $LogFile
                $stopFailed = $true
                break
            }
        }
        if (-not $stopFailed -and $ServiceName) {
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc) {
                try {
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                    Write-VesLog INFO "Stopped service: $ServiceName" -LogFile $LogFile
                }
                catch {
                    Write-VesLog ERROR "Could not stop service $ServiceName -> $($_.Exception.Message)" -LogFile $LogFile
                    $stopFailed = $true
                }
            }
        }
        if (-not $stopFailed) {
            $targetItem = Get-Item -LiteralPath $TargetRoot -ErrorAction SilentlyContinue
            if ($targetItem) {
                $targetPrefix = $targetItem.FullName.TrimEnd('\') + '\'
                $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase) })
                foreach ($p in $running) {
                    if ($KillProcesses) {
                        Write-VesLog WARN ("Killing running instance PID {0}: {1}" -f $p.ProcessId, $p.CommandLine) -Data @{processor = $Processor; pid = $p.ProcessId; commandLine = $p.CommandLine } -LogFile $LogFile
                        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
                        catch {
                            Write-VesLog ERROR "Could not kill PID $($p.ProcessId) -> $($_.Exception.Message)" -LogFile $LogFile
                            $stopFailed = $true
                        }
                    }
                    else {
                        Write-VesLog ERROR ("Running instance holds {0}: PID {1} {2}. Re-run with -KillProcesses to stop it." -f $TargetRoot, $p.ProcessId, $p.CommandLine) -LogFile $LogFile
                        $stopFailed = $true
                    }
                }
                if ($KillProcesses -and -not $stopFailed -and $running.Count) {
                    $ids = @($running | ForEach-Object { $_.ProcessId })
                    $deadline = (Get-Date).AddSeconds(30)
                    while ((Get-Date) -lt $deadline -and (Get-Process -Id $ids -ErrorAction SilentlyContinue)) {
                        Start-Sleep -Milliseconds 250
                    }
                    $alive = @(Get-Process -Id $ids -ErrorAction SilentlyContinue)
                    if ($alive.Count) {
                        Write-VesLog ERROR "Instance(s) still alive after kill: $(($alive | ForEach-Object Id) -join ', ')" -LogFile $LogFile
                        $stopFailed = $true
                    }
                }
            }
        }
        if (-not $stopFailed) {
            Write-VesLog INFO "Rollback $rollbackSource -> $TargetRoot" -LogFile $LogFile
            New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
            robocopy $rollbackSource $TargetRoot /MIR /NP /R:2 /W:5 | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-VesLog ERROR "Rollback copy failed ($LASTEXITCODE)" -LogFile $LogFile; Stop-Deploy $VES_EXIT_DRIFT }
            $global:LASTEXITCODE = 0
        }
    }
    finally {
        if ($ServiceName) {
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc) {
                try {
                    Start-Service -Name $ServiceName -ErrorAction Stop
                    Write-VesLog INFO "Started service: $ServiceName" -LogFile $LogFile
                }
                catch { Write-VesLog ERROR "FAILED to restart service $ServiceName -> $($_.Exception.Message)" -LogFile $LogFile }
            }
        }
        foreach ($tn in $disabled) {
            try {
                Enable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
                Write-VesLog INFO "Re-enabled task: $tn" -LogFile $LogFile
            }
            catch { Write-VesLog ERROR "FAILED to re-enable task $tn -> $($_.Exception.Message)" -LogFile $LogFile }
        }
        if ($StartTasksAfter -and -not $stopFailed) {
            foreach ($tn in $disabled) {
                try {
                    Start-ScheduledTask -TaskName $tn -ErrorAction Stop
                    Write-VesLog INFO "Started task: $tn" -LogFile $LogFile
                }
                catch { Write-VesLog WARN "Could not start task $tn -> $($_.Exception.Message)" -LogFile $LogFile }
            }
        }
    }
    if ($stopFailed) { Write-VesLog ERROR 'Rollback stopped because the processor could not be quiesced.' -LogFile $LogFile; Stop-Deploy $VES_EXIT_DRIFT }
    Write-VesLog OK "Rollback complete: $Processor restored from $rollbackSource" -LogFile $LogFile
    Stop-Deploy $VES_EXIT_OK
}

# A tag source needs both halves; fail closed before any stage runs.
if ($BaselineRepo -and [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    Write-VesLog ERROR '-BaselineRepo requires -ReleaseTag.' -LogFile $LogFile
    Write-VesLog ERROR 'RUN END: deployment outcome=ERROR exit=10' `
        -Data @{runId = $runId; outcome = 'ERROR'; exitCode = 10; processor = $Processor; release = $StagedCommit } -LogFile $LogFile
    exit $VES_EXIT_USAGE
}

$gateRequired = New-Object System.Collections.Generic.List[string]
$rollbackOnlyProvided = (-not [string]::IsNullOrWhiteSpace($BackupRoot)) -or (-not [string]::IsNullOrWhiteSpace($RollbackBackup))
if ($Rollback) {
    if (-not [string]::IsNullOrWhiteSpace($StagedRoot) -or -not [string]::IsNullOrWhiteSpace($StagedCommit) -or -not [string]::IsNullOrWhiteSpace($ManifestPath) -or -not [string]::IsNullOrWhiteSpace($TrustParam) -or -not [string]::IsNullOrWhiteSpace($ApprovedCommitParam) -or -not [string]::IsNullOrWhiteSpace($ReleaseTag) -or -not [string]::IsNullOrWhiteSpace($BaselineRepo)) {
        Write-VesLog ERROR 'Rollback mode does not accept deploy-only parameters (StagedRoot, StagedCommit, ManifestPath, TrustParam, ApprovedCommitParam, ReleaseTag, BaselineRepo).' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        Write-VesLog ERROR '-TargetRoot is required for rollback.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($BackupRoot) -and [string]::IsNullOrWhiteSpace($RollbackBackup)) {
        Write-VesLog ERROR 'Rollback requires -BackupRoot or -RollbackBackup.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
}
else {
    if ($rollbackOnlyProvided) {
        Write-VesLog ERROR 'Rollback-only parameters require -Rollback.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        Write-VesLog ERROR '-TargetRoot is required for deploy.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($StagedRoot)) {
        Write-VesLog ERROR '-StagedRoot is required for deploy.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($StagedCommit)) {
        Write-VesLog ERROR '-StagedCommit is required for deploy.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        Write-VesLog ERROR '-ManifestPath is required for deploy.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($TrustParam)) {
        Write-VesLog ERROR '-TrustParam is required for deploy.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($ApprovedCommitParam)) {
        Write-VesLog ERROR '-ApprovedCommitParam is required for deploy.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
}
foreach ($path in $RequiredArtifactPaths) {
    if (-not [string]::IsNullOrWhiteSpace($path) -and -not $gateRequired.Contains($path)) {
        $gateRequired.Add($path)
    }
}
if ($ConfigContract) {
    if (-not $ConfigPath) {
        Write-VesLog ERROR '-ConfigPath is required when -ConfigContract is supplied.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    # When live config sits inside TargetRoot, derive its staged relative path so
    # a missing config blocks before copy even though *.config is hash-excluded.
    $targetFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    $configFull = [IO.Path]::GetFullPath($ConfigPath)
    $targetPrefix = $targetFull + '\'
    if ($configFull.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $relativeConfig = $configFull.Substring($targetPrefix.Length)
        if (-not $gateRequired.Contains($relativeConfig)) { $gateRequired.Add($relativeConfig) }
    }
    elseif ($gateRequired.Count -eq 0) {
        Write-VesLog ERROR 'ConfigPath is outside TargetRoot; supply -RequiredArtifactPaths with its staged relative path.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
}

# run a named stage; if it exits non-zero, abort the whole deploy with that stage's code
function Step($name, $code) {
    Write-VesLog INFO ">>> $name" -LogFile $LogFile
    & $code
    if ($LASTEXITCODE -ne 0) {
        $stageCode = $LASTEXITCODE
        Write-VesLog ERROR "STAGE FAILED: $name (exit $stageCode)" -LogFile $LogFile
        # --- DATADOG DISABLED -------------------------------------------------
        # Timeline event on stage failure. The gate self-reports its own block/override
        # events, so skip it here to avoid double-marking the same failure.
        # if ($name -ne 'pre-deploy gate') {
        #     Send-VesDatadogEvent -Title "Deploy FAILED at '$name': $Processor" `
        #         -Text "Stage '$name' failed for $Processor $StagedCommit (exit $stageCode)." `
        #         -AlertType (Get-VesAlertType -Environment $Environment) -Tags ($ddTags + 'event:deploy-failed')
        # }
        # ----------------------------------------------------------------------
        Stop-Deploy $stageCode
    }
}

# Stage 1: block the deploy unless the staged commit/content matches the approved baseline
# Invoked via powershell.exe child process so that `exit N` inside the script terminates only
# the child -- not this process -- allowing Step's error logging to fire.
Step 'pre-deploy gate' {
    # -LogFile appended only when set: PS 5.1 drops empty-string args to native
    # commands, which would leave a bare -LogFile expecting a value in the child.
    $gateArgs = @(
        '-StagedRoot', $StagedRoot, '-StagedCommit', $StagedCommit,
        '-ApprovedCommitParam', $ApprovedCommitParam, '-TrustParam', $TrustParam,
        '-ManifestPath', $ManifestPath, '-Processor', $Processor,
        '-Environment', $Environment, '-Region', $Region)
    foreach ($requiredPath in $gateRequired) { $gateArgs += '-RequiredArtifactPaths', $requiredPath }
    if ($ReleaseTag) { $gateArgs += '-ReleaseTag', $ReleaseTag }
    if ($BaselineRepo) { $gateArgs += '-BaselineRepo', $BaselineRepo }
    if ($LogFile) { $gateArgs += '-LogFile', $LogFile }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-PreDeployGate.ps1') @gateArgs
}

# Past the gate. -WhatIf short-circuits to the else branch; the real work runs here.
if ($PSCmdlet.ShouldProcess($TargetRoot, "Deploy $Processor $StagedCommit")) {

    # Deploy backup capability: snapshot the current live tree into a dated backup
    # folder before overwriting it with the staged release, creating the restore
    # point used by rollback.
    if ($BackupRoot) {
        $backupDir = Join-Path $BackupRoot ("{0}_{1}_{2}" -f (Get-Date).ToString('yyyyMMdd'), $Initials, $Processor)
        if (Test-Path -LiteralPath $TargetRoot) {
            Write-VesLog INFO "Backup $TargetRoot -> $backupDir" -LogFile $LogFile
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            robocopy $TargetRoot $backupDir /E /NP /R:2 /W:5 | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-VesLog ERROR "Backup failed ($LASTEXITCODE); aborting before copy" -LogFile $LogFile; Stop-Deploy $VES_EXIT_DRIFT }
            $global:LASTEXITCODE = 0
        }
        else {
            Write-VesLog WARN "TargetRoot does not exist yet; nothing to back up." -LogFile $LogFile
        }
    }

    # Stop -> copy -> restart. try/finally guarantees we re-enable tasks and
    # restart the service even if the copy fails, so we never leave prod down.
    # Stage 3: stop -> copy -> restart, tracking what we disabled so finally can undo it
    $disabled = New-Object System.Collections.Generic.List[string]
    $copyFailed = $false
    $stopFailed = $false
    try {
        # disable the scheduled tasks that hold the target files open
        foreach ($tn in $ScheduledTasks) {
            try {
                Disable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
                $disabled.Add($tn); Write-VesLog INFO "Disabled task: $tn" -LogFile $LogFile 
            }
            catch { Write-VesLog ERROR "Could not disable task $tn -> $($_.Exception.Message)" -LogFile $LogFile; $stopFailed = $true; break }
        }
        # stop the Windows service too, for Java-service targets
        if (-not $stopFailed -and $ServiceName) {
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc) {
                try {
                    Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                    Write-VesLog INFO "Stopped service: $ServiceName" -LogFile $LogFile 
                }
                catch { Write-VesLog ERROR "Could not stop service $ServiceName -> $($_.Exception.Message)" -LogFile $LogFile; $stopFailed = $true }
            }
        }
        # Console-EXE instances: a running exe under TargetRoot keeps its files
        # locked even after its task is disabled and would corrupt the /MIR copy.
        # ExecutablePath-under-TargetRoot is the instance identity (same exe name
        # runs from several folders per box); working dir isn't exposed by WMI.
        if (-not $stopFailed) {
            $targetItem = Get-Item -LiteralPath $TargetRoot -ErrorAction SilentlyContinue
            if ($targetItem) {
                $targetPrefix = $targetItem.FullName.TrimEnd('\') + '\'
                $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ExecutablePath -and
                        $_.ExecutablePath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase) })
                foreach ($p in $running) {
                    if ($KillProcesses) {
                        # audit line BEFORE the kill: which instance (mode arg visible in CommandLine)
                        Write-VesLog WARN ("Killing running instance PID {0}: {1}" -f $p.ProcessId, $p.CommandLine) `
                            -Data @{processor = $Processor; pid = $p.ProcessId; commandLine = $p.CommandLine } -LogFile $LogFile
                        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
                        catch {
                            Write-VesLog ERROR "Could not kill PID $($p.ProcessId) -> $($_.Exception.Message)" -LogFile $LogFile
                            $stopFailed = $true
                        }
                    }
                    else {
                        Write-VesLog ERROR ("Running instance holds {0}: PID {1} {2}. Re-run with -KillProcesses to stop it." -f `
                                $TargetRoot, $p.ProcessId, $p.CommandLine) -LogFile $LogFile
                        $stopFailed = $true
                    }
                }
                # wait for killed instances to actually exit and release handles
                if ($KillProcesses -and -not $stopFailed -and $running.Count) {
                    $ids = @($running | ForEach-Object { $_.ProcessId })
                    $deadline = (Get-Date).AddSeconds(30)
                    while ((Get-Date) -lt $deadline -and (Get-Process -Id $ids -ErrorAction SilentlyContinue)) {
                        Start-Sleep -Milliseconds 250
                    }
                    $alive = @(Get-Process -Id $ids -ErrorAction SilentlyContinue)
                    if ($alive.Count) {
                        Write-VesLog ERROR "Instance(s) still alive after kill: $(($alive | ForEach-Object Id) -join ', ')" -LogFile $LogFile
                        $stopFailed = $true
                    }
                }
            }
        }
        # only mirror the staged tree in once everything is safely stopped
        if (-not $stopFailed) {
            Write-VesLog INFO "Copy $StagedRoot -> $TargetRoot" -LogFile $LogFile
            # /MIR so stale files get removed; binary copy, nothing rewrites line endings
            robocopy $StagedRoot $TargetRoot /MIR /NP /R:2 /W:5 | Out-Null
            # robocopy: 0-7 are success variants, 8+ is failure
            if ($LASTEXITCODE -ge 8) { Write-VesLog ERROR "robocopy failed ($LASTEXITCODE)" -LogFile $LogFile; $copyFailed = $true }
            $global:LASTEXITCODE = 0   # clear the 1-7 success codes so Step doesn't trip on them
        }
    }
    finally {
        # restart in reverse order: service first, then re-enable the tasks
        if ($ServiceName) {
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc) {
                try {
                    Start-Service -Name $ServiceName -ErrorAction Stop
                    Write-VesLog INFO "Started service: $ServiceName" -LogFile $LogFile 
                }
                catch { Write-VesLog ERROR "FAILED to restart service $ServiceName -> $($_.Exception.Message)" -LogFile $LogFile }
            }
        }
        foreach ($tn in $disabled) {
            try {
                Enable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
                Write-VesLog INFO "Re-enabled task: $tn" -LogFile $LogFile
            }
            catch { Write-VesLog ERROR "FAILED to re-enable task $tn -> $($_.Exception.Message)" -LogFile $LogFile }
        }
        # prompt relaunch, only after a clean stop+copy: never auto-start a tree a
        # failed copy may have left broken (next trigger / the operator owns that).
        if ($StartTasksAfter -and -not $stopFailed -and -not $copyFailed) {
            foreach ($tn in $disabled) {
                try {
                    Start-ScheduledTask -TaskName $tn -ErrorAction Stop
                    Write-VesLog INFO "Started task: $tn" -LogFile $LogFile
                }
                catch { Write-VesLog WARN "Could not start task $tn -> $($_.Exception.Message)" -LogFile $LogFile }
            }
        }
    }
    # a failed stop or copy aborts here (processor already restored by finally)
    if ($stopFailed) { Write-VesLog ERROR "Stop phase failed; processor state restored, no copy performed." -LogFile $LogFile; Stop-Deploy $VES_EXIT_DRIFT }
    if ($copyFailed) { Stop-Deploy $VES_EXIT_DRIFT }

}
else {
    # -WhatIf path: the gate already ran, so report success without touching prod
    Write-VesLog WARN 'WhatIf: skipping stop/backup/copy, gate only.' -LogFile $LogFile
    Stop-Deploy $VES_EXIT_OK
}

# Stage 4: prove the deployed tree matches the trusted baseline (files, and config if supplied)
Step 'post-deploy verify' {
    # config is optional per system; only run VerifyConfig when a contract is
    # supplied. 'All' hard-requires the config params, so a config-less system
    # must verify files only, not fail with a usage error.
    # Array-style args (not hashtable splat) required for child-process invocation.
    # $(if ...), not (if ...): PS 5.1 has no if-expression, a bare (if ...) is
    # parsed as a command named 'if' and dies at runtime.
    $verArgs = @(
        '-Mode', $(if ($ConfigContract) { 'All' } else { 'VerifyFiles' }),
        '-ReleaseRoot', $TargetRoot,
        '-ManifestPath', $ManifestPath,
        '-TrustParam', $TrustParam,
        '-Processor', $Processor,
        '-CommitSha', $StagedCommit,
        '-Environment', $Environment,
        '-Region', $Region
    )
    if ($ReleaseTag) { $verArgs += '-ReleaseTag', $ReleaseTag }
    if ($BaselineRepo) { $verArgs += '-BaselineRepo', $BaselineRepo }
    if ($LogFile) { $verArgs += '-LogFile', $LogFile }
    if ($ConfigContract) { $verArgs += '-ConfigContract', $ConfigContract, '-ConfigPath', $ConfigPath }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-Verification.ps1') @verArgs
}

# Stage 5: confirm the processor is actually alive after the restart (service/task/log/endpoint)
Step 'health check' {
    # Build arg array so each array-valued param is passed as repeated named args
    # (e.g. -RequiredAssemblies a.dll -RequiredAssemblies b.dll), which PowerShell
    # -File mode binds correctly to [string[]] parameters.
    $hcArgs = @('-Processor', $Processor, '-CommitSha', $StagedCommit, '-Environment', $Environment)
    if ($ReleaseTag) { $hcArgs += '-ReleaseTag', $ReleaseTag }
    if ($LogFile) { $hcArgs += '-LogFile', $LogFile }
    foreach ($dll in $RequiredAssemblies) { $hcArgs += '-RequiredAssemblies', $dll }
    if ($ServiceName) { $hcArgs += '-ServiceName', $ServiceName }
    foreach ($tn in $ScheduledTasks) { $hcArgs += '-ScheduledTasks', $tn }
    if ($FreshLogDir) { $hcArgs += '-FreshLogDir', $FreshLogDir, '-FreshLogMaxAgeMinutes', "$FreshLogMaxAgeMinutes" }
    if ($ScheduledTasks.Count -gt 0) {
        $hcArgs += '-ProcessPathRoot', $TargetRoot
        if ($ProcessArgumentPattern) { $hcArgs += '-ProcessArgumentPattern', $ProcessArgumentPattern }
    }
    if ($HealthUrl) { $hcArgs += '-HealthUrl', $HealthUrl }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-HealthCheck.ps1') @hcArgs
}

# Backup retention capability: after a fully green deploy, keep only the newest
# N dated backup folders for this processor and prune the older restore points.
if ($BackupRoot -and $KeepBackups -gt 0 -and (Test-Path -LiteralPath $BackupRoot)) {
    $pattern = '^\d{8}_.+_' + [regex]::Escape($Processor) + '$'
    $old = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } |
        Sort-Object Name -Descending | Select-Object -Skip $KeepBackups)
    foreach ($b in $old) {
        try {
            Remove-Item -LiteralPath $b.FullName -Recurse -Force
            Write-VesLog INFO "Pruned old backup: $($b.Name)" -LogFile $LogFile 
        }
        catch { Write-VesLog WARN "Could not prune backup $($b.Name): $($_.Exception.Message)" -LogFile $LogFile }
    }
}

Write-VesLog OK "DEPLOY COMPLETE: $Processor @ $StagedCommit verified+healthy" -LogFile $LogFile
# --- DATADOG DISABLED ---------------------------------------------------------
# Timeline event: the "authorized deploy" marker. Drift after this point is expected;
# drift with no marker is the unauthorized-change picture the drift runner surfaces.
# Send-VesDatadogEvent -Title "Deploy COMPLETE: $Processor" `
#     -Text "Deploy of $Processor $StagedCommit completed: gate + copy + verify + health all green." `
#     -AlertType 'success' -Tags ($ddTags + 'event:deploy-complete')
# ------------------------------------------------------------------------------
Stop-Deploy $VES_EXIT_OK
