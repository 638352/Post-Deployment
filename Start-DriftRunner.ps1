#Requires -Version 5.1
<#
.SYNOPSIS
    Scheduled drift detection across all configured systems. Run from Task
    Scheduler on a fixed cadence.
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

if (-not (Test-Path $TargetsFile)) { throw "Targets file not found: $TargetsFile" }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$targets = Get-Content $TargetsFile -Raw | ConvertFrom-Json
$runStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')

$worst = $VES_EXIT_OK
foreach ($t in $targets) {
    $log  = Join-Path $LogDir ("{0}_{1}.jsonl" -f $t.processor, $runStamp)
    Write-VesLog INFO "Drift check: $($t.processor)" -LogFile $log

    $args = @{
        Mode = 'All'; ReleaseRoot = $t.releaseRoot; ManifestPath = $t.manifestPath
        TrustParam = $t.trustParam; ConfigContract = $t.configContract
        ConfigPath = $t.configPath; Processor = $t.processor; Region = $Region
        LogFile = $log; Json = $true
    }
    $raw  = & $verify @args
    $code = $LASTEXITCODE   # grab before anything else runs

    if ($code -eq $VES_EXIT_NOBASE) {
        Write-VesLog ERROR "DRIFT-CHECK TRUST FAIL $($t.processor): baseline missing/tampered during scheduled check." -LogFile $log
        if ($worst -lt $VES_EXIT_NOBASE) { $worst = $VES_EXIT_NOBASE }
    }
    elseif ($code -eq $VES_EXIT_DRIFT) {
        Write-VesLog DRIFT "DRIFT DETECTED $($t.processor): prod diverged from baseline (no deploy expected)." -LogFile $log
        if ($worst -lt $VES_EXIT_DRIFT) { $worst = $VES_EXIT_DRIFT }
    }
    else {
        Write-VesLog OK "Clean: $($t.processor)" -LogFile $log
    }
}

Write-VesLog INFO "Drift run complete. worst=$worst"
exit $worst
