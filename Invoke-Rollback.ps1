#Requires -Version 5.1
<#
.DESCRIPTION
    Restore a processor from a deploy backup: pick the backup, quiesce the
    processor, mirror the backup tree back over TargetRoot, restore an
    out-of-tree config, restart, then PROVE the restore by re-running
    verification and the health check. Optionally re-pin the SSM trust anchor
    back to the restored release.

    The restore points are the dated folders Deploy-Processor writes before it
    overwrites production: <BackupRoot>\<yyyyMMddTHHmmss>_<Initials>_<Processor>
    (older date-only folders are still restorable). Each carries a
    rollback-record.json sidecar naming what it replaced, the config it stashed,
    and the SSM values in force at the time. The sidecar is written LAST by the
    deploy, so a backup without one may be incomplete -- this script warns and
    cross-checks the file count rather than trusting the folder blindly.

    Two deliberate differences from Deploy-Processor:
      * tasks are STARTED after a clean restore by default (-NoStartTasksAfter
        opts out). A rollback that leaves the processor down fails its own
        health check.
      * -Reason is required, but validated in-body rather than declared
        Mandatory: under `powershell.exe -File` a missing mandatory parameter
        prompts on stdin, which hangs a scheduled or child-process run.

    Exit codes:
      0  restored, verified (or explicitly allowed unverified), healthy
      1  restored cleanly, but the post-rollback verify reported drift
      2  no usable backup / partial backup / restore copy failed / could not
         quiesce / no baseline to verify against -- production is NOT proven
      3  restored and verified, but the processor is not healthy after restart
      10 usage or unsafe configuration

    Mutating script: it writes a JSONL audit log by default (see README).
.EXAMPLE
    .\Invoke-Rollback.ps1 -Processor OutboundDBQ -BackupRoot C:\...\BackUp -ListBackups
