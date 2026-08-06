#Requires -Version 5.1
<#
.SYNOPSIS
    Name the cause behind a failing rollback test instead of inferring it.

.DESCRIPTION
    Invoke-Rollback.ps1 has six separate paths that end in VES_EXIT_NOBASE, so a
    Pester failure reading "Expected 0, but got 2" does not say which one fired.
    It does not have to. Invoke-Rollback logs by default -- New-VesLogFile writes
    one JSONL file per run into VES_AUDIT_LOG_DIR -- and the ERROR line naming
    the cause is therefore already on disk after every suite run. Pester simply
    never shows it.

    This script runs the rollback suite with the audit log pointed at a directory
    it controls, then reads those logs back and reports, per test case, the exit
    code and the error that produced it. Nothing about the tests is hardcoded:
    the case name is recovered from the target path each run logs, and whether a
    run used the shared Git baseline archive is read from the run's own
    'anchored' field. Edits to the suite cannot make this report stale.

    It also snapshots the machine-global state that a fresh CI runner would not
    carry. That is the difference worth looking at when the same commit passes in
    CI and fails on one workstation.

.PARAMETER LogDir
    Classify an existing audit-log directory instead of running anything. Use it
    on logs from a run that already happened; Invoke-Tests.ps1 leaves them in
    <temp>\ves-verify-test-logs-<pid>.

.PARAMETER TestPath
    Test file to run. Defaults to Invoke-Rollback.Tests.ps1 next to this script.

.PARAMETER StateOnly
    Print the machine-state snapshot and exit. Runs no tests and reads no logs.

.EXAMPLE
    .\tests\Debug-RollbackFailure.ps1
    Run the rollback suite and name the cause of every non-zero exit.

.EXAMPLE
    .\tests\Debug-RollbackFailure.ps1 -LogDir $env:TEMP\ves-verify-test-logs-1234
    Classify the logs from a run that already happened.

.NOTES
    Diagnostic only. Runs no deployment and touches no production path. Safe to
    run repeatedly.
#>
[CmdletBinding()]
param(
    [string]$LogDir,
    [string]$TestPath,
    [switch]$StateOnly
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $here

# The exit-2 sites in Invoke-Rollback.ps1, plus the two verification failures
# that reach it through $verifyCode. Matched on a distinctive substring of the
# message each site logs; the line numbers are informational and will drift.
$exitTwoSites = @(
    [PSCustomObject]@{ Site = 'Invoke-Rollback.ps1:208'; Match = 'Backup folder not found'; Cause = '-BackupDir named a folder that does not exist' }
    [PSCustomObject]@{ Site = 'Invoke-Rollback.ps1:228'; Match = 'nothing to roll back to'; Cause = 'no backup for this processor under -BackupRoot' }
    [PSCustomObject]@{ Site = 'Invoke-Rollback.ps1:278'; Match = 'Partial backup:'; Cause = 'backup holds fewer files than its own manifest claims' }
    [PSCustomObject]@{ Site = 'Invoke-Rollback.ps1:341'; Match = 'is already running (lock:'; Cause = 'THE PROGRAMDATA ROLLBACK LOCK WAS ALREADY HELD' }
    [PSCustomObject]@{ Site = 'Invoke-Rollback.ps1:399'; Match = 'Could not quiesce the processor'; Cause = 'target tree could not be made safe to mirror' }
    [PSCustomObject]@{ Site = 'Invoke-Rollback.ps1:404'; Match = 'Restore copy failed'; Cause = 'robocopy failed part-way through the mirror' }
    [PSCustomObject]@{ Site = 'Invoke-Rollback.ps1:453'; Match = 'POST-ROLLBACK VERIFY UNAVAILABLE'; Cause = 'no baseline described the restored release' }
    [PSCustomObject]@{ Site = 'Invoke-Verification.ps1'; Match = 'Verification error:'; Cause = 'THE BASELINE ARCHIVE COULD NOT BE READ (git tag / repo)' }
    [PSCustomObject]@{ Site = 'Invoke-Verification.ps1:275'; Match = 'Manifest self-hash mismatch'; Cause = 'archived baseline is corrupt or was tampered with' }
    [PSCustomObject]@{ Site = 'Invoke-Verification.ps1:311'; Match = 'No anchor:'; Cause = 'verification refused to report on an unanchored tree' }
)

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ('== {0} {1}' -f $Title, ('=' * [Math]::Max(0, 74 - $Title.Length))) -ForegroundColor Cyan
}

