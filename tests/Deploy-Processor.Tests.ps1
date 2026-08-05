#Requires -Version 5.1
# Deploy-Processor.ps1 end-to-end: gate -> backup -> copy -> verify -> health, the
# console-EXE instance handling, the dated backup + rollback-record sidecar, the
# -Rollback alias, and -AutoRollback.
#
# Git baseline archive fixtures replace the old SSM stubs. The "running instance" is a real
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
    # Named <Processor>.json: that is the capture convention the archive stores
    # under, and the gate derives the archived leaf from this local name.
    $script:ManifestPath = Join-Path $script:Root 'dptest.json'

    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:Release,
        '-ManifestPath', $script:ManifestPath, '-Processor', 'dptest',
        '-CommitSha', 'abc1234', '-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "baseline capture failed: $($cap.Output)" }
    $script:TrustedHash = (Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json).manifestHash

    $script:OrigPath = $env:PATH
    # The trust anchor: the captured manifest committed under the release tag.
    # -StagedCommit below must equal the commitSha recorded in it (abc1234) --
    # that pairing IS the commit gate.
    $script:Archive = New-VesBaselineArchive -Path (Join-Path $script:Root 'archive') `
        -Processor 'dptest' -ManifestPath $script:ManifestPath -Tag 'dptest/v1.0.0'

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
            '-BaselineRepo', $script:Archive,
            '-ReleaseTag', 'dptest/v1.0.0',
            '-FreshLogDir', $script:FreshLogs
        ) + $Extra
    }

    # A target already holding a previous release, so a backup has something to take.
    # Its logs\ dir carries a fresh log line, which is what the liveness probe reads.
    # The staged tree has no logs\, so /MIR deletes it: the deploy then fails its
    # health check, and a rollback that really restored the tree passes it again.
    # (logs\ is excluded from the manifest by VES_DEFAULT_EXCLUDE, so file verify
    # is unaffected either way.)
    function script:New-LiveTarget([string]$Name) {
        $t = New-VesTree (Join-Path $script:Root $Name) 'previous-release'
        Set-Content -Path (Join-Path $t 'only-on-this-server.txt') -Value 'server-local' -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $t 'logs') -Force | Out-Null
        Set-Content -Path (Join-Path $t 'logs\today.log') -Value 'alive' -NoNewline
        $t
    }
}

AfterAll {
    $env:PATH = $script:OrigPath
    Remove-VesBaselineArchive -Path $script:Archive
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

    It 'does not cry DRIFT on a healthy deploy just because the pin names the incoming release' {
        # The anchor is pinned at capture (UAT sign-off), so during a normal deploy
        # it already describes the release being installed, not the one on disk.
        # Logging that expected mismatch as DRIFT fired on 100% of clean deploys and
        # trained operators to ignore the one word that means "production is wrong".
        $target = New-LiveTarget 'target-nodrift'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @(
                '-BackupRoot', (Join-Path $script:Root 'backups-nodrift')))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'Pre-deploy tree does NOT match'
        $r.Output | Should -Match 'as expected before a deploy'
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
        $rec.baselineRepo | Should -Be $script:Archive
    }

    It 'records the hash of the incoming release, so a rollback can tell what replaced this backup' {
        $rec = Get-Content -LiteralPath (Join-Path $script:BkDir.FullName 'rollback-record.json') -Raw | ConvertFrom-Json
        $rec.incomingManifestHash | Should -Be $script:TrustedHash
        $rec.replacedByReleaseTag | Should -Be 'dptest/v1.0.0'
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
        # 2, not 1: nothing was compared and production was not touched, so the
        # honest answer is "could not proceed" (ERROR), not "production drifted".
        $r.ExitCode | Should -Be 2
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
    # The deploy deletes the target's logs\ dir (the staged tree has none), so the
    # liveness probe fails after the copy and passes again once the tree is restored.
    function script:New-AutoArgs([string]$Target, [string]$Backups, [string[]]$Extra = @()) {
        @('-Processor', 'dptest', '-StagedRoot', $script:Staged, '-TargetRoot', $Target,
            '-StagedCommit', 'abc1234', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'dptest/v1.0.0',
            '-BackupRoot', $Backups, '-FreshLogDir', (Join-Path $Target 'logs')) + $Extra
    }

    It 'is opt-in: without it a failed health check leaves the new release in place' {
        $target = New-LiveTarget 'target-noauto'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-AutoArgs $target (Join-Path $script:Root 'backups-noauto'))
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Not -Match 'AUTO-ROLLBACK'
        # the new release is still there: nothing was reverted
        (Get-Content -LiteralPath (Join-Path $target 'app.txt') -Raw) | Should -Be 'hello'
    }

    It 'restores the prior release on a health failure, and still reports the deploy as failed' {
        $target = New-LiveTarget 'target-auto'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-AutoArgs $target (Join-Path $script:Root 'backups-auto') @('-AutoRollback'))
        # the failing stage's code, never 0: rolling back is remediation, not success
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'AUTO-ROLLBACK COMPLETE'
        # prior release is back, including the server-only file /MIR had deleted
        (Get-Content -LiteralPath (Join-Path $target 'app.txt') -Raw) | Should -Be 'previous-release'
        Test-Path (Join-Path $target 'only-on-this-server.txt') | Should -BeTrue
        # and no restore-point bookkeeping leaked into production
        Test-Path (Join-Path $target 'rollback-record.json') | Should -BeFalse
        Test-Path (Join-Path $target 'backup-manifest.json') | Should -BeFalse
    }

    It 'says RESTORED BUT UNPROVEN (exit 2) when the restore lands but cannot prove itself' {
        $target = New-LiveTarget 'target-auto-unproven'
        # health probe points at a directory that stays empty whatever we restore,
        # so the rollback's own health check fails after a good copy
        $dead = Join-Path $script:Root 'logs-empty'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' @(
            '-Processor', 'dptest', '-StagedRoot', $script:Staged, '-TargetRoot', $target,
            '-StagedCommit', 'abc1234', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'dptest/v1.0.0',
            '-BackupRoot', (Join-Path $script:Root 'backups-unproven'), '-FreshLogDir', $dead, '-AutoRollback')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'AUTO-ROLLBACK RESTORED BUT UNPROVEN'
        # the copy DID happen -- that is the distinction the message draws
        (Get-Content -LiteralPath (Join-Path $target 'app.txt') -Raw) | Should -Be 'previous-release'
    }

    It 'exits 2 when there was no backup to restore from' {
        # brand-new target: nothing to back up, so auto-rollback has no restore point
        $target = Join-Path $script:Root 'target-auto-nobackup-taken'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' @(
            '-Processor', 'dptest', '-StagedRoot', $script:Staged, '-TargetRoot', $target,
            '-StagedCommit', 'abc1234', '-ManifestPath', $script:ManifestPath,
            '-BaselineRepo', $script:Archive, '-ReleaseTag', 'dptest/v1.0.0',
            '-BackupRoot', (Join-Path $script:Root 'backups-none'), '-FreshLogDir', $script:DeadLogs, '-AutoRollback')
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'AUTO-ROLLBACK UNAVAILABLE'
    }

    It 'refuses a BackupRoot nested inside TargetRoot before it can eat its own restore point' {
        $target = New-LiveTarget 'target-nested-backup'
        $r = Invoke-VesScript 'Deploy-Processor.ps1' (New-DeployArgs $target @('-BackupRoot', (Join-Path $target 'BackUp')))
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'overlap'
        $r.Output | Should -Not -Match 'pre-deploy gate'
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