.EXAMPLE
    .\Invoke-Rollback.ps1 -Processor OutboundDBQ -TargetRoot C:\...\VES.OutboundProcessor `
      -BackupRoot C:\...\BackUp -Reason 'VEMS-1234 bad release' -WhatIf
#>
# No ConfirmImpact='High': that makes ShouldProcess prompt by default, which a
# scheduled run or the -AutoRollback child process cannot answer (and which throws
# outright on a host with no interactive UI). The mandatory -Reason and the audit
# record are the deliberate friction instead.
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Restore')]
param(
    [Parameter(Mandatory)][string]$Processor,
    # Folder holding this processor's dated backups. Required to pick the newest;
    # optional only when -BackupDir names the folder outright.
    [string]$BackupRoot,
    [Parameter(ParameterSetName = 'Restore')][string]$TargetRoot,
    # Read-only: show what could be restored and stop.
    [Parameter(ParameterSetName = 'List', Mandatory)][switch]$ListBackups,
    # Why this restore is happening. Required for a restore; goes in the audit log.
    [Parameter(ParameterSetName = 'Restore')][string]$Reason,
    # Restore this specific backup folder instead of the newest one.
    [Parameter(ParameterSetName = 'Restore')][string]$BackupDir,

    # --- restore scope --------------------------------------------------------
    # Live config path. When it sits outside TargetRoot it is restored from the
    # backup's _ves-config stash; when it sits inside, it rides along in the mirror.
    [string]$ConfigPath,
    # Keep the CURRENT config instead of the backed-up one.
    [switch]$NoConfigRestore,
    # File/dir names or paths to leave untouched by the mirror (robocopy /XF, /XD).
    [string[]]$PreservePaths = @(),

    # --- stop / start (same shape as Deploy-Processor) ------------------------
    [string]$ServiceName,
    [string[]]$ScheduledTasks = @(),
    [switch]$KillProcesses,
    # Inverted on purpose: a rollback restarts the processor unless told not to.
    [switch]$NoStartTasksAfter,

    # --- post-rollback proof --------------------------------------------------
    [string]$BaselineRepo,
    # Release tag of the RESTORED release; overrides the sidecar's priorReleaseTag.
    [string]$ReleaseTag,
    # Manifest describing the RESTORED release (not the failed one).
    [string]$ManifestPath,
    [string]$TrustParam,
    [string]$ConfigContract,
    [switch]$SkipHealth,
    # Accept a restore that could not be verified against any baseline (exit 0
    # instead of 2). Use only when no manifest for the prior release exists.
    [switch]$AllowUnverifiedRollback,

    # --- health probes, passed through ---------------------------------------
    [string[]]$RequiredAssemblies = @(),
    [string]$HealthUrl,
    [string]$FreshLogDir,
    [int]$FreshLogMaxAgeMinutes = 60,
    [string]$ProcessArgumentPattern,

    # --- trust anchor ---------------------------------------------------------
    # Re-pin SSM to the restored release. Off by default, operator-only, and
    # applied only after the post-rollback verification passes.
    [switch]$RepinTrust,
    [string]$ApprovedCommitParam,

    [string]$Initials = $env:USERNAME,
    [string]$Environment = 'prod',
    [string]$Region = 'us-gov-west-1',
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
# Mutating script: log by default so a restore always leaves evidence.
if (-not $LogFile) { $LogFile = New-VesLogFile -Prefix ("rollback-{0}" -f $Processor) }
$runId = [guid]::NewGuid().ToString()
$script:chosen = $null
$script:restored = $false

Write-VesLog INFO 'RUN START: rollback' `
    -Data @{runId = $runId; script = 'Invoke-Rollback.ps1'; processor = $Processor; environment = $Environment; target = $TargetRoot; reason = $Reason } `
    -LogFile $LogFile

function Stop-Rollback([int]$code) {
    $outcome = Get-VesOutcome -ExitCode $code
    Write-VesLog ($(if ($outcome -eq 'PASS') { 'OK' } else { 'ERROR' })) `
        "RUN END: rollback outcome=$outcome exit=$code" `
        -Data @{runId = $runId; outcome = $outcome; exitCode = $code; processor = $Processor; backupDir = $script:chosen; restored = $script:restored } -LogFile $LogFile
    exit $code
}

# Read a property off a ConvertFrom-Json document without assuming it exists.
# Sidecars written by an older deploy, or hand-edited, would otherwise throw.
function Get-RecordValue($doc, [string]$name) {
    if ($null -eq $doc) { return $null }
    if (-not $doc.PSObject.Properties[$name]) { return $null }
    return $doc.$name
}

# --- List mode: read-only, mutates nothing ------------------------------------
if ($ListBackups) {
    if (-not $BackupRoot) { Write-VesLog ERROR '-BackupRoot is required to list backups.' -LogFile $LogFile; Stop-Rollback $VES_EXIT_USAGE }
    $all = @(Get-VesBackupSet -BackupRoot $BackupRoot -Processor $Processor)
    if ($all.Count -eq 0) {
        Write-VesLog WARN "No backups found for $Processor under $BackupRoot." -LogFile $LogFile
        Stop-Rollback $VES_EXIT_OK
    }
    Write-VesLog INFO ("{0} backup(s) for {1}, newest first:" -f $all.Count, $Processor) -LogFile $LogFile
    foreach ($b in $all) {
        $rec = $b.Record
        $pinMatch = $null
        $priorSsm = Get-RecordValue $rec 'priorSsm'
        $recordedHash = Get-RecordValue $rec 'backupManifestHash'
        if ($priorSsm -and $recordedHash) {
            $pinnedHash = Get-RecordValue $priorSsm 'trustHash'
            if ($pinnedHash) { $pinMatch = ($pinnedHash -eq $recordedHash) }
        }
        $line = "  {0}  files={1}  size={2:N0}B  record={3}  replacedBy={4}  priorTag={5}  matchedPin={6}" -f `
            $b.Name, $b.FileCount, $b.SizeBytes, $(if ($b.HasRecord) { 'yes' } else { 'NO (may be incomplete)' }), `
            $(if (Get-RecordValue $rec 'replacedByCommit') { Get-RecordValue $rec 'replacedByCommit' } else { '-' }), `
            $(if (Get-RecordValue $rec 'priorReleaseTag') { Get-RecordValue $rec 'priorReleaseTag' } else { '-' }), `
            $(if ($null -eq $pinMatch) { 'unknown' } else { $pinMatch })
        Write-VesLog INFO $line -Data @{
            backupDir = $b.FullName; stamp = "$($b.Stamp)"; stampKind = $b.StampKind; initials = $b.Initials
            fileCount = $b.FileCount; sizeBytes = $b.SizeBytes; hasRecord = $b.HasRecord; matchedPin = $pinMatch
        } -LogFile $LogFile
    }
    Stop-Rollback $VES_EXIT_OK
}

# --- Restore mode -------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
    Write-VesLog ERROR '-TargetRoot is required for a restore.' -LogFile $LogFile; Stop-Rollback $VES_EXIT_USAGE
}
if ([string]::IsNullOrWhiteSpace($Reason)) {
    Write-VesLog ERROR '-Reason is required: a restore of production must say why. (Validated here rather than as a Mandatory parameter, which would prompt on stdin under -File.)' -LogFile $LogFile
    Stop-Rollback $VES_EXIT_USAGE
}
if ([string]::IsNullOrWhiteSpace($BackupRoot) -and [string]::IsNullOrWhiteSpace($BackupDir)) {
    Write-VesLog ERROR 'Rollback requires -BackupRoot (newest backup) or -BackupDir (a specific one).' -LogFile $LogFile
    Stop-Rollback $VES_EXIT_USAGE
}

# Nesting check BEFORE anything else: /MIR from a source that lives under its own
# destination deletes the restore source mid-flight.
$targetFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
if ($BackupRoot) {
    $rootFull = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
    if ($rootFull -eq $targetFull -or
        $rootFull.StartsWith($targetFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $targetFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-VesLog ERROR "Unsafe configuration: BackupRoot and TargetRoot overlap ($rootFull vs $targetFull). The mirror would destroy the restore source." -LogFile $LogFile
        Stop-Rollback $VES_EXIT_USAGE
    }
}

# --- Pick the backup ----------------------------------------------------------
$entry = $null
if ($BackupDir) {
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        Write-VesLog ERROR "Backup folder not found: $BackupDir" -LogFile $LogFile; Stop-Rollback $VES_EXIT_NOBASE
    }
    $chosenPath = (Get-Item -LiteralPath $BackupDir).FullName
    if ($BackupRoot) {
        $matched = @(Get-VesBackupSet -BackupRoot $BackupRoot -Processor $Processor | Where-Object { $_.FullName -eq $chosenPath })
        if ($matched.Count -eq 1) { $entry = $matched[0] }
    }
    if (-not $entry) {
        # Deliberate escape hatch: a backup moved to another volume is still restorable.
        Write-VesLog WARN "Backup folder is outside the enumerated set for $Processor; restoring it anyway: $chosenPath" -LogFile $LogFile
        $parent = Split-Path -Parent $chosenPath
        $leaf = Split-Path -Leaf $chosenPath
        $probe = @(Get-VesBackupSet -BackupRoot $parent -Processor $Processor | Where-Object { $_.Name -eq $leaf })
        if ($probe.Count -eq 1) { $entry = $probe[0] }
    }
}
else {
    $all = @(Get-VesBackupSet -BackupRoot $BackupRoot -Processor $Processor)
    if ($all.Count -eq 0) {
        Write-VesLog ERROR "No backup found for $Processor under $BackupRoot; there is nothing to roll back to." -LogFile $LogFile
        Stop-Rollback $VES_EXIT_NOBASE
    }
    $entry = $all[0]
    $chosenPath = $entry.FullName
}
$script:chosen = $chosenPath
$record = $null
if ($entry) { $record = $entry.Record }
Write-VesLog INFO "Rollback source: $chosenPath" -Data @{runId = $runId; backupDir = $chosenPath; reason = $Reason } -LogFile $LogFile

if (-not $record) {
    Write-VesLog WARN "No rollback-record.json in ${chosenPath}: this backup predates the sidecar convention or was left incomplete. Config restore and trust re-pin are unavailable." -LogFile $LogFile
}

# --- Safety gates: everything below runs BEFORE the first mutation ------------
# Count the payload the way Get-VesBackupSet does, so the sidecars and the config
# stash never mask an otherwise empty backup.
$stashDir = Join-Path $chosenPath '_ves-config'
$payload = @(Get-ChildItem -LiteralPath $chosenPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne 'rollback-record.json' -and $_.Name -ne 'backup-manifest.json' -and
            -not $_.FullName.StartsWith(($stashDir + '\'), [StringComparison]::OrdinalIgnoreCase)
        })
if ($payload.Count -eq 0) {
    Write-VesLog ERROR "Backup contains no files: $chosenPath. Mirroring it would wipe production." -LogFile $LogFile
    Stop-Rollback $VES_EXIT_USAGE
}

# Partial-backup check: the deploy's own manifest of the tree says how many files
# there should be. Fewer means the backup copy died part-way.
$backupManifestPath = Join-Path $chosenPath 'backup-manifest.json'
$backupManifest = $null
if (Test-Path -LiteralPath $backupManifestPath) {
    try {
        # Read the count straight out of the JSON rather than through
        # Import-VesManifest: a manifest too damaged to load is exactly when this
        # guard matters most, so it must not be the thing that disables it.
        $backupManifest = Get-Content -LiteralPath $backupManifestPath -Raw -Encoding utf8 | ConvertFrom-Json
        $expected = [int](Get-RecordValue $backupManifest 'fileCount')
        if ($expected -gt 0 -and $payload.Count -lt $expected) {
            Write-VesLog ERROR ("Partial backup: {0} files on disk but the backup manifest lists {1}. Refusing to restore an incomplete tree." -f $payload.Count, $expected) -LogFile $LogFile
            Stop-Rollback $VES_EXIT_NOBASE
        }
    }
    catch {
        Write-VesLog WARN "Could not read backup-manifest.json: $($_.Exception.Message)" -LogFile $LogFile
        $backupManifest = $null
    }
}

$priorSsm = Get-RecordValue $record 'priorSsm'
$priorTrustHash = Get-RecordValue $priorSsm 'trustHash'
$priorTrustRead = [bool](Get-RecordValue $priorSsm 'trustHashRead')
$priorApprovedCommit = Get-RecordValue $priorSsm 'approvedCommit'
$priorApprovedRead = [bool](Get-RecordValue $priorSsm 'approvedCommitRead')
if (-not $TrustParam) { $TrustParam = Get-RecordValue $record 'trustParam' }
if (-not $ApprovedCommitParam) { $ApprovedCommitParam = Get-RecordValue $record 'approvedCommitParam' }
if (-not $ReleaseTag) { $ReleaseTag = Get-RecordValue $record 'priorReleaseTag' }
if (-not $ConfigPath) { $ConfigPath = Get-RecordValue $record 'configPath' }

if ($RepinTrust) {
    if (-not $priorTrustRead -or [string]::IsNullOrWhiteSpace($priorTrustHash)) {
        Write-VesLog ERROR '-RepinTrust needs the prior SSM value recorded in rollback-record.json; this backup has none, and re-pinning to a blank anchor would break every later verify.' -LogFile $LogFile
        Stop-Rollback $VES_EXIT_USAGE
    }
    if (-not $TrustParam) {
        Write-VesLog ERROR '-RepinTrust requires -TrustParam (or a trustParam in the backup record).' -LogFile $LogFile
        Stop-Rollback $VES_EXIT_USAGE
    }
}

# --- Build the robocopy exclusions -------------------------------------------
# The restore MUST mirror: /E alone would leave the bad release's files behind and
# every one of them would surface as EXTRA in the post-rollback verify.
$excludeFiles = New-Object System.Collections.Generic.List[string]
$excludeDirs = New-Object System.Collections.Generic.List[string]
# our own sidecars, by bare name so a nested copy is covered too
$excludeFiles.Add('rollback-record.json')
$excludeFiles.Add('backup-manifest.json')
# full path, so a legitimately-named _ves-config deeper in the tree is not skipped
$excludeDirs.Add($stashDir)

foreach ($p in $PreservePaths) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $TargetRoot $p }
    if (Test-Path -LiteralPath $full -PathType Container) { $excludeDirs.Add($full) } else { $excludeFiles.Add($p) }
    if ($p -notmatch $Global:VES_DEFAULT_EXCLUDE) {
        Write-VesLog WARN "Preserved path '$p' is hash-verified, so the post-rollback verify will report it as CHANGED or EXTRA." -LogFile $LogFile
    }
}
# Keeping the live config means excluding it from the mirror; otherwise /MIR
# replaces it with the backup's copy, which is exactly what -NoConfigRestore asks
# us not to do.
$configInsideTarget = $false
if ($ConfigPath) {
    $configInsideTarget = ([IO.Path]::GetFullPath($ConfigPath)).StartsWith($targetFull + '\', [StringComparison]::OrdinalIgnoreCase)
    if ($NoConfigRestore -and $configInsideTarget) {
        $excludeFiles.Add((Split-Path -Leaf $ConfigPath))
        Write-VesLog INFO "Keeping the live config; excluded from the mirror: $ConfigPath" -LogFile $LogFile
    }
}

# --- WhatIf / confirmation ----------------------------------------------------
# Block-level ShouldProcess, not per-cmdlet: robocopy is a native command and gets
# no automatic -WhatIf.
if (-not $PSCmdlet.ShouldProcess($TargetRoot, "Rollback $Processor from $(Split-Path -Leaf $chosenPath)")) {
    Write-VesLog WARN ("WhatIf: would restore {0} ({1} files) to {2}; configRestore={3}; repinTrust={4}. Nothing changed." -f `
            $chosenPath, $payload.Count, $TargetRoot, (-not $NoConfigRestore), [bool]$RepinTrust) -LogFile $LogFile
    Stop-Rollback $VES_EXIT_OK
}

