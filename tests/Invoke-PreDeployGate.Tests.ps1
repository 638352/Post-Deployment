#Requires -Version 5.1
# Invoke-PreDeployGate.ps1 end-to-end. The gate's SSM reads go through the AWS
# CLI, so a fake aws.cmd is prepended to PATH: the test controls the approved
# commit and trusted hash without touching real AWS. Exit contract: 0 pass,
# 1 blocked, 2 SSM/trust error.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root         = Join-Path $TestDrive 'gate'
    $script:Release      = New-VesTree (Join-Path $script:Root 'release')
    $script:ManifestPath = Join-Path $script:Root 'baseline.json'

    # capture the baseline (no -TrustParam, so capture itself never hits SSM)
    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode','Capture','-ReleaseRoot',$script:Release,
        '-ManifestPath',$script:ManifestPath,'-Processor','gatetest',
        '-AllowUntrustedCapture','-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "baseline capture failed: $($cap.Output)" }
    $script:TrustedHash = (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json).manifestHash

    # fake aws on PATH: answers the two get-parameter calls the gate makes.
    # arg layout: %1=ssm %2=get-parameter %3=--name %4=<parameter name>
    $script:StubDir = Join-Path $TestDrive 'awsstub'
    New-Item -ItemType Directory -Path $script:StubDir -Force | Out-Null
    @(
        '@echo off'
        'if "%~4"=="/ves/gatetest/approved-commit" echo abc1234& exit /b 0'
        ('if "%~4"=="/ves/gatetest/baseline-hash" echo {0}& exit /b 0' -f $script:TrustedHash)
        'echo An error occurred (ParameterNotFound) 1>&2'
        'exit /b 254'
    ) | Set-Content -Path (Join-Path $script:StubDir 'aws.cmd') -Encoding ascii
    $script:OrigPath = $env:PATH
    $env:PATH = "$($script:StubDir);$env:PATH"

    # common args for the trust-anchored (content gate) invocations
    $script:GateArgs = @(
        '-StagedCommit','abc1234',
        '-ApprovedCommitParam','/ves/gatetest/approved-commit',
        '-TrustParam','/ves/gatetest/baseline-hash',
        '-ManifestPath',$script:ManifestPath,
        '-Processor','gatetest')
}

AfterAll { $env:PATH = $script:OrigPath }

Describe 'gate pass' {
    It 'exits 0 when the staged tree matches the approved release' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' ($script:GateArgs + @('-StagedRoot',$script:Release))
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'GATE PASS'
    }
}

Describe 'gate block names the files' {
    It 'names a missing file in the block message (the Storage.Net case)' {
        $staged = New-VesTree (Join-Path $script:Root 'staged-missing')
        Remove-Item -LiteralPath (Join-Path $staged 'bin\lib.dll')
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' ($script:GateArgs + @('-StagedRoot',$staged))
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'MISSING from artifact: bin/lib\.dll'
        $r.Output   | Should -Match 'Deployment blocked: bin/lib\.dll is missing from the artifact'
    }

    It 'names a changed file when nothing is missing' {
        $staged = New-VesTree (Join-Path $script:Root 'staged-changed')
        Set-Content -Path (Join-Path $staged 'app.txt') -Value 'TAMPERED' -NoNewline
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' ($script:GateArgs + @('-StagedRoot',$staged))
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'CHANGED vs approved:\s+app\.txt'
        $r.Output   | Should -Match 'Deployment blocked: staged artifact does not match the approved release'
    }

    It 'blocks a missing config path even though config files are hash-excluded' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' (
            $script:GateArgs + @(
                '-StagedRoot',$script:Release,
                '-RequiredArtifactPaths','app.exe.config'))
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'app\.exe\.config is missing from the artifact'
    }

    It 'passes when an explicitly required hash-excluded config path exists' {
        $staged = New-VesTree (Join-Path $script:Root 'staged-with-config')
        Set-Content -Path (Join-Path $staged 'app.exe.config') -Value '<configuration />'
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' (
            $script:GateArgs + @(
                '-StagedRoot',$staged,
                '-RequiredArtifactPaths','app.exe.config'))
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'Required artifact path present'
    }
}

Describe 'gate block and error paths' {
    It 'blocks on a wrong staged commit (commit gate, no -TrustParam)' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot',$script:Release,'-StagedCommit','wrong123',
            '-ApprovedCommitParam','/ves/gatetest/approved-commit','-Processor','gatetest')
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'Staged commit wrong123 != approved'
    }

    It 'exits 2 when the SSM parameter is unreadable' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot',$script:Release,'-StagedCommit','abc1234',
            '-ApprovedCommitParam','/ves/gatetest/no-such-param','-Processor','gatetest')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'Gate error'
    }
}
