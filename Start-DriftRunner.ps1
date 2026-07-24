#Requires -Version 5.1
<#
.DESCRIPTION
    Validates the confirmed server inventory, then runs a full files+config
    verification for every target. Each target gets a timestamped JSONL log.

    A heartbeat JSON file is atomically updated in finally, even when inventory
    parsing or a target check fails. Test-DriftHeartbeat.ps1 is scheduled
    independently and alerts when that heartbeat is missing/stale, so a dead or
    delayed drift job cannot look like a clean run.

    Exit is the worst outcome: 0 clean, 1 drift, 2 trust/inventory/runtime error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetsFile,
    [string]$Region = 'us-gov-west-1',
    # Set VES_AUDIT_LOG_DIR to a central durable share, or pass -LogDir.
    [string]$LogDir,
    [string]$HeartbeatPath,
    # 365 days by default for ATO/GovCloud audit evidence. 0 disables pruning.
    [int]$LogRetentionDays = 365
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$verify = Join-Path $PSScriptRoot 'Invoke-Verification.ps1'

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    if (-not [string]::IsNullOrWhiteSpace($env:VES_AUDIT_LOG_DIR)) {
        $LogDir = $env:VES_AUDIT_LOG_DIR
    } else {
        $LogDir = 'D:\ves-verify\logs'
    }
}
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
if ([string]::IsNullOrWhiteSpace($HeartbeatPath)) {
    $HeartbeatPath = Join-Path $LogDir 'ves-verify-drift.heartbeat.json'
}

$runId = [guid]::NewGuid().ToString()
$runStamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$runStarted = (Get-Date).ToUniversalTime()
$runLog = Join-Path $LogDir ("drift-run_{0}.jsonl" -f $runStamp)
$worst = $VES_EXIT_NOBASE
$targetCount = 0
$targets = @()
$driftedNames = New-Object System.Collections.Generic.List[string]
$trustFailNames = New-Object System.Collections.Generic.List[string]
$errorNames = New-Object System.Collections.Generic.List[string]

