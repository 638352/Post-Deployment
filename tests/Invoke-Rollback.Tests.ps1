#Requires -Version 5.1
# Invoke-Rollback.ps1 end-to-end. Every case runs the script as a child process
# and reads the real exit code back, because the exit-code contract IS the
# interface an operator and a scheduled runner both read.
#
# The dangerous cases (empty backup, partial backup, nested BackupRoot) assert
# that TargetRoot is untouched, not just that the exit code is right: the point
# of those gates is that nothing happens.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root = Join-Path $TestDrive 'rb'
    $script:OrigPath = $env:PATH

    # 'v1' is the good release we roll back TO; 'v2' is the bad one in production.
    $script:V1 = New-VesTree (Join-Path $script:Root 'v1') 'version-one'
    $script:V2 = New-VesTree (Join-Path $script:Root 'v2') 'version-two'

    # Manifest of v1, used as the post-rollback baseline for the happy path.
    $script:V1Manifest = Join-Path $script:Root 'v1-baseline.json'
    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:V1, '-ManifestPath', $script:V1Manifest,
        '-Processor', 'rbtest', '-CommitSha', 'testcommit1', '-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "v1 capture failed: $($cap.Output)" }
    $script:V1Hash = (Get-Content -LiteralPath $script:V1Manifest -Raw | ConvertFrom-Json).manifestHash

    # Manifest of v2 as well, purely so the stub can pin what production would pin.
    $script:V2Manifest = Join-Path $script:Root 'v2-baseline.json'
    $cap2 = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:V2, '-ManifestPath', $script:V2Manifest,
        '-Processor', 'rbtest', '-CommitSha', 'testcommit1', '-AllowUnarchivedCapture')
    if ($cap2.ExitCode -ne 0) { throw "v2 capture failed: $($cap2.Output)" }
    $script:V2Hash = (Get-Content -LiteralPath $script:V2Manifest -Raw | ConvertFrom-Json).manifestHash

    # The archive holds BOTH releases under their own tags: v1.0.0 (the release
    # being restored) and v2.0.0 (the one being rolled away from). Verifying the
    # restore against v1's tag is the correct pairing; the old SSM fixture proved
    # what happens when a restore is checked against the wrong release's anchor.
    $script:Archive = New-VesBaselineArchive -Path (Join-Path $script:Root 'archive') `
        -Processor 'rbtest' -ManifestPath $script:V1Manifest -Tag 'rbtest/v1.0.0'
    New-VesBaselineArchive -Path $script:Archive `
        -Processor 'rbtest' -ManifestPath $script:V2Manifest -Tag 'rbtest/v2.0.0' | Out-Null

    # Fresh target (holding the bad v2) + a backup of v1, per test.
    # -Processor defaults to 'rbtest', which is what every pre-existing case uses.
    # The database-coupled gate keys on the processor NAME, so those cases need the
    # backup folder named for the real unit instead.
    function script:New-Case([string]$Name, [hashtable]$Record = @{}, [switch]$NoRecord, [switch]$EmptyBackup, [string]$Processor = 'rbtest') {
        $case = Join-Path $script:Root $Name
        $target = New-VesTree (Join-Path $case 'target') 'version-two'
        Set-Content -Path (Join-Path $target 'leftover-from-bad-release.txt') -Value 'junk' -NoNewline
        $backupRoot = Join-Path $case 'backups'
        $args = @{
            BackupRoot = $backupRoot; Processor = $Processor
            Stamp      = '20260804T120000'; Initials = 'RH'
            Record     = $Record
        }
        if (-not $EmptyBackup) { $args['SourceTree'] = $script:V1 }
        if ($NoRecord) { $args['NoRecord'] = $true }
        $backupDir = New-VesBackupFolder @args
        [PSCustomObject]@{ Case = $case; Target = $target; BackupRoot = $backupRoot; BackupDir = $backupDir }
    }

    # -SkipHealth by default: Invoke-HealthCheck refuses to report a pass when no
    # probes are configured (exit 10), so a case that is not about health has to
    # opt out of it explicitly. The health case below passes a real probe instead.
    function script:New-RollbackArgs($c, [string[]]$Extra = @()) {
        @('-Processor', 'rbtest', '-TargetRoot', $c.Target, '-BackupRoot', $c.BackupRoot,
            '-Reason', 'pester', '-SkipHealth') + $Extra
    }

    # Same shape, but for the one database-coupled unit.
    function script:New-CoupledArgs($c, [string[]]$Extra = @()) {
        @('-Processor', 'InboundHandler', '-TargetRoot', $c.Target, '-BackupRoot', $c.BackupRoot,
            '-Reason', 'pester', '-SkipHealth') + $Extra
    }
}

