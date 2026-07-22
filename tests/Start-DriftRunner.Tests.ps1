#Requires -Version 5.1
# Start-DriftRunner.ps1 log housekeeping. The runner and the per-processor deploy
# wrappers both write <name>_<stamp>.jsonl into the SAME log dir, so the prune step
# has to tell them apart. No SSM: targets carry no trustParam, so aws is never called.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    Import-Module (Join-Path (Get-VesRepoRoot) 'module\VesVerify.psm1') -Force

    # one real target so the runner has something to verify and its logs to prune
    $script:Release  = New-VesTree (Join-Path $TestDrive 'dr-release')
    $script:Manifest = Join-Path $TestDrive 'dr-baseline.json'
    Export-VesManifest -Manifest (Get-VesManifest -ReleaseRoot $script:Release) `
        -Path $script:Manifest -Processor 'alpha' | Out-Null

    # the runner always calls Invoke-Verification -Mode All, which hard-requires the
    # config params -- omitting them would exit 10 (usage), not 0. Reuse the json
    # fixtures the Verify-Config tests already prove pass together.
    $script:Targets = Join-Path $TestDrive 'dr-targets.json'
    @(
        [PSCustomObject]@{
            processor      = 'alpha'
            releaseRoot    = $script:Release
            manifestPath   = $script:Manifest
            configContract = (Join-Path $PSScriptRoot 'fixtures\json\contract.json')
            configPath     = (Join-Path $PSScriptRoot 'fixtures\json\config.json')
        }
    ) | ConvertTo-Json -Depth 5 | Out-File -FilePath $script:Targets -Encoding utf8
}

Describe 'log pruning' {
    BeforeEach {
        $script:LogDir = Join-Path $TestDrive ('dr-logs-{0}' -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

        # everything back-dated well past the retention window
        $old = (Get-Date).AddDays(-90)
        $script:Seeded = @{
            OwnLog      = 'alpha_20250101T010101Z.jsonl'                  # the runner's own
            OtherTarget = 'bravo_20250101T010101Z.jsonl'                  # not in targets.json
            DeployLog1  = 'deploy_OutboundDBQ_20250101T010101Z.jsonl'     # deploy audit trail
            DeployLog2  = 'deploy_alpha_20250101T010101Z.jsonl'           # deploy audit trail
            Stray       = 'someone-elses-notes.jsonl'                     # parked by a human
        }
        foreach ($n in $script:Seeded.Values) {
            $p = Join-Path $script:LogDir $n
            Set-Content -Path $p -Value '{"seeded":true}'
            (Get-Item -LiteralPath $p).LastWriteTime = $old
        }
    }

    It 'prunes its own stale target logs' {
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile',$script:Targets,'-LogDir',$script:LogDir,'-LogRetentionDays','30') | Out-Null
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.OwnLog) | Should -BeFalse
    }

    It 'does NOT prune the deploy audit logs' {
        # regression: the old filter matched any _<stamp>.jsonl, so the drift runner
        # silently ate the deploy audit trail the wrappers write to the same folder
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile',$script:Targets,'-LogDir',$script:LogDir,'-LogRetentionDays','30') | Out-Null
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.DeployLog1) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.DeployLog2) | Should -BeTrue
    }

    It 'does not touch a stray file or a non-target processor log' {
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile',$script:Targets,'-LogDir',$script:LogDir,'-LogRetentionDays','30') | Out-Null
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.Stray)       | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:LogDir $script:Seeded.OtherTarget) | Should -BeTrue
    }

    It 'prunes nothing when retention is 0' {
        Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile',$script:Targets,'-LogDir',$script:LogDir,'-LogRetentionDays','0') | Out-Null
        foreach ($n in $script:Seeded.Values) {
            Test-Path -LiteralPath (Join-Path $script:LogDir $n) | Should -BeTrue
        }
    }
}

Describe 'exit code' {
    It 'exits 0 when every target matches its baseline' {
        $logDir = Join-Path $TestDrive ('dr-clean-{0}' -f ([guid]::NewGuid().ToString('N')))
        $r = Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile',$script:Targets,'-LogDir',$logDir,'-LogRetentionDays','0')
        $r.ExitCode | Should -Be 0
    }

    It 'exits 1 when a target has drifted' {
        $logDir = Join-Path $TestDrive ('dr-drift-{0}' -f ([guid]::NewGuid().ToString('N')))
        Set-Content -Path (Join-Path $script:Release 'app.txt') -Value 'CHANGED' -NoNewline
        try {
            $r = Invoke-VesScript 'Start-DriftRunner.ps1' @(
                '-TargetsFile',$script:Targets,'-LogDir',$logDir,'-LogRetentionDays','0')
            $r.ExitCode | Should -Be 1
        } finally {
            Set-Content -Path (Join-Path $script:Release 'app.txt') -Value 'hello' -NoNewline
        }
    }
}