function Write-Heartbeat([int]$ExitCode) {
    $completed = (Get-Date).ToUniversalTime()
    $outcome = Get-VesOutcome -ExitCode $ExitCode
    $doc = [ordered]@{
        schema         = 'ves.drift-heartbeat.v1'
        runId          = $runId
        startedUtc     = $runStarted.ToString('o')
        completedUtc   = $completed.ToString('o')
        durationSeconds= [math]::Round(($completed - $runStarted).TotalSeconds, 3)
        outcome        = $outcome
        exitCode       = $ExitCode
        targetCount    = $targetCount
        driftCount     = $driftedNames.Count
        trustFailCount = $trustFailNames.Count
        errorCount     = $errorNames.Count
        host            = $env:COMPUTERNAME
        targetsFile     = $TargetsFile
    }
    $heartbeatDir = Split-Path -Parent $HeartbeatPath
    if ($heartbeatDir -and -not (Test-Path -LiteralPath $heartbeatDir)) {
        New-Item -ItemType Directory -Path $heartbeatDir -Force | Out-Null
    }
    $tempPath = "$HeartbeatPath.tmp.$([guid]::NewGuid().ToString('N'))"
    try {
        ($doc | ConvertTo-Json -Depth 5) | Out-File -FilePath $tempPath -Encoding utf8
        Move-Item -LiteralPath $tempPath -Destination $HeartbeatPath -Force
    } finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

try {
    Write-VesLog INFO 'RUN START: scheduled drift verification' `
        -Data @{runId=$runId; script='Start-DriftRunner.ps1'; targetsFile=$TargetsFile} -LogFile $runLog

    $inventory = Import-VesTargetInventory -Path $TargetsFile
    foreach ($warning in $inventory.Warnings) {
        Write-VesLog WARN "Inventory warning: $warning" -Data @{runId=$runId} -LogFile $runLog
    }
    if (-not $inventory.Valid) {
        foreach ($problem in $inventory.Errors) {
            Write-VesLog ERROR "Inventory invalid: $problem" -Data @{runId=$runId} -LogFile $runLog
        }
        throw 'Target inventory is incomplete or invalid; no drift target was reported clean.'
    }

    $targets = @($inventory.Targets)
    $targetCount = $targets.Count
    $worst = $VES_EXIT_OK

    foreach ($t in $targets) {
        $log = Join-Path $LogDir ("{0}_{1}.jsonl" -f $t.processor, $runStamp)
        Write-VesLog INFO "Drift check: $($t.processor) on $($t.server)" `
            -Data @{runId=$runId; processor=$t.processor; server=$t.server; environment=$t.environment} -LogFile $log

        $params = @{
            Mode = 'All'
            ReleaseRoot = $t.releaseRoot
            ManifestPath = $t.manifestPath
            TrustParam = $t.trustParam
            ConfigContract = $t.configContract
            ConfigPath = $t.configPath
            Processor = $t.processor
            CommitSha = $t.releaseTag
            Environment = $t.environment
            Region = $Region
            LogFile = $log
            Json = $true
        }
        $null = & $verify @params
        $code = $LASTEXITCODE
        $targetTags = @(
            "processor:$($t.processor)",
            "server:$($t.server)",
            (Get-VesDatadogEnvTag -Environment $t.environment),
            'check:drift'
        )

        if ($code -eq $VES_EXIT_OK) {
            Write-VesLog OK "Clean: $($t.processor)" -Data @{runId=$runId; outcome='PASS'; exitCode=0} -LogFile $log
        }
        elseif ($code -eq $VES_EXIT_DRIFT) {
            $driftedNames.Add($t.processor)
            if ($worst -lt $VES_EXIT_DRIFT) { $worst = $VES_EXIT_DRIFT }
            Write-VesLog DRIFT "DRIFT DETECTED $($t.processor): deployed files/config diverged from baseline." `
                -Data @{runId=$runId; outcome='FAIL'; exitCode=$code} -LogFile $log
            Send-VesDatadogEvent -Title "Drift detected: $($t.processor) on $($t.server)" `
                -Text "The scheduled post-deployment check found drift for $($t.processor) in $($t.environment). See $log." `
                -AlertType (Get-VesAlertType -Environment $t.environment) -Tags ($targetTags + 'event:drift-detected')
        }
        elseif ($code -eq $VES_EXIT_NOBASE) {
            $trustFailNames.Add($t.processor)
            if ($worst -lt $VES_EXIT_NOBASE) { $worst = $VES_EXIT_NOBASE }
            Write-VesLog ERROR "DRIFT-CHECK TRUST FAIL $($t.processor): baseline missing, unreadable, or untrusted." `
                -Data @{runId=$runId; outcome='ERROR'; exitCode=$code} -LogFile $log
            Send-VesDatadogEvent -Title "Verification trust failure: $($t.processor) on $($t.server)" `
                -Text "The scheduled check could not establish a trusted baseline for $($t.processor) in $($t.environment). See $log." `
                -AlertType (Get-VesAlertType -Environment $t.environment) -Tags ($targetTags + 'event:trust-failure')
        }
        else {
            $errorNames.Add($t.processor)
            if ($worst -lt $VES_EXIT_NOBASE) { $worst = $VES_EXIT_NOBASE }
            Write-VesLog ERROR "DRIFT-CHECK ERROR $($t.processor): verify exited $code; treating as unverified." `
                -Data @{runId=$runId; outcome='ERROR'; exitCode=$code} -LogFile $log
            Send-VesDatadogEvent -Title "Verification error: $($t.processor) on $($t.server)" `
                -Text "The scheduled check did not finish reliably for $($t.processor) in $($t.environment) (exit $code). See $log." `
                -AlertType (Get-VesAlertType -Environment $t.environment) -Tags ($targetTags + 'event:verification-error')
        }
    }

    $ddTags = @('check:drift')
    Send-VesDatadogMetric -Metric 'deployment.drift.run.targets'   -Value $targetCount          -Tags $ddTags
    Send-VesDatadogMetric -Metric 'deployment.drift.run.drift'     -Value $driftedNames.Count   -Tags $ddTags
    Send-VesDatadogMetric -Metric 'deployment.drift.run.trustfail' -Value $trustFailNames.Count -Tags $ddTags
    Send-VesDatadogMetric -Metric 'deployment.drift.run.errors'    -Value $errorNames.Count     -Tags $ddTags

    # Prune only this runner's per-target logs. Never touch deploy audit logs,
    # run summaries, heartbeat files, removed-target history, or stray files.
    if ($LogRetentionDays -gt 0 -and $targetCount -gt 0) {
        $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
        $alt = @($targets | ForEach-Object { $_.processor } |
                 Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                 ForEach-Object { [regex]::Escape($_) }) -join '|'
        $ownLog = "^($alt)_\d{8}T\d{6}Z\.jsonl$"
        $stale = @(if ($alt) {
            Get-ChildItem -LiteralPath $LogDir -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $ownLog -and $_.LastWriteTime -lt $cutoff }
        })
        foreach ($file in $stale) {
            try { Remove-Item -LiteralPath $file.FullName -Force }
            catch { Write-VesLog WARN "Could not prune $($file.Name): $($_.Exception.Message)" -LogFile $runLog }
        }
        if ($stale.Count) {
            Write-VesLog INFO "Pruned $($stale.Count) drift log(s) older than $LogRetentionDays day(s)." -LogFile $runLog
        }
    }
}
catch {
    $worst = $VES_EXIT_NOBASE
    Write-VesLog ERROR "Drift run error: $($_.Exception.Message)" `
        -Data @{runId=$runId; outcome='ERROR'; exitCode=$worst} -LogFile $runLog
    Send-VesDatadogEvent -Title 'Scheduled drift verification error' `
        -Text "The drift sweep could not complete on $env:COMPUTERNAME. $($_.Exception.Message)" `
        -AlertType 'error' -Tags @('check:drift','event:runner-error')
}
finally {
    $outcome = Get-VesOutcome -ExitCode $worst
    Write-VesLog ($(if ($outcome -eq 'PASS') {'OK'} elseif ($outcome -eq 'FAIL') {'DRIFT'} else {'ERROR'})) `
        "RUN END: scheduled drift verification outcome=$outcome exit=$worst" `
        -Data @{runId=$runId; outcome=$outcome; exitCode=$worst; targets=$targetCount} -LogFile $runLog
    try {
        Write-Heartbeat -ExitCode $worst
        Send-VesDatadogMetric -Metric 'deployment.drift.heartbeat.completed_unixtime' `
            -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Tags @('check:drift')
        Send-VesDatadogMetric -Metric 'deployment.drift.run.status' `
            -Value ($(if ($worst -eq $VES_EXIT_OK) {1} else {0})) -Tags @('check:drift')
    } catch {
        Write-VesLog ERROR "Could not write drift heartbeat: $($_.Exception.Message)" -LogFile $runLog
        $worst = $VES_EXIT_NOBASE
    }
}

exit $worst
