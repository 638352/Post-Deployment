#Requires -Version 5.1
# Invoke-Preflight.ps1. Most cases exercise the no-SSM paths: manifest integrity
# and the config contract parse check, passing no -TrustParam / -ApprovedCommitParam
# / SSM-bearing targets file, so aws is never called. The 'SSM failure reporting'
# block is the exception: it puts a shim aws.cmd on PATH, so it still never touches
# a real CLI or AWS account. Exit contract: 0 ready, 2 not ready, 10 usage.

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

    # a baseline captured under the OLD exclude pattern: it carries a top-level
    # logs/ entry that the current pattern drops, so it needs re-capture + re-pin
    $script:StaleManifest = Join-Path $TestDrive 'stale-pattern.json'
    $staleDoc = Get-Content -LiteralPath $script:GoodManifest -Raw | ConvertFrom-Json
    $staleDoc.files = @($staleDoc.files) + [PSCustomObject]@{
        RelPath = 'logs/output.txt'; Sha256 = ('A' * 64); Bytes = 7 }
    # re-pin the self-hash so the manifest stays internally consistent -- we are
    # testing the pattern check, not the tamper check
    $staleDoc.manifestHash = Get-VesManifestHash -Manifest $staleDoc.files
    $staleDoc.fileCount    = @($staleDoc.files).Count
    ($staleDoc | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:StaleManifest -Encoding utf8
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

Describe 'exclude-pattern staleness' {
    It 'warns, but stays ready, for a baseline captured under the old pattern' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-ManifestPath',$script:StaleManifest,'-Processor','pf','-Json')
        $r.ExitCode   | Should -Be 0        # WARN must not flip readiness
        $r.Json.ready | Should -BeTrue
        $row = @($r.Json.checks | Where-Object { $_.check -eq 'manifest-pattern' })
        $row.Count    | Should -Be 1
        $row[0].status| Should -Be 'WARN'
        $row[0].detail| Should -Match 'logs/output.txt'
    }

    It 'passes the pattern check for a baseline captured under the current rules' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-ManifestPath',$script:GoodManifest,'-Processor','pf','-Json')
        $row = @($r.Json.checks | Where-Object { $_.check -eq 'manifest-pattern' })
        $row[0].status | Should -Be 'PASS'
    }
}

Describe 'SSM failure reporting' {
    # These DO invoke 'aws' -- but a shim on PATH, never the real CLI or an account.
    BeforeAll {
        $script:Shim = Join-Path $TestDrive 'pf-awsshim'
        New-Item -ItemType Directory -Path $script:Shim -Force | Out-Null
        Set-Content -Path (Join-Path $script:Shim 'aws.cmd') -Value @(
            '@echo off'
            'echo An error occurred (ParameterNotFound) when calling GetParameter 1>&2'
            'exit /b 254')
        $script:OldPath = $env:PATH
        $env:PATH = "$script:Shim;$env:PATH"
    }
    AfterAll { $env:PATH = $script:OldPath }

    It 'reports the failing parameter as a check row instead of aborting the run' {
        # regression: native stderr under EAP=Stop threw, so the run died in the
        # outer catch as "Preflight error: <raw stderr>" and never emitted the
        # check table, the summary, or -Json at all
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-Processor','pf','-ApprovedCommitParam','/ves/pf/approved-commit','-Json')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Not -Match 'Preflight error:'
        $r.Output   | Should -Match 'Preflight NOT READY'
        $row = @($r.Json.checks | Where-Object { $_.check -eq 'ssm:/ves/pf/approved-commit' })
        $row.Count     | Should -Be 1
        $row[0].status | Should -Be 'FAIL'
        $row[0].detail | Should -Match 'parameter does not exist'
    }

    It 'reports every target instead of aborting on the first' {
        $targets = Join-Path $TestDrive 'two-targets.json'
        @(
            [PSCustomObject]@{ processor='alpha'; trustParam='/ves/alpha/baseline-hash'
                               manifestPath=$script:GoodManifest }
            [PSCustomObject]@{ processor='bravo'; trustParam='/ves/bravo/baseline-hash'
                               manifestPath=$script:GoodManifest }
        ) | ConvertTo-Json -Depth 5 | Out-File -FilePath $targets -Encoding utf8

        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile',$targets,'-Json')
        $r.ExitCode | Should -Be 2
        @($r.Json.checks | Where-Object { $_.check -eq 'ssm:/ves/alpha/baseline-hash' }).Count | Should -Be 1
        @($r.Json.checks | Where-Object { $_.check -eq 'ssm:/ves/bravo/baseline-hash' }).Count | Should -Be 1
    }
}
