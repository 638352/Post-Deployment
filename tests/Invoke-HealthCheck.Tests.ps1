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
}
