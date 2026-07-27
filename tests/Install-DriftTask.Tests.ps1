#Requires -Version 5.1
# Install-DriftTask.ps1 behavior tests. These are mock-driven so they validate
# task-registration logic without requiring admin rights or touching Task Scheduler.

BeforeAll {
  . (Join-Path $PSScriptRoot '_helpers.ps1')
  $script:InstallScript = Join-Path (Get-VesRepoRoot) 'Install-DriftTask.ps1'
}

Describe 'Install-DriftTask uninstall path' {
  It 'removes both runner and watchdog tasks when present' {
    Mock Get-ScheduledTask {
      [PSCustomObject]@{ TaskName = $TaskName }
    }
    Mock Unregister-ScheduledTask {}
    Mock Write-Host {}

    & $script:InstallScript -TaskName 'runner-task' -WatchdogTaskName 'watchdog-task' -Uninstall

    Should -Invoke Get-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'runner-task' }
    Should -Invoke Get-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'watchdog-task' }
    Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'runner-task' }
    Should -Invoke Unregister-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'watchdog-task' }
  }

  It 'skips unregister when tasks do not exist' {
    Mock Get-ScheduledTask { $null }
    Mock Unregister-ScheduledTask {}

    & $script:InstallScript -TaskName 'runner-task' -WatchdogTaskName 'watchdog-task' -Uninstall

    Should -Invoke Unregister-ScheduledTask -Times 0
  }
}

Describe 'Install-DriftTask validation' {
  It 'throws when IntervalMinutes is not positive' {
    { & $script:InstallScript -IntervalMinutes 0 } | Should -Throw 'IntervalMinutes must be greater than zero.'
  }

  It 'throws when HeartbeatMaxAgeMinutes is not greater than IntervalMinutes' {
    { & $script:InstallScript -IntervalMinutes 30 -HeartbeatMaxAgeMinutes 30 } |
    Should -Throw 'HeartbeatMaxAgeMinutes must be greater than IntervalMinutes.'
  }
}

Describe 'Install-DriftTask registration flow' {
  BeforeEach {
    $global:RegisteredTaskArgs = @{}
    $script:TargetsFile = Join-Path $TestDrive 'targets.json'
    $script:LogDir = Join-Path $TestDrive 'logs'

    Mock Test-Path {
      param($Path, $LiteralPath)
      $p = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path }
      # Simulate missing targets + missing log dir, but present script dependencies.
      if ($p -like '*targets.json') { return $false }
      if ($p -eq $script:LogDir) { return $false }
      return $true
    }
    Mock New-Item {}
    Mock Write-Warning {}
    Mock Write-Host {}
    Mock Register-ScheduledTask {
      param($TaskName, $Action)
      $global:RegisteredTaskArgs[$TaskName] = $Action.Arguments
      [PSCustomObject]@{ TaskName = $TaskName }
    }
  }

  It 'registers both scheduled tasks and warns when targets file is missing' {
    & $script:InstallScript -TaskName 'runner-task' -WatchdogTaskName 'watchdog-task' `
      -TargetsFile $script:TargetsFile -LogDir $script:LogDir -IntervalMinutes 30 -Environment 'qa'

    Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -match 'Targets file' }
    Should -Invoke New-Item -Times 1 -ParameterFilter { $ItemType -eq 'Directory' }
    Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'runner-task' }
    Should -Invoke Register-ScheduledTask -Times 1 -ParameterFilter { $TaskName -eq 'watchdog-task' }
  }

  It 'derives default heartbeat max age as three intervals (minimum 15)' {
    & $script:InstallScript -TaskName 'runner-task' -WatchdogTaskName 'watchdog-task' `
      -TargetsFile $script:TargetsFile -LogDir $script:LogDir -IntervalMinutes 10 -Environment 'qa'

    $global:RegisteredTaskArgs['watchdog-task'] | Should -Match '-MaxAgeMinutes 30'
  }

  It 'uses explicit HeartbeatMaxAgeMinutes when provided' {
    & $script:InstallScript -TaskName 'runner-task' -WatchdogTaskName 'watchdog-task' `
      -TargetsFile $script:TargetsFile -LogDir $script:LogDir -IntervalMinutes 30 -HeartbeatMaxAgeMinutes 95 -Environment 'qa'

    $global:RegisteredTaskArgs['watchdog-task'] | Should -Match '-MaxAgeMinutes 95'
  }
}
