#Requires -Version 5.1

BeforeAll {
  . (Join-Path $PSScriptRoot '_helpers.ps1')
}

Describe 'Invoke-HealthCheck' {
  It 'refuses to report healthy when no probe was configured' {
    $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @('-Json')
    $r.ExitCode | Should -Be 10
    $r.Output | Should -Match 'No health probes were configured'
  }

  It 'unexpected terminating error exits as health (3), not drift (1)' {
    # Probe is configured so we pass the usage gate; env forces the outer catch.
    $prev = $env:VES_HEALTH_FORCE_THROW
    $env:VES_HEALTH_FORCE_THROW = '1'
    try {
      $tmp = Join-Path $TestDrive 'health-force'
      New-Item -ItemType Directory -Path $tmp -Force | Out-Null
      $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
        '-FreshLogDir', $tmp, '-Json'
      )
      $r.ExitCode | Should -Be 3
      $r.ExitCode | Should -Not -Be 1
      $r.Output | Should -Match 'VES_HEALTH_FORCE_THROW'
    }
    finally {
      if ($null -eq $prev) { Remove-Item Env:VES_HEALTH_FORCE_THROW -ErrorAction SilentlyContinue }
      else { $env:VES_HEALTH_FORCE_THROW = $prev }
    }
  }
}

Describe 'multi-value arguments arriving over -File' {
    # Deploy-Processor and Invoke-Rollback launch this script as a `powershell.exe
    # -File` child, and -File cannot bind an array: repeating a named argument is
    # ParameterAlreadyBound (the child never runs at all) and `-X a,b` binds as ONE
    # string. VESEMSEGRESS02 and 03 each run two processors out of a shared folder
    # and so need two task names, which is what made this reachable in PROD.
    It 'probes two scheduled tasks separately rather than as one fused name' {
        # Neither task exists here, so both are reported missing -- the point is
        # that there are TWO findings under their own names, not one.
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-Processor', 'hctest',
            '-ScheduledTasks', 'VLER_EM_Real_Time_DBQ_Processor,VLER_EM_Real_Time_Outbound_Processor')
        $r.Output | Should -Not -Match 'specified more than once'
        $r.Output | Should -Match 'VLER_EM_Real_Time_DBQ_Processor'
        $r.Output | Should -Match 'VLER_EM_Real_Time_Outbound_Processor'
        $r.Output | Should -Not -Match ([regex]::Escape('VLER_EM_Real_Time_DBQ_Processor,VLER_EM_Real_Time_Outbound_Processor'))
        # a missing task is not health, and must not be reported as a pass
        $r.ExitCode | Should -Be 3
    }

    It 'counts a joined list as two probes, not one' {
        # $probeCount decides whether the run carries any evidence at all. If the
        # joined form were left unsplit a two-task processor would be under-counted,
        # which is the quiet half of this bug.
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @(
            '-Processor', 'hctest', '-Json',
            '-ScheduledTasks', 'Task_One,Task_Two')
        $r.Output | Should -Match 'Task_One'
        $r.Output | Should -Match 'Task_Two'
    }

    It 'still refuses a run with no probe configured at all' {
        # The joined-empty case must not accidentally look like a configured probe.
        $r = Invoke-VesScript 'Invoke-HealthCheck.ps1' @('-Processor', 'hctest')
        $r.ExitCode | Should -Be 10
    }
}
