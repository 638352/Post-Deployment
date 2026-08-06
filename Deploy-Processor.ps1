#Requires -Version 5.1
<#
.SYNOPSIS
    Gate, stop, backup, copy, restart, verify, and health-check a processor deploy.
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

    Config handling has two postures, chosen per unit by -PreserveFiles, because
    the deployment runbook itself uses both:
      * default (empty): the package ships the config and the mirror installs it.
        The gate requires it in the staged tree, so a package without it is
        blocked before the copy. This is "delete all files INCLUDING the
        exe.config", e.g. VESEMSEGRESS01 in 4.7.
      * -PreserveFiles '*.config': robocopy /XF holds the server's own config
        back, so it survives the deploy and the gate stops demanding one in the
        package. This is "delete all files EXCEPT the exe.config files", which is
        what 4.7 does on every other unit.
    Either way the live config is proven by Verify-Config against its contract;
    *.config is outside the byte-hash baseline by design, so the file check is
    unaffected. Preserving anything that IS hashed logs a warning, because it will
    surface as CHANGED or EXTRA in the post-deploy verify.

    Break-glass is intentionally not wired through here (open policy decision).
    -WhatIf runs the gate only and skips stop/backup/copy.

    Rollback: with -BackupRoot the pre-copy backup is the restore point, recorded
    by a rollback-record.json sidecar (what it replaced and the config it
    stashed). -AutoRollback restores it when the post-deploy verify or the health
    check fails; the deploy still exits with that stage's code, because rolling
    back is remediation, not success. -Rollback runs a restore instead of a
    deploy by delegating to Invoke-Rollback.ps1, which owns the safety gates and
    the post-restore proof.

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
    # Files the mirror must NOT overwrite or delete (robocopy /XF).
    #
    # Empty by default, which keeps the staged-config posture: the mirror installs
    # the package's config and the gate requires the package to carry it. Set it
    # to '*.config' for a unit whose runbook step reads "delete all files EXCEPT
    # the exe.config files" -- the server then keeps its own environment-specific
    # config across the deploy, and the gate stops demanding one in the package.
    # Either way the live config is proven by Verify-Config against its contract;
    # $VES_DEFAULT_EXCLUDE already keeps *.config out of the byte-hash baseline,
    # so preserving it costs the file check nothing.
    [string[]]$PreserveFiles = @(),
    # Directory names the mirror must leave alone (robocopy /XD), e.g. a
    # server-only spool folder that lives inside the processor tree.
    [string[]]$PreserveDirs = @(),
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
    # dated backup of the current target before overwrite:
    # <BackupRoot>\<yyyyMMddTHHmmss>_<Initials>_<Processor>, plus a
    # rollback-record.json sidecar. Skipped if not set -- and without it there is
    # nothing to roll back to, so set it on every real deploy.
    [string]$BackupRoot,
    # newest N backups to keep for this processor; older ones get pruned after a
    # successful deploy only. 0 keeps everything.
    [int]$KeepBackups = 5,
    # opt-in: restore the backup automatically when the post-deploy verify or the
    # health check fails. Requires -BackupRoot. A rolled-back deploy still exits
    # with the failing stage's code -- rollback is remediation, not success.
    # Never moves the approved release tag (that is operator-only, see Invoke-Rollback).
    [switch]$AutoRollback,
    # Restore a backup instead of deploying. Thin alias for Invoke-Rollback.ps1,
    # which owns the restore logic (selection, safety gates, post-restore verify).
    [switch]$Rollback,
    # rollback only: restore this specific backup folder instead of the newest.
    [string]$RollbackBackup,
    # rollback only: why this restore is happening. Recorded in the audit log.
    [string]$RollbackReason,
    # Rollback only, and deliberately separate from -ReleaseTag/-ManifestPath:
    # every other release parameter on this script names the release being
    # DEPLOYED, so forwarding them to a restore would verify the restored old tree
    # against the new release's baseline -- the likeliest way to make a good
    # rollback look like a bad one. These name the PRIOR release instead, and are
    # what let the alias reach Invoke-Rollback's strong proof rungs (1 and 2)
    # rather than always degrading to the backup's own manifest.
    [string]$RollbackReleaseTag,
    [string]$RollbackManifestPath,
    # Rollback only: forwarded to Invoke-Rollback, which refuses to restore a
    # database-coupled unit (InboundHandler) without one of them. Declared here so
    # an operator holding the deploy command line can still reverse it in one step;
    # the claim itself, and the gate, belong to Invoke-Rollback.
    #
    # BOTH are declared deliberately. Invoke-Rollback's own refusal text tells the
    # operator to "pass -SqlRollbackDeferred instead", and this script is documented
    # as a thin alias for it (RUNBOOK 7.1). Accepting only the confirming switch made
    # that instruction fail parameter binding on the alias, and left a false positive
    # attestation as the only way through -- the opposite of what the gate is for.
    [switch]$ConfirmedSqlRollbackComplete,
    [switch]$SqlRollbackDeferred,
    [string]$Initials = $env:USERNAME,
    [string]$HealthUrl,
    # liveness for endpoint-less .exe processors; passed through to the health check
    [string]$FreshLogDir,
    [int]$FreshLogMaxAgeMinutes = 60,
    [string]$ProcessArgumentPattern,
    [string]$Environment = 'prod',
    [string]$LogFile
)
# Backup and rollback capabilities:
# - Deploy mode backs the live TargetRoot up to <BackupRoot>\<stamp>_<Initials>_<Processor>
#   before overwriting it, with a rollback-record.json sidecar naming what it replaced.
# - -AutoRollback restores that backup when the post-deploy verify or health stage fails.
# - -Rollback delegates to Invoke-Rollback.ps1 for an operator-driven restore.
# - Each processor wrapper supplies the live target path and backup root used here.
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
# This script is itself launched with `powershell.exe -File` (by the test harness,
# by a scheduled runner, by any wrapper that does not splat), and -File cannot
# carry an array. Normalize on the way IN so a joined argument and a real array
# behave identically, then join again on the way out to each child stage. Doing
# both makes the transport symmetric at every hop instead of only the last one.
$ScheduledTasks = Expand-VesList -Value $ScheduledTasks
$RequiredAssemblies = Expand-VesList -Value $RequiredAssemblies
$RequiredArtifactPaths = Expand-VesList -Value $RequiredArtifactPaths
$PreserveFiles = Expand-VesList -Value $PreserveFiles
$PreserveDirs = Expand-VesList -Value $PreserveDirs
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