AfterAll {
    $env:PATH = $script:OrigPath
    Remove-VesBaselineArchive -Path $script:Archive
}

Describe '-ListBackups' {
    It 'lists both name shapes newest first, exits 0, and changes nothing' {
        $c = New-Case 'list'
        New-VesBackupFolder -BackupRoot $c.BackupRoot -Processor 'rbtest' -Stamp '20260801' -SourceTree $script:V1 | Out-Null
        $before = (Get-ChildItem -LiteralPath $c.Target -Recurse -File).Count
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' @('-Processor', 'rbtest', '-BackupRoot', $c.BackupRoot, '-ListBackups')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match '20260804T120000_RH_rbtest'
        $r.Output | Should -Match '20260801_TT_rbtest'
        (Get-ChildItem -LiteralPath $c.Target -Recurse -File).Count | Should -Be $before
    }

    It 'exits 0 with a warning when there is nothing to list' {
        $empty = Join-Path $script:Root 'nolist'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' @('-Processor', 'rbtest', '-BackupRoot', $empty, '-ListBackups')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'No backups found'
    }
}

Describe 'restore fidelity' {
    It 'mirrors the backup back, removes the bad release files, and leaves no sidecars behind' {
        $c = New-Case 'fidelity'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-BaselineRepo', $script:Archive, '-ReleaseTag', 'rbtest/v1.0.0'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Rollback complete'
        # restored content
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
        # /MIR removed what the bad release added
        Test-Path (Join-Path $c.Target 'leftover-from-bad-release.txt') | Should -BeFalse
        # our own bookkeeping must never land in production
        Test-Path (Join-Path $c.Target 'rollback-record.json') | Should -BeFalse
        Test-Path (Join-Path $c.Target 'backup-manifest.json') | Should -BeFalse
        Test-Path (Join-Path $c.Target '_ves-config') | Should -BeFalse
    }

    It 'restores a specific backup with -BackupDir instead of the newest' {
        $c = New-Case 'pick'
        # a NEWER backup holding different content: picking by -BackupDir must ignore it
        $newer = New-VesBackupFolder -BackupRoot $c.BackupRoot -Processor 'rbtest' -Stamp '20260805T120000' -SourceTree $script:V2
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-BackupDir', $c.BackupDir, '-ManifestPath', $script:V1Manifest))
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
        $newer | Should -Not -BeNullOrEmpty
    }

    It 'picks the newest backup when none is named' {
        $c = New-Case 'newest'
        New-VesBackupFolder -BackupRoot $c.BackupRoot -Processor 'rbtest' -Stamp '20260805T120000' -SourceTree $script:V2 | Out-Null
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-AllowUnverifiedRollback'))
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
    }
}

Describe 'safety gates (nothing may happen)' {
    It 'refuses an empty backup rather than wiping production' {
        $c = New-Case 'emptybackup' -EmptyBackup
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c)
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'would wipe production'
        # production untouched
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
        Test-Path (Join-Path $c.Target 'leftover-from-bad-release.txt') | Should -BeTrue
    }

    It 'refuses a partial backup (fewer files than its own manifest claims)' {
        $c = New-Case 'partial'
        # write a manifest claiming the tree is bigger than what is on disk
        $fake = [ordered]@{ schema = 'ves.manifest.v1'; processor = 'rbtest'; commitSha = 'x'
            capturedUtc = '2026-08-04T00:00:00Z'; capturedBy = 't'; manifestHash = 'x'
            fileCount = 99; files = @()
        }
        ($fake | ConvertTo-Json -Depth 5) | Out-File -FilePath (Join-Path $c.BackupDir 'backup-manifest.json') -Encoding utf8
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Partial backup'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
    }

    It 'refuses a BackupRoot nested inside TargetRoot (the mirror would eat the source)' {
        $c = New-Case 'nested'
        $nestedRoot = Join-Path $c.Target 'BackUp'
        New-VesBackupFolder -BackupRoot $nestedRoot -Processor 'rbtest' -Stamp '20260804T130000' -SourceTree $script:V1 | Out-Null
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' @(
            '-Processor', 'rbtest', '-TargetRoot', $c.Target, '-BackupRoot', $nestedRoot, '-Reason', 'pester')
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'overlap'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
    }

    It 'requires -Reason (validated in-body, so it never prompts on stdin)' {
        $c = New-Case 'noreason'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' @('-Processor', 'rbtest', '-TargetRoot', $c.Target, '-BackupRoot', $c.BackupRoot)
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match '-Reason is required'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
    }

    It 'exits 2 when no backup exists at all' {
        $c = New-Case 'nobackup'
        Remove-Item -LiteralPath $c.BackupDir -Recurse -Force
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'nothing to roll back to'
    }

    It 'changes nothing under -WhatIf' {
        $c = New-Case 'whatif'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-WhatIf'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'WhatIf: would restore'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
        Test-Path (Join-Path $c.Target 'leftover-from-bad-release.txt') | Should -BeTrue
    }
}

