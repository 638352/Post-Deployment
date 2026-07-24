#Requires -Version 5.1
# Invoke-Verification.ps1, filesystem paths only. No -TrustParam anywhere, so
# nothing hits SSM. Checks the exit-code contract: 0 match, 1 drift, 2 no
# baseline, 10 usage.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root         = Join-Path $TestDrive 'ver'
    $script:Release      = New-VesTree (Join-Path $script:Root 'release')
    $script:ManifestPath = Join-Path $script:Root 'baseline.json'

    $script:Cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode','Capture','-ReleaseRoot',$script:Release,
        '-ManifestPath',$script:ManifestPath,'-Processor','test',
        '-AllowUntrustedCapture','-AllowUnarchivedCapture','-Json')
}

Describe 'Capture' {
    It 'exits 0 and reports captured' {
        $script:Cap.ExitCode   | Should -Be 0
        $script:Cap.Json.status | Should -Be 'captured'
    }
    It 'writes the manifest' {
        Test-Path -LiteralPath $script:ManifestPath | Should -BeTrue
    }
    It 'warns when there is no trust anchor' {
        $script:Cap.Output | Should -Match 'NOT trust-anchored'
    }

    It 'fails closed without explicit local-development exceptions' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',(Join-Path $script:Root 'should-not-capture.json'),
            '-Processor','test','-Json')
        $r.ExitCode | Should -Be 10
        $r.Output   | Should -Match 'requires -TrustParam'
    }
}

Describe 'VerifyFiles' {
    It 'passes a matching tree' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,
            '-ManifestPath',$script:ManifestPath,'-Json')
        $r.ExitCode    | Should -Be 0
        $r.Json.status | Should -Be 'match'
    }

    It 'reports drift on a changed file' {
        $drift = New-VesTree (Join-Path $script:Root 'drift')
        Set-Content -Path (Join-Path $drift 'app.txt') -Value 'CHANGED' -NoNewline
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$drift,
            '-ManifestPath',$script:ManifestPath,'-Json')
        $r.ExitCode    | Should -Be 1
        $r.Json.status | Should -Be 'drift'
        $r.Output      | Should -Match 'File verify FAIL'
    }

    It 'exits 2 on a tampered manifest' {
        $tampered = Join-Path $script:Root 'tampered.json'
        $doc = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        $doc.files[0].Sha256 = ('F' * 64)
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $tampered -Encoding utf8
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,
            '-ManifestPath',$tampered,'-Json')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'self-hash mismatch'
    }

    It 'exits 10 without -ManifestPath' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,'-Json')
        $r.ExitCode | Should -Be 10
    }
}

Describe 'Capture -ArchiveRepo' {
    BeforeAll {
        $script:Repo = Join-Path $TestDrive 'audit-repo'
        New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
        git -C $script:Repo init --quiet
        git -C $script:Repo config user.email 'test@example.com'
        git -C $script:Repo config user.name 'ves-verify tests'
    }

    It 'commits the manifest under the processor baselines folder and tags the release' {
        $mp = Join-Path $script:Root 'archived-baseline.json'
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',$mp,'-Processor','archtest',
            '-ArchiveRepo',$script:Repo,'-ReleaseTag','archtest/v1.0.0',
            '-AllowUntrustedCapture','-Json')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match 'Baseline archived to Git'
        Test-Path (Join-Path $script:Repo 'baselines\archtest\archived-baseline.json') | Should -BeTrue
        Test-Path (Join-Path $script:Repo 'baselines\archtest\release-record.json') | Should -BeTrue
        @(git -C $script:Repo tag)              | Should -Contain 'archtest/v1.0.0'
        (git -C $script:Repo log --oneline -1)  | Should -Match 'Baseline capture: archtest'
    }

    It 'fails the capture (exit 2) when the archive repo is not a git checkout' {
        $notRepo = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $notRepo -Force | Out-Null
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',(Join-Path $script:Root 'archived-baseline-2.json'),
            '-Processor','archtest','-ArchiveRepo',$notRepo,
            '-ReleaseTag','archtest/v2.0.0','-AllowUntrustedCapture','-Json')
        $r.ExitCode    | Should -Be 2
        $r.Json.status | Should -Be 'error'
        $r.Output      | Should -Match 'not a git checkout'
    }

    It 'rejects a release tag that is not <system>/vMAJOR.MINOR.PATCH (exit 10)' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',(Join-Path $script:Root 'bad-tag-baseline.json'),
            '-Processor','archtest','-ArchiveRepo',$script:Repo,
            '-ReleaseTag','not-a-semver-tag','-AllowUntrustedCapture','-Json')
        $r.ExitCode | Should -Be 10
        $r.Output   | Should -Match 'vMAJOR\.MINOR\.PATCH'
    }

    It 'pushes the release record and tag to the remote with -PushRemote' {
        $bare = Join-Path $TestDrive 'audit-remote.git'
        git init --bare --quiet $bare
        git -C $script:Repo remote add origin $bare
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',(Join-Path $script:Root 'archived-baseline.json'),
            '-Processor','archtest','-ArchiveRepo',$script:Repo,
            '-ReleaseTag','archtest/v1.1.0','-PushRemote',
            '-AllowUntrustedCapture','-Json')
        $r.ExitCode | Should -Be 0
        $r.Output   | Should -Match "pushed to remote 'origin'"
        @(git -C $bare tag) | Should -Contain 'archtest/v1.1.0'
    }

    It 'fails the capture (exit 2) when the push cannot reach the remote' {
        git -C $script:Repo remote set-url origin (Join-Path $TestDrive 'no-such-remote.git')
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',(Join-Path $script:Root 'archived-baseline.json'),
            '-Processor','archtest','-ArchiveRepo',$script:Repo,
            '-ReleaseTag','archtest/v1.2.0','-PushRemote',
            '-AllowUntrustedCapture','-Json')
        $r.ExitCode    | Should -Be 2
        $r.Json.status | Should -Be 'error'
        $r.Output      | Should -Match 'git .*push.* failed'
    }
}