# --- Restore ------------------------------------------------------------------
# One rollback per processor at a time: two concurrent /MIR runs into one tree
# corrupt it. CreateNew fails if the lock already exists.
$lockPath = Join-Path $env:ProgramData ("ves-verify\{0}.rollback.lock" -f ($Processor -replace '[^\w.-]', '_'))
$lockDir = Split-Path -Parent $lockPath
if (-not (Test-Path -LiteralPath $lockDir)) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }
$lock = $null
try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None) }
catch {
    Write-VesLog ERROR "Another rollback for $Processor is already running (lock: $lockPath). Refusing to mirror the same tree twice." -LogFile $LogFile
    Stop-Rollback $VES_EXIT_NOBASE
}

$stop = $null
$restoreFailed = $false
try {
    $stop = Stop-VesProcessorTarget -TargetRoot $TargetRoot -ScheduledTasks $ScheduledTasks `
        -ServiceName $ServiceName -KillProcesses:$KillProcesses -Processor $Processor -LogFile $LogFile
    if ($stop.Stopped) {
        Write-VesLog INFO "Restore $chosenPath -> $TargetRoot" -LogFile $LogFile
        if (-not (Test-Path -LiteralPath $TargetRoot)) { New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null }
        $rcArgs = @($chosenPath, $TargetRoot, '/MIR', '/NP', '/R:2', '/W:5')
        foreach ($f in $excludeFiles) { $rcArgs += '/XF', $f }
        foreach ($d in $excludeDirs) { $rcArgs += '/XD', $d }
        robocopy @rcArgs | Out-Null
        # robocopy: 0-7 are success variants, 8+ is failure
        if ($LASTEXITCODE -ge 8) { Write-VesLog ERROR "Restore copy failed ($LASTEXITCODE)" -LogFile $LogFile; $restoreFailed = $true }
        $global:LASTEXITCODE = 0
        if (-not $restoreFailed) { $script:restored = $true }

        # Out-of-tree config: not in the mirror, so restore it explicitly. Stash the
        # current one first so the rollback is itself reversible.
        if ($script:restored -and $ConfigPath -and -not $NoConfigRestore -and -not $configInsideTarget) {
            $stashed = Join-Path $stashDir (Split-Path -Leaf $ConfigPath)
            if (Test-Path -LiteralPath $stashed) {
                try {
                    if (Test-Path -LiteralPath $ConfigPath) {
                        $pre = Join-Path $stashDir 'pre-rollback'
                        New-Item -ItemType Directory -Path $pre -Force | Out-Null
                        Copy-Item -LiteralPath $ConfigPath -Destination $pre -Force
                    }
                    Copy-Item -LiteralPath $stashed -Destination $ConfigPath -Force
                    Write-VesLog OK "Restored out-of-tree config: $ConfigPath" -LogFile $LogFile
                }
                catch {
                    Write-VesLog ERROR "Could not restore config $ConfigPath -> $($_.Exception.Message)" -LogFile $LogFile
                    $restoreFailed = $true
                }
            }
            else {
                Write-VesLog WARN "No stashed config in this backup; the live config at $ConfigPath was left as it is." -LogFile $LogFile
            }
        }
    }
}
finally {
    # Restart even on failure: never leave production down. Tasks are started after
    # a clean restore unless the operator opted out.
    $startTasks = ((-not $NoStartTasksAfter) -and $stop -and $stop.Stopped -and -not $restoreFailed)
    if ($stop) {
        Start-VesProcessorTarget -DisabledTasks $stop.DisabledTasks -ServiceName $ServiceName `
            -StartTasks:$startTasks -LogFile $LogFile | Out-Null
    }
    if ($lock) { $lock.Close(); Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
}

