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
    # console EXE processors: exe filename (e.g. VES.OutboundDBQProcessor.exe).
    # Combined with -ProcessCmdArg to kill the specific instance before copy.
    [string]$ProcessName,
    # command-line argument that identifies which instance to kill; required because
    # the same exe runs 2-3 times per egress server (RTP for Ack/XML, RTPDP for DBQ).
    # If both -ProcessName and -ProcessCmdArg are supplied, the matching process is
    # killed before the robocopy and the folder's files are no longer held open.
    [string]$ProcessCmdArg,
    # Task Scheduler jobs on THIS server to disable before copy / re-enable after,
    # e.g. VLER_EM_Real_Time_Outbound_Processor. Empty for service-only systems.
    [string[]]$ScheduledTasks = @(),
    # dated backup of the current target before overwrite (runbook convention:
    # <BackupRoot>\<yyyyMMdd>_<Initials>_<Processor>). Skipped if not set.
    [string]$BackupRoot,
    [string]$Initials = $env:USERNAME,
    [string]$HealthUrl,
    # liveness for endpoint-less .exe processors; passed through to the health check
    [string]$FreshLogDir,
    # batch file that starts the console EXE processor; launched after copy to
    # restore liveness. The bat is responsible for the actual exe launch.
    [string]$LaunchBat,
    [string]$Region = 'us-gov-west-1',
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# Guard against process-kill or bat-launch with unsafe values supplied to these
# optional parameters. ProcessCmdArg must be a simple argument token (word chars,
# hyphens, dots) so a misconfigured value cannot inadvertently kill unrelated
# processes. LaunchBat must be an absolute, traversal-free path ending in .bat.
if ($ProcessCmdArg -and -not (Test-VesArgToken $ProcessCmdArg)) {
    Write-VesLog ERROR "ProcessCmdArg must contain only word characters, hyphens, or dots: '$ProcessCmdArg'" -LogFile $LogFile
    exit $VES_EXIT_USAGE
}
if ($LaunchBat) {
    # normalize first so GetFullPath resolves any relative segments;
    # IsPathRooted + .bat extension check is sufficient after normalization
    try { $LaunchBat = [System.IO.Path]::GetFullPath($LaunchBat) } catch {}
    if (-not [System.IO.Path]::IsPathRooted($LaunchBat) -or $LaunchBat -notmatch '(?i)\.bat$') {
        Write-VesLog ERROR "LaunchBat must be an absolute .bat path: '$LaunchBat'" -LogFile $LogFile
        exit $VES_EXIT_USAGE
    }
}

# run a named stage; if it exits non-zero, abort the whole deploy with that stage's code
function Step($name, $code) {
    Write-VesLog INFO ">>> $name" -LogFile $LogFile
    & $code
    if ($LASTEXITCODE -ne 0) {
        Write-VesLog ERROR "STAGE FAILED: $name (exit $LASTEXITCODE)" -LogFile $LogFile
        exit $LASTEXITCODE
    }
}

