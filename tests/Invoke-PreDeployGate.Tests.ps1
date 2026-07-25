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

Describe 'gate refuses a commit-string-only pass' {
    It 'exits 10 when the commit matches but no content source is supplied' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot',$script:Release,'-StagedCommit','abc1234',
            '-ApprovedCommitParam','/ves/gatetest/approved-commit','-Processor','gatetest')
        $r.ExitCode | Should -Be 10
        $r.Output   | Should -Match 'No content check possible'
    }

    It 'passes commit-only with an explicit, logged -AllowCommitOnly' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot',$script:Release,'-StagedCommit','abc1234',
            '-ApprovedCommitParam','/ves/gatetest/approved-commit','-Processor','gatetest',
            '-AllowCommitOnly')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'AllowCommitOnly engaged'
        $r.Output   | Should -Match 'NOT verified'
    }
}

Describe 'gate content baseline from the Git release tag' {
    BeforeAll {
        # Archive the gatetest baseline under a release tag; the archived leaf is
        # baseline.json, so the gate passes -ManifestPath to name the same leaf.
        $script:TagRepo = Join-Path $TestDrive 'gate-tag-repo'
        New-Item -ItemType Directory -Path $script:TagRepo -Force | Out-Null
        git -C $script:TagRepo init --quiet
        git -C $script:TagRepo config user.email 'test@example.com'
        git -C $script:TagRepo config user.name 'ves-verify tests'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',$script:ManifestPath,'-Processor','gatetest',
            '-ArchiveRepo',$script:TagRepo,'-ReleaseTag','gatetest/v1.0.0',
            '-AllowUntrustedCapture')
        if ($cap.ExitCode -ne 0) { throw "gate tag capture failed: $($cap.Output)" }
        $script:TagArgs = @(
            '-StagedCommit','abc1234',
            '-ApprovedCommitParam','/ves/gatetest/approved-commit',
            '-BaselineRepo',$script:TagRepo,'-ReleaseTag','gatetest/v1.0.0',
            '-ManifestPath',$script:ManifestPath,
            '-Processor','gatetest')
    }

    It 'passes a matching staged tree with no -TrustParam (tag-anchored)' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' ($script:TagArgs + @('-StagedRoot',$script:Release))
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'read from Git release tag'
        $r.Output   | Should -Match 'anchored to the Git release tag only'
        $r.Output   | Should -Match 'GATE PASS'
    }

    It 'blocks and names the missing file from the tag-archived manifest' {
        $staged = New-VesTree (Join-Path $script:Root 'tag-staged-missing')
        Remove-Item -LiteralPath (Join-Path $staged 'bin\lib.dll')
        $gateArgs = @(
            '-StagedRoot',$staged,'-StagedCommit','abc1234',
            '-ApprovedCommitParam','/ves/gatetest/approved-commit',
            '-BaselineRepo',$script:TagRepo,'-ReleaseTag','gatetest/v1.0.0',
            '-ManifestPath',$script:ManifestPath,
            '-Processor','gatetest')
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' $gateArgs
        $r.ExitCode | Should -Be 1
        $r.Output   | Should -Match 'Deployment blocked: bin/lib\.dll is missing from the artifact'
    }

    It 'agrees with SSM when both sources are supplied' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' (
            $script:TagArgs + @('-StagedRoot',$script:Release,'-TrustParam','/ves/gatetest/baseline-hash'))
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'GATE PASS'
    }

    It 'exits 2 when the tag manifest disagrees with the SSM-trusted hash' {
        # Archive a DIFFERENT tree under a new tag; SSM still pins the original.
        $other = New-VesTree (Join-Path $script:Root 'tag-other-release')
        Set-Content -Path (Join-Path $other 'app.txt') -Value 'other-bytes' -NoNewline
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$other,
            '-ManifestPath',(Join-Path $script:Root 'other-baseline.json'),
            '-Processor','gatetest','-ArchiveRepo',$script:TagRepo,
            '-ReleaseTag','gatetest/v2.0.0','-AllowUntrustedCapture')
        if ($cap.ExitCode -ne 0) { throw "second capture failed: $($cap.Output)" }
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot',$script:Release,'-StagedCommit','abc1234',
            '-ApprovedCommitParam','/ves/gatetest/approved-commit',
            '-TrustParam','/ves/gatetest/baseline-hash',
            '-BaselineRepo',$script:TagRepo,'-ReleaseTag','gatetest/v2.0.0',
            '-ManifestPath',(Join-Path $script:Root 'other-baseline.json'),
            '-Processor','gatetest')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'does not match the SSM-trusted hash'
    }

    It 'exits 10 when -BaselineRepo is given without -ReleaseTag' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot',$script:Release,'-StagedCommit','abc1234',
            '-ApprovedCommitParam','/ves/gatetest/approved-commit',
            '-BaselineRepo',$script:TagRepo,'-Processor','gatetest')
        $r.ExitCode | Should -Be 10
        $r.Output   | Should -Match 'must be supplied together'
    }
}
