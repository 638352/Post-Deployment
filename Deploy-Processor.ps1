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
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$TargetRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$TrustParam,
    [Parameter(Mandatory)][string]$ApprovedCommitParam,
    [string]$ConfigContract,
    [string]$ConfigPath,
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
    [string]$Initials = $env:USERNAME,
    [string]$HealthUrl,
    # liveness for endpoint-less .exe processors; passed through to the health check
    [string]$FreshLogDir,
    [string]$Region = 'us-gov-west-1',
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# Low-cardinality tags shared by every deploy event emitted to Datadog.
$ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag))

# run a named stage; if it exits non-zero, abort the whole deploy with that stage's code
function Step($name, $code) {
    Write-VesLog INFO ">>> $name" -LogFile $LogFile
    & $code
    if ($LASTEXITCODE -ne 0) {
        Write-VesLog ERROR "STAGE FAILED: $name (exit $LASTEXITCODE)" -LogFile $LogFile
        # Timeline event on stage failure. The gate self-reports its own block/override
        # events, so skip it here to avoid double-marking the same failure.
        if ($name -ne 'pre-deploy gate') {
            Send-VesDatadogEvent -Title "Deploy FAILED at '$name': $Processor" `
                -Text "Stage '$name' failed for $Processor $StagedCommit (exit $LASTEXITCODE)." `
                -AlertType 'error' -Tags ($ddTags + 'event:deploy-failed')
        }
        exit $LASTEXITCODE
    }
}

# Stage 1: block the deploy unless the staged commit/content matches the approved baseline
# Invoked via powershell.exe child process so that `exit N` inside the script terminates only
# the child -- not this process -- allowing Step's error logging and Datadog event to fire.
Step 'pre-deploy gate' {
    # -LogFile appended only when set: PS 5.1 drops empty-string args to native
    # commands, which would leave a bare -LogFile expecting a value in the child.
    $gateArgs = @(
        '-StagedRoot', $StagedRoot, '-StagedCommit', $StagedCommit,
        '-ApprovedCommitParam', $ApprovedCommitParam, '-TrustParam', $TrustParam,
        '-ManifestPath', $ManifestPath, '-Processor', $Processor, '-Region', $Region)
    if ($LogFile) { $gateArgs += '-LogFile', $LogFile }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-PreDeployGate.ps1') @gateArgs
}

# Past the gate. -WhatIf short-circuits to the else branch; the real work runs here.
if ($PSCmdlet.ShouldProcess($TargetRoot, "Deploy $Processor $StagedCommit")) {

    # Stage 2: dated backup of the current prod files before we overwrite them
    if ($BackupRoot) {
        $backupDir = Join-Path $BackupRoot ("{0}_{1}_{2}" -f (Get-Date).ToString('yyyyMMdd'), $Initials, $Processor)
        if (Test-Path -LiteralPath $TargetRoot) {
            Write-VesLog INFO "Backup $TargetRoot -> $backupDir" -LogFile $LogFile
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            robocopy $TargetRoot $backupDir /E /NP /R:2 /W:5 | Out-Null
            if ($LASTEXITCODE -ge 8) { Write-VesLog ERROR "Backup failed ($LASTEXITCODE); aborting before copy" -LogFile $LogFile; exit $VES_EXIT_DRIFT }
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
                            -Data @{processor=$Processor; pid=$p.ProcessId; commandLine=$p.CommandLine} -LogFile $LogFile
                        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
                        catch {
                            Write-VesLog ERROR "Could not kill PID $($p.ProcessId) -> $($_.Exception.Message)" -LogFile $LogFile
                            $stopFailed = $true
                        }
                    } else {
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
    if ($stopFailed) { Write-VesLog ERROR "Stop phase failed; processor state restored, no copy performed." -LogFile $LogFile; exit $VES_EXIT_DRIFT }
    if ($copyFailed) { exit $VES_EXIT_DRIFT }

}
else {
    # -WhatIf path: the gate already ran, so report success without touching prod
    Write-VesLog WARN 'WhatIf: skipping stop/backup/copy, gate only.' -LogFile $LogFile
    exit $VES_EXIT_OK
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
        '-Region', $Region
    )
    if ($LogFile) { $verArgs += '-LogFile', $LogFile }
    if ($ConfigContract) { $verArgs += '-ConfigContract', $ConfigContract, '-ConfigPath', $ConfigPath }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-Verification.ps1') @verArgs
}

# Stage 5: confirm the processor is actually alive after the restart (service/task/log/endpoint)
Step 'health check' {
    # Build arg array so each array-valued param is passed as repeated named args
    # (e.g. -RequiredAssemblies a.dll -RequiredAssemblies b.dll), which PowerShell
    # -File mode binds correctly to [string[]] parameters.
    $hcArgs = @('-Processor', $Processor, '-CommitSha', $StagedCommit)
    if ($LogFile) { $hcArgs += '-LogFile', $LogFile }
    foreach ($dll in $RequiredAssemblies) { $hcArgs += '-RequiredAssemblies', $dll }
    if ($ServiceName) { $hcArgs += '-ServiceName', $ServiceName }
    foreach ($tn in $ScheduledTasks) { $hcArgs += '-ScheduledTasks', $tn }
    if ($FreshLogDir) { $hcArgs += '-FreshLogDir', $FreshLogDir }
    if ($HealthUrl) { $hcArgs += '-HealthUrl', $HealthUrl }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-HealthCheck.ps1') @hcArgs
}

# all five stages passed
# backup cleanup, last and only after a fully green deploy: a failed deploy must
# never eat its own restore point. Keep the newest N dated folders for THIS
# processor (name sorts by date because it starts yyyyMMdd), drop the rest.
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
# Timeline event: the "authorized deploy" marker. Drift after this point is expected;
# drift with no marker is the unauthorized-change picture the drift runner surfaces.
Send-VesDatadogEvent -Title "Deploy COMPLETE: $Processor" `
    -Text "Deploy of $Processor $StagedCommit completed: gate + copy + verify + health all green." `
    -AlertType 'success' -Tags ($ddTags + 'event:deploy-complete')
exit $VES_EXIT_OK