# Set by the auto-rollback handler so the terminal record always states whether a
# rollback was attempted and how it went -- a rollback must never be silent.
$script:rolledBack = $false
$script:rollbackExitCode = $null
# Whether this unit's release is half database. Read from the module so this script
# and Invoke-Rollback cannot disagree about it -- and they must not, because the one
# that drifts silently is the attestation. Auto-rollback of a coupled unit restores
# files against a database that still carries the new objects, so the run owes a
# manual SQL rollback that no exit code here can represent.
$script:dbCoupled = $VES_DB_COUPLED_PROCESSORS -contains $Processor
$script:sqlRollbackOwed = $false

function Stop-Deploy([int]$code) {
    $outcome = Get-VesOutcome -ExitCode $code
    Write-VesLog ($(if ($outcome -eq 'PASS') { 'OK' } elseif ($outcome -eq 'FAIL') { 'ERROR' } else { 'ERROR' })) `
        "RUN END: deployment outcome=$outcome exit=$code" `
        -Data @{runId = $runId; outcome = $outcome; exitCode = $code; processor = $Processor; release = $StagedCommit; releaseTag = $ReleaseTag; rolledBack = $script:rolledBack; rollbackExitCode = $script:rollbackExitCode; databaseCoupled = $script:dbCoupled; sqlRollbackOwed = $script:sqlRollbackOwed } -LogFile $LogFile
    exit $code
}

# Every stage below runs as a `powershell.exe -File` child, which cannot carry an
# array (see ConvertTo-VesList). Join the multi-valued parameters ONCE, here, so
# the gate, rollback, and health call sites cannot each get it subtly different --
# and so a name carrying the delimiter is refused before the gate, not discovered
# by a stop phase that has already opened production.
try {
    $rbTasks = ConvertTo-VesList -Value $ScheduledTasks -Name 'scheduled task'
    $rbAssemblies = ConvertTo-VesList -Value $RequiredAssemblies -Name 'required assembly'
}
catch {
    Write-VesLog ERROR $_.Exception.Message -LogFile $LogFile
    Stop-Deploy $VES_EXIT_USAGE
}

