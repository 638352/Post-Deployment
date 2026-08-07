#Requires -Version 5.1
# Test-DriftHeartbeat.ps1 coverage.
# Exit-code contract: 0 fresh heartbeat, 2 missed/stale/corrupt, 10 usage.
# All cases run the script as a child process so the real exit code is read back.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    # Shared log dir: we want each child run to write its own log, but pointing
    # them all at TestDrive keeps the test node self-contained.
    $script:LogDir = Join-Path $TestDrive 'hb-logs'
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

    # Emit a valid heartbeat file at $Path with completedUtc set to $OffsetMinutes
    # in the past (positive) or future (negative) relative to now.
    function script:New-Heartbeat([string]$Path, [double]$OffsetMinutes = 1,
                                   [string]$Schema = 'ves.drift-heartbeat.v1',
                                   [string]$Outcome = 'clean', [int]$ExitCode = 0) {
        $completed = ([DateTimeOffset]::UtcNow).AddMinutes(-$OffsetMinutes).ToString('o')
        $doc = [ordered]@{
            schema       = $Schema
            completedUtc = $completed
            outcome      = $Outcome
            exitCode     = $ExitCode
        }
        ($doc | ConvertTo-Json -Depth 4) | Out-File -FilePath $Path -Encoding utf8
    }

    function script:New-Args([string]$HeartbeatPath, [int]$MaxAge = 75, [string[]]$Extra = @()) {
        @('-HeartbeatPath', $HeartbeatPath, '-MaxAgeMinutes', $MaxAge,
          '-LogFile', (Join-Path $script:LogDir ('hb-{0}.jsonl' -f [guid]::NewGuid().ToString('N')))) + $Extra
    }
}

Describe 'exit 10: usage' {
    It 'rejects MaxAgeMinutes = 0' {
        $hb = Join-Path $TestDrive 'hb-zero-age.json'
        New-Heartbeat $hb
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb -MaxAge 0)
        $r.ExitCode | Should -Be 10
    }

    It 'rejects a negative MaxAgeMinutes' {
        $hb = Join-Path $TestDrive 'hb-neg-age.json'
        New-Heartbeat $hb
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb -MaxAge -10)
        $r.ExitCode | Should -Be 10
    }
}

Describe 'exit 2: missed or unreadable heartbeat' {
    It 'reports an error when the heartbeat file does not exist' {
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args (Join-Path $TestDrive 'no-such.json'))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Heartbeat not found'
    }

    It 'reports an error when the heartbeat schema is wrong' {
        $hb = Join-Path $TestDrive 'hb-bad-schema.json'
        New-Heartbeat $hb -Schema 'ves.drift-heartbeat.v99'
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'schema'
    }

    It 'reports an error when the heartbeat is stale' {
        $hb = Join-Path $TestDrive 'hb-stale.json'
        New-Heartbeat $hb -OffsetMinutes 120   # 120 minutes old; threshold is 75
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb -MaxAge 75)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'stale'
    }

    It 'reports an error when the heartbeat timestamp is far in the future (clock skew > 5 min)' {
        $hb = Join-Path $TestDrive 'hb-future.json'
        New-Heartbeat $hb -OffsetMinutes -30   # 30 minutes in the future
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'future'
    }

    It 'reports an error when the file is not valid JSON' {
        $hb = Join-Path $TestDrive 'hb-corrupt.json'
        Set-Content -Path $hb -Value 'not { json }' -NoNewline
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb)
        $r.ExitCode | Should -Be 2
    }

    It 'reports an error when completedUtc is absent' {
        $hb = Join-Path $TestDrive 'hb-no-completed.json'
        @{ schema = 'ves.drift-heartbeat.v1'; outcome = 'clean'; exitCode = 0 } |
            ConvertTo-Json | Out-File -FilePath $hb -Encoding utf8
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'completedUtc'
    }
}

Describe 'exit 0: fresh heartbeat' {
    It 'passes when the heartbeat is within the threshold' {
        $hb = Join-Path $TestDrive 'hb-fresh.json'
        New-Heartbeat $hb -OffsetMinutes 1   # 1 minute old; well within any threshold
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb -MaxAge 75)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'PASS'
    }

    It 'allows a small clock skew (heartbeat up to 5 min in the future)' {
        $hb = Join-Path $TestDrive 'hb-skew.json'
        New-Heartbeat $hb -OffsetMinutes -3   # 3 minutes in the future: within the 5-min grace
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb -MaxAge 75)
        $r.ExitCode | Should -Be 0
    }

    It 'emits JSON output when -Json is passed' {
        $hb = Join-Path $TestDrive 'hb-json.json'
        New-Heartbeat $hb -OffsetMinutes 2
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' (New-Args $hb -Extra @('-Json'))
        $r.ExitCode | Should -Be 0
        $r.Json | Should -Not -BeNullOrEmpty
        $r.Json.fresh | Should -Be $true
    }
}
