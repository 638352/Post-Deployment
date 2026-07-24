[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetsFile,
    [string]$Region = 'us-gov-west-1',
    # keep this out of Git, the logs contain prod hostnames and paths
    [string]$LogDir = 'D:\ves-verify\logs',
    # prune drift JSONL logs older than this many days (deploy audit logs are
    # written by other scripts and never pruned here)
    [int]$LogRetentionDays = 365,
    # environment tag for Datadog emits
    [string]$Environment = 'prod'
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$verify = Join-Path $PSScriptRoot 'Invoke-Verification.ps1'

# load the target list and ensure the log dir exists; one run stamp groups this run's logs
if (-not (Test-Path $TargetsFile)) { throw "Targets file not found: $TargetsFile" }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$targets = Get-Content $TargetsFile -Raw | ConvertFrom-Json
# one timestamp for the whole pass so all the logs line up
$runStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')

# verify every target, tracking the worst exit code seen across all of them
$worst = $VES_EXIT_OK
$envTag = Get-VesDatadogEnvTag -Environment $Environment
$drifted = 0; $trustFailed = 0
$flagged = New-Object System.Collections.Generic.List[string]
# check every target even if an earlier one drifted
foreach ($t in $targets) {
    # one JSONL log per target per run; a missing/stale file later means the task died
    $log  = Join-Path $LogDir ("{0}_{1}.jsonl" -f $t.processor, $runStamp)
    Write-VesLog INFO "Drift check: $($t.processor)" -LogFile $log

    # run a full files+config verify for this target; a config-less target
    # verifies files only ('All' hard-requires the config params, mirroring
    # the same guard in Deploy-Processor)
    $hasConfig = ($t.PSObject.Properties['configContract'] -and $t.configContract)
    $args = @{
        Mode = $(if ($hasConfig) { 'All' } else { 'VerifyFiles' })
        ReleaseRoot = $t.releaseRoot; ManifestPath = $t.manifestPath
        TrustParam = $t.trustParam; Processor = $t.processor; Region = $Region
        LogFile = $log; Json = $true
    }
    if ($hasConfig) { $args.ConfigContract = $t.configContract; $args.ConfigPath = $t.configPath }
    $raw  = & $verify @args
    # grab this immediately, anything else overwrites it
    $code = $LASTEXITCODE   # grab before anything else runs

    # classify the outcome and raise $worst accordingly (trust failure > drift > clean)
    if ($code -eq $VES_EXIT_NOBASE) {
        Write-VesLog ERROR "DRIFT-CHECK TRUST FAIL $($t.processor): baseline missing/tampered during scheduled check." -LogFile $log
        if ($worst -lt $VES_EXIT_NOBASE) { $worst = $VES_EXIT_NOBASE }
        $trustFailed++; $flagged.Add("$($t.processor):trust-fail")
    }
    elseif ($code -eq $VES_EXIT_DRIFT) {
        Write-VesLog DRIFT "DRIFT DETECTED $($t.processor): prod diverged from baseline (no deploy expected)." -LogFile $log
        if ($worst -lt $VES_EXIT_DRIFT) { $worst = $VES_EXIT_DRIFT }
        $drifted++; $flagged.Add("$($t.processor):drift")
    }
    elseif ($code -ne $VES_EXIT_OK) {
        # usage/unknown exit: the check itself did not run, which must never
        # read as "no drift" -- escalate as a trust-level failure
        Write-VesLog ERROR "DRIFT-CHECK ERROR $($t.processor): verify exited $code (check did not complete)." -LogFile $log
        if ($worst -lt $VES_EXIT_NOBASE) { $worst = $VES_EXIT_NOBASE }
        $trustFailed++; $flagged.Add("$($t.processor):check-error")
    }
    else {
        Write-VesLog OK "Clean: $($t.processor)" -LogFile $log
    }
    # per-system gauge: 1 = still matches the approved baseline, 0 = drift or trust failure
    Send-VesDatadogMetric -Metric 'deployment.drift.status' -Value ($(if ($code -eq $VES_EXIT_OK) { 1 } else { 0 })) `
        -Tags @("processor:$($t.processor)", $envTag)
}

# run-level rollup gauges plus a heartbeat every pass. The heartbeat matters
# because a scheduled task that quietly dies produces no log entries, which
# looks the same as "no drift" -- Datadog alerts when this stops arriving.
Send-VesDatadogMetric -Metric 'deployment.drift.targets'      -Value @($targets).Count -Tags @($envTag)
Send-VesDatadogMetric -Metric 'deployment.drift.drifted'      -Value $drifted          -Tags @($envTag)
Send-VesDatadogMetric -Metric 'deployment.drift.trust_failed' -Value $trustFailed      -Tags @($envTag)
Send-VesDatadogMetric -Metric 'deployment.drift.heartbeat'    -Value 1                 -Tags @($envTag)

# one event only when a sweep flags something; clean sweeps stay off the event stream
if ($flagged.Count -gt 0) {
    Send-VesDatadogEvent -Title "Drift sweep flagged $($flagged.Count) system(s) on $env:COMPUTERNAME" `
        -Text ($flagged -join ', ') -AlertType (Get-VesAlertType -Environment $Environment) `
        -Tags @($envTag, 'event:drift-sweep')
}

# atomic heartbeat file for Test-DriftHeartbeat.ps1: write to a temp file, then
# rename into place so a reader never sees a half-written JSON document
try {
    $hbPath = Join-Path $LogDir 'ves-verify-drift.heartbeat.json'
    $hbTmp  = "$hbPath.tmp"
    $hb = [ordered]@{
        schema       = 'ves.drift-heartbeat.v1'
        completedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        outcome      = $(if ($worst -eq $VES_EXIT_OK) { 'PASS' } elseif ($worst -eq $VES_EXIT_DRIFT) { 'DRIFT' } else { 'TRUST-FAIL' })
        exitCode     = $worst
        targets      = @($targets).Count
        host         = $env:COMPUTERNAME
    } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($hbTmp, $hb, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $hbTmp -Destination $hbPath -Force
} catch {
    Write-Warning "Heartbeat write failed (non-fatal): $($_.Exception.Message)"
}

# retention: prune this runner's JSONL logs past the cutoff; heartbeat and
# anything another script wrote are left alone
if ($LogRetentionDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    Get-ChildItem -LiteralPath $LogDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# exit with the worst code so the scheduled task's Last Run Result reflects any drift/trust failure
Write-VesLog INFO "Drift run complete. worst=$worst"
# worst code wins, that is what task scheduler records
exit $worst
