#Requires -Version 5.1
# In-process unit tests for the backup/rollback module surface:
#   Get-VesBackupSet          which folders count as a backup, and in what order
#   Stop-/Start-VesProcessorTarget   the stop/restart phase shared by deploy and rollback
#   Get-VesWorstExitCode      severity ordering (2 outranks 3, despite 3 -gt 2)

# Scheduled-task cmdlets ship with the ScheduledTasks module and are absent on some
# CI hosts. Mock requires the command to resolve, so those cases are gated. This has
# to sit at file scope: Pester evaluates -Skip during discovery, before BeforeAll.
$script:HasTaskCmdlets = [bool](Get-Command Disable-ScheduledTask -ErrorAction SilentlyContinue)

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    Import-Module (Join-Path (Get-VesRepoRoot) 'module\VesVerify.psm1') -Force
}

Describe 'Get-VesBackupSet' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'bset'
        $script:Src = New-VesTree (Join-Path $script:Root 'src')
        $script:BackupRoot = Join-Path $script:Root 'backups'
    }

    It 'returns an empty set for a BackupRoot that does not exist' {
        $set = @(Get-VesBackupSet -BackupRoot (Join-Path $script:Root 'nope') -Processor 'p1')
        $set.Count | Should -Be 0
    }

    It 'recognizes both the timestamped and the legacy date-only shape' {
        New-VesBackupFolder -BackupRoot $script:BackupRoot -Processor 'p1' -Stamp '20260801' -SourceTree $script:Src | Out-Null
        New-VesBackupFolder -BackupRoot $script:BackupRoot -Processor 'p1' -Stamp '20260802T131500' -SourceTree $script:Src | Out-Null
        $set = @(Get-VesBackupSet -BackupRoot $script:BackupRoot -Processor 'p1')
        $set.Count | Should -Be 2
        @($set | Where-Object { $_.StampKind -eq 'date' }).Count | Should -Be 1
        @($set | Where-Object { $_.StampKind -eq 'timestamp' }).Count | Should -Be 1
    }

    It 'orders newest first across both shapes' {
        $set = @(Get-VesBackupSet -BackupRoot $script:BackupRoot -Processor 'p1')
        $set[0].Name | Should -Match '^20260802T131500_'
    }

    It 'ranks a same-day timestamped backup above the same-day date-only one' {
        $root = Join-Path $script:Root 'sameday'
        New-VesBackupFolder -BackupRoot $root -Processor 'p2' -Stamp '20260803' -SourceTree $script:Src | Out-Null
        New-VesBackupFolder -BackupRoot $root -Processor 'p2' -Stamp '20260803T090000' -SourceTree $script:Src | Out-Null
        $set = @(Get-VesBackupSet -BackupRoot $root -Processor 'p2')
        $set[0].Name | Should -Be '20260803T090000_TT_p2'
    }

    It 'ignores folders belonging to another processor' {
        $root = Join-Path $script:Root 'mixed'
        New-VesBackupFolder -BackupRoot $root -Processor 'wanted' -Stamp '20260804T101500' -SourceTree $script:Src | Out-Null
        New-VesBackupFolder -BackupRoot $root -Processor 'other' -Stamp '20260804T101600' -SourceTree $script:Src | Out-Null
        $set = @(Get-VesBackupSet -BackupRoot $root -Processor 'wanted')
        $set.Count | Should -Be 1
        $set[0].Name | Should -Match '_wanted$'
    }

    It 'counts payload files only, excluding the sidecars and the config stash' {
        $root = Join-Path $script:Root 'counting'
        $dir = New-VesBackupFolder -BackupRoot $root -Processor 'p3' -Stamp '20260804T110000' -SourceTree $script:Src
        New-Item -ItemType Directory -Path (Join-Path $dir '_ves-config') -Force | Out-Null
        Set-Content -Path (Join-Path $dir '_ves-config\app.exe.config') -Value 'cfg' -NoNewline
        Set-Content -Path (Join-Path $dir 'backup-manifest.json') -Value '{}' -NoNewline
        $set = @(Get-VesBackupSet -BackupRoot $root -Processor 'p3')
        # New-VesTree writes exactly two files; sidecars and _ves-config must not count
        $set[0].FileCount | Should -Be 2
        $set[0].HasManifest | Should -BeTrue
        $set[0].SizeBytes | Should -BeGreaterThan 0
    }

    It 'reports HasRecord=false for a backup with no sidecar (the incomplete-backup signal)' {
        $root = Join-Path $script:Root 'norecord'
        New-VesBackupFolder -BackupRoot $root -Processor 'p4' -Stamp '20260804T120000' -SourceTree $script:Src -NoRecord | Out-Null
        $set = @(Get-VesBackupSet -BackupRoot $root -Processor 'p4')
        $set[0].HasRecord | Should -BeFalse
        $set[0].Record | Should -BeNullOrEmpty
    }

    It 'survives a malformed sidecar instead of throwing under StrictMode' {
        $root = Join-Path $script:Root 'badrecord'
        $dir = New-VesBackupFolder -BackupRoot $root -Processor 'p5' -Stamp '20260804T130000' -SourceTree $script:Src
        Set-Content -Path (Join-Path $dir 'rollback-record.json') -Value 'not json {{' -NoNewline
        { Get-VesBackupSet -BackupRoot $root -Processor 'p5' } | Should -Not -Throw
        $set = @(Get-VesBackupSet -BackupRoot $root -Processor 'p5')
        $set[0].HasRecord | Should -BeFalse
    }

    It 'yields exactly one entry for a single backup when wrapped in @()' {
        $root = Join-Path $script:Root 'single'
        New-VesBackupFolder -BackupRoot $root -Processor 'p6' -Stamp '20260804T140000' -SourceTree $script:Src | Out-Null
        $set = @(Get-VesBackupSet -BackupRoot $root -Processor 'p6')
        $set.Count | Should -Be 1
        $set[0].Name | Should -Be '20260804T140000_TT_p6'
    }

    It 'reads the record back for a backup that has one' {
        $root = Join-Path $script:Root 'withrecord'
        New-VesBackupFolder -BackupRoot $root -Processor 'p7' -Stamp '20260804T150000' -SourceTree $script:Src `
            -Record @{ replacedByCommit = 'deadbee'; priorReleaseTag = 'p7/v1.2.3' } | Out-Null
        $set = @(Get-VesBackupSet -BackupRoot $root -Processor 'p7')
        $set[0].HasRecord | Should -BeTrue
        $set[0].Record.replacedByCommit | Should -Be 'deadbee'
        $set[0].Record.priorReleaseTag | Should -Be 'p7/v1.2.3'
    }
}

Describe 'Get-VesWorstExitCode' {
    It 'returns 0 for an empty set' {
        Get-VesWorstExitCode -ExitCode @() | Should -Be 0
    }
    It 'ranks ERROR(2) above FAIL(3) even though 3 -gt 2' {
        Get-VesWorstExitCode -ExitCode @(3, 2) | Should -Be 2
        Get-VesWorstExitCode -ExitCode @(2, 3) | Should -Be 2
    }
    It 'ranks health(3) above drift(1), and usage(10) above everything' {
        Get-VesWorstExitCode -ExitCode @(1, 3) | Should -Be 3
        Get-VesWorstExitCode -ExitCode @(0, 1, 2, 3, 10) | Should -Be 10
    }
    It 'passes a clean run through' {
        Get-VesWorstExitCode -ExitCode @(0, 0) | Should -Be 0
    }
}

Describe 'Get-VesManifest empty tree' {
    It 'returns an empty object[] (not $null) for a directory with no files' {
        $empty = Join-Path $TestDrive 'empty-manifest-root'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $m = Get-VesManifest -ReleaseRoot $empty
        $null -eq $m | Should -BeFalse
        @($m).Count | Should -Be 0
    }

    It 'hashes and compares an empty manifest without parameter-binding errors' {
        $empty = Join-Path $TestDrive 'empty-manifest-compare'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        # Assign first, then wrap. `@($fn)` around a unary-comma empty return nests
        # the empty array as one element and breaks Compare-VesFiles.
        $m = Get-VesManifest -ReleaseRoot $empty
        $m = @($m)
        { Get-VesManifestHash -Manifest $m } | Should -Not -Throw
        $hash = Get-VesManifestHash -Manifest $m
        $hash | Should -Match '^[0-9a-f]{64}$'
        $diff = Compare-VesFiles -Baseline $m -ReleaseRoot $empty
        $diff.Match | Should -BeTrue
        $diff.Missing.Count | Should -Be 0
        $diff.Extra.Count | Should -Be 0
        $diff.Changed.Count | Should -Be 0
    }
}

Describe 'Stop-VesProcessorTarget' {
    BeforeAll {
        $script:Target = New-VesTree (Join-Path $TestDrive 'stoptarget')
    }

    It 'reports Stopped with nothing to do on a quiet target' {
        Mock -ModuleName VesVerify Get-CimInstance { @() }
        $r = Stop-VesProcessorTarget -TargetRoot $script:Target
        $r.Stopped | Should -BeTrue
        $r.DisabledTasks.Count | Should -Be 0
        $r.BlockingPids.Count | Should -Be 0
    }

    It 'blocks (Stopped=false) and reports the PID when an instance holds the target' {
        Mock -ModuleName VesVerify Get-CimInstance {
            [PSCustomObject]@{ ProcessId = 4242; ExecutablePath = (Join-Path $script:Target 'proc.exe'); CommandLine = 'proc.exe RTPDP' }
        }
        $r = Stop-VesProcessorTarget -TargetRoot $script:Target
        $r.Stopped | Should -BeFalse
        $r.BlockingPids | Should -Contain 4242
        $r.Errors -join ' ' | Should -Match '-KillProcesses'
    }

    It 'kills the instance and reports it when -KillProcesses is set' {
        Mock -ModuleName VesVerify Get-CimInstance {
            [PSCustomObject]@{ ProcessId = 4242; ExecutablePath = (Join-Path $script:Target 'proc.exe'); CommandLine = 'proc.exe RTPDP' }
        }
        Mock -ModuleName VesVerify Stop-Process { }
        Mock -ModuleName VesVerify Get-Process { }
        $r = Stop-VesProcessorTarget -TargetRoot $script:Target -KillProcesses
        $r.Stopped | Should -BeTrue
        $r.KilledPids | Should -Contain 4242
        Should -Invoke -ModuleName VesVerify Stop-Process -Times 1
    }

    It 'fails closed when a killed instance never releases its handles' {
        Mock -ModuleName VesVerify Get-CimInstance {
            [PSCustomObject]@{ ProcessId = 4242; ExecutablePath = (Join-Path $script:Target 'proc.exe'); CommandLine = 'proc.exe' }
        }
        Mock -ModuleName VesVerify Stop-Process { }
        Mock -ModuleName VesVerify Get-Process { [PSCustomObject]@{ Id = 4242 } }
        $r = Stop-VesProcessorTarget -TargetRoot $script:Target -KillProcesses -HandleWaitSeconds 0
        $r.Stopped | Should -BeFalse
        $r.Errors -join ' ' | Should -Match 'still alive'
    }

    It 'does not throw when the target root does not exist' {
        Mock -ModuleName VesVerify Get-CimInstance { @() }
        { Stop-VesProcessorTarget -TargetRoot (Join-Path $TestDrive 'missing-target') } | Should -Not -Throw
    }

    It 'records only the tasks it actually disabled, and stops at the first failure' -Skip:(-not $script:HasTaskCmdlets) {
        Mock -ModuleName VesVerify Get-CimInstance { @() }
        Mock -ModuleName VesVerify Disable-ScheduledTask { if ($TaskName -eq 'bad') { throw 'access denied' } }
        $r = Stop-VesProcessorTarget -TargetRoot $script:Target -ScheduledTasks @('good', 'bad', 'never')
        $r.Stopped | Should -BeFalse
        $r.DisabledTasks | Should -Be @('good')
        # 'never' must not be attempted after 'bad' failed
        Should -Invoke -ModuleName VesVerify Disable-ScheduledTask -Times 2
    }

    It 'reports ServiceStopped and never throws when the service stop fails' {
        Mock -ModuleName VesVerify Get-CimInstance { @() }
        Mock -ModuleName VesVerify Get-Service { [PSCustomObject]@{ Name = 'svc' } }
        Mock -ModuleName VesVerify Stop-Service { throw 'cannot stop' }
        $r = Stop-VesProcessorTarget -TargetRoot $script:Target -ServiceName 'svc'
        $r.Stopped | Should -BeFalse
        $r.ServiceStopped | Should -BeFalse
        $r.Errors -join ' ' | Should -Match 'Could not stop service'
    }
}

Describe 'Start-VesProcessorTarget' {
    It 're-enables exactly the tasks it was given, without starting them' -Skip:(-not $script:HasTaskCmdlets) {
        Mock -ModuleName VesVerify Enable-ScheduledTask { }
        Mock -ModuleName VesVerify Start-ScheduledTask { }
        $r = Start-VesProcessorTarget -DisabledTasks @('t1', 't2')
        $r.StartedTasks.Count | Should -Be 0
        Should -Invoke -ModuleName VesVerify Enable-ScheduledTask -Times 2
        Should -Invoke -ModuleName VesVerify Start-ScheduledTask -Times 0
    }

    It 'starts the tasks when -StartTasks is set' -Skip:(-not $script:HasTaskCmdlets) {
        Mock -ModuleName VesVerify Enable-ScheduledTask { }
        Mock -ModuleName VesVerify Start-ScheduledTask { }
        $r = Start-VesProcessorTarget -DisabledTasks @('t1') -StartTasks
        $r.StartedTasks | Should -Be @('t1')
    }

    It 'collects a restart failure instead of throwing' -Skip:(-not $script:HasTaskCmdlets) {
        Mock -ModuleName VesVerify Enable-ScheduledTask { throw 'nope' }
        { Start-VesProcessorTarget -DisabledTasks @('t1') } | Should -Not -Throw
        (Start-VesProcessorTarget -DisabledTasks @('t1')).Errors -join ' ' | Should -Match 'FAILED to re-enable'
    }

    It 'restarts the service and does nothing else when no tasks were disabled' {
        Mock -ModuleName VesVerify Get-Service { [PSCustomObject]@{ Name = 'svc' } }
        Mock -ModuleName VesVerify Start-Service { }
        $r = Start-VesProcessorTarget -ServiceName 'svc'
        $r.Errors.Count | Should -Be 0
        Should -Invoke -ModuleName VesVerify Start-Service -Times 1
    }
}