Describe 'database-coupled rollback gate' {
    # InboundHandler's release is half database: the 4.7 procedures take parameters
    # the prior binaries do not pass, so a file-only restore is a broken state. The
    # gate refuses the operator path and lets the automated one through with the
    # debt recorded -- blocking auto-rollback would strand production on the failed
    # release, which is worse.
    It 'refuses a file-only restore of a coupled unit, and touches nothing' {
        $c = New-Case 'coupled-refuse' -Processor 'InboundHandler'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-CoupledArgs $c)
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'database-coupled'
        $r.Output | Should -Match 'REVERSE of the rollout order'
        # production untouched: the gate runs before a backup is even chosen
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
        Test-Path (Join-Path $c.Target 'leftover-from-bad-release.txt') | Should -BeTrue
    }

    # Two contradictory claims about a database the script cannot query. Caught with
    # the other usage gates rather than resolved by branch order, which would have
    # let the confirming switch win and erase the debt the caller also asked for.
    It 'refuses both SQL switches at once rather than picking one' {
        $c = New-Case 'coupled-both' -Processor 'InboundHandler'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' `
            (New-CoupledArgs $c @('-ConfirmedSqlRollbackComplete', '-SqlRollbackDeferred'))
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'contradict each other'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
    }

    # The fixture's sidecar carries no baselineRepo/priorReleaseTag and the backup
    # has no backup-manifest.json, so every restore below is unprovable and exits 2
    # (NO-BASELINE) by the contract at the top of this file. That is the documented
    # outcome, not an incidental one -- pin it, or a regression that changed the
    # coupled path's exit code would satisfy these tests unnoticed.
    It 'restores the files when the operator confirms the SQL rollback ran' {
        $c = New-Case 'coupled-confirmed' -Processor 'InboundHandler'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-CoupledArgs $c @('-ConfirmedSqlRollbackComplete'))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Operator confirms the SQL rollback ran'
        $r.Output | Should -Not -Match 'DATABASE ROLLBACK STILL OWED'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
    }

    It 'restores under -SqlRollbackDeferred and records the debt as a machine-readable field' {
        $c = New-Case 'coupled-deferred' -Processor 'InboundHandler'
        $log = Join-Path $c.Case 'deferred.jsonl'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-CoupledArgs $c @('-SqlRollbackDeferred', '-LogFile', $log))
        $r.ExitCode | Should -Be 2
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
        $r.Output | Should -Match 'SQL ROLLBACK NOT DONE'
        # Outside the attested/not-attested branch on purpose: this run is NOT
        # attested (exit 2) and the debt is still real, so the banner must fire.
        $r.Output | Should -Match 'DATABASE ROLLBACK STILL OWED'
        # the debt is machine-readable, not just prose in the console
        $records = @(Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object { $_.PSObject.Properties['sqlRollbackOwed'] -and $_.sqlRollbackOwed }).Count |
            Should -BeGreaterThan 0
        # ... and it reaches the RUN END record, which is what a log consumer reads
        $runEnd = @($records | Where-Object { $_.msg -match 'RUN END' })[-1]
        $runEnd.sqlRollbackOwed | Should -BeTrue
    }

    # -WhatIf changed nothing, so it owes nothing. The refusal must still happen
    # (the operator needs to learn the unit is coupled), but a dry run must not
    # leave a debt record implying a half-finished rollback sitting in production.
    It 'records no debt for a -WhatIf run, which restored nothing' {
        $c = New-Case 'coupled-whatif' -Processor 'InboundHandler'
        $log = Join-Path $c.Case 'whatif.jsonl'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' `
            (New-CoupledArgs $c @('-SqlRollbackDeferred', '-WhatIf', '-LogFile', $log))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match 'DATABASE ROLLBACK STILL OWED'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
        $records = @(Get-Content -LiteralPath $log | ForEach-Object { $_ | ConvertFrom-Json })
        $runEnd = @($records | Where-Object { $_.msg -match 'RUN END' })[-1]
        $runEnd.sqlRollbackOwed | Should -BeFalse
    }

    It 'leaves an uncoupled processor exactly as it was (regression guard)' {
        $c = New-Case 'coupled-none'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c)
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Not -Match 'database-coupled'
        $r.Output | Should -Not -Match 'SQL ROLLBACK NOT DONE'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
    }
}

