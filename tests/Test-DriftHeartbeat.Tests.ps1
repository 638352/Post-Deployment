#Requires -Version 5.1
# Test-DriftHeartbeat.ps1 end-to-end checks against fixture heartbeat files.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    function script:New-HeartbeatFile {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][DateTimeOffset]$CompletedUtc,
            [string]$Outcome = 'PASS',
            [int]$ExitCode = 0
        )
        $doc = [ordered]@{
            schema       = 'ves.drift-heartbeat.v1'
            completedUtc = $CompletedUtc.ToString('o')
            outcome      = $Outcome
            exitCode     = $ExitCode
        }
        ($doc | ConvertTo-Json -Depth 4) | Out-File -FilePath $Path -Encoding utf8
        $Path
    }
}

Describe 'heartbeat freshness contract' {
    It 'exits 0 and reports fresh heartbeat json when within max age' {
        $hb = Join-Path $TestDrive 'fresh-heartbeat.json'
        New-HeartbeatFile -Path $hb -CompletedUtc ([DateTimeOffset]::UtcNow.AddMinutes(-5)) | Out-Null
        $log = Join-Path $TestDrive 'fresh-watchdog.jsonl'

        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb,
            '-MaxAgeMinutes', '30',
            '-Environment', 'uat',
            '-LogFile', $log,
            '-Json')

        $r.ExitCode | Should -Be 0
        $r.Json | Should -Not -BeNullOrEmpty
        $r.Json.fresh | Should -BeTrue
        $r.Json.heartbeat.schema | Should -Be 'ves.drift-heartbeat.v1'
        Test-Path -LiteralPath $log | Should -BeTrue
    }

    It 'tolerates small clock skew (heartbeat up to 5 minutes in the future)' {
        $hb = Join-Path $TestDrive 'skew-heartbeat.json'
        New-HeartbeatFile -Path $hb -CompletedUtc ([DateTimeOffset]::UtcNow.AddMinutes(3)) | Out-Null

        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb,
            '-MaxAgeMinutes', '30',
            '-LogFile', (Join-Path $TestDrive 'skew-watchdog.jsonl'),
            '-Json')

        $r.ExitCode | Should -Be 0
        $r.Json.fresh | Should -BeTrue
    }

    It 'exits 2 on stale heartbeat' {
        $hb = Join-Path $TestDrive 'stale-heartbeat.json'
        New-HeartbeatFile -Path $hb -CompletedUtc ([DateTimeOffset]::UtcNow.AddMinutes(-120)) | Out-Null

        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb,
            '-MaxAgeMinutes', '30',
            '-LogFile', (Join-Path $TestDrive 'stale-watchdog.jsonl'),
            '-Json')

        $r.ExitCode | Should -Be 2
        $r.Json.fresh | Should -BeFalse
        $r.Json.error | Should -Match 'stale'
    }

    It 'exits 2 when heartbeat file is missing' {
        $missing = Join-Path $TestDrive 'missing-heartbeat.json'
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $missing,
            '-MaxAgeMinutes', '30',
            '-LogFile', (Join-Path $TestDrive 'missing-watchdog.jsonl'))

        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Heartbeat not found'
    }

    It 'exits 2 when heartbeat is too far in the future' {
        $hb = Join-Path $TestDrive 'future-heartbeat.json'
        New-HeartbeatFile -Path $hb -CompletedUtc ([DateTimeOffset]::UtcNow.AddMinutes(10)) | Out-Null

        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb,
            '-MaxAgeMinutes', '30',
            '-LogFile', (Join-Path $TestDrive 'future-watchdog.jsonl'))

        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'in the future'
    }

    It 'exits 10 when MaxAgeMinutes is not greater than zero' {
        $hb = Join-Path $TestDrive 'usage-heartbeat.json'
        New-HeartbeatFile -Path $hb -CompletedUtc ([DateTimeOffset]::UtcNow) | Out-Null

        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath', $hb,
            '-MaxAgeMinutes', '0',
            '-LogFile', (Join-Path $TestDrive 'usage-watchdog.jsonl'))

        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'greater than zero'
    }
}