if (-not $stop -or -not $stop.Stopped) {
    Write-VesLog ERROR 'Could not quiesce the processor; no restore was attempted. Production still carries the release you were rolling back.' -LogFile $LogFile
    Stop-Rollback $VES_EXIT_NOBASE
}
if ($restoreFailed) {
    # A half-mirrored tree is an ERROR (indeterminate), not a clean FAIL.
    Write-VesLog ERROR 'Restore copy failed; production is in an INDETERMINATE state and needs manual recovery.' -LogFile $LogFile
    Stop-Rollback $VES_EXIT_NOBASE
}
Write-VesLog OK "Rollback complete: $Processor restored from $chosenPath" -LogFile $LogFile

# --- Prove it -----------------------------------------------------------------
# Which manifest describes the RESTORED release, strongest source first. Verifying
# a restored old tree against the new release's manifest is the likeliest way to
# make a good rollback look like a bad one, which is what this ladder prevents.
$verifyCode = $VES_EXIT_OK
$verifySource = $null
$verifyManifest = $null
$verifyTrust = $null
$verifyRepo = $null

if ($BaselineRepo -and $ReleaseTag) {
    $verifySource = "tag $ReleaseTag in $BaselineRepo"; $verifyRepo = $BaselineRepo; $verifyTrust = $TrustParam
}
elseif ($ManifestPath) {
    $verifySource = "manifest $ManifestPath"; $verifyManifest = $ManifestPath; $verifyTrust = $TrustParam
}
elseif ($backupManifest) {
    # Self-recorded snapshot: proves the restore is byte-identical to what was in
    # production before the deploy. It is NOT SSM-anchored, so no -TrustParam.
    $verifySource = 'the backup''s own manifest'; $verifyManifest = $backupManifestPath
    Write-VesLog WARN 'Verifying against the backup''s own manifest: this proves the restore matches pre-deploy production, not that that state was approved.' -LogFile $LogFile
}

