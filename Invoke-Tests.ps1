#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the ves-verify Pester test suite. DEV-TIME ONLY.
.DESCRIPTION
    These tests are for the workstation/CI where ves-verify is developed. They are
    NOT meant to run on the legacy PS 5.1 production boxes. The suite needs Pester
    5.x (the in-box Pester 3.4 will not parse the tests); install it once with:

        Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck

    Run it under Windows PowerShell 5.1 (the target runtime) so the in-process and
    child-process tests exercise the same engine as production:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1

    Exit code is the number of failed tests (0 = all green), so it drops straight
    into CI later.
.PARAMETER Path
    Test path to run. Defaults to the tests\ folder next to this script.
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'tests')
)

$p5 = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending | Select-Object -First 1

if (-not $p5) {
    Write-Host 'ERROR: Pester 5.x is required and was not found.' -ForegroundColor Red
    Write-Host 'Install it with:' -ForegroundColor Yellow
    Write-Host '  Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 2
}

Import-Module $p5.Path -Force
Write-Host ("Using Pester {0} from {1}" -f $p5.Version, $p5.Path) -ForegroundColor Gray

$cfg = New-PesterConfiguration
$cfg.Run.Path         = $Path
$cfg.Run.PassThru     = $true
$cfg.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $cfg
exit $result.FailedCount
