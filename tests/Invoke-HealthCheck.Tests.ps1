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