if (-not $verifySource) {
    if ($AllowUnverifiedRollback) {
        Write-VesLog WARN 'POST-ROLLBACK VERIFY SKIPPED: no baseline for the restored release, and -AllowUnverifiedRollback was supplied.' -LogFile $LogFile
    }
    else {
        Write-VesLog ERROR 'POST-ROLLBACK VERIFY UNAVAILABLE: no baseline describes the restored release. Supply -BaselineRepo/-ReleaseTag or -ManifestPath, or accept the risk with -AllowUnverifiedRollback.' -LogFile $LogFile
        $verifyCode = $VES_EXIT_NOBASE
    }
}
else {
    Write-VesLog INFO ">>> post-rollback verify ($verifySource)" -LogFile $LogFile
    $verArgs = @(
        '-Mode', $(if ($ConfigContract) { 'All' } else { 'VerifyFiles' }),
        '-ReleaseRoot', $TargetRoot,
        '-Processor', $Processor,
        '-Environment', $Environment,
        '-Region', $Region)
    if ($verifyManifest) { $verArgs += '-ManifestPath', $verifyManifest }
    if ($verifyRepo) { $verArgs += '-BaselineRepo', $verifyRepo }
    if ($ReleaseTag -and $verifyRepo) { $verArgs += '-ReleaseTag', $ReleaseTag }
    if ($verifyTrust) { $verArgs += '-TrustParam', $verifyTrust }
    if ($ConfigContract) { $verArgs += '-ConfigContract', $ConfigContract, '-ConfigPath', $ConfigPath }
    if ($LogFile) { $verArgs += '-LogFile', $LogFile }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Invoke-Verification.ps1') @verArgs
    $verifyCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($verifyCode -ne 0) { Write-VesLog ERROR "Post-rollback verify failed (exit $verifyCode)." -LogFile $LogFile }
}