# Rollback mode: hand off to Invoke-Rollback.ps1, which owns backup selection,
# the safety gates (empty/partial backup, nested BackupRoot), config restore, and
# the post-restore verify + health proof. Kept here as an alias so an operator
# already holding the deploy command line can reverse it without a second script,
# but the restore itself has exactly one implementation.
if ($Rollback) {
    # Validate BEFORE building the argument array. PS 5.1 drops empty-string
    # arguments to native commands (the same trap called out at the gate below),
    # so a blank -TargetRoot here would silently let '-BackupRoot' bind as
    # -TargetRoot's value and shift every later argument by one.
    if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
        Write-VesLog ERROR '-TargetRoot is required for -Rollback.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($Initials)) {
        Write-VesLog ERROR '-Initials is required (it defaults to $env:USERNAME, which is empty in this context).' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    $rbArgs = @('-Processor', $Processor, '-TargetRoot', $TargetRoot)
    if ($BackupRoot) { $rbArgs += '-BackupRoot', $BackupRoot }
    # Prior-release baseline, so the alias can reach the proof rungs that actually
    # show the restored release was approved. Never -ReleaseTag/-ManifestPath:
    # those name the incoming release.
    if ($RollbackReleaseTag) { $rbArgs += '-ReleaseTag', $RollbackReleaseTag }
    if ($RollbackManifestPath) { $rbArgs += '-ManifestPath', $RollbackManifestPath }
    if ($BaselineRepo) { $rbArgs += '-BaselineRepo', $BaselineRepo }
    if ($RollbackBackup) { $rbArgs += '-BackupDir', $RollbackBackup }
    if ($RollbackReason) { $rbArgs += '-Reason', $RollbackReason }
    if ($ConfigPath) { $rbArgs += '-ConfigPath', $ConfigPath }
    if ($ConfigContract) { $rbArgs += '-ConfigContract', $ConfigContract }
    if ($ServiceName) { $rbArgs += '-ServiceName', $ServiceName }
    if ($rbTasks) { $rbArgs += '-ScheduledTasks', $rbTasks }
    if ($rbAssemblies) { $rbArgs += '-RequiredAssemblies', $rbAssemblies }
    if ($KillProcesses) { $rbArgs += '-KillProcesses' }
    if (-not $StartTasksAfter) { $rbArgs += '-NoStartTasksAfter' }
    if ($HealthUrl) { $rbArgs += '-HealthUrl', $HealthUrl }
    if ($FreshLogDir) { $rbArgs += '-FreshLogDir', $FreshLogDir, '-FreshLogMaxAgeMinutes', "$FreshLogMaxAgeMinutes" }
    if ($ProcessArgumentPattern) { $rbArgs += '-ProcessArgumentPattern', $ProcessArgumentPattern }
    if ($ConfirmedSqlRollbackComplete) { $rbArgs += '-ConfirmedSqlRollbackComplete' }
    if ($SqlRollbackDeferred) { $rbArgs += '-SqlRollbackDeferred' }
    $rbArgs += '-Initials', $Initials, '-Environment', $Environment
    if ($LogFile) { $rbArgs += '-LogFile', $LogFile }
    # -WhatIf does not cross a -File boundary; forward it explicitly.
    if ($WhatIfPreference) { $rbArgs += '-WhatIf' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-Rollback.ps1') @rbArgs
    $rbCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    Stop-Deploy $rbCode
}


# A tag source needs both halves; fail closed before any stage runs.
if ($BaselineRepo -and [string]::IsNullOrWhiteSpace($ReleaseTag)) {
    Write-VesLog ERROR '-BaselineRepo requires -ReleaseTag.' -LogFile $LogFile
    Write-VesLog ERROR 'RUN END: deployment outcome=ERROR exit=10' `
        -Data @{runId = $runId; outcome = 'ERROR'; exitCode = 10; processor = $Processor; release = $StagedCommit } -LogFile $LogFile
    exit $VES_EXIT_USAGE
}

$gateRequired = New-Object System.Collections.Generic.List[string]
# -BackupRoot is NOT rollback-only: a deploy needs it to create the restore point
# in the first place, and both processor wrappers set it. Only -RollbackBackup and
# -RollbackReason are meaningless outside rollback mode.
$rollbackOnlyProvided = (-not [string]::IsNullOrWhiteSpace($RollbackBackup)) -or
                        (-not [string]::IsNullOrWhiteSpace($RollbackReason)) -or
                        (-not [string]::IsNullOrWhiteSpace($RollbackReleaseTag)) -or
                        (-not [string]::IsNullOrWhiteSpace($RollbackManifestPath)) -or
                        [bool]$ConfirmedSqlRollbackComplete -or
                        [bool]$SqlRollbackDeferred
if (-not $Rollback) {
    if ($rollbackOnlyProvided) {
        Write-VesLog ERROR 'Rollback-only parameters require -Rollback.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ($AutoRollback -and [string]::IsNullOrWhiteSpace($BackupRoot)) {
        # Fail here, not at stage 4: finding out there is nothing to restore from
        # only once the deploy has already overwritten prod is the worst moment.
        Write-VesLog ERROR '-AutoRollback requires -BackupRoot: there would be nothing to restore from.' -LogFile $LogFile
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
    # The anchor replaced -TrustParam/-ApprovedCommitParam (no AWS in this
    # environment). Both halves are required for the same reason those were: a
    # deploy with nothing to verify against must not start.
    if ([string]::IsNullOrWhiteSpace($BaselineRepo)) {
        Write-VesLog ERROR '-BaselineRepo is required for deploy (the archived release record is the trust anchor).' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
        Write-VesLog ERROR '-ReleaseTag is required for deploy (names the approved release to verify against).' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
    # A BackupRoot inside TargetRoot destroys itself twice over: the /E backup
    # recurses into its own destination, and the /MIR that follows then deletes
    # the restore point it just made. Measured, not theoretical.
    if ($BackupRoot -and $TargetRoot) {
        $rootFull = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
        $tgtFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
        if ($rootFull -eq $tgtFull -or
            $rootFull.StartsWith($tgtFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $tgtFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Write-VesLog ERROR "Unsafe configuration: BackupRoot and TargetRoot overlap ($rootFull vs $tgtFull). The backup would copy into itself and the mirror would then delete it." -LogFile $LogFile
            Stop-Deploy $VES_EXIT_USAGE
        }
    }
}
# A preserved path that IS byte-hashed will surface as CHANGED or EXTRA in the
# post-deploy verify, because the baseline describes the staged release and the
# server keeps its own copy. *.config is already outside the hash by design, so the
# default preserve list is silent; anything else the operator adds is not.
foreach ($p in (@($PreserveFiles) + @($PreserveDirs))) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($p -notmatch $Global:VES_DEFAULT_EXCLUDE) {
        Write-VesLog WARN "Preserved path '$p' is hash-verified, so the post-deploy verify will report it as CHANGED or EXTRA." -LogFile $LogFile
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
        # ...unless the mirror is going to preserve it. Demanding the package ship
        # a file the copy will then hold back is friction with no safety value, and
        # it would block every deploy of a package built once for several servers.
        # The live config is still proven -- by Verify-Config against its contract.
        if (Test-VesPreservedPath -RelativePath $relativeConfig -PreserveFiles $PreserveFiles -PreserveDirs $PreserveDirs) {
            Write-VesLog INFO "Config is preserved on the server (not mirrored), so it is not required in the staged package: $relativeConfig" -LogFile $LogFile
        }
        elseif (-not $gateRequired.Contains($relativeConfig)) { $gateRequired.Add($relativeConfig) }
    }
    elseif ($gateRequired.Count -eq 0) {
        Write-VesLog ERROR 'ConfigPath is outside TargetRoot; supply -RequiredArtifactPaths with its staged relative path.' -LogFile $LogFile
        Stop-Deploy $VES_EXIT_USAGE
    }
}

# Set by the backup block below; declared here so the auto-rollback handler can
# test it even on the paths where no backup was taken.
$backupDir = $null
$rollbackOnFail = $null

# run a named stage; if it exits non-zero, abort the whole deploy with that stage's
# code. $onFail (optional) gets a chance to remediate first and returns the code to
# exit with; both pre-existing call sites pass two arguments and are unaffected.
function Step($name, $code, $onFail = $null) {
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
        if ($onFail) {
            # The handler shells a child process whose stdout would otherwise be
            # spliced into the scriptblock's return value, so read the code back
            # through a script-scoped variable instead of from the pipeline.
            $script:onFailExitCode = $null
            & $onFail $name $stageCode
            if ($null -ne $script:onFailExitCode) { $stageCode = $script:onFailExitCode }
        }
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
        '-ManifestPath', $ManifestPath, '-Processor', $Processor,
        '-Environment', $Environment,
        # Both halves of the anchor. Passed unconditionally: if either is empty the
        # gate must refuse (exit 10), and omitting the switch here would hide that
        # misconfiguration behind a parameter the gate never saw.
        '-BaselineRepo', $BaselineRepo, '-ReleaseTag', $ReleaseTag)
    # One joined argument, not one per path: two required artifacts passed as two
    # -RequiredArtifactPaths would fail the gate child with ParameterAlreadyBound
    # before it ran a single check.
    $gateRequiredArg = ConvertTo-VesList -Value $gateRequired -Name 'required artifact path'
    if ($gateRequiredArg) { $gateArgs += '-RequiredArtifactPaths', $gateRequiredArg }
    if ($LogFile) { $gateArgs += '-LogFile', $LogFile }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-PreDeployGate.ps1') @gateArgs
}

# Past the gate. -WhatIf short-circuits to the else branch; the real work runs here.
if ($PSCmdlet.ShouldProcess($TargetRoot, "Deploy $Processor $StagedCommit")) {

    # Stage 2: snapshot the current live tree into a timestamped backup folder
    # before overwriting it. This IS the restore point -- everything after the
    # robocopy is best-effort evidence that must never abort a deploy, but the
    # copy itself is load-bearing and aborts on failure.
    if ($BackupRoot) {
        # yyyyMMddTHHmmss, not yyyyMMdd: with date-only names a second deploy on
        # the same day by the same operator robocopied the ALREADY-OVERWRITTEN
        # tree into the same folder, destroying the true pre-deploy state.
        # Local time to match how operators read these names; createdUtc in the
        # sidecar is the unambiguous value.
        $backupDir = Join-Path $BackupRoot ("{0}_{1}_{2}" -f (Get-Date).ToString('yyyyMMddTHHmmss'), $Initials, $Processor)
        if (Test-Path -LiteralPath $TargetRoot) {
            Write-VesLog INFO "Backup $TargetRoot -> $backupDir" -LogFile $LogFile
            if ((Test-Path -LiteralPath $backupDir) -and
                @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count) {
                Write-VesLog WARN "Backup folder already exists and is not empty; /E will merge two releases into it: $backupDir" -LogFile $LogFile
            }
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            robocopy $TargetRoot $backupDir /E /NP /R:2 /W:5 | Out-Null
            # Robocopy 8+ is a hard copy failure. NOBASE (2), not DRIFT (1): nothing
            # was compared and production did not change, so "drift" is the wrong
            # word -- the honest statement is that we could not take a restore point,
            # which is the ERROR class (2 outranks 3; see Get-VesOutcome). This is
            # the same code Invoke-Rollback uses for its equivalent could-not-proceed
            # cases, so monitoring reads both the same way.
            if ($LASTEXITCODE -ge 8) { Write-VesLog ERROR "Backup failed ($LASTEXITCODE); aborting before copy. No restore point was taken, so production state is unproven." -LogFile $LogFile; Stop-Deploy $VES_EXIT_NOBASE }
            $global:LASTEXITCODE = 0

            $recordErrors = New-Object System.Collections.Generic.List[string]

            # (a) Hash the tree we are about to replace. Hash $TargetRoot, not the
            # backup copy, so our own sidecars stay out of the manifest.
            $backupHash = $null
            $backupFileCount = $null
            try {
                # Assign the call directly: Get-VesManifest returns a comma-wrapped
                # array, so wrapping the CALL in @() nests it one level deeper and
                # the manifest lands with a single bogus entry.
                $preManifest = Get-VesManifest -ReleaseRoot $TargetRoot
                $backupHash = Export-VesManifest -Manifest $preManifest `
                    -Path (Join-Path $backupDir 'backup-manifest.json') -CommitSha 'pre-deploy' -Processor $Processor
                $backupFileCount = @($preManifest).Count
            }
            catch {
                # >260-char paths defeat Get-ChildItem/Get-FileHash under 5.1 where
                # robocopy succeeds. Degrade the evidence, never the deploy.
                $msg = "Could not hash the pre-deploy tree: $($_.Exception.Message)"
                Write-VesLog WARN $msg -LogFile $LogFile; $recordErrors.Add($msg)
            }

            # (b) Config living outside TargetRoot is not in the /E copy above and
            # would otherwise be unrecoverable. Stash it beside the payload.
            $configInsideTarget = $false
            $configBackupRelPath = $null
            if ($ConfigPath) {
                $targetFullForCfg = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\') + '\'
                $configInsideTarget = ([IO.Path]::GetFullPath($ConfigPath)).StartsWith($targetFullForCfg, [StringComparison]::OrdinalIgnoreCase)
                if (-not $configInsideTarget) {
                    try {
                        if (Test-Path -LiteralPath $ConfigPath) {
                            $stash = Join-Path $backupDir '_ves-config'
                            New-Item -ItemType Directory -Path $stash -Force | Out-Null
                            Copy-Item -LiteralPath $ConfigPath -Destination $stash -Force
                            $configBackupRelPath = Join-Path '_ves-config' (Split-Path -Leaf $ConfigPath)
                            Write-VesLog INFO "Backed up out-of-tree config: $ConfigPath" -LogFile $LogFile
                        }
                        else {
                            $msg = "ConfigPath not found at backup time: $ConfigPath"
                            Write-VesLog WARN $msg -LogFile $LogFile; $recordErrors.Add($msg)
                        }
                    }
                    catch {
                        $msg = "Could not back up config $ConfigPath -> $($_.Exception.Message)"
                        Write-VesLog WARN $msg -LogFile $LogFile; $recordErrors.Add($msg)
                    }
                }
            }

            # (c) The hash of the release we are about to install, read from the
            # archived record. Formerly read from the SSM pin (which never
            # existed here). Best-effort: the gate has already proven this record
            # readable, so a failure now is evidence-gathering noise, not a reason
            # to abort a deploy that passed its gate.
            $incomingHash = $null
            try {
                $incomingRecord = Get-VesManifestFromTag -RepoPath $BaselineRepo -Tag $ReleaseTag -Processor $Processor `
                    -FileName $(if ($ManifestPath) { Split-Path -Leaf $ManifestPath } else { $null })
                $incomingHash = $incomingRecord.RecomputedHash
            }
            catch {
                $recordErrors.Add("Could not read incoming release hash from ${ReleaseTag}: $($_.Exception.Message)")
            }

            # Free signal -- but it has to be read the right way round. The anchor
            # names the INCOMING release (captured at UAT sign-off), not the one
            # currently on disk. A mismatch here is therefore the expected case on
            # every healthy deploy and must not be logged as DRIFT: doing so trains
            # operators to ignore the one word that is supposed to mean
            # "production is wrong".
            if ($backupHash -and $incomingHash) {
                if ($backupHash -eq $incomingHash) {
                    Write-VesLog WARN 'Pre-deploy tree already matches the incoming release; this deploy is re-copying bits production is already carrying.' -LogFile $LogFile
                }
                else {
                    Write-VesLog INFO 'Pre-deploy tree differs from the incoming release, as expected before a deploy. Its hash is recorded in backup-manifest.json so this restore point can be identified later.' `
                        -Data @{preDeployManifestHash = $backupHash; incomingManifestHash = $incomingHash } -LogFile $LogFile
                }
            }

            # (d) Written LAST, on purpose: its presence is how rollback knows the
            # backup finished rather than dying part-way through the copy.
            try {
                $record = [ordered]@{
                    schema              = 'ves.rollback-record.v1'
                    processor           = $Processor
                    createdUtc          = (Get-Date).ToUniversalTime().ToString('o')
                    createdBy           = "$env:USERNAME@$env:COMPUTERNAME"
                    initials            = $Initials
                    sourceTargetRoot    = $TargetRoot
                    replacedByCommit    = $StagedCommit
                    replacedByReleaseTag = $ReleaseTag
                    priorReleaseTag     = $null
                    backupManifestHash  = $backupHash
                    backupFileCount     = $backupFileCount
                    manifestPath        = $ManifestPath
                    configPath          = $ConfigPath
                    configInsideTarget  = $configInsideTarget
                    configBackupRelPath = $configBackupRelPath
                    baselineRepo        = $BaselineRepo
                    incomingManifestHash = $incomingHash
                    recordErrors        = $recordErrors.ToArray()
                }
                ($record | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path $backupDir 'rollback-record.json') -Encoding utf8
                Write-VesLog OK "Restore point ready: $backupDir" -LogFile $LogFile
            }
            catch {
                Write-VesLog WARN "Could not write rollback-record.json: $($_.Exception.Message)" -LogFile $LogFile
            }
        }
        else {
            Write-VesLog WARN "TargetRoot does not exist yet; nothing to back up." -LogFile $LogFile
        }
    }

    # Auto-rollback handler. Runs when a stage AFTER the copy fails, i.e. once prod
    # is already carrying the new bits. Shells Invoke-Rollback with this run's own
    # -LogFile so both runs interleave in one JSONL stream, and deliberately does
    # NOT attempt to change which release the archive marks approved: an automated
    # write to the trust anchor, triggered by a failing deploy, is the most
    # dangerous thing this suite could do.
    if ($AutoRollback) {
        $rollbackOnFail = {
            param([string]$stageName, [int]$stageCode)
            if (-not $backupDir -or -not (Test-Path -LiteralPath $backupDir)) {
                Write-VesLog ERROR 'AUTO-ROLLBACK UNAVAILABLE: no backup was taken (TargetRoot did not exist at deploy time). Manual recovery required.' `
                    -Data @{runId = $runId; stage = $stageName } -LogFile $LogFile
                $script:onFailExitCode = $VES_EXIT_NOBASE
                return
            }
            Write-VesLog WARN "AUTO-ROLLBACK: restoring $backupDir after '$stageName' failed (exit $stageCode)" `
                -Data @{runId = $runId; stage = $stageName; stageExitCode = $stageCode; backupDir = $backupDir } -LogFile $LogFile
            $rbCode = $null
            try {
                $rbArgs = @(
                    '-Processor', $Processor, '-TargetRoot', $TargetRoot, '-BackupRoot', $BackupRoot,
                    '-BackupDir', $backupDir, '-Environment', $Environment,
                    '-Initials', $Initials, '-LogFile', $LogFile,
                    '-Reason', ("auto-rollback: deploy stage '$stageName' failed with exit $stageCode"))
                # -File cannot bind arrays at all: repeating the named argument is
                # ParameterAlreadyBound. Pass the joined form (see ConvertTo-VesList).
                if ($rbTasks) { $rbArgs += '-ScheduledTasks', $rbTasks }
                if ($rbAssemblies) { $rbArgs += '-RequiredAssemblies', $rbAssemblies }
                if ($ServiceName) { $rbArgs += '-ServiceName', $ServiceName }
                if ($BaselineRepo) { $rbArgs += '-BaselineRepo', $BaselineRepo }
                if ($ConfigContract) { $rbArgs += '-ConfigContract', $ConfigContract }
                if ($ConfigPath) { $rbArgs += '-ConfigPath', $ConfigPath }
                if ($FreshLogDir) { $rbArgs += '-FreshLogDir', $FreshLogDir, '-FreshLogMaxAgeMinutes', "$FreshLogMaxAgeMinutes" }
                if ($ProcessArgumentPattern) { $rbArgs += '-ProcessArgumentPattern', $ProcessArgumentPattern }
                if ($HealthUrl) { $rbArgs += '-HealthUrl', $HealthUrl }
                # by stage 4 the finally above has already restarted the tasks, so the
                # processor may be live and holding files again
                if ($KillProcesses) { $rbArgs += '-KillProcesses' }
                # Always, and unconditionally: Invoke-Rollback refuses a
                # database-coupled unit without one of its two SQL switches, and a
                # child process launched by a failing deploy cannot answer that
                # refusal. Blocking here would leave production on the release that
                # just failed -- strictly worse than restoring the files and
                # recording that the database rollback is still owed. For units
                # that are not coupled the switch is inert.
                $rbArgs += '-SqlRollbackDeferred'
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-Rollback.ps1') @rbArgs
                $rbCode = $LASTEXITCODE
            }
            catch {
                Write-VesLog ERROR "AUTO-ROLLBACK could not be launched: $($_.Exception.Message)" -Data @{runId = $runId } -LogFile $LogFile
                $rbCode = $VES_EXIT_NOBASE
            }
            # never let the child's code leak into the deploy's own exit path
            $global:LASTEXITCODE = 0
            $script:rolledBack = $true
            $script:rollbackExitCode = $rbCode
            # Debt follows files on disk, not exit codes. Exit 2 can mean "never
            # mirrored" (empty backup, lock held, launch failure) OR "mirrored but
            # unproven" (no baseline). Exit codes alone cannot tell those apart;
            # Invoke-Rollback already records sqlRollbackOwed only after the mirror
            # succeeds. Read that signal from the shared log. No child RUN END
            # (launch catch / missing log) means no debt -- inventing one would
            # attest a database rollback after a restore that never happened.
            $script:sqlRollbackOwed = $false
            if ($script:dbCoupled -and $LogFile -and (Test-Path -LiteralPath $LogFile)) {
                try {
                    $rbEnds = @(Get-Content -LiteralPath $LogFile -ErrorAction Stop |
                            ForEach-Object {
                            try { $_ | ConvertFrom-Json } catch { $null }
                        } |
                            Where-Object { $_ -and $_.PSObject.Properties['msg'] -and $_.msg -match '^RUN END: rollback' })
                    if ($rbEnds.Count -gt 0) {
                        $lastRb = $rbEnds[-1]
                        if ($lastRb.PSObject.Properties['sqlRollbackOwed'] -and $lastRb.sqlRollbackOwed) {
                            $script:sqlRollbackOwed = $true
                        }
                    }
                }
                catch {
                    # An unreadable log must not invent debt, and must not abort
                    # the already-failed deploy's exit path.
                }
            }
            Write-VesLog ($(if ($rbCode -eq 0) { 'OK' } else { 'ERROR' })) 'ROLLBACK OUTCOME' `
                -Data @{runId = $runId; stage = $stageName; stageExitCode = $stageCode; rollbackExitCode = $rbCode; backupDir = $backupDir } -LogFile $LogFile
            if ($rbCode -eq 0) {
                # "restored, re-verified, healthy" is a claim about files. For a
                # coupled unit it is only half the rollback, and the health probe
                # cannot see the other half: it checks log freshness, and a binary
                # logging "expects parameter ... which was not supplied" on every
                # message keeps it green. Say files, and name what is still owed.
                if ($script:dbCoupled) {
                    Write-VesLog WARN ("AUTO-ROLLBACK COMPLETE (FILES ONLY): prior release files restored, re-verified, log-active. But {0} is database-coupled and the restore ran with -SqlRollbackDeferred, so the DATABASE ROLLBACK IS STILL OWED -- production is NOT back on the prior release until the SQL rollback scripts have been run in the REVERSE of the rollout order. The deploy still FAILED (exit {1})." -f $Processor, $stageCode) `
                        -Data @{runId = $runId; sqlRollbackOwed = $true; databaseCoupled = $true } -LogFile $LogFile
                }
                else {
                    Write-VesLog OK "AUTO-ROLLBACK COMPLETE: prior release restored, re-verified, healthy. The deploy still FAILED (exit $stageCode)." -LogFile $LogFile
                }
                $script:onFailExitCode = $stageCode
            }
            elseif ($rbCode -eq $VES_EXIT_DRIFT -or $rbCode -eq $VES_EXIT_HEALTH) {
                # The copy itself worked -- the restored release just could not be
                # proven (drift) or is not alive (health). Say that, rather than
                # claiming a failed restore: the two need different responses.
                Write-VesLog ERROR "AUTO-ROLLBACK RESTORED BUT UNPROVEN (rollback exit $rbCode): the prior release is back on disk but did not pass its own verify/health check. A human must confirm production." -LogFile $LogFile
                $script:onFailExitCode = $VES_EXIT_NOBASE
            }
            else {
                Write-VesLog ERROR "AUTO-ROLLBACK FAILED (exit $rbCode). Production is in an INDETERMINATE state; manual recovery required." -LogFile $LogFile
                $script:onFailExitCode = $VES_EXIT_NOBASE
            }
        }
    }

    # Stage 3: stop -> copy -> restart. The try/finally is what guarantees prod
    # comes back up even if the copy throws, so it stays here in plain sight; the
    # two long side-effecting halves live in the module and are shared with
    # Invoke-Rollback so a restore quiesces the box exactly the way a deploy does.
    # $stop is initialised BEFORE the try: if the stop call itself throws, finally
    # must not blow up on an unassigned variable.
    $stop = $null
    $copyFailed = $false
    try {
        $stop = Stop-VesProcessorTarget -TargetRoot $TargetRoot -ScheduledTasks $ScheduledTasks `
            -ServiceName $ServiceName -KillProcesses:$KillProcesses -Processor $Processor -LogFile $LogFile
        # only mirror the staged tree in once everything is safely stopped
        if ($stop.Stopped) {
            Write-VesLog INFO "Copy $StagedRoot -> $TargetRoot" -LogFile $LogFile
            # /MIR so stale files get removed; binary copy, nothing rewrites line endings.
            # /XF and /XD hold back the preserved paths: without them /MIR replaces the
            # server's own config with the staged one AND deletes any server-only file,
            # and the post-deploy verify still reports PASS because the mirror made the
            # tree match the manifest. The dated backup was the only recovery.
            $rcArgs = @($StagedRoot, $TargetRoot, '/MIR', '/NP', '/R:2', '/W:5')
            foreach ($f in $PreserveFiles) { if ($f) { $rcArgs += '/XF', $f } }
            foreach ($d in $PreserveDirs) { if ($d) { $rcArgs += '/XD', $d } }
            robocopy @rcArgs | Out-Null
            # robocopy: 0-7 are success variants, 8+ is failure
            if ($LASTEXITCODE -ge 8) { Write-VesLog ERROR "robocopy failed ($LASTEXITCODE)" -LogFile $LogFile; $copyFailed = $true }
            $global:LASTEXITCODE = 0   # clear the 1-7 success codes so Step doesn't trip on them
        }
    }
    finally {
        # prompt relaunch, only after a clean stop+copy: never auto-start a tree a
        # failed copy may have left broken (next trigger / the operator owns that).
        $startTasks = ($StartTasksAfter -and $stop -and $stop.Stopped -and -not $copyFailed)
        if ($stop) {
            Start-VesProcessorTarget -DisabledTasks $stop.DisabledTasks -ServiceName $ServiceName `
                -StartTasks:$startTasks -LogFile $LogFile | Out-Null
        }
    }
    # a failed stop or copy aborts here (processor already restored by finally)
    if (-not $stop -or -not $stop.Stopped) {
        # Nothing was copied, so the tree is untouched: an auto-rollback here would
        # be pointless churn against the same file locks that blocked the stop.
        # NOBASE (2), not DRIFT (1): no comparison ran and production was not
        # touched, so this is "we could not proceed", not "production is wrong".
        # Invoke-Rollback returns 2 for the identical could-not-quiesce case.
        Write-VesLog ERROR "Stop phase failed; processor state restored, no copy performed. Production is unchanged but unverified." -LogFile $LogFile
        Stop-Deploy $VES_EXIT_NOBASE
    }
    if ($copyFailed) {
        # A /MIR that died part-way left production indeterminate — same class as a
        # failed restore or aborted backup: NOBASE (2), not DRIFT (1). Drift means
        # "we compared and production differs"; here no successful compare ran.
        # Auto-rollback is the remediation path when a backup exists.
        $code = $VES_EXIT_NOBASE
        if ($rollbackOnFail) {
            $script:onFailExitCode = $null
            & $rollbackOnFail 'copy' $VES_EXIT_NOBASE
            if ($null -ne $script:onFailExitCode) { $code = $script:onFailExitCode }
        }
        Stop-Deploy $code
    }

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
        '-Processor', $Processor,
        '-CommitSha', $StagedCommit,
        '-Environment', $Environment
    )
    if ($ReleaseTag) { $verArgs += '-ReleaseTag', $ReleaseTag }
    if ($BaselineRepo) { $verArgs += '-BaselineRepo', $BaselineRepo }
    if ($LogFile) { $verArgs += '-LogFile', $LogFile }
    if ($ConfigContract) { $verArgs += '-ConfigContract', $ConfigContract, '-ConfigPath', $ConfigPath }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-Verification.ps1') @verArgs
} $rollbackOnFail

