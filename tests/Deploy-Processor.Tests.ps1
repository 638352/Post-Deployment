#Requires -Version 5.1
# Deploy-Processor.ps1 end-to-end: gate -> backup -> copy -> verify -> health, the
# console-EXE instance handling, the dated backup + rollback-record sidecar, the
# -Rollback alias, and -AutoRollback.
#
# SSM is stubbed with a fake aws.cmd on PATH. The "running instance" is a real
# process: powershell.exe copied INTO the target dir and started there, so its
# ExecutablePath sits under TargetRoot exactly like a deployed processor exe.
#
# Health probes are always supplied: Invoke-HealthCheck refuses to report a pass
# when nothing is configured, so a probe-less deploy would exit 10 on every case.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root = Join-Path $TestDrive 'dp'
    $script:Release = New-VesTree (Join-Path $script:Root 'release')
    $script:Staged = New-VesTree (Join-Path $script:Root 'staged')   # identical tree = same manifest hash
    $script:ManifestPath = Join-Path $script:Root 'baseline.json'

    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:Release,
        '-ManifestPath', $script:ManifestPath, '-Processor', 'dptest',
        '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "baseline capture failed: $($cap.Output)" }
    $script:TrustedHash = (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json).manifestHash

    $script:OrigPath = $env:PATH
    $script:CallLog = Join-Path $TestDrive 'aws-calls-dp.txt'
    New-VesAwsStub -Path (Join-Path $TestDrive 'awsstub-dp') -CallLog $script:CallLog -Parameters @{
        '/ves/dptest/approved-commit' = 'abc1234'
        '/ves/dptest/baseline-hash'   = $script:TrustedHash
    } | Out-Null

    # A log dir with a file written just now: the fresh-log liveness probe passes.
    $script:FreshLogs = Join-Path $script:Root 'logs-fresh'
    New-Item -ItemType Directory -Path $script:FreshLogs -Force | Out-Null
    Set-Content -Path (Join-Path $script:FreshLogs 'today.log') -Value 'alive' -NoNewline

    # Empty log dir: the same probe fails, which is how a health failure is forced.
    $script:DeadLogs = Join-Path $script:Root 'logs-empty'
    New-Item -ItemType Directory -Path $script:DeadLogs -Force | Out-Null

    function script:New-DeployArgs([string]$TargetRoot, [string[]]$Extra = @()) {
        @(
            '-Processor', 'dptest',
            '-StagedRoot', $script:Staged,
            '-TargetRoot', $TargetRoot,
            '-StagedCommit', 'abc1234',
            '-ManifestPath', $script:ManifestPath,
            '-TrustParam', '/ves/dptest/baseline-hash',
            '-ApprovedCommitParam', '/ves/dptest/approved-commit',
            '-FreshLogDir', $script:FreshLogs
        ) + $Extra
    }

    # A target already holding a previous release, so a backup has something to take.
    function script:New-LiveTarget([string]$Name) {
        $t = New-VesTree (Join-Path $script:Root $Name) 'previous-release'
        Set-Content -Path (Join-Path $t 'only-on-this-server.txt') -Value 'server-local' -NoNewline
        $t
    }
}

AfterAll {
    $env:PATH = $script:OrigPath
    $env:VES_STUB_LOG = $null
}

Describe 'clean deploy' {
    It 'runs gate -> copy -> verify -> health and exits 0' {
        $target = Join-Path $script:Root 'target-clean'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'DEPLOY COMPLETE'
        Test-Path (Join-Path $target 'bin\lib.dll') | Should -BeTrue
    }

    It 'gate-only with -WhatIf, target untouched' {
        $target = Join-Path $script:Root 'target-whatif'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-WhatIf'))
        $r.ExitCode | Should -Be 0
        Test-Path $target | Should -BeFalse
    }

    It 'accepts -BackupRoot on a deploy (it is how the restore point gets created)' {
        $target = New-LiveTarget 'target-backup-accepted'
        $backups = Join-Path $script:Root 'backups-accepted'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-BackupRoot', $backups))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'Rollback-only parameters'
    }
}