# Independent of the verify above: did the tree we restored match what SSM had
# pinned at backup time? Informational either way -- the restore is still correct.
$recordedHash = Get-RecordValue $record 'backupManifestHash'
if ($recordedHash -and $priorTrustRead -and $priorTrustHash) {
    if ($recordedHash -eq $priorTrustHash) {
        Write-VesLog OK 'Restored tree matches the SSM-pinned prior baseline.' -LogFile $LogFile
    }
    else {
        Write-VesLog DRIFT 'Restored tree matches pre-deploy production, which itself differed from the pinned baseline.' -LogFile $LogFile
    }
}

# --- Health -------------------------------------------------------------------
# Runs even when the verify failed: an operator looking at a half-restored box
# needs the whole picture in one run, not one stage at a time.
$healthCode = $VES_EXIT_OK
if ($SkipHealth) {
    Write-VesLog WARN 'Health check skipped (-SkipHealth).' -LogFile $LogFile
}
else {
    Write-VesLog INFO '>>> post-rollback health check' -LogFile $LogFile
    $hcArgs = @('-Processor', $Processor, '-Environment', $Environment)
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
    $healthCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($healthCode -ne 0) { Write-VesLog ERROR "Post-rollback health check failed (exit $healthCode)." -LogFile $LogFile }
}

