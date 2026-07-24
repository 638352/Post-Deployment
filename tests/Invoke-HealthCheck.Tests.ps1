#Requires -Version 5.1
# Invoke-HealthCheck.ps1 - the checks that don't need a live host: fresh-log
# liveness and assembly load. The service / scheduled-task / HTTP branches want a
# running service, a registered task, or a listening port, so they're skipped for
# now. Exit contract: 0 healthy, 3 unhealthy.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:FxDll = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.dll'
}

Describe 'fresh-log liveness' {
    It 'passes on a fresh log' {
        $d = Join-Path $TestDrive 'fresh'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -Path (Join-Path $d 'today.log') -Value 'a line'
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @('-FreshLogDir',$d,'-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 0
        $r.Json.healthy | Should -BeTrue
    }

    It 'fails on a stale log' {
        $d = Join-Path $TestDrive 'stale'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $f = Join-Path $d 'old.log'; Set-Content -Path $f -Value 'a line'
        (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddHours(-2)
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-FreshLogDir',$d,'-FreshLogMaxAgeMinutes','60','-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 3
        $r.Json.healthy | Should -BeFalse
        $r.Output       | Should -Match 'stale'
    }

    It 'fails on a missing directory' {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-FreshLogDir',(Join-Path $TestDrive 'no-such-dir'),'-Json')
        $r.ExitCode | Should -Be 3
    }

    It 'fails on an empty directory' {
        $d = Join-Path $TestDrive 'empty'; New-Item -ItemType Directory -Path $d -Force | Out-Null
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @('-FreshLogDir',$d,'-Json')
        $r.ExitCode | Should -Be 3
    }
}

Describe 'assembly load' {
    It 'fails when the assembly file is missing' {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-RequiredAssemblies',(Join-Path $TestDrive 'ghost.dll'),'-Json')
        $r.ExitCode | Should -Be 3
        $r.Output   | Should -Match 'Assembly LOAD FAIL'
    }

    It 'passes on an assembly whose types resolve' -Skip:(-not (Test-Path (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\System.dll'))) {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-RequiredAssemblies',$script:FxDll,'-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 0
        $r.Json.healthy | Should -BeTrue
    }
}

Describe 'health evidence requirements' {
    It 'refuses to pass when no probe is configured' {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @('-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 10
        $r.Json.healthy | Should -BeFalse
        $r.Json.outcome | Should -Be 'ERROR'
        $r.Output       | Should -Match 'No health probes'
    }

    It 'fails when the exact process path root does not exist' {
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-ProcessPathRoot',(Join-Path $TestDrive 'missing-process-root'),
            '-ProcessArgumentPattern','\bRTPDP\b','-Processor','hc','-Json')
        $r.ExitCode     | Should -Be 3
        $r.Json.healthy | Should -BeFalse
        $r.Output       | Should -Match 'Process path check failed'
    }
}
