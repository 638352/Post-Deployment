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
    # dated backup of the current target before overwrite (runbook convention:
    # <BackupRoot>\<yyyyMMdd>_<Initials>_<Processor>). Skipped if not set.
    [string]$BackupRoot,
    [string]$Initials = $env:USERNAME,
    [string]$HealthUrl,
    # liveness for endpoint-less .exe processors; passed through to the health check
    [string]$FreshLogDir,
    # dated backups to keep per processor under BackupRoot; older ones are pruned
    # after a successful backup. Deploy audit logs are never pruned.
    [int]$KeepBackups = 5,
    # outbound console exes: kill a running instance whose executable lives under
    # TargetRoot (audited by PID and command line). Without this switch a detected
    # running instance aborts the deploy instead of fighting the file lock.
    [switch]$KillProcesses,
    # relaunch the processor via its scheduled task(s) after a clean copy
    [switch]$StartTasksAfter,
    [string]$Region = 'us-gov-west-1',
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# run a named stage; if it exits non-zero, abort the whole deploy with that stage's code
function Step($name, $code) {
    Write-VesLog INFO ">>> $name" -LogFile $LogFile
    & $code
    if ($LASTEXITCODE -ne 0) {
        Write-VesLog ERROR "STAGE FAILED: $name (exit $LASTEXITCODE)" -LogFile $LogFile
        # name the failed stage on the Datadog timeline; the gate announces its
        # own PASS/BLOCKED/OVERRIDE, so this covers every stage after it
        if ($name -ne 'pre-deploy gate') {
            Send-VesDatadogEvent -Title "Deploy FAILED: $Processor" `
                -Text "Stage '$name' failed with exit $LASTEXITCODE (staged=$StagedCommit)." `
                -AlertType error -Tags @("processor:$Processor")
        }
        exit $LASTEXITCODE
    }
}

# emit a deploy-failure timeline event, then exit with the given code
function Fail-Deploy([string]$stage, [string]$why, [int]$code) {
    Send-VesDatadogEvent -Title "Deploy FAILED: $Processor" `
        -Text "Stage '$stage' failed: $why (staged=$StagedCommit)." `
        -AlertType error -Tags @("processor:$Processor")
    exit $code
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
        # save the current state before anything gets overwritten
        $backupDir = Join-Path $BackupRoot ("{0}_{1}_{2}" -f (Get-Date).ToString('yyyyMMdd'), $Initials, $Processor)
        if (Test-Path -LiteralPath $TargetRoot) {
            Write-VesLog INFO "Backup $TargetRoot -> $backupDir" -LogFile $LogFile
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            robocopy $TargetRoot $backupDir /E /NP /R:2 /W:5 | Out-Null
            if ($LASTEXITCODE -ge 8) {
                Write-VesLog ERROR "Backup failed ($LASTEXITCODE); aborting before copy" -LogFile $LogFile
                Fail-Deploy 'backup' "robocopy exit $LASTEXITCODE" $VES_EXIT_DRIFT
            }
            $global:LASTEXITCODE = 0
            # retention: keep the newest $KeepBackups dated backups for this
            # processor; the dated yyyyMMdd prefix makes name order = age order
            $old = Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "^\d{8}_.+_$([regex]::Escape($Processor))$" } |
                Sort-Object Name -Descending | Select-Object -Skip $KeepBackups
            foreach ($b in $old) {
                Write-VesLog INFO "Pruning old backup: $($b.FullName)" -LogFile $LogFile
                Remove-Item -LiteralPath $b.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
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
        # outbound console exes are not covered by service/task stop: find any
        # process whose executable path sits under TargetRoot
        if (-not $stopFailed) {
            $tgt = $TargetRoot.TrimEnd('\')
            $locked = @(Get-CimInstance Win32_Process | Where-Object {
                $_.ExecutablePath -and $_.ExecutablePath.StartsWith("$tgt\", [StringComparison]::OrdinalIgnoreCase)
            })
            if ($locked.Count -gt 0 -and -not $KillProcesses) {
                # safe default: abort rather than fight the file lock mid-copy
                foreach ($pr in $locked) {
                    Write-VesLog ERROR ("Running instance holds target: PID {0} {1}" -f $pr.ProcessId, $pr.ExecutablePath) -LogFile $LogFile
                }
                Write-VesLog ERROR 'Running instance(s) detected under TargetRoot; re-run with -KillProcesses or stop them manually.' -LogFile $LogFile
                $stopFailed = $true
            }
            elseif ($locked.Count -gt 0) {
                # audited kill: PID + full command line land in the JSONL log first
                foreach ($pr in $locked) {
                    Write-VesLog WARN ("KillProcesses: stopping PID {0}" -f $pr.ProcessId) `
                        -Data @{pid=$pr.ProcessId; exe=$pr.ExecutablePath; cmdline=$pr.CommandLine} -LogFile $LogFile
                    try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction Stop }
                    catch { Write-VesLog ERROR ("Could not stop PID {0} -> {1}" -f $pr.ProcessId, $_.Exception.Message) -LogFile $LogFile; $stopFailed = $true }
                }
                if (-not $stopFailed) { Start-Sleep -Seconds 2 }   # let handles release before the mirror
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
    }
    # a failed stop or copy aborts here (processor already restored by finally)
    if ($stopFailed) {
        Write-VesLog ERROR "Stop phase failed; processor state restored, no copy performed." -LogFile $LogFile
        Fail-Deploy 'stop' 'processor could not be safely stopped' $VES_EXIT_DRIFT
    }
    if ($copyFailed) { Fail-Deploy 'copy' 'robocopy mirror failed' $VES_EXIT_DRIFT }

    # -StartTasksAfter: relaunch the outbound processor via its scheduled task(s)
    # now that a clean copy is in place (finally only re-enabled them)
    if ($StartTasksAfter) {
        foreach ($tn in $ScheduledTasks) {
            try { Start-ScheduledTask -TaskName $tn -ErrorAction Stop
                  Write-VesLog INFO "Started task: $tn" -LogFile $LogFile }
            catch { Write-VesLog WARN "Could not start task $tn -> $($_.Exception.Message)" -LogFile $LogFile }
        }
    }

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
        -HealthUrl $HealthUrl -Processor $Processor -CommitSha $StagedCommit -LogFile $LogFile
}

# all five stages passed; the COMPLETE event is the authorized-change marker
# that drift alerts get overlaid against on the Datadog timeline
Write-VesLog OK "DEPLOY COMPLETE: $Processor @ $StagedCommit verified+healthy" -LogFile $LogFile
Send-VesDatadogEvent -Title "Deploy COMPLETE: $Processor" `
    -Text "$Processor @ $StagedCommit deployed, verified, and healthy." `
    -AlertType success -Tags @("processor:$Processor")
exit $VES_EXIT_OK
