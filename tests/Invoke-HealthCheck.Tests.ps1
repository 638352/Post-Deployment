#Requires -Version 5.1
# End-to-end tests for Invoke-HealthCheck.ps1 — only the host-independent checks:
# fresh-log liveness and assembly load. The service / scheduled-task / HTTP-probe
# branches need live host state (a running service, a registered task, a listening
# endpoint) or mocking, and are out of scope for this round. Exit contract here is
# 0 healthy / 3 health failure.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:FxDll = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.dll'
}

Describe 'Invoke-HealthCheck fresh-log liveness' {
    It 'passes when the newest log file is fresh (exit 0)' {
        $d = Join-Path $TestDrive 'fresh'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -Path (Join-Path $d 'today.log') -Value 'a line'
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @('-FreshLogDir',$d,'-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 0
        $r.Json.healthy | Should -BeTrue
    }

    It 'fails when the newest log file is stale (exit 3)' {
        $d = Join-Path $TestDrive 'stale'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $f = Join-Path $d 'old.log'; Set-Content -Path $f -Value 'a line'
        (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddHours(-2)
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-FreshLogDir',$d,'-FreshLogMaxAgeMinutes','60','-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 3
        $r.Json.healthy | Should -BeFalse
        $r.Output       | Should -Match 'stale'
    }

    It 'fails when the log directory is missing (exit 3)' {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-FreshLogDir',(Join-Path $TestDrive 'no-such-dir'),'-Json')
        $r.ExitCode | Should -Be 3
    }

    It 'fails when the log directory is empty (exit 3)' {
        $d = Join-Path $TestDrive 'empty'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @('-FreshLogDir',$d,'-Json')
        $r.ExitCode | Should -Be 3
    }
}

Describe 'Invoke-HealthCheck assembly load' {
    It 'fails when a required assembly file is missing (exit 3)' {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-RequiredAssemblies',(Join-Path $TestDrive 'ghost.dll'),'-Json')
        $r.ExitCode | Should -Be 3
        $r.Output   | Should -Match 'Assembly LOAD FAIL'
    }

    It 'passes for a real assembly whose types resolve (exit 0)' -Skip:(-not (Test-Path (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.dll'))) {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-RequiredAssemblies',$script:FxDll,'-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 0
        $r.Json.healthy | Should -BeTrue
    }
}
