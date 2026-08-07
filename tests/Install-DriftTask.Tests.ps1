#Requires -Version 5.1
# Install-DriftTask.ps1 contract checks with elevation-aware behavior.

BeforeAll {
  . (Join-Path $PSScriptRoot '_helpers.ps1')

  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $script:IsElevated = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

  $script:InstallScript = Join-Path (Get-VesRepoRoot) 'Install-DriftTask.ps1'
}

Describe 'elevation guard' {
  It 'fails with explicit guidance when not running elevated' -Skip:$script:IsElevated {
    $r = Invoke-VesScript 'Install-DriftTask.ps1' @(
      '-TargetsFile', (Join-Path $TestDrive 'targets.json'),
      '-LogDir', (Join-Path $TestDrive 'logs'))

    $r.ExitCode | Should -Not -Be 0
    $r.Output | Should -Match 'must run elevated'
  }
}

Describe 'parameter and uninstall behavior (elevated only)' -Skip:(-not $script:IsElevated) {
  BeforeEach {
    Mock -CommandName Get-ScheduledTask -MockWith {
      param([string]$TaskName)
      if ($TaskName -in @('ves-verify-drift', 'ves-verify-drift-watchdog')) {
        [pscustomobject]@{ TaskName = $TaskName }
      }
    }
    Mock -CommandName Unregister-ScheduledTask {}
    Mock -CommandName New-VesLogFile { Join-Path $TestDrive 'install-drift-task.jsonl' }
    Mock -CommandName Write-VesLog {}
    Mock -CommandName Write-Host {}

    Mock -CommandName New-ScheduledTaskAction {}
    Mock -CommandName New-ScheduledTaskTrigger {}
    Mock -CommandName New-ScheduledTaskPrincipal {}
    Mock -CommandName New-ScheduledTaskSettingsSet {}
    Mock -CommandName Register-ScheduledTask {}
  }

  It 'throws on non-positive IntervalMinutes before registration calls' {
    { & $script:InstallScript -IntervalMinutes 0 -TargetsFile (Join-Path $TestDrive 'targets.json') -LogDir (Join-Path $TestDrive 'logs') } |
    Should -Throw 'IntervalMinutes must be greater than zero.'

    Assert-MockCalled Register-ScheduledTask -Times 0 -Exactly
  }

  It 'uninstall removes both runner and watchdog tasks when present' {
    & $script:InstallScript -Uninstall -TaskName 'ves-verify-drift' -WatchdogTaskName 'ves-verify-drift-watchdog' -LogDir (Join-Path $TestDrive 'logs')

    Assert-MockCalled Get-ScheduledTask -Times 2
    Assert-MockCalled Unregister-ScheduledTask -Times 2
    Assert-MockCalled Write-VesLog -Times 2
  }
}