Describe 'backup and rollback record' {
    BeforeAll {
        $script:BkTarget = New-LiveTarget 'target-backup'
        $script:BkRoot = Join-Path $script:Root 'backups'
        $script:BkResult = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $script:BkTarget @('-BackupRoot', $script:BkRoot))
        $script:BkDir = @(Get-ChildItem -LiteralPath $script:BkRoot -Directory)[0]
    }

    It 'deploys cleanly and leaves exactly one backup folder' {
        $script:BkResult.ExitCode | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:BkRoot -Directory).Count | Should -Be 1
    }

    It 'names the backup with a time, not just a date, so a same-day redeploy cannot clobber it' {
        $script:BkDir.Name | Should -Match '^\d{8}T\d{6}_.+_dptest$'
    }

    It 'captures the tree that was replaced, including the server-only file the mirror deleted' {
        (Get-Content -LiteralPath (Join-Path $script:BkDir.FullName 'app.txt') -Raw) | Should -Be 'previous-release'
        Test-Path (Join-Path $script:BkDir.FullName 'only-on-this-server.txt') | Should -BeTrue
        # and /MIR did remove it from production, which is why the backup matters
        Test-Path (Join-Path $script:BkTarget 'only-on-this-server.txt') | Should -BeFalse
    }

    It 'writes a rollback-record.json describing what it replaced' {
        $rec = Get-Content -LiteralPath (Join-Path $script:BkDir.FullName 'rollback-record.json') -Raw | ConvertFrom-Json
        $rec.schema | Should -Be 'ves.rollback-record.v1'
        $rec.processor | Should -Be 'dptest'
        $rec.replacedByCommit | Should -Be 'abc1234'
        $rec.sourceTargetRoot | Should -Be $script:BkTarget
        $rec.trustParam | Should -Be '/ves/dptest/baseline-hash'
    }

    It 'records the SSM values that were in force before this release' {
        $rec = Get-Content -LiteralPath (Join-Path $script:BkDir.FullName 'rollback-record.json') -Raw | ConvertFrom-Json
        $rec.priorSsm.trustHashRead | Should -BeTrue
        $rec.priorSsm.trustHash | Should -Be $script:TrustedHash
        $rec.priorSsm.approvedCommitRead | Should -BeTrue
        $rec.priorSsm.approvedCommit | Should -Be 'abc1234'
    }

    It 'writes a backup-manifest.json of the pre-deploy tree' {
        $mf = Get-Content -LiteralPath (Join-Path $script:BkDir.FullName 'backup-manifest.json') -Raw | ConvertFrom-Json
        $mf.schema | Should -Be 'ves.manifest.v1'
        $mf.fileCount | Should -BeGreaterThan 0
    }

    It 'prunes across both folder shapes, keeping the newest N' {
        $root = Join-Path $script:Root 'backups-prune'
        $target = New-LiveTarget 'target-prune'
        # seed a mix of legacy date-only and current timestamped folders
        foreach ($s in @('20260701', '20260702T090000', '20260703', '20260704T090000')) {
            New-VesBackupFolder -BackupRoot $root -Processor 'dptest' -Stamp $s -SourceTree $script:Release | Out-Null
        }
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-BackupRoot', $root, '-KeepBackups', '2'))
        $r.ExitCode | Should -Be 0
        $kept = @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name)
        $kept.Count | Should -Be 2
        # the deploy's own brand-new backup and the newest seeded one survive
        $kept[0].Name | Should -Be '20260704T090000_TT_dptest'
    }
}

Describe 'running console-EXE instance' {
    AfterEach {
        # never leave a sleeper behind, even when an assertion failed
        if ($script:LockProc -and -not $script:LockProc.HasExited) {
            Stop-Process -Id $script:LockProc.Id -Force -ErrorAction SilentlyContinue
        }
        $script:LockProc = $null
    }

    It 'aborts (state restored, no copy) when an instance holds the target and -KillProcesses is not set' {
        $target = Join-Path $script:Root 'target-locked'
        $script:LockProc = Start-VesLockedInstance $target
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target)
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Running instance holds'
        $r.Output | Should -Match '-KillProcesses'
        # no copy happened: the staged files never landed
        Test-Path (Join-Path $target 'bin\lib.dll') | Should -BeFalse
        # and the instance was left alone
        $script:LockProc.HasExited | Should -BeFalse
    }

    It 'kills the instance (audited) and deploys when -KillProcesses is set' {
        $target = Join-Path $script:Root 'target-kill'
        $script:LockProc = Start-VesLockedInstance $target
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-KillProcesses'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match ('Killing running instance PID {0}' -f $script:LockProc.Id)
        $r.Output | Should -Match 'DEPLOY COMPLETE'
        $script:LockProc.HasExited | Should -BeTrue
        # /MIR removed the foreign exe and the staged tree is in place
        Test-Path (Join-Path $target 'locked-instance.exe') | Should -BeFalse
        Test-Path (Join-Path $target 'bin\lib.dll') | Should -BeTrue
    }
}

