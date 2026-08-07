#Requires -Version 5.1
# Test-DriftHeartbeat.ps1: missing / bad schema / stale / fresh heartbeat → exit contract.
# Runs as a child powershell.exe via Invoke-VesScript (the script calls exit).

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:Root = Join-Path $TestDrive 'hb'
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null

    function script:New-Heartbeat([string]$Path, [datetime]$CompletedUtc, [string]$Schema = 'ves.drift-heartbeat.v1') {
        $doc = [ordered]@{
            schema       = $Schema
            completedUtc = $CompletedUtc.ToUniversalTime().ToString('o')
            outcome      = 'PASS'
            exitCode     = 0
        }
        ($doc | ConvertTo-Json -Compress) | Out-File -FilePath $Path -Encoding utf8
        $Path
    }
}

Describe 'Test-DriftHeartbeat' {
    It 'exits 10 when -MaxAgeMinutes is not positive' {
        $hb = Join-Path $script:Root 'unused.json'
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb, '-MaxAgeMinutes', '0')
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'MaxAgeMinutes'
    }

    It 'exits 2 when the heartbeat file is missing' {
        $missing = Join-Path $script:Root 'does-not-exist.json'
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $missing, '-MaxAgeMinutes', '75')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'MISSED DRIFT RUN|Heartbeat not found'
    }

    It 'exits 2 when the heartbeat schema is wrong' {
        $hb = Join-Path $script:Root 'bad-schema.json'
        New-Heartbeat $hb ([datetime]::UtcNow) -Schema 'not.a.heartbeat'
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb, '-MaxAgeMinutes', '75')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'schema'
    }

    It 'exits 2 when the heartbeat is stale' {
        $hb = Join-Path $script:Root 'stale.json'
        New-Heartbeat $hb ([datetime]::UtcNow.AddMinutes(-120))
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb, '-MaxAgeMinutes', '75')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'stale'
    }

    It 'exits 0 when the heartbeat is fresh' {
        $hb = Join-Path $script:Root 'fresh.json'
        New-Heartbeat $hb ([datetime]::UtcNow.AddMinutes(-5))
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb, '-MaxAgeMinutes', '75')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Heartbeat fresh|outcome=PASS'
    }
}