# --- Trust re-pin: last, and only on a proven restore -------------------------
if ($RepinTrust) {
    if ($verifyCode -ne 0) {
        Write-VesLog ERROR 'TRUST RE-PIN SKIPPED: the post-rollback verification did not pass, and pinning the anchor to an unproven tree is exactly what the anchor exists to prevent.' -LogFile $LogFile
    }
    elseif ($PSCmdlet.ShouldProcess($TrustParam, 'Re-pin the SSM trust anchor to the restored release')) {
        $currentPin = $null
        try { $currentPin = Get-VesTrustedHash -ParameterName $TrustParam -Region $Region } catch { $currentPin = $null }
        # audit line BEFORE the write, so the intent is on record even if it fails
        Write-VesLog WARN 'TRUST RE-PIN' -Data @{
            runId = $runId; trustParam = $TrustParam; fromHash = $currentPin; toHash = $priorTrustHash
            approvedCommitParam = $ApprovedCommitParam; toApprovedCommit = $priorApprovedCommit
            operator = "$env:USERNAME@$env:COMPUTERNAME"; reason = $Reason; backupDir = $chosenPath
        } -LogFile $LogFile
        try {
            Set-VesTrustedHash -ParameterName $TrustParam -Value $priorTrustHash -Region $Region
            # One switch drives BOTH values: re-pinning the hash without the
            # approved-commit leaves the gate and the verifier disagreeing about
            # which release is approved, which is worse than doing neither.
            if ($ApprovedCommitParam -and $priorApprovedRead -and $priorApprovedCommit) {
                Set-VesTrustedHash -ParameterName $ApprovedCommitParam -Value $priorApprovedCommit -Region $Region
            }
            else {
                Write-VesLog WARN 'Approved-commit was not recorded in this backup; only the baseline hash was re-pinned. Re-pin the approved commit by hand before the next deploy.' -LogFile $LogFile
            }
            Write-VesLog OK 'TRUST RE-PIN COMPLETE' -Data @{runId = $runId; trustParam = $TrustParam; toHash = $priorTrustHash } -LogFile $LogFile
        }
        catch {
            Write-VesLog ERROR "TRUST RE-PIN FAILED: $($_.Exception.Message)" -LogFile $LogFile
            $verifyCode = Get-VesWorstExitCode -ExitCode @($verifyCode, $VES_EXIT_NOBASE)
        }
    }
}

# Severity, not numeric order: 2 (ERROR) outranks 3 (FAIL).
Stop-Rollback (Get-VesWorstExitCode -ExitCode @($verifyCode, $healthCode))