Describe 'VerifyFiles from the Git release tag' {
    BeforeAll {
        # A dedicated archive repo whose manifest leaf matches the capture
        # convention <processor>.json, so verify needs no -ManifestPath at all.
        $script:TagRepo = Join-Path $TestDrive 'tag-repo'
        New-Item -ItemType Directory -Path $script:TagRepo -Force | Out-Null
        git -C $script:TagRepo init --quiet
        git -C $script:TagRepo config user.email 'test@example.com'
        git -C $script:TagRepo config user.name 'ves-verify tests'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture','-ReleaseRoot',$script:Release,
            '-ManifestPath',(Join-Path $script:Root 'tagtest.json'),
            '-Processor','tagtest','-ArchiveRepo',$script:TagRepo,
            '-ReleaseTag','tagtest/v1.0.0','-AllowUntrustedCapture')
        if ($cap.ExitCode -ne 0) { throw "tag capture failed: $($cap.Output)" }
    }

    It 'passes a matching tree against the tag-archived manifest' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,
            '-BaselineRepo',$script:TagRepo,'-ReleaseTag','tagtest/v1.0.0',
            '-Processor','tagtest','-Json')
        $r.ExitCode        | Should -Be 0
        $r.Json.status     | Should -Be 'match'
        $r.Json.releaseTag | Should -Be 'tagtest/v1.0.0'
        $r.Output          | Should -Match 'read from Git release tag'
    }

    It 'reports drift against the tag-archived manifest' {
        $drift = New-VesTree (Join-Path $script:Root 'tag-drift')
        Set-Content -Path (Join-Path $drift 'app.txt') -Value 'CHANGED' -NoNewline
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$drift,
            '-BaselineRepo',$script:TagRepo,'-ReleaseTag','tagtest/v1.0.0',
            '-Processor','tagtest','-Json')
        $r.ExitCode    | Should -Be 1
        $r.Json.status | Should -Be 'drift'
    }

    It 'exits 2 when the tag does not exist in the archive repo' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,
            '-BaselineRepo',$script:TagRepo,'-ReleaseTag','tagtest/v9.9.9',
            '-Processor','tagtest','-Json')
        $r.ExitCode    | Should -Be 2
        $r.Json.status | Should -Be 'error'
    }

    It 'exits 10 when -BaselineRepo is given without -ReleaseTag' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,
            '-BaselineRepo',$script:TagRepo,'-Processor','tagtest','-Json')
        $r.ExitCode | Should -Be 10
        $r.Output   | Should -Match 'requires -ReleaseTag'
    }
}

Describe 'VerifyConfig' {
    BeforeAll {
        $script:ConfigContract = Join-Path $PSScriptRoot 'fixtures\json\contract.json'
        $script:ConfigPath = Join-Path $PSScriptRoot 'fixtures\json\config.json'
    }

    It 'passes without requiring -ReleaseRoot' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyConfig',
            '-ConfigContract',$script:ConfigContract,
            '-ConfigPath',$script:ConfigPath,
            '-Json')
        $r.ExitCode    | Should -Be 0
        $r.Json.status | Should -Be 'match'
    }

    It 'exits 10 when file verification has no release root' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles',
            '-ManifestPath',$script:ManifestPath,
            '-Json')
        $r.ExitCode | Should -Be 10
        $r.Output   | Should -Match 'ReleaseRoot required'
    }
}