function Show-MachineState {
    <#
    .SYNOPSIS What this box carries that a fresh CI runner would not.
    #>
    Write-Section 'Machine state a clean runner would not have'

    # The rollback lock is the only machine-global path the suite touches that
    # sits outside Pester's TestDrive. A file left here by an interrupted run
    # makes every restore-mode test exit 2 until someone deletes it.
    $lockDir = if ($env:ProgramData) { Join-Path $env:ProgramData 'ves-verify' } else { $null }
    if (-not $lockDir) {
        Write-Host '  ProgramData is not set; Invoke-Rollback would fail building its lock path.' -ForegroundColor Yellow
    }
    elseif (-not (Test-Path -LiteralPath $lockDir)) {
        Write-Host ('  {0} does not exist -- no stale lock possible.' -f $lockDir) -ForegroundColor Green
    }
    else {
        $locks = @(Get-ChildItem -LiteralPath $lockDir -Filter '*.rollback.lock' -File -ErrorAction SilentlyContinue)
        if ($locks.Count -eq 0) {
            Write-Host ('  {0} exists, no *.rollback.lock in it.' -f $lockDir) -ForegroundColor Green
        }
        else {
            Write-Host ('  STALE LOCK(S) in {0}:' -f $lockDir) -ForegroundColor Red
            foreach ($l in $locks) {
                Write-Host ('    {0}  written {1:u}  {2} bytes' -f $l.Name, $l.LastWriteTimeUtc, $l.Length) -ForegroundColor Red
            }
            Write-Host '    Delete these and re-run: nothing in the suite ever removes one.' -ForegroundColor Red
        }
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $lockDir 'logs') -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
        if ($logs.Count -gt 0) {
            Write-Host ('  {0} audit log(s) under {1}\logs -- tests wrote to ProgramData at some point.' -f $logs.Count, $lockDir) -ForegroundColor Yellow
        }
    }

    # A leaked VES_AUDIT_LOG_DIR sends this run's evidence somewhere unexpected.
    if ($env:VES_AUDIT_LOG_DIR) {
        Write-Host ('  VES_AUDIT_LOG_DIR is already set: {0}' -f $env:VES_AUDIT_LOG_DIR) -ForegroundColor Yellow
        Write-Host '    Invoke-Tests.ps1 restores this in a finally, so a set value means a run was interrupted.' -ForegroundColor Yellow
    }
    else {
        Write-Host '  VES_AUDIT_LOG_DIR is not set (expected outside a suite run).' -ForegroundColor Green
    }

    $leftovers = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'ves-verify-test-logs-*' -Directory -ErrorAction SilentlyContinue)
    Write-Host ('  {0} leftover ves-verify-test-logs-* dir(s) in temp.' -f $leftovers.Count)

    # The baseline-archive fixture is a real git repo, and _helpers.ps1 records
    # two flakes already traced to git timing in it. Version and the two settings
    # that fixture disables are worth having in the report.
    try {
        $gitVersion = (& git --version 2>&1 | Out-String).Trim()
        Write-Host ('  git: {0}' -f $gitVersion)
        foreach ($key in @('gc.auto', 'maintenance.auto', 'core.fscache')) {
            $val = (& git config --global --get $key 2>&1 | Out-String).Trim()
            if (-not $val) { $val = '(unset)' }
            Write-Host ('    global {0} = {1}' -f $key, $val)
        }
    }
    catch {
        Write-Host ('  git not usable: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }

    Write-Host ('  host: {0} / PowerShell {1}' -f $env:COMPUTERNAME, $PSVersionTable.PSVersion)
}

function Read-RollbackRunLog {
    <#
    .SYNOPSIS Summarise one rollback JSONL: which case, what exit, which error.
    .DESCRIPTION
      Everything here comes out of the log itself. The case name is the parent of
      the target directory the run recorded, which is how New-Case builds it
      (<TestDrive>\rb\<case>\target), so no test metadata has to be duplicated.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $records = @()
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records += ($line | ConvertFrom-Json) } catch { }
    }
    if ($records.Count -eq 0) { return $null }

    $case = '(unknown)'
    $target = $null
    $backupDir = $null
    $exitCode = $null
    $anchored = $false
    $listMode = $true
    $verifySource = $null
    $errors = @()

    foreach ($r in $records) {
        if ($r.PSObject.Properties['target'] -and $r.target) { $target = $r.target; $listMode = $false }
        if ($r.PSObject.Properties['backupDir'] -and $r.backupDir) { $backupDir = $r.backupDir }
        if ($r.PSObject.Properties['exitCode'] -and $null -ne $r.exitCode) { $exitCode = [int]$r.exitCode }
        if ($r.PSObject.Properties['anchored'] -and $r.anchored) { $anchored = $true }
        if ($r.PSObject.Properties['verifySource'] -and $r.verifySource) { $verifySource = $r.verifySource }
        if ($r.level -eq 'ERROR' -and $r.msg -notlike 'RUN END*') { $errors += $r.msg }
    }
    # Split on either separator rather than through Split-Path: these are strings
    # out of a log, not necessarily paths this host can resolve.
    if ($target) {
        $parts = @($target -split '[\\/]+' | Where-Object { $_ })
        if ($parts.Count -ge 2) { $case = $parts[$parts.Count - 2] }
    }
    elseif ($backupDir) {
        # -ListBackups passes no -TargetRoot, so fall back to the backup path,
        # which New-Case builds under the same per-case directory.
        $parts = @($backupDir -split '[\\/]+' | Where-Object { $_ })
        if ($parts.Count -ge 2) { $case = $parts[$parts.Count - 2] }
    }
    if ($listMode) { $case = '{0} [ListBackups]' -f $case }

    [PSCustomObject]@{
        File         = Split-Path -Leaf $Path
        Case         = $case
        ExitCode     = $exitCode
        Anchored     = $anchored
        ListMode     = $listMode
        VerifySource = $verifySource
        Errors       = $errors
    }
}

