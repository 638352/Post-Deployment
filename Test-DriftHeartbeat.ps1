#Requires -Version 5.1
<#
.SYNOPSIS
    Independently detects a missed or dead scheduled drift run.
.DESCRIPTION
    Reads the atomic heartbeat written by Start-DriftRunner.ps1. A missing,
    unreadable, future-dated, or stale heartbeat is an ERROR (exit 2), writes
    structured evidence, and emits a Datadog event. Production uses error
    severity; lower environments use warning severity.

    Schedule this as a separate task so it can report when the drift task itself
    never starts or hangs before completion.
#>
[CmdletBinding()]
param(
    [string]$HeartbeatPath = 'D:\ves-verify\logs\ves-verify-drift.heartbeat.json',
    [int]$MaxAgeMinutes = 75,
    [string]$Environment = 'prod',
    [string]$LogFile,
    [switch]$Json
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
if (-not $LogFile) { $LogFile = New-VesLogFile -Prefix 'drift-heartbeat-watchdog' }
$runId = [guid]::NewGuid().ToString()
Write-VesLog INFO 'RUN START: drift heartbeat watchdog' `
    -Data @{runId=$runId; script='Test-DriftHeartbeat.ps1'; environment=$Environment; heartbeat=$HeartbeatPath} `
    -LogFile $LogFile

if ($MaxAgeMinutes -le 0) {
    Write-VesLog ERROR '-MaxAgeMinutes must be greater than zero.' `
        -Data @{runId=$runId; outcome='ERROR'; exitCode=$VES_EXIT_USAGE} -LogFile $LogFile
    exit $VES_EXIT_USAGE
}

$fresh = $false
$ageMinutes = $null
$detail = $null
$heartbeat = $null
try {
    if (-not (Test-Path -LiteralPath $HeartbeatPath)) {
        throw "Heartbeat not found: $HeartbeatPath"
    }
    $heartbeat = Get-Content -LiteralPath $HeartbeatPath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $heartbeat.PSObject.Properties['schema'] -or $heartbeat.schema -ne 'ves.drift-heartbeat.v1') {
        throw "Heartbeat schema is missing or unsupported: $($heartbeat.schema)"
    }
    if (-not $heartbeat.PSObject.Properties['completedUtc'] -or [string]::IsNullOrWhiteSpace("$($heartbeat.completedUtc)")) {
        throw 'Heartbeat has no completedUtc value.'
    }
    $completed = [DateTimeOffset]::Parse(
        "$($heartbeat.completedUtc)",
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
    $ageMinutes = [math]::Round(([DateTimeOffset]::UtcNow - $completed.ToUniversalTime()).TotalMinutes, 2)
    if ($ageMinutes -lt -5) {
        throw "Heartbeat completion time is in the future by $([math]::Abs($ageMinutes)) minutes."
    }
    if ($ageMinutes -gt $MaxAgeMinutes) {
        throw "Heartbeat is stale: $ageMinutes minutes old (maximum $MaxAgeMinutes)."
    }
    $fresh = $true
    $detail = "Heartbeat fresh: $ageMinutes minutes old; last outcome=$($heartbeat.outcome), exit=$($heartbeat.exitCode)."
}
catch {
    $detail = $_.Exception.Message
}

$tags = @((Get-VesDatadogEnvTag -Environment $Environment), 'check:drift-heartbeat')
Send-VesDatadogMetric -Metric 'deployment.drift.heartbeat.status' -Value ([int]$fresh) -Tags $tags
if ($null -ne $ageMinutes) {
    Send-VesDatadogMetric -Metric 'deployment.drift.heartbeat.age_minutes' -Value $ageMinutes -Tags $tags
}

if ($fresh) {
    Write-VesLog OK $detail -Data @{runId=$runId; outcome='PASS'; exitCode=0; ageMinutes=$ageMinutes} -LogFile $LogFile
    if ($Json) {
        [PSCustomObject]@{runId=$runId; fresh=$true; ageMinutes=$ageMinutes; heartbeat=$heartbeat} |
            ConvertTo-Json -Depth 6 -Compress
    }
    Write-VesLog OK 'RUN END: drift heartbeat watchdog outcome=PASS exit=0' `
        -Data @{runId=$runId; outcome='PASS'; exitCode=0} -LogFile $LogFile
    exit $VES_EXIT_OK
}

Write-VesLog ERROR "MISSED DRIFT RUN: $detail" `
    -Data @{runId=$runId; outcome='ERROR'; exitCode=$VES_EXIT_NOBASE; ageMinutes=$ageMinutes} -LogFile $LogFile
Send-VesDatadogEvent -Title "Missed scheduled drift verification on $env:COMPUTERNAME" `
    -Text "$detail Heartbeat path: $HeartbeatPath" `
    -AlertType (Get-VesAlertType -Environment $Environment) -Tags ($tags + 'event:missed-run')
if ($Json) {
    [PSCustomObject]@{runId=$runId; fresh=$false; ageMinutes=$ageMinutes; error=$detail} |
        ConvertTo-Json -Compress
}
Write-VesLog ERROR 'RUN END: drift heartbeat watchdog outcome=ERROR exit=2' `
    -Data @{runId=$runId; outcome='ERROR'; exitCode=$VES_EXIT_NOBASE} -LogFile $LogFile
exit $VES_EXIT_NOBASE