Describe '-AutoRollback' {
    It 'is opt-in: without it a failed health check leaves the new release in place' {
        $target = New-LiveTarget 'target-noauto'
        $backups = Join-Path $script:Root 'backups-noauto'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' @(
            '-Processor', 'dptest', '-StagedRoot', $script:Staged, '-TargetRoot', $target,
            '-StagedCommit', 'abc1234', '-ManifestPath', $script:ManifestPath,
            '-TrustParam', '/ves/dptest/baseline-hash', '-ApprovedCommitParam', '/ves/dptest/approved-commit',
            '-BackupRoot', $backups, '-FreshLogDir', $script:DeadLogs)
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Not -Match 'AUTO-ROLLBACK'
        # the new release is still there: nothing was reverted
        (Get-Content -LiteralPath (Join-Path $target 'app.txt') -Raw) | Should -Be 'hello'
    }

    It 'restores the prior release on a health failure, and still reports the deploy as failed' {
        $target = New-LiveTarget 'target-auto'
        $backups = Join-Path $script:Root 'backups-auto'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' @(
            '-Processor', 'dptest', '-StagedRoot', $script:Staged, '-TargetRoot', $target,
            '-StagedCommit', 'abc1234', '-ManifestPath', $script:ManifestPath,
            '-TrustParam', '/ves/dptest/baseline-hash', '-ApprovedCommitParam', '/ves/dptest/approved-commit',
            '-BackupRoot', $backups, '-FreshLogDir', $script:DeadLogs, '-AutoRollback')
        # the failing stage's code, never 0: rolling back is remediation, not success
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'AUTO-ROLLBACK COMPLETE'
        # prior release is back, including the server-only file /MIR had deleted
        (Get-Content -LiteralPath (Join-Path $target 'app.txt') -Raw) | Should -Be 'previous-release'
        Test-Path (Join-Path $target 'only-on-this-server.txt') | Should -BeTrue
        # and no restore-point bookkeeping leaked into production
        Test-Path (Join-Path $target 'rollback-record.json') | Should -BeFalse
    }

    It 'exits 2 with INDETERMINATE when the restore itself cannot succeed' {
        $target = New-LiveTarget 'target-auto-broken'
        $backups = Join-Path $script:Root 'backups-auto-broken'
        # Point the restore at a backup root the deploy cannot use: BackupRoot under
        # TargetRoot means the mirror would eat its own source, so rollback refuses.
        $nested = Join-Path $target 'BackUp'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' @(
            '-Processor', 'dptest', '-StagedRoot', $script:Staged, '-TargetRoot', $target,
            '-StagedCommit', 'abc1234', '-ManifestPath', $script:ManifestPath,
            '-TrustParam', '/ves/dptest/baseline-hash', '-ApprovedCommitParam', '/ves/dptest/approved-commit',
            '-BackupRoot', $nested, '-FreshLogDir', $script:DeadLogs, '-AutoRollback')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'AUTO-ROLLBACK FAILED'
        $r.Output | Should -Match 'INDETERMINATE'
        $backups | Should -Not -BeNullOrEmpty
    }

    It 'refuses -AutoRollback without -BackupRoot, before the gate runs' {
        $target = Join-Path $script:Root 'target-auto-nobackup'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-AutoRollback'))
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match '-AutoRollback requires -BackupRoot'
        # the gate never ran
        $r.Output | Should -Not -Match 'pre-deploy gate'
    }
}

Describe '-Rollback alias' {
    It 'restores the latest backup into the target tree' {
        $target = New-LiveTarget 'target-alias'
        $backups = Join-Path $script:Root 'backups-alias'
        $deploy = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-BackupRoot', $backups))
        $deploy.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $target 'app.txt') -Raw) | Should -Be 'hello'

        $r = Invoke-VesScript 'Deploy-Processor.ps1' @(
            '-Processor', 'dptest', '-TargetRoot', $target, '-BackupRoot', $backups,
            '-Rollback', '-RollbackReason', 'pester alias check')
        $r.Output | Should -Match 'Rollback complete'
        (Get-Content -LiteralPath (Join-Path $target 'app.txt') -Raw) | Should -Be 'previous-release'
        Test-Path (Join-Path $target 'only-on-this-server.txt') | Should -BeTrue
    }

    It 'rejects rollback-only parameters outside rollback mode' {
        $target = Join-Path $script:Root 'target-alias-misuse'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-RollbackBackup', $script:Root))
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'Rollback-only parameters require -Rollback'
    }
}
