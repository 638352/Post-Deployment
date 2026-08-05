#Requires -Version 5.1
# Start-DriftRunner.ps1 against ves.targets.v1 + a real Git baseline archive.
# Log-pruning assertions guard deploy audit logs that share the same LogDir.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    Import-Module (Join-Path (Get-VesRepoRoot) 'module\VesVerify.psm1') -Force

    $script:Release  = New-VesTree (Join-Path $TestDrive 'dr-release')
    # Leaf must match baselines/<processor>/<processor>.json in the archive: when
    # -BaselineRepo is set, verify uses Split-Path -Leaf of ManifestPath as the
    # archived filename.
    $script:Manifest = Join-Path $TestDrive 'alpha.json'
    Export-VesManifest -Manifest (Get-VesManifest -ReleaseRoot $script:Release) `
        -Path $script:Manifest -Processor 'alpha' -CommitSha 'dr-commit-1' | Out-Null

    $script:Archive = Join-Path $TestDrive 'dr-archive'
    New-Item -ItemType Directory -Path $script:Archive -Force | Out-Null
    New-VesBaselineArchive -Path $script:Archive -Processor 'alpha' `
        -ManifestPath $script:Manifest -Tag 'alpha/v1.0.0'

    # Mode All requires config params; reuse fixtures Verify-Config proves pass together.
    $script:Targets = Join-Path $TestDrive 'dr-targets.json'
    $doc = [ordered]@{
        schema            = 'ves.targets.v1'
        inventoryComplete = $true
        requiredServers   = @('DRSERVER01')
        targets           = @(
            [ordered]@{
                processor       = 'alpha'
                server          = 'DRSERVER01'
                environment     = 'uat'
                inventoryStatus = 'confirmed'
                releaseTag      = 'alpha/v1.0.0'
                releaseRoot     = $script:Release
                manifestPath    = $script:Manifest
                configContract  = (Join-Path $PSScriptRoot 'fixtures\json\contract.json')
                configPath      = (Join-Path $PSScriptRoot 'fixtures\json\config.json')
            }
        )
    }
    ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:Targets -Encoding utf8
}

AfterAll {
    if ($script:Archive -and (Test-Path -LiteralPath $script:Archive)) {
        Get-ChildItem -LiteralPath $script:Archive -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.IsReadOnly = $false } catch {} }
        Remove-Item -LiteralPath $script:Archive -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'log pruning' {
    BeforeEach {
        $script:LogDir = Join-Path $TestDrive ('dr-logs-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

        $old = (Get-Date).AddDays(-90)
        $script:Seeded = @{
            OwnLog      = 'alpha_20250101T010101Z.jsonl'
            OtherTarget = 'bravo_20250101T010101Z.jsonl'
            DeployLog1  = 'deploy_OutboundDBQ_20250101T010101Z.jsonl'
            DeployLog2  = 'deploy_alpha_20250101T010101Z.jsonl'
            Stray       = 'someone-elses-notes.jsonl'
        }
        foreach ($n in $script:Seeded.Values) {
            $p = Join-Path $script:LogDir $n
            Set-Content -Path $p -Value '{"seeded":true}'
            (Get-Item -LiteralPath $p).LastWriteTime = $old
        }
    }

    It 'prunes its own stale target logs' {
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile', $script:Targets, '-BaselineRepo', $script:Archive,
            '-LogDir', $script:LogDir, '-LogRetentionDays', '30') | Out-Null
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.OwnLog) | Should -BeFalse
    }

    It 'does NOT prune the deploy audit logs' {
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile', $script:Targets, '-BaselineRepo', $script:Archive,
            '-LogDir', $script:LogDir, '-LogRetentionDays', '30') | Out-Null
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.DeployLog1) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.DeployLog2) | Should -BeTrue
    }

    It 'does not touch a stray file or a non-target processor log' {
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile', $script:Targets, '-BaselineRepo', $script:Archive,
            '-LogDir', $script:LogDir, '-LogRetentionDays', '30') | Out-Null
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.Stray)       | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.OtherTarget) | Should -BeTrue
    }

    It 'prunes nothing when retention is 0' {
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile', $script:Targets, '-BaselineRepo', $script:Archive,
            '-LogDir', $script:LogDir, '-LogRetentionDays', '0') | Out-Null
        foreach ($n in $script:Seeded.Values) {
            Test-Path -LiteralPath (Join-Path $script:LogDir $n) | Should -BeTrue
        }
    }
}

Describe 'exit code' {
    It 'exits 0 when every target matches its baseline' {
        $logDir = Join-Path $TestDrive ('dr-clean-{0}' -f ([guid]::NewGuid().ToString('N')))
        $r = Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile', $script:Targets, '-BaselineRepo', $script:Archive,
            '-LogDir', $logDir, '-LogRetentionDays', '0')
        $r.ExitCode | Should -Be 0
    }

    It 'exits 1 when a target has drifted' {
        $logDir = Join-Path $TestDrive ('dr-drift-{0}' -f ([guid]::NewGuid().ToString('N')))
        Set-Content -Path (Join-Path $script:Release 'app.txt') -Value 'CHANGED' -NoNewline
        try {
            $r = Invoke-VesScript 'Start-DriftRunner.ps1' @(
                '-TargetsFile', $script:Targets, '-BaselineRepo', $script:Archive,
                '-LogDir', $logDir, '-LogRetentionDays', '0')
            $r.ExitCode | Should -Be 1
        } finally {
            Set-Content -Path (Join-Path $script:Release 'app.txt') -Value 'hello' -NoNewline
        }
    }

    It 'exits 2 when the inventory is still incomplete' {
        $logDir = Join-Path $TestDrive ('dr-inv-{0}' -f ([guid]::NewGuid().ToString('N')))
        $bad = Join-Path $TestDrive 'dr-incomplete.json'
        $doc = Get-Content -LiteralPath $script:Targets -Raw | ConvertFrom-Json
        $doc.inventoryComplete = $false
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $bad -Encoding utf8
        $r = Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile', $bad, '-BaselineRepo', $script:Archive,
            '-LogDir', $logDir, '-LogRetentionDays', '0')
        $r.ExitCode | Should -Be 2
    }
}
