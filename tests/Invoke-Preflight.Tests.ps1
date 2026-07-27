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

Describe 'targets inventory gate' {
    # Regression cover for the -TargetsFile path. Reading the inventory with a bare
    # ConvertFrom-Json instead of Import-VesTargetInventory skips the coverage gate
    # AND iterates the root object rather than .targets, so preflight silently
    # validates nothing and still exits 2 on unrelated grounds. The module tests
    # exercise Import-VesTargetInventory directly, so only these catch that.
    BeforeAll {
        $script:V1Targets = Join-Path $TestDrive 'v1-incomplete.json'
        [PSCustomObject]@{
            schema            = 'ves.targets.v1'
            inventoryComplete = $false
            requiredServers   = @('SERVER-A','SERVER-B')
            targets           = @(
                [PSCustomObject]@{ processor = 'alpha'; inventoryStatus = 'needs-confirmation'
                                   manifestPath = $script:GoodManifest }
            )
        } | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:V1Targets -Encoding utf8
    }

    It 'fails closed when inventoryComplete is not true' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile',$script:V1Targets,'-Json')
        $r.ExitCode | Should -Be 2
        $inventory = @($r.Json.checks | Where-Object { $_.check -eq 'inventory' -and $_.status -eq 'FAIL' })
        $inventory.Count | Should -BeGreaterThan 0
        ($inventory.detail -join ' ') | Should -Match 'inventoryComplete'
    }

    It 'names every required server that has no confirmed target' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile',$script:V1Targets,'-Json')
        $detail = (@($r.Json.checks | Where-Object { $_.check -eq 'inventory' }).detail -join ' ')
        $detail | Should -Match 'SERVER-A'
        $detail | Should -Match 'SERVER-B'
    }

    It 'still runs the per-target checks from .targets, not the root object' {
        # the regressed build logged "--- target: ? ---" and never reached the
        # manifest check, because the root object has no manifestPath
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-TargetsFile',$script:V1Targets,'-Json')
        @($r.Json.checks | Where-Object { $_.check -eq 'manifest' }).Count | Should -BeGreaterThan 0
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

Describe 'run evidence' {
    # Regression: the log-file bootstrap and the RUN START / RUN END lines were
    # dropped from this script, so a preflight run without -LogFile wrote console
    # text and nothing else -- a box could be declared READY with no record of it.
    BeforeEach {
        $script:EvidenceDir = Join-Path $TestDrive ("evidence-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:EvidenceDir -Force | Out-Null
        $script:PrevAuditDir = $env:VES_AUDIT_LOG_DIR
        $env:VES_AUDIT_LOG_DIR = $script:EvidenceDir
    }
    AfterEach { $env:VES_AUDIT_LOG_DIR = $script:PrevAuditDir }

    It 'writes a JSONL log with run boundaries when -LogFile is omitted' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-Processor', 'pf', '-ManifestPath', $script:GoodManifest)
        $r.ExitCode | Should -Be 0

        $logs = @(Get-ChildItem -LiteralPath $script:EvidenceDir -Filter '*.jsonl')
        $logs.Count | Should -BeGreaterThan 0
        $text = Get-Content -LiteralPath $logs[0].FullName -Raw
        $text | Should -Match 'RUN START: preflight'
        $text | Should -Match 'RUN END: preflight outcome=PASS exit=0'
    }

    It 'records a RUN END on the not-ready path too' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @(
            '-Processor', 'pf', '-ManifestPath', $script:BadManifest)
        $r.ExitCode | Should -Be 2
        $text = (Get-ChildItem -LiteralPath $script:EvidenceDir -Filter '*.jsonl' |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $text | Should -Match 'RUN END: preflight outcome=ERROR exit=2'
    }

    It 'records a RUN END on the usage path too' {
        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-Json')
        $r.ExitCode | Should -Be 10
        $text = (Get-ChildItem -LiteralPath $script:EvidenceDir -Filter '*.jsonl' |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $text | Should -Match 'RUN END: preflight outcome=ERROR exit=10'
    }
}

Describe 'manifest metadata outside the trust hash' {
    It 'reports the counted file total and warns when fileCount disagrees' {
        # fileCount, commitSha and capturedBy sit outside the hashed files[], so
        # they can be edited without breaking the anchor. Preflight must not echo
        # a forged number back as trust-anchored fact.
        $forged = Join-Path $TestDrive 'forged-count.json'
        $doc = Get-Content -LiteralPath $script:GoodManifest -Raw | ConvertFrom-Json
        $real = @($doc.files).Count
        $doc.fileCount = 999
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $forged -Encoding utf8

        $r = Invoke-VesScript 'Invoke-Preflight.ps1' @('-Processor', 'pf', '-ManifestPath', $forged, '-Json')
        $r.ExitCode | Should -Be 0
        $manifestRow = @($r.Json.checks | Where-Object { $_.check -eq 'manifest' })[0]
        $manifestRow.detail | Should -Match ("\({0} files\)" -f $real)
        $manifestRow.detail | Should -Not -Match '999'
        $metaRow = @($r.Json.checks | Where-Object { $_.check -eq 'manifest-metadata' })
        $metaRow.Count     | Should -Be 1
        $metaRow[0].status | Should -Be 'WARN'
    }
}
