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
    $script:CallLog = Join-Path $TestDrive 'aws-calls-rb.txt'

    # 'v1' is the good release we roll back TO; 'v2' is the bad one in production.
    $script:V1 = New-VesTree (Join-Path $script:Root 'v1') 'version-one'
    $script:V2 = New-VesTree (Join-Path $script:Root 'v2') 'version-two'

    # Manifest of v1, used as the post-rollback baseline for the happy path.
    $script:V1Manifest = Join-Path $script:Root 'v1-baseline.json'
    $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:V1, '-ManifestPath', $script:V1Manifest,
        '-Processor', 'rbtest', '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
    if ($cap.ExitCode -ne 0) { throw "v1 capture failed: $($cap.Output)" }
    $script:V1Hash = (Get-Content -LiteralPath $script:V1Manifest -Raw | ConvertFrom-Json).manifestHash

    # Manifest of v2 as well, purely so the stub can pin what production would pin.
    $script:V2Manifest = Join-Path $script:Root 'v2-baseline.json'
    $cap2 = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode', 'Capture', '-ReleaseRoot', $script:V2, '-ManifestPath', $script:V2Manifest,
        '-Processor', 'rbtest', '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
    if ($cap2.ExitCode -ne 0) { throw "v2 capture failed: $($cap2.Output)" }
    $script:V2Hash = (Get-Content -LiteralPath $script:V2Manifest -Raw | ConvertFrom-Json).manifestHash

    # The anchor pins V2 -- the release being rolled AWAY from. That is what
    # production actually looks like at rollback time: capture pins at UAT sign-off,
    # before the deploy, and nothing re-pins on the way back down.
    #
    # This fixture used to pin V1 (the release being restored), which is the inverse.
    # That inversion hid a real deadlock: with the pin naming V2, passing -TrustParam
    # to the post-rollback verify failed the restored V1 manifest against the wrong
    # anchor and returned exit 2 on a byte-perfect restore -- which then permanently
    # blocked -RepinTrust, since that is gated on the same verify passing.
    New-VesAwsStub -Path (Join-Path $TestDrive 'awsstub-rb') -CallLog $script:CallLog -Parameters @{
        '/ves/rbtest/baseline-hash'   = $script:V2Hash
        '/ves/rbtest/approved-commit' = 'newcommit'
        # A second anchor that DOES name the restored release, for the case where a
        # rollback is run after the pin has already been moved back.
        '/ves/rbtest/prior-baseline-hash' = $script:V1Hash
    } | Out-Null

    # Fresh target (holding the bad v2) + a backup of v1, per test.
    function script:New-Case([string]$Name, [hashtable]$Record = @{}, [switch]$NoRecord, [switch]$EmptyBackup) {
        $case = Join-Path $script:Root $Name
        $target = New-VesTree (Join-Path $case 'target') 'version-two'
        Set-Content -Path (Join-Path $target 'leftover-from-bad-release.txt') -Value 'junk' -NoNewline
        $backupRoot = Join-Path $case 'backups'
        $args = @{
            BackupRoot = $backupRoot; Processor = 'rbtest'
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
}

AfterAll {
    $env:PATH = $script:OrigPath
    $env:VES_STUB_LOG = $null
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
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-ManifestPath', $script:V1Manifest, '-TrustParam', '/ves/rbtest/baseline-hash'))
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
            '-Processor', 'rbtest', '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
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
            '-Processor', 'rbtest', '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @('-ManifestPath', $v2Manifest))
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Post-rollback verify failed'
    }

    It 'proves a good restore even though the live pin still names the release being rolled back' {
        # The regression this guards: -TrustParam was passed to the post-rollback
        # verify unconditionally, so the restored release's manifest was compared
        # against an anchor naming the FAILED release and a byte-perfect restore
        # exited 2. This is the README's documented operator command shape.
        $c = New-Case 'anchor-stale' -Record @{
            priorSsm = @{ trustHash = $script:V1Hash; trustHashRead = $true; approvedCommit = 'oldcommit'; approvedCommitRead = $true }
        }
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $script:V1Manifest, '-TrustParam', '/ves/rbtest/baseline-hash'))
        $r.ExitCode | Should -Be 0
        # and it says so, rather than quietly dropping the anchor
        $r.Output | Should -Match 'NOT SSM-anchored'
        $r.Output | Should -Match 'release being rolled back'
    }

    It 'still cross-checks SSM when the anchor genuinely names the restored release' {
        $c = New-Case 'anchor-fresh' -Record @{
            priorSsm = @{ trustHash = $script:V1Hash; trustHashRead = $true; approvedCommit = 'oldcommit'; approvedCommitRead = $true }
        }
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $script:V1Manifest, '-TrustParam', '/ves/rbtest/prior-baseline-hash'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'SSM-anchored'
        $r.Output | Should -Match 'Manifest trust verified against SSM'
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

Describe 'trust re-pin' {
    It 'refuses -RepinTrust when the backup recorded no prior value, and writes nothing to SSM' {
        $c = New-Case 'repin-norecord' -NoRecord
        Remove-Item -LiteralPath $script:CallLog -Force -ErrorAction SilentlyContinue
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-RepinTrust', '-TrustParam', '/ves/rbtest/baseline-hash'))
        $r.ExitCode | Should -Be 10
        $r.Output | Should -Match 'rollback-record.json'
        (Get-VesStubCalls $script:CallLog) | Should -Not -Match 'put-parameter'
    }

    It 'skips the re-pin (and writes nothing) when the post-rollback verify fails' {
        $c = New-Case 'repin-badverify' -Record @{
            priorSsm = @{ trustHash = $script:V1Hash; trustHashRead = $true; approvedCommit = 'oldcommit'; approvedCommitRead = $true }
        }
        $v2Manifest = Join-Path $c.Case 'v2.json'
        $cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode', 'Capture', '-ReleaseRoot', $script:V2, '-ManifestPath', $v2Manifest,
            '-Processor', 'rbtest', '-AllowUntrustedCapture', '-AllowUnarchivedCapture')
        $cap.ExitCode | Should -Be 0
        Remove-Item -LiteralPath $script:CallLog -Force -ErrorAction SilentlyContinue
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $v2Manifest, '-RepinTrust', '-TrustParam', '/ves/rbtest/baseline-hash'))
        # Exit 1: the restored v1 tree genuinely differs from the v2 manifest it was
        # verified against. The live pin names v2 (the release being rolled away
        # from), so it is correctly NOT used as the anchor -- the failure reported is
        # the real drift, not a trust error standing in for one.
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'NOT SSM-anchored'
        $r.Output | Should -Match 'TRUST RE-PIN SKIPPED'
        (Get-VesStubCalls $script:CallLog) | Should -Not -Match 'put-parameter'
    }

    It 're-pins BOTH the baseline hash and the approved commit on a proven restore' {
        $c = New-Case 'repin-ok' -Record @{
            priorSsm = @{ trustHash = $script:V1Hash; trustHashRead = $true; approvedCommit = 'oldcommit'; approvedCommitRead = $true }
        }
        Remove-Item -LiteralPath $script:CallLog -Force -ErrorAction SilentlyContinue
        $r = Invoke-VesScript 'Invoke-Rollback.ps1' (New-RollbackArgs $c @(
                '-ManifestPath', $script:V1Manifest, '-RepinTrust',
                '-TrustParam', '/ves/rbtest/baseline-hash', '-ApprovedCommitParam', '/ves/rbtest/approved-commit'))
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'TRUST RE-PIN COMPLETE'
        $calls = Get-VesStubCalls $script:CallLog
        $calls | Should -Match 'put-parameter'
        $calls | Should -Match '/ves/rbtest/baseline-hash'
        $calls | Should -Match '/ves/rbtest/approved-commit'
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
