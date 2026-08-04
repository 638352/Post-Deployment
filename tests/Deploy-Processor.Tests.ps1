#Requires -Version 5.1

BeforeAll {
  . (Join-Path $PSScriptRoot '_helpers.ps1')

  $script:Root = Join-Path $TestDrive 'deploy'
  $script:BackupRoot = Join-Path $script:Root 'backups'
  $script:TargetRoot = Join-Path $script:Root 'target'
  $script:LogFile = Join-Path $script:Root 'rollback.log'

  New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $script:TargetRoot -Force | Out-Null

  Set-Content -Path (Join-Path $script:TargetRoot 'current.txt') -Value 'live' -NoNewline
  $backupDir = Join-Path $script:BackupRoot '20260804_test_test'
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
  Set-Content -Path (Join-Path $backupDir 'restored.txt') -Value 'backup' -NoNewline
}

Describe 'Deploy-Processor rollback mode' {
  It 'restores the latest backup into the target tree' {
    $result = Invoke-VesScript 'Deploy-Processor.ps1' @(
      '-Processor', 'test',
      '-TargetRoot', $script:TargetRoot,
      '-BackupRoot', $script:BackupRoot,
      '-Rollback',
      '-LogFile', $script:LogFile)

    $result.ExitCode | Should -Be 0
    $result.Output | Should -Match 'Rollback complete'
    Test-Path -LiteralPath (Join-Path $script:TargetRoot 'restored.txt') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $script:TargetRoot 'current.txt') | Should -BeFalse
  }

  It 'rejects rollback-only parameters outside rollback mode' {
    $result = Invoke-VesScript 'Deploy-Processor.ps1' @(
      '-Processor', 'test',
      '-TargetRoot', $script:TargetRoot,
      '-RollbackBackup', (Join-Path $script:BackupRoot '20260804_test_test'),
      '-LogFile', $script:LogFile)

    $result.ExitCode | Should -Not -Be 0
    $result.Output | Should -Match 'Rollback-only parameters require -Rollback'
  }
}
