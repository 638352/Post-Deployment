#Requires -Version 5.1
# Invoke-PreDeployGate.ps1 direct coverage. This file did not exist while the
# gate ran against AWS SSM -- the component that blocks unapproved releases had
# no tests of its own, which is how "exit 2 is the only reachable outcome" went
# unnoticed. These cases pin the full exit-code contract:
#   0 pass, 1 blocked, 2 anchor unreadable/untrustworthy, 10 usage.
#
# The anchor is a real git archive (no stubs): the manifest committed under the
# release tag supplies BOTH the approved commit (its commitSha field) and the
# baseline hash.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root = Join-Path $TestDrive 'gate'
    $script:Staged = New-VesTree (Join-Path $script:Root 'staged')
    $script:ManifestPath = Join-Path $script:Root 'gatetest.json'

    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:Staged,
        '-ManifestPath', $script:ManifestPath, '-Processor', 'gatetest',
        '-CommitSha', 'abc1234', '-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "gatetest capture failed: $($cap.Output)" }

    $script:Archive = New-VesBaselineArchive -Path (Join-Path $script:Root 'archive') `
        -Processor 'gatetest' -ManifestPath $script:ManifestPath -Tag 'gatetest/v1.0.0'

    function script:New-GateArgs([string[]]$Extra = @()) {
        @('-StagedRoot', $script:Staged, '-StagedCommit', 'abc1234',
            '-Processor', 'gatetest', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'gatetest/v1.0.0') + $Extra
    }
}

AfterAll {
    Remove-VesBaselineArchive -Path $script:Archive
}

Describe 'exit 0: approved release' {
    It 'passes when the staged commit and tree both match the archived record' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' (New-GateArgs)
        $r.ExitCode | Should -Be 0
        # both checks RAN -- a pass that skipped one is the failure mode this
        # suite exists to prevent
        $r.Output | Should -Match 'Commit gate PASS'
        $r.Output | Should -Match 'Content gate PASS'
        $r.Output | Should -Match 'GATE PASS'
    }
}

Describe 'exit 1: blocked' {
    It 'blocks a staged commit that is not the approved one' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot', $script:Staged, '-StagedCommit', 'fff9999',
            '-Processor', 'gatetest', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'gatetest/v1.0.0')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Staged commit fff9999 != approved abc1234'
    }

    It 'blocks a staged tree that does not match the archived baseline, naming the file' {
        $tampered = New-VesTree (Join-Path $script:Root 'staged-tampered')
        Set-Content -Path (Join-Path $tampered 'app.txt') -Value 'not-the-approved-bytes' -NoNewline
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot', $tampered, '-StagedCommit', 'abc1234',
            '-Processor', 'gatetest', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'gatetest/v1.0.0')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'CHANGED vs approved'
        $r.Output | Should -Match 'app\.txt'
    }

    It 'blocks a missing required artifact path' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' (New-GateArgs @(
                '-RequiredArtifactPaths', 'settings\prod.config'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'settings\\prod\.config is missing'
    }
}

Describe 'exit 2: anchor unreadable or untrustworthy' {
    It 'refuses when the tag does not exist (indistinguishable from a deleted tag)' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot', $script:Staged, '-StagedCommit', 'abc1234',
            '-Processor', 'gatetest', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'gatetest/v9.9.9')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Gate error \(anchor\)'
    }

    It 'refuses when the baseline repo is not a git checkout' {
        $notRepo = Join-Path $script:Root 'not-a-repo'
        New-Item -ItemType Directory -Path $notRepo -Force | Out-Null
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot', $script:Staged, '-StagedCommit', 'abc1234',
            '-Processor', 'gatetest', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $notRepo, '-ReleaseTag', 'gatetest/v1.0.0')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'not a git checkout'
    }

    It 'refuses an archived manifest that records no commitSha' {
        # A record with no commit cannot approve anything: the commit gate would
        # otherwise degrade to comparing against 'unknown'.
        $nocommitManifest = Join-Path $script:Root 'nocommit.json'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode', 'Capture', '-ReleaseRoot', $script:Staged,
            '-ManifestPath', $nocommitManifest, '-Processor', 'nocommit',
            '-CommitSha', 'placeholder', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        # strip the recorded commit the way a pre-contract capture would have
        $doc = Get-Content -LiteralPath $nocommitManifest -Raw | ConvertFrom-Json
        $doc.commitSha = 'unknown'
        ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $nocommitManifest -Encoding utf8
        $arc2 = New-VesBaselineArchive -Path (Join-Path $script:Root 'archive-nocommit') `
            -Processor 'nocommit' -ManifestPath $nocommitManifest -Tag 'nocommit/v1.0.0'
        try {
            $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
                '-StagedRoot', $script:Staged, '-StagedCommit', 'unknown',
                '-Processor', 'nocommit', '-ManifestPath', $nocommitManifest,
                '-BaselineRepo', $arc2, '-ReleaseTag', 'nocommit/v1.0.0')
            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'records no commitSha'
        }
        finally { Remove-VesBaselineArchive -Path $arc2 }
    }
}

Describe 'exit 10: usage' {
    It 'refuses to run without an anchor at all -- there is no commit-only mode' {
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot', $script:Staged, '-StagedCommit', 'abc1234', '-Processor', 'gatetest')
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'No anchor'
        $r.Output | Should -Not -Match 'GATE PASS'
    }

    It 'rejects a malformed release tag instead of handing it to git' {
        # A branch name must not become an anchor: branches move without force.
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot', $script:Staged, '-StagedCommit', 'abc1234',
            '-Processor', 'gatetest', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'main')
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'Malformed release tag'
    }
}

Describe 'the documented tamper scenario' {
    It 'catches an attacker who edits the staged tree AND regenerates the local manifest' {
        # The attack the module header describes: edit the bits, then re-capture
        # the manifest next to them so the two agree. The local-manifest pair is
        # self-consistent; only the tag anchor can catch it. This is the exact
        # scenario that passed verification unnoticed while the anchor was vacant.
        $evil = New-VesTree (Join-Path $script:Root 'staged-evil')
        Set-Content -Path (Join-Path $evil 'app.txt') -Value 'MALICIOUS PAYLOAD' -NoNewline
        # Same leaf name as the real manifest -- an attacker overwrites the real
        # file in place, and the gate derives the archived leaf from this name.
        $evilDir = Join-Path $script:Root 'evil'
        New-Item -ItemType Directory -Path $evilDir -Force | Out-Null
        $evilManifest = Join-Path $evilDir 'gatetest.json'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode', 'Capture', '-ReleaseRoot', $evil,
            '-ManifestPath', $evilManifest, '-Processor', 'gatetest',
            '-CommitSha', 'abc1234', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        $r = Invoke-VesScript 'Invoke-PreDeployGate.ps1' @(
            '-StagedRoot', $evil, '-StagedCommit', 'abc1234',
            '-Processor', 'gatetest', '-ManifestPath', $evilManifest,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'gatetest/v1.0.0')
        $r.ExitCode | Should -Be 1
        # -Match is case-insensitive: assert on the full pass line, or the
        # legitimate 'Commit gate PASS.' (the attacker kept the commit string)
        # would satisfy a bare 'GATE PASS' pattern.
        $r.Output | Should -Not -Match 'GATE PASS: deploy may proceed'
        $r.Output | Should -Match 'Deployment blocked'
    }
}
