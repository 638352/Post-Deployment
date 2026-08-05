#Requires -Version 5.1
# Invoke-Preflight.ps1 -TargetsFile mode.
#
# This file exists because of a fail-open bug: preflight parsed the targets file
# with a raw ConvertFrom-Json and iterated the ves.targets.v1 ROOT object as if it
# were the target array. Every per-target field resolved to $null, both per-target
# checks returned on their IsNullOrWhiteSpace guards, and preflight exited 0 READY
# having verified no manifest and no contract.
#
# So the assertions below are deliberately two-sided: a bad inventory must FAIL,
# and a good one must PASS *having actually run the per-target checks* -- otherwise
# a future regression that skips the checks again would still look green.
#
# 2026-08-05: the trust anchor moved from an SSM-pinned hash to the manifest
# archived under the Git release tag (there is no AWS in this environment). The
# tamper cases below are the SAME cases as before, re-pointed at the tag anchor --
# they are the reason preflight can still tell "approved" from "edited", so do not
# delete them if the anchor changes again; re-point them.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root = Join-Path $TestDrive 'pf'
    $script:OrigPath = $env:PATH

    # A real release + its captured manifest, so the manifest check has something
    # genuine to verify rather than a path that happens not to exist.
    $script:Release = New-VesTree (Join-Path $script:Root 'release')
    $script:ManifestPath = Join-Path $script:Root 'pftest.json'
    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:Release, '-ManifestPath', $script:ManifestPath,
        '-Processor', 'pftest', '-CommitSha', 'testcommit1', '-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "pftest capture failed: $($cap.Output)" }
    $script:Hash = (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json).manifestHash

    $script:Contract = Join-Path $script:Root 'pftest.config.json'
    '{ "format": "keyvalue", "requiredKeys": ["outbound.queue"] }' |
        Set-Content -LiteralPath $script:Contract -Encoding utf8

    # The trust anchor: a baseline archive repo with the captured manifest committed
    # under pftest/v1.0.0. This is what replaced the SSM pin.
    $script:Archive = Join-Path $script:Root 'archive'
    New-Item -ItemType Directory -Path (Join-Path $script:Archive 'baselines\pftest') -Force | Out-Null
    Copy-Item -LiteralPath $script:ManifestPath -Destination (Join-Path $script:Archive 'baselines\pftest\pftest.json')
    & git -C $script:Archive init -q .
    & git -C $script:Archive config user.email 'test@ves.local'
    & git -C $script:Archive config user.name 'ves tests'
    & git -C $script:Archive add -A
    & git -C $script:Archive commit -qm 'pftest baseline v1.0.0'
    & git -C $script:Archive tag 'pftest/v1.0.0'

    function script:New-Inventory([string]$Name, [hashtable]$Overrides = @{}) {
        $target = [ordered]@{
            processor       = 'pftest'
            server          = 'PFSERVER01'
            environment     = 'uat'
            inventoryStatus = 'confirmed'
            releaseTag      = 'pftest/v1.0.0'
            releaseRoot     = $script:Release
            manifestPath    = $script:ManifestPath
            configContract  = $script:Contract
            configPath      = (Join-Path $script:Release 'app.txt')
        }
        foreach ($k in $Overrides.Keys) { $target[$k] = $Overrides[$k] }
        $doc = [ordered]@{
            schema            = 'ves.targets.v1'
            inventoryComplete = $true
            requiredServers   = @('PFSERVER01')
            targets           = @($target)
        }
        $path = Join-Path $script:Root "$Name.json"
        ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding utf8
        $path
    }
}

AfterAll {
    $env:PATH = $script:OrigPath
    $env:VES_STUB_LOG = $null
    # git writes its loose objects read-only, and Pester's TestDrive teardown does a
    # plain Delete() that throws UnauthorizedAccessException on them -- which fails
    # the whole container even when every test passed. Clear the attribute first.
    if ($script:Archive -and (Test-Path -LiteralPath $script:Archive)) {
        Get-ChildItem -LiteralPath $script:Archive -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.IsReadOnly = $false } catch {} }
        Remove-Item -LiteralPath $script:Archive -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Invoke-Preflight -TargetsFile' {
    It 'reports READY and actually runs the per-target manifest and contract checks' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile', (New-Inventory 'good'), '-BaselineRepo', $script:Archive)
        $r.ExitCode | Should -Be 0
        # the checks RAN -- not merely "nothing failed"
        $r.Output | Should -Match 'intact and anchored to pftest/v1\.0\.0'
        $r.Output | Should -Match 'contract parses, format=keyvalue'
        $r.Output | Should -Match 'confirmed target'
    }

    It 'WARNs rather than PASSes when no anchor is configured' {
        # Self-consistency is not tamper evidence: the self-hash lives inside the
        # file it protects. Reporting a clean PASS here would overstate the control.
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile', (New-Inventory 'noanchor'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'NOT anchored'
        $r.Output | Should -Not -Match 'intact and anchored'
    }

    It 'refuses the checked-in fail-closed starter inventory' {
        # targets.json ships with inventoryComplete=false and placeholder values on
        # purpose; preflight must never call that ready.
        $repoTargets = Join-Path (Get-VesRepoRoot) 'targets.json'
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile', $repoTargets)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'inventoryComplete is not true'
    }

    It 'fails an inventory whose targets are not confirmed' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile', (New-Inventory 'unconfirmed' @{ inventoryStatus = 'needs-confirmation' }))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match "inventoryStatus must be 'confirmed'"
    }

    It 'fails an inventory that still carries a placeholder' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile', (New-Inventory 'placeholder' @{ releaseTag = 'TBD' }))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'placeholder'
    }

    It 'fails a legacy bare-array inventory instead of silently accepting it' {
        $legacy = Join-Path $script:Root 'legacy.json'
        '[{ "processor": "pftest" }]' | Set-Content -LiteralPath $legacy -Encoding utf8
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile', $legacy)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Legacy bare-array inventory'
    }

    It 'fails a manifest that disagrees with the tag-archived baseline' {
        # THE tamper case: a locally valid, self-consistent manifest that is not the
        # one archived under the approved release tag. Must never report ready.
        $other = Join-Path $script:Root 'other.json'
        $otherTree = New-VesTree (Join-Path $script:Root 'other-release') 'different'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode', 'Capture', '-ReleaseRoot', $otherTree, '-ManifestPath', $other,
            '-Processor', 'pftest', '-CommitSha', 'testcommit1', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile', (New-Inventory 'mismatch' @{ manifestPath = $other }),
            '-BaselineRepo', $script:Archive)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'anchor mismatch'
    }

    It 'fails closed when a configured anchor cannot be read' {
        # A tag that does not exist is indistinguishable from a tag deleted to hide
        # a change, so an unreadable anchor must FAIL rather than degrade to a WARN.
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile', (New-Inventory 'ghosttag' @{ releaseTag = 'pftest/v9.9.9' }),
            '-BaselineRepo', $script:Archive)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'cannot read baseline from pftest/v9\.9\.9'
    }

    It 'rejects a malformed release tag instead of ignoring it' {
        # NB: a bare 'v1.0.0' is NOT malformed -- Test-VesReleaseTag makes the
        # <system>/ prefix optional, so it reaches git and fails as an unreadable
        # anchor instead. Use a tag with no version part at all.
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile', (New-Inventory 'badtag' @{ releaseTag = 'pftest/release-one' }),
            '-BaselineRepo', $script:Archive)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'malformed release tag'
    }
}
