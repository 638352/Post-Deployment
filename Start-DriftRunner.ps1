#Requires -Version 5.1
<#
.DESCRIPTION
    Reads a JSON targets file, runs Invoke-Verification -Mode All per target, and
    writes a per-target JSONL result under -LogDir. Drift showing up between
    deploy events is the unauthorized-change signal.

    The exit code and the JSONL logs ARE the signal: point your monitoring at the
    logs (or read Task Scheduler's Last Run Result). Each run writes a timestamped
    log per target, so a missing or stale run log means the scheduled task died.

    Exit is the worst per-target code: 0 clean, 1 drift somewhere, 2 trust
    failure somewhere.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetsFile,
    [string]$Region = 'us-gov-west-1',
    # keep this out of Git, the logs contain prod hostnames and paths
    [string]$LogDir = 'D:\ves-verify\logs'
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$verify = Join-Path $PSScriptRoot 'Invoke-Verification.ps1'

# load the target list and ensure the log dir exists; one run stamp groups this run's logs
if (-not (Test-Path $TargetsFile)) { throw "Targets file not found: $TargetsFile" }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$targets = Get-Content $TargetsFile -Raw | ConvertFrom-Json
$runStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')

# verify every target, tracking the worst exit code seen across all of them
$worst = $VES_EXIT_OK
# run-level counters + affected-processor lists feed the Datadog summary below
$targetCount    = @($targets).Count
$driftedNames   = New-Object System.Collections.Generic.List[string]
$trustFailNames = New-Object System.Collections.Generic.List[string]
foreach ($t in $targets) {
    # one JSONL log per target per run; a missing/stale file later means the task died
    $log  = Join-Path $LogDir ("{0}_{1}.jsonl" -f $t.processor, $runStamp)
    Write-VesLog INFO "Drift check: $($t.processor)" -LogFile $log

    # run a full files+config verify for this target ($params, not $args:
    # $args is a reserved automatic variable and reusing it invites refactor bugs)
    $params = @{
        Mode = 'All'; ReleaseRoot = $t.releaseRoot; ManifestPath = $t.manifestPath
        TrustParam = $t.trustParam; ConfigContract = $t.configContract
        ConfigPath = $t.configPath; Processor = $t.processor; Region = $Region
        LogFile = $log; Json = $true
    }
    $raw  = & $verify @params
    $code = $LASTEXITCODE   # grab before anything else runs

    # classify the outcome and raise $worst accordingly (trust failure > drift > clean).
    # Only exit 0 is clean: a usage/param error (10) or any other non-zero code means
    # the target is misconfigured or the check didn't really run -- never report it clean.
    if ($code -eq $VES_EXIT_NOBASE) {
        Write-VesLog ERROR "DRIFT-CHECK TRUST FAIL $($t.processor): baseline missing/tampered during scheduled check." -LogFile $log
        $trustFailNames.Add($t.processor)
        if ($worst -lt $VES_EXIT_NOBASE) { $worst = $VES_EXIT_NOBASE }
    }
    elseif ($code -eq $VES_EXIT_DRIFT) {
        Write-VesLog DRIFT "DRIFT DETECTED $($t.processor): prod diverged from baseline (no deploy expected)." -LogFile $log
        $driftedNames.Add($t.processor)
        if ($worst -lt $VES_EXIT_DRIFT) { $worst = $VES_EXIT_DRIFT }
    }
    elseif ($code -eq $VES_EXIT_OK) {
        Write-VesLog OK "Clean: $($t.processor)" -LogFile $log
    }
    else {
        # exit 10 (usage) or anything unexpected: the check couldn't be trusted to run.
        # Surface it as at least a trust failure so monitoring doesn't read it as clean.
        Write-VesLog ERROR "DRIFT-CHECK ERROR $($t.processor): verify exited $code (misconfigured target?); treating as not-clean." -LogFile $log
        if ($worst -lt $VES_EXIT_NOBASE) { $worst = $VES_EXIT_NOBASE }
    }
}

# --- Datadog: scheduled drift-run summary (non-fatal) -----------------------
# Per-target verify gauges already come from Invoke-Verification; here we emit
# the run-level rollup so a scheduled drift sweep is visible/alertable on its own.
# Tags stay low-cardinality: no per-target tags on the run rollup.
$ddTags = @((Get-VesDatadogEnvTag), 'check:drift')
Send-VesDatadogMetric -Metric 'deployment.drift.run.targets'   -Value $targetCount            -Tags $ddTags
Send-VesDatadogMetric -Metric 'deployment.drift.run.drift'     -Value $driftedNames.Count     -Tags $ddTags
Send-VesDatadogMetric -Metric 'deployment.drift.run.trustfail' -Value $trustFailNames.Count   -Tags $ddTags

# Only raise an event when something needs attention -- a clean scheduled sweep
# runs often and shouldn't spam the event stream. Trust failure outranks drift.
if ($trustFailNames.Count -or $driftedNames.Count) {
    $alertType = if ($trustFailNames.Count) { 'error' } else { 'warning' }
    $lines = @()
    if ($trustFailNames.Count) { $lines += "Trust failures: $($trustFailNames -join ', ')" }
    if ($driftedNames.Count)   { $lines += "Drift: $($driftedNames -join ', ')" }
    Send-VesDatadogEvent -Title "Drift sweep flagged $($trustFailNames.Count + $driftedNames.Count)/$targetCount target(s)" `
        -Text ($lines -join "`n") -AlertType $alertType -Tags $ddTags
}

# exit with the worst code so the scheduled task's Last Run Result reflects any drift/trust failure
Write-VesLog INFO "Drift run complete. worst=$worst"
exit $worst
