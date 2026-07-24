#Requires -Version 5.1

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
}

Describe 'drift heartbeat watchdog' {
    It 'passes for a fresh completed run' {
        $path = Join-Path $TestDrive 'fresh-heartbeat.json'
        [ordered]@{
            schema='ves.drift-heartbeat.v1'
            completedUtc=(Get-Date).ToUniversalTime().ToString('o')
            outcome='PASS'
            exitCode=0
        } | ConvertTo-Json | Out-File -FilePath $path -Encoding utf8

        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath',$path,'-MaxAgeMinutes','30',
            '-LogFile',(Join-Path $TestDrive 'fresh-watchdog.jsonl'),'-Json')
        $r.ExitCode  | Should -Be 0
        $r.Json.fresh | Should -BeTrue
    }

    It 'errors and names a stale heartbeat' {
        $path = Join-Path $TestDrive 'stale-heartbeat.json'
        [ordered]@{
            schema='ves.drift-heartbeat.v1'
            completedUtc=(Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
            outcome='PASS'
            exitCode=0
        } | ConvertTo-Json | Out-File -FilePath $path -Encoding utf8

        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath',$path,'-MaxAgeMinutes','30','-Environment','uat',
            '-LogFile',(Join-Path $TestDrive 'stale-watchdog.jsonl'),'-Json')
        $r.ExitCode   | Should -Be 2
        $r.Json.fresh | Should -BeFalse
        $r.Output     | Should -Match 'MISSED DRIFT RUN'
        $r.Output     | Should -Match 'stale'
    }

    It 'errors when no heartbeat exists' {
        $r = Invoke-VesScript 'Test-DriftHeartbeat.ps1' @(
            '-HeartbeatPath',(Join-Path $TestDrive 'absent.json'),
            '-MaxAgeMinutes','30',
            '-LogFile',(Join-Path $TestDrive 'missing-watchdog.jsonl'),'-Json')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'Heartbeat not found'
    }
}