Describe 'post-rollback proof' {
    It 'exits 2 when no baseline describes the restored release' {
        $c = New-Case 'noproof' -NoRecord
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c)
        # the files ARE restored -- we just cannot prove the result
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
        $r.Output | Should -Match 'POST-ROLLBACK VERIFY UNAVAILABLE'
        $r.ExitCode | Should -Be 2
    }

    It 'exits 0 for the same case with -AllowUnverifiedRollback' {
        $c = New-Case 'noproof-allowed' -NoRecord
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-AllowUnverifiedRollback'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'POST-ROLLBACK VERIFY SKIPPED'
    }

    It 'warns but still verifies against the backup own manifest when the deploy wrote one' {
        $c = New-Case 'ownmanifest'
        # a real backup-manifest for the v1 payload, as Deploy-Processor writes
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode', 'Capture', '-ReleaseRoot', $script:V1,
            '-ManifestPath', (Join-Path $c.BackupDir 'backup-manifest.json'),
            '-Processor', 'rbtest', '-CommitSha', 'testcommit1', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'not that that state was approved'
    }

    It 'exits 1 when the restored tree does not match the supplied baseline' {
        $c = New-Case 'drift'
        # verify the restored v1 tree against the v2 manifest: a real drift result
        $v2Manifest = Join-Path $c.Case 'v2.json'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode', 'Capture', '-ReleaseRoot', $script:V2, '-ManifestPath', $v2Manifest,
            '-Processor', 'rbtest', '-CommitSha', 'testcommit1', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-ManifestPath', $v2Manifest))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Post-rollback verify failed'
    }

    It 'proves a good restore against the PRIOR release tag, not the failed release''s baseline' {
        # The trap this guards (inherited from the SSM era): a restore verified
        # against the anchor of the release being rolled AWAY from exits 2 on a
        # byte-perfect restore. -ReleaseTag on a rollback must name the release
        # being RESTORED -- here v1 -- and the archive holds v2 as well, so a
        # regression that grabs "the latest" tag would fail this case.
        $c = New-Case 'anchor-prior'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-BaselineRepo', $script:Archive, '-ReleaseTag', 'rbtest/v1.0.0'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'anchored to rbtest/v1\.0\.0'
    }

    It 'reports drift when the restore is verified against the wrong release''s tag' {
        # The inverse pairing, kept as a test so the failure mode stays visible:
        # v1 bits checked against v2's baseline must fail as drift, never pass.
        $c = New-Case 'anchor-wrong'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-BaselineRepo', $script:Archive, '-ReleaseTag', 'rbtest/v2.0.0'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Post-rollback verify failed'
    }

    It 'exits 3 when the restore is clean but the processor is not healthy' {
        $c = New-Case 'health'
        $emptyLogs = Join-Path $c.Case 'logs-empty'
        New-Item -ItemType Directory -Path $emptyLogs -Force | Out-Null
        # a real probe (an empty log dir = no fresh log line = not alive), so the
        # health check actually runs rather than being skipped
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' @(
            '-Processor', 'rbtest', '-TargetRoot', $c.Target, '-BackupRoot', $c.BackupRoot, '-Reason', 'pester',
            '-ManifestPath', $script:V1Manifest, '-FreshLogDir', $emptyLogs)
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'Rollback complete'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
    }
}

