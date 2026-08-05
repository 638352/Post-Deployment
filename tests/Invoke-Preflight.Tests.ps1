#Requires -Version 5.1
# Invoke-Preflight.ps1 -TargetsFile mode.
#
# This file exists because of a fail-open bug: preflight parsed the targets file
# with a raw ConvertFrom-Json and iterated the ves.targets.v1 ROOT object as if it
# were the target array. Every per-target field resolved to $null, both per-target
# checks returned on their IsNullOrWhiteSpace guards, and preflight exited 0 READY
# having verified no SSM parameter, no manifest, and no contract.
#
# So the assertions below are deliberately two-sided: a bad inventory must FAIL,
# and a good one must PASS *having actually run the per-target checks* -- otherwise
# a future regression that skips the checks again would still look green.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root = Join-Path $TestDrive 'pf'
    $script:OrigPath = $env:PATH
    $script:CallLog = Join-Path $TestDrive 'aws-calls-pf.txt'

    # A real release + its captured manifest, so the manifest check has something
    # genuine to verify rather than a path that happens not to exist.
    $script:Release = New-VesTree (Join-Path $script:Root 'release')
    $script:ManifestPath = Join-Path $script:Root 'pftest.json'
    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:Release, '-ManifestPath', $script:ManifestPath,
        '-Processor', 'pftest', '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "pftest capture failed: $($cap.Output)" }
    $script:Hash = (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json).manifestHash

    $script:Contract = Join-Path $script:Root 'pftest.config.json'
    '{ "format": "keyvalue", "requiredKeys": ["outbound.queue"] }' |
        Set-Content -LiteralPath $script:Contract -Encoding utf8

    New-VesAwsStub -Path (Join-Path $TestDrive 'awsstub-pf') -CallLog $script:CallLog -Parameters @{
        '/ves/pftest/baseline-hash' = $script:Hash
    } | Out-Null

    function script:New-Inventory([string]$Name, [hashtable]$Overrides = @{}) {
        $target = [ordered]@{
            processor       = 'pftest'
            server          = 'PFSERVER01'
            environment     = 'uat'
            inventoryStatus = 'confirmed'
            releaseTag      = 'pftest/v1.0.0'
            releaseRoot     = $script:Release
            manifestPath    = $script:ManifestPath
            trustParam      = '/ves/pftest/baseline-hash'
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
}

Describe 'Invoke-Preflight -TargetsFile' {
    It 'reports READY and actually runs the per-target manifest and contract checks' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile', (New-Inventory 'good'))
        $r.ExitCode | Should -Be 0
        # the checks RAN -- not merely "nothing failed"
        $r.Output | Should -Match 'intact and trust-anchored'
        $r.Output | Should -Match 'contract parses, format=keyvalue'
        $r.Output | Should -Match 'confirmed target'
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

    It 'reports a manifest whose hash no longer matches the SSM pin' {
        # point the target at a manifest the stub does not pin
        $other = Join-Path $script:Root 'other.json'
        $otherTree = New-VesTree (Join-Path $script:Root 'other-release') 'different'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode', 'Capture', '-ReleaseRoot', $otherTree, '-ManifestPath', $other,
            '-Processor', 'pftest', '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile', (New-Inventory 'mismatch' @{ manifestPath = $other }))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'trust mismatch'
    }
}
