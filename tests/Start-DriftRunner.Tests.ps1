#Requires -Version 5.1
# Start-DriftRunner.ps1 inventory validation, heartbeat, exit contract, and log
# housekeeping. SSM is stubbed so the target remains trust-anchored.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    Import-Module (Join-Path (Get-VesRepoRoot) 'module\VesVerify.psm1') -Force

    # one real target so the runner has something to verify and its logs to prune
    $script:Release  = New-VesTree (Join-Path $TestDrive 'dr-release')
    $script:Manifest = Join-Path $TestDrive 'dr-baseline.json'
    $script:TrustedHash = Export-VesManifest -Manifest (Get-VesManifest -ReleaseRoot $script:Release) `
        -Path $script:Manifest -Processor 'alpha'

    $script:StubDir = Join-Path $TestDrive 'awsstub-drift'
    New-Item -ItemType Directory -Path $script:StubDir -Force | Out-Null
    @(
        '@echo off'
        ('if "%~4"=="/ves/alpha/baseline-hash" echo {0}& exit /b 0' -f $script:TrustedHash)
        'echo An error occurred (ParameterNotFound) 1>&2'
        'exit /b 254'
    ) | Set-Content -Path (Join-Path $script:StubDir 'aws.cmd') -Encoding ascii
    $script:OrigPath = $env:PATH
    $env:PATH = "$($script:StubDir);$env:PATH"

    # the runner always calls Invoke-Verification -Mode All, which hard-requires the
    # config params -- omitting them would exit 10 (usage), not 0. Reuse the json
    # fixtures the Verify-Config tests already prove pass together.
    $script:Targets = Join-Path $TestDrive 'dr-targets.json'
    [PSCustomObject]@{
        schema = 'ves.targets.v1'
        inventoryComplete = $true
        requiredServers = @('test-server')
        targets = @(
            [PSCustomObject]@{
                processor      = 'alpha'
                server         = 'test-server'
                environment    = 'qa'
                inventoryStatus= 'confirmed'
                releaseTag     = 'alpha/v1.0.0'
                releaseRoot    = $script:Release
                manifestPath   = $script:Manifest
                trustParam     = '/ves/alpha/baseline-hash'
                configContract = (Join-Path $PSScriptRoot 'fixtures\json\contract.json')
                configPath     = (Join-Path $PSScriptRoot 'fixtures\json\config.json')
            }
        )
    } | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:Targets -Encoding utf8
}

AfterAll {
    $env:PATH = $script:OrigPath
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

    It 'fails closed when the inventory is not explicitly complete' {
        $badInventory = Join-Path $TestDrive 'dr-incomplete-targets.json'
        $doc = Get-Content -LiteralPath $script:Targets -Raw | ConvertFrom-Json
        $doc.inventoryComplete = $false
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $badInventory -Encoding utf8
        $logDir = Join-Path $TestDrive ('dr-incomplete-{0}' -f ([guid]::NewGuid().ToString('N')))
        $r = Invoke-VesScript 'Start-DriftRunner.ps1' @(
            '-TargetsFile',$badInventory,'-LogDir',$logDir,'-LogRetentionDays','0')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'inventoryComplete'
    }

    It 'writes a completion heartbeat even when drift is found' {
        $logDir = Join-Path $TestDrive ('dr-heartbeat-{0}' -f ([guid]::NewGuid().ToString('N')))
        $heartbeat = Join-Path $logDir 'heartbeat.json'
        Set-Content -Path (Join-Path $script:Release 'app.txt') -Value 'CHANGED' -NoNewline
        try {
            $r = Invoke-VesScript 'Start-DriftRunner.ps1' @(
                '-TargetsFile',$script:Targets,'-LogDir',$logDir,
                '-HeartbeatPath',$heartbeat,'-LogRetentionDays','0')
            $r.ExitCode | Should -Be 1
            $hb = Get-Content -LiteralPath $heartbeat -Raw | ConvertFrom-Json
            $hb.schema   | Should -Be 'ves.drift-heartbeat.v1'
            $hb.outcome  | Should -Be 'FAIL'
            $hb.exitCode | Should -Be 1
        } finally {
            Set-Content -Path (Join-Path $script:Release 'app.txt') -Value 'hello' -NoNewline
        }
    }
}