# Stage 1: block the deploy unless the staged commit/content matches the approved baseline
Step 'pre-deploy gate' {
    & (Join-Path $here 'Invoke-PreDeployGate.ps1') -StagedRoot $StagedRoot -StagedCommit $StagedCommit `
        -ApprovedCommitParam $ApprovedCommitParam -TrustParam $TrustParam -Processor $Processor `
        -Region $Region -LogFile $LogFile
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
        } else {
            Write-VesLog WARN "TargetRoot does not exist yet; nothing to back up." -LogFile $LogFile
        }
    }

    # Stop -> copy -> restart. try/finally guarantees we re-enable tasks and
    # restart the service even if the copy fails, so we never leave prod down.
    # Stage 3: stop -> copy -> restart, tracking what we disabled so finally can undo it
    $disabled  = New-Object System.Collections.Generic.List[string]
    $copyFailed = $false
    $stopFailed = $false
    try {
        # disable the scheduled tasks that hold the target files open
        foreach ($tn in $ScheduledTasks) {
            try { Disable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
                  $disabled.Add($tn); Write-VesLog INFO "Disabled task: $tn" -LogFile $LogFile }
            catch { Write-VesLog ERROR "Could not disable task $tn -> $($_.Exception.Message)" -LogFile $LogFile; $stopFailed = $true; break }
        }
        # stop the Windows service too, for Java-service targets
        if (-not $stopFailed -and $ServiceName) {
            $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            if ($svc) {
                try { Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                      Write-VesLog INFO "Stopped service: $ServiceName" -LogFile $LogFile }
                catch { Write-VesLog ERROR "Could not stop service $ServiceName -> $($_.Exception.Message)" -LogFile $LogFile; $stopFailed = $true }
            }
        }
        # kill the specific console EXE instance before copy. Disabling the task does
        # NOT terminate a running instance; the process holds the folder's files open
        # until it exits, which would cause the robocopy to fail. Match by exe name +
        # command-line arg so only the target instance is killed (same exe name runs
        # 2-3 times per egress server with different args: RTP for Ack/XML, RTPDP for DBQ).
        if (-not $stopFailed -and $ProcessName -and $ProcessCmdArg) {
            try {
                $wmiHits = @(Get-VesProcess -ProcessName $ProcessName -ProcessCmdArg $ProcessCmdArg -ErrorAction Stop)
                if ($wmiHits.Count -gt 0) {
                    foreach ($p in $wmiHits) {
                        try {
                            Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
                            Write-VesLog INFO "Killed: $ProcessName pid=$($p.ProcessId) (arg=$ProcessCmdArg)" -LogFile $LogFile
                        } catch {
                            # process may have exited naturally between the WMI query and
                            # Stop-Process; a gone process no longer holds the files open
                            Write-VesLog WARN "Could not kill $ProcessName pid=$($p.ProcessId) (already exited?): $($_.Exception.Message)" -LogFile $LogFile
                        }
                    }
                } else {
                    # not running is a warning, not a hard stop; robocopy can proceed
                    Write-VesLog WARN "No running '$ProcessName' with arg '$ProcessCmdArg'; nothing to kill." -LogFile $LogFile
                }
            } catch {
                Write-VesLog ERROR "Could not kill $ProcessName($ProcessCmdArg) -> $($_.Exception.Message)" -LogFile $LogFile
                $stopFailed = $true
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
                try { Start-Service -Name $ServiceName -ErrorAction Stop
                      Write-VesLog INFO "Started service: $ServiceName" -LogFile $LogFile }
                catch { Write-VesLog ERROR "FAILED to restart service $ServiceName -> $($_.Exception.Message)" -LogFile $LogFile }
            }
        }
        foreach ($tn in $disabled) {
            try { Enable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
                  Write-VesLog INFO "Re-enabled task: $tn" -LogFile $LogFile }
            catch { Write-VesLog ERROR "FAILED to re-enable task $tn -> $($_.Exception.Message)" -LogFile $LogFile }
        }
        # relaunch the console EXE via its .bat so the processor is live again.
        # Runs even if the copy failed so we never leave the processor down.
        if ($LaunchBat) {
            if (Test-Path -LiteralPath $LaunchBat) {
                try {
                    # array form of ArgumentList handles paths with spaces correctly.
                    # -Wait lets us read the bat's exit code; -PassThru hands back the
                    # process object. The bat typically uses 'start' to launch the exe
                    # non-blocking, so cmd.exe itself returns quickly.
                    # TOCTOU note: Test-Path and Start-Process are not atomic. The parent
                    # directory's write ACL must be restricted to the deployment account
                    # to prevent file substitution between the two calls. Hash validation
                    # of the bat would require pre-registration and is out of scope here.
                    Write-VesLog WARN "Launching batch file (ensure $LaunchBat dir ACL restricts write to deployment account)" -LogFile $LogFile
                    $batProc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$LaunchBat`"") `
                        -NoNewWindow -Wait -PassThru
                    if ($batProc.ExitCode -ne 0) {
                        Write-VesLog ERROR "LaunchBat returned exit $($batProc.ExitCode): $LaunchBat" -LogFile $LogFile
                    } else {
                        Write-VesLog INFO "Relaunched: $LaunchBat" -LogFile $LogFile
                    }
                } catch {
                    Write-VesLog ERROR "FAILED to relaunch $LaunchBat -> $($_.Exception.Message)" -LogFile $LogFile
                }
            } else {
                Write-VesLog ERROR "LaunchBat not found (processor may be down): $LaunchBat" -LogFile $LogFile
            }
        }
    }
    # a failed stop or copy aborts here (processor already restored by finally)
    if ($stopFailed) { Write-VesLog ERROR "Stop phase failed; processor state restored, no copy performed." -LogFile $LogFile; exit $VES_EXIT_DRIFT }
    if ($copyFailed) { exit $VES_EXIT_DRIFT }

} else {
    # -WhatIf path: the gate already ran, so report success without touching prod
    Write-VesLog WARN 'WhatIf: skipping stop/backup/copy, gate only.' -LogFile $LogFile
    exit $VES_EXIT_OK
}

# Stage 4: prove the deployed tree matches the trusted baseline (files, and config if supplied)
Step 'post-deploy verify' {
    # config is optional per system; only run VerifyConfig when a contract is
    # supplied. 'All' hard-requires the config params, so a config-less system
    # must verify files only, not fail with a usage error.
    $a = @{
        Mode = if ($ConfigContract) { 'All' } else { 'VerifyFiles' }
        ReleaseRoot=$TargetRoot; ManifestPath=$ManifestPath; TrustParam=$TrustParam
        Processor=$Processor; Region=$Region; LogFile=$LogFile
    }
    if ($ConfigContract) { $a.ConfigContract=$ConfigContract; $a.ConfigPath=$ConfigPath }
    & (Join-Path $here 'Invoke-Verification.ps1') @a
}

# Stage 5: confirm the processor is actually alive after the restart (service/task/log/endpoint)
Step 'health check' {
    & (Join-Path $here 'Invoke-HealthCheck.ps1') -RequiredAssemblies $RequiredAssemblies `
        -ServiceName $ServiceName -ScheduledTasks $ScheduledTasks -FreshLogDir $FreshLogDir `
        -HealthUrl $HealthUrl -ProcessName $ProcessName -ProcessCmdArg $ProcessCmdArg `
        -Processor $Processor -CommitSha $StagedCommit -LogFile $LogFile
}

# all five stages passed
Write-VesLog OK "DEPLOY COMPLETE: $Processor @ $StagedCommit verified+healthy" -LogFile $LogFile
exit $VES_EXIT_OK
