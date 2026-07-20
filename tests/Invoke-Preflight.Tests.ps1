#Requires -Version 5.1
# Invoke-Preflight.ps1, the no-SSM paths: manifest integrity and the config
# contract parse check. We never pass -TrustParam / -ApprovedCommitParam / a
# targets file with SSM params, so aws is never called. Exit contract: 0 ready,
# 2 not ready, 10 usage.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    Import-Module (Join-Path (Get-VesRepoRoot) 'module\VesVerify.psm1') -Force

    $tree = New-VesTree (Join-Path $TestDrive 'pf-release')
    $manifest = Get-VesManifest -ReleaseRoot $tree

    $script:GoodManifest = Join-Path $TestDrive 'good.json'
    Export-VesManifest -Manifest $manifest -Path $script:GoodManifest -Processor 'pf' | Out-Null

    $script:BadManifest = Join-Path $TestDrive 'bad.json'
    $doc = Get-Content -LiteralPath $script:GoodManifest -Raw | ConvertFrom-Json
    $doc.files[0].Sha256 = ('F' * 64)
    ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:BadManifest -Encoding utf8

    $script:GoodContract = Join-Path $PSScriptRoot 'fixtures\json\contract.json'
    $script:BadContract  = Join-Path $TestDrive 'bad-format.json'
    '{ "format": "yaml", "requiredKeys": [] }' | Out-File -FilePath $script:BadContract -Encoding utf8
}

Describe 'usage' {
    It 'exits 10 with no targets and no per-processor params' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-Json')
        $r.ExitCode | Should -Be 10
    }
    It 'exits 10 when the targets file is missing' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-TargetsFile',(Join-Path $TestDrive 'no-targets.json'),'-Json')
        $r.ExitCode | Should -Be 10
    }
}

Describe 'manifest self-check' {
    It 'is ready for an intact manifest' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-ManifestPath',$script:GoodManifest,'-Processor','pf','-Json')
        $r.ExitCode   | Should -Be 0
        $r.Json.ready | Should -BeTrue
    }
    It 'is not ready for a tampered manifest' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-ManifestPath',$script:BadManifest,'-Processor','pf','-Json')
        $r.ExitCode   | Should -Be 2
        $r.Json.ready | Should -BeFalse
        $r.Output     | Should -Match 'self-hash mismatch'
    }
}

Describe 'config contract check' {
    It 'is ready for a well-formed contract even without manifest or SSM params' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-ConfigContract',$script:GoodContract,'-Json')
        $r.ExitCode   | Should -Be 0
        $r.Json.ready | Should -BeTrue
    }

    It 'is ready for a well-formed contract' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-ManifestPath',$script:GoodManifest,'-ConfigContract',$script:GoodContract,'-Json')
        $r.ExitCode | Should -Be 0
    }
    It 'is not ready for an unknown format' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-ManifestPath',$script:GoodManifest,'-ConfigContract',$script:BadContract,'-Json')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'format missing/unknown'
    }
}