# Stage 5: confirm the processor is actually alive after the restart (service/task/log/endpoint)
Step 'health check' {
    # Array-valued params travel as ONE delimiter-joined argument: PowerShell
    # -File mode cannot bind an array, and repeating a named argument fails the
    # child with ParameterAlreadyBound. Invoke-HealthCheck splits them back out.
    $hcArgs = @('-Processor', $Processor, '-CommitSha', $StagedCommit, '-Environment', $Environment)
    if ($ReleaseTag) { $hcArgs += '-ReleaseTag', $ReleaseTag }
    if ($LogFile) { $hcArgs += '-LogFile', $LogFile }
    if ($rbAssemblies) { $hcArgs += '-RequiredAssemblies', $rbAssemblies }
    if ($ServiceName) { $hcArgs += '-ServiceName', $ServiceName }
    if ($rbTasks) { $hcArgs += '-ScheduledTasks', $rbTasks }
    if ($FreshLogDir) { $hcArgs += '-FreshLogDir', $FreshLogDir, '-FreshLogMaxAgeMinutes', "$FreshLogMaxAgeMinutes" }
    if ($ScheduledTasks.Count -gt 0) {
        $hcArgs += '-ProcessPathRoot', $TargetRoot
        if ($ProcessArgumentPattern) { $hcArgs += '-ProcessArgumentPattern', $ProcessArgumentPattern }
    }
    if ($HealthUrl) { $hcArgs += '-HealthUrl', $HealthUrl }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-HealthCheck.ps1') @hcArgs
} $rollbackOnFail

# Backup retention capability: after a fully green deploy, keep only the newest N
# backup folders for this processor and prune the older restore points. Enumerated
# through Get-VesBackupSet, the same function the restore picker uses, so the two
# can never disagree about what counts as a backup (both name shapes included).
# Unreachable on a failed deploy, so a failure can never eat its own restore point.
if ($BackupRoot -and $KeepBackups -gt 0 -and (Test-Path -LiteralPath $BackupRoot)) {
    $old = @(Get-VesBackupSet -BackupRoot $BackupRoot -Processor $Processor | Select-Object -Skip $KeepBackups)
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