Describe 'config restore' {
    It 'restores an out-of-tree config from the backup stash' {
        $c = New-Case 'cfg'
        $cfg = Join-Path $c.Case 'live\app.exe.config'
        New-Item -ItemType Directory -Path (Split-Path -Parent $cfg) -Force | Out-Null
        Set-Content -Path $cfg -Value 'new-bad-config' -NoNewline
        $stash = Join-Path $c.BackupDir '_ves-config'
        New-Item -ItemType Directory -Path $stash -Force | Out-Null
        Set-Content -Path (Join-Path $stash 'app.exe.config') -Value 'old-good-config' -NoNewline

        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $script:V1Manifest, '-ConfigPath', $cfg))
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $cfg -Raw) | Should -Be 'old-good-config'
        # the config it replaced is kept, so the rollback is itself reversible
        (Get-Content -LiteralPath (Join-Path $stash 'pre-rollback\app.exe.config') -Raw) | Should -Be 'new-bad-config'
    }

    It 'keeps the live config with -NoConfigRestore' {
        $c = New-Case 'cfg-keep'
        $cfg = Join-Path $c.Case 'live\app.exe.config'
        New-Item -ItemType Directory -Path (Split-Path -Parent $cfg) -Force | Out-Null
        Set-Content -Path $cfg -Value 'server-specific' -NoNewline
        $stash = Join-Path $c.BackupDir '_ves-config'
        New-Item -ItemType Directory -Path $stash -Force | Out-Null
        Set-Content -Path (Join-Path $stash 'app.exe.config') -Value 'old-good-config' -NoNewline

        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $script:V1Manifest, '-ConfigPath', $cfg, '-NoConfigRestore'))
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $cfg -Raw) | Should -Be 'server-specific'
    }

    It 'protects an in-tree config from the mirror with -NoConfigRestore' {
        $c = New-Case 'cfg-intree'
        $cfg = Join-Path $c.Target 'app.exe.config'
        Set-Content -Path $cfg -Value 'server-specific' -NoNewline
        # the backup carries a different copy of the same file
        Set-Content -Path (Join-Path $c.BackupDir 'app.exe.config') -Value 'backup-config' -NoNewline

        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $script:V1Manifest, '-ConfigPath', $cfg, '-NoConfigRestore'))
        $r.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $cfg -Raw) | Should -Be 'server-specific'
    }
}

Describe 'post-rollback attestation' {
    # Replaced the SSM 'trust re-pin' cases. The safety property those cases
    # guarded is preserved: nothing is ever asserted about a tree whose
    # verification did not pass. What changed is the action -- there is no pin to
    # rewrite; the run attests and names the operator work still required.

    It 'makes no claim about production when the post-rollback verify fails' {
        $c = New-Case 'attest-badverify'
        # verify the restored v1 bits against v2's tag: genuine drift, exit 1
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-BaselineRepo', $script:Archive, '-ReleaseTag', 'rbtest/v2.0.0'))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'RESTORE NOT ATTESTED'
        $r.Output | Should -Not -Match 'RESTORED RELEASE ATTESTED'
    }

    It 'attests a proven restore and names the archive re-point the operator still owes' {
        $c = New-Case 'attest-ok'
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-BaselineRepo', $script:Archive, '-ReleaseTag', 'rbtest/v1.0.0'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'RESTORED RELEASE ATTESTED'
        # the message must carry the instruction, not assume the operator knows
        $r.Output | Should -Match 're-point the approved release tag'
    }
}

Describe 'running console-EXE instance' {
    AfterEach {
        if ($script:LockProc -and -not $script:LockProc.HasExited) {
            Stop-Process -Id $script:LockProc.Id -Force -ErrorAction SilentlyContinue
        }
        $script:LockProc = $null
    }

    It 'refuses to restore over a live instance without -KillProcesses' {
        $c = New-Case 'locked'
        $script:LockProc = Start-VesLockedInstance $c.Target
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-ManifestPath', $script:V1Manifest))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'Could not quiesce'
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-two'
        $script:LockProc.HasExited | Should -BeFalse
    }

    It 'kills the instance and restores with -KillProcesses' {
        $c = New-Case 'locked-kill'
        $script:LockProc = Start-VesLockedInstance $c.Target
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $script:V1Manifest, '-KillProcesses'))
        $r.ExitCode | Should -Be 0
        $script:LockProc.HasExited | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $c.Target 'app.txt') -Raw) | Should -Be 'version-one'
    }
}