function Get-ExitCause {
    <#
    .SYNOPSIS Map a run's error messages to the source site that produced them.
    #>
    param([string[]]$Message)
    foreach ($m in $Message) {
        foreach ($site in $exitTwoSites) {
            if ($m -like ('*' + $site.Match + '*')) { return $site }
        }
    }
    return $null
}

# --- Machine state ------------------------------------------------------------
Show-MachineState
if ($StateOnly) { return }

# --- Get a set of logs to classify -------------------------------------------
$pesterFailed = $null
if ($LogDir) {
    if (-not (Test-Path -LiteralPath $LogDir)) { throw "LogDir not found: $LogDir" }
    Write-Section 'Classifying an existing log directory'
    Write-Host ('  {0}' -f $LogDir)
}
else {
    if (-not $TestPath) { $TestPath = Join-Path $here 'Invoke-Rollback.Tests.ps1' }
    if (-not (Test-Path -LiteralPath $TestPath)) { throw "Test file not found: $TestPath" }

    $p5 = Get-Module -ListAvailable Pester |
        Where-Object { $_.Version -ge [version]'5.0.0' -and $_.Version -lt [version]'6.0.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $p5) { throw 'Pester 5.x not found. See Invoke-Tests.ps1 for the install command.' }
    Import-Module $p5.Path -Force

    # Our own log dir rather than the one Invoke-Tests.ps1 derives from its PID,
    # so the runs this report reads are unambiguously the ones it just started.
    $LogDir = Join-Path ([IO.Path]::GetTempPath()) ('ves-rollback-diag-{0}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

    Write-Section 'Running the rollback suite'
    Write-Host ('  tests:   {0}' -f $TestPath)
    Write-Host ('  logs:    {0}' -f $LogDir)
    Write-Host ('  Pester:  {0}' -f $p5.Version)

    $cfg = New-PesterConfiguration
    $cfg.Run.Path = $TestPath
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'

    $previous = $env:VES_AUDIT_LOG_DIR
    $env:VES_AUDIT_LOG_DIR = $LogDir
    try { $result = Invoke-Pester -Configuration $cfg }
    finally { $env:VES_AUDIT_LOG_DIR = $previous }

    Write-Host ('  result:  {0} passed, {1} failed of {2}' -f $result.PassedCount, $result.FailedCount, $result.TotalCount) `
        -ForegroundColor $(if ($result.FailedCount -eq 0) { 'Green' } else { 'Red' })

    $pesterFailed = @($result.Tests | Where-Object { $_.Result -eq 'Failed' })
    if ($pesterFailed.Count -gt 0) {
        Write-Section 'Tests Pester reported as failed'
        foreach ($t in $pesterFailed) {
            Write-Host ('  [-] {0}' -f $t.Name) -ForegroundColor Red
            $msg = ($t.ErrorRecord | Select-Object -First 1 | ForEach-Object { "$_" })
            if ($msg) { Write-Host ('      {0}' -f ($msg -split "`r?`n")[0]) -ForegroundColor DarkGray }
        }
    }
}

# --- Classify every rollback run ---------------------------------------------
$logFiles = @(Get-ChildItem -LiteralPath $LogDir -Filter 'rollback-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
if ($logFiles.Count -eq 0) {
    Write-Host ''
    Write-Host 'No rollback-*.jsonl logs in that directory. Invoke-Rollback logs by default, so' -ForegroundColor Yellow
    Write-Host 'an empty directory means the suite never reached the script -- check BeforeAll.' -ForegroundColor Yellow
    return
}

$runs = @()
foreach ($f in $logFiles) {
    $summary = Read-RollbackRunLog -Path $f.FullName
    if ($summary) { $runs += $summary }
}

Write-Section ('Every rollback run in this log dir ({0})' -f $runs.Count)
Write-Host ('  {0,-24} {1,4}  {2,-8} {3}' -f 'CASE', 'EXIT', 'ANCHORED', 'CAUSE')
Write-Host ('  {0,-24} {1,4}  {2,-8} {3}' -f ('-'*24), '----', '--------', ('-'*40))
foreach ($run in $runs) {
    $cause = Get-ExitCause -Message $run.Errors
    $causeText = if ($cause) { $cause.Cause } elseif ($run.ExitCode -eq 0) { '' } else { '(no ERROR logged)' }
    $colour = if ($run.ExitCode -eq 0) { 'Gray' } elseif ($run.ExitCode -eq 2) { 'Red' } else { 'Yellow' }
    Write-Host ('  {0,-24} {1,4}  {2,-8} {3}' -f $run.Case, $run.ExitCode, $run.Anchored, $causeText) -ForegroundColor $colour
}

# --- Verdict ------------------------------------------------------------------
Write-Section 'Verdict'

# Several rollback cases are supposed to exit 2 -- refusing a partial backup and
# refusing to mirror over a live instance both do. So say up front whether any
# test actually failed, or this reads as an alarm when the suite was green.
if ($null -ne $pesterFailed) {
    if ($pesterFailed.Count -eq 0) {
        Write-Host '  Every test passed. Any exit 2 below is a case that expects it.' -ForegroundColor Green
    }
    else {
        Write-Host ('  {0} test(s) failed. Causes below are what the script logged for each run.' -f $pesterFailed.Count) -ForegroundColor Red
    }
}
else {
    Write-Host '  No Pester result in this mode, so which exits were expected is not known here.' -ForegroundColor DarkGray
}

$exitTwo = @($runs | Where-Object { $_.ExitCode -eq 2 })
if ($exitTwo.Count -eq 0) {
    Write-Host '  No run exited 2. Whatever was reported before is not reproducing now.' -ForegroundColor Green
    return
}

$byCause = @{}
foreach ($run in $exitTwo) {
    $cause = Get-ExitCause -Message $run.Errors
    $key = if ($cause) { '{0}  --  {1}' -f $cause.Site, $cause.Cause } else { 'unclassified (no matching ERROR line)' }
    if (-not $byCause.ContainsKey($key)) { $byCause[$key] = @() }
    $byCause[$key] += $run.Case
}

Write-Host ('  {0} run(s) exited 2, from these sites:' -f $exitTwo.Count)
foreach ($key in ($byCause.Keys | Sort-Object)) {
    Write-Host ('    {0}' -f $key) -ForegroundColor Red
    Write-Host ('      cases: {0}' -f (($byCause[$key] | Sort-Object -Unique) -join ', ')) -ForegroundColor DarkGray
}

# The two hypotheses worth separating, answered from the logs rather than guessed.
$lockRuns = @($exitTwo | Where-Object {
        $c = Get-ExitCause -Message $_.Errors
        $c -and $c.Match -eq 'is already running (lock:'
    })
$anchoredRuns = @($exitTwo | Where-Object { $_.Anchored })

Write-Host ''
if ($lockRuns.Count -gt 0) {
    Write-Host ('  THE LOCK DID FIRE, in {0} run(s): {1}' -f $lockRuns.Count, (($lockRuns | ForEach-Object { $_.Case }) -join ', ')) -ForegroundColor Red
    Write-Host '  Check the machine-state section above for a stale lock file, then make the' -ForegroundColor Red
    Write-Host '  lock path honour VES_AUDIT_LOG_DIR the way Write-VesLog already does.' -ForegroundColor Red
}
else {
    Write-Host '  The lock never fired: no run logged the refusal message. Do not refactor it' -ForegroundColor Green
    Write-Host '  on the strength of an exit code -- six sites in this script return 2.' -ForegroundColor Green
}

# -ListBackups returns before the lock is ever opened, so a failing list-mode run
# rules the lock out on structure alone, whatever the logs happen to say.
$listExitTwo = @($exitTwo | Where-Object { $_.ListMode })
if ($listExitTwo.Count -gt 0) {
    Write-Host ('  A -ListBackups run exited 2 ({0}). List mode returns before the lock is' -f (($listExitTwo | ForEach-Object { $_.Case }) -join ', ')) -ForegroundColor Yellow
    Write-Host '  opened, so the lock cannot be the cause of this failure set.' -ForegroundColor Yellow
}

if ($anchoredRuns.Count -eq $exitTwo.Count -and $exitTwo.Count -gt 0) {
    Write-Host ''
    Write-Host '  EVERY exit-2 run used the shared Git baseline archive (anchored=True).' -ForegroundColor Yellow
    Write-Host '  That points at the New-VesBaselineArchive fixture, not at the rollback script.' -ForegroundColor Yellow
    Write-Host '  _helpers.ps1 already documents two flakes traced to git timing in it.' -ForegroundColor Yellow
}
elseif ($anchoredRuns.Count -gt 0) {
    Write-Host ''
    Write-Host ('  {0} of {1} exit-2 runs used the shared Git baseline archive.' -f $anchoredRuns.Count, $exitTwo.Count) -ForegroundColor Yellow
}

Write-Host ''
Write-Host ('  Full logs kept at: {0}' -f $LogDir)
