#Requires -Version 5.1
<#
.DESCRIPTION
    Needs Pester 5.x; the in-box Pester 3.4 won't parse the tests. Install once:
        Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
    Run under Windows PowerShell 5.1 so the tests use the same engine as prod:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
    Exit code is the failed-test count (0 = green).
.PARAMETER Path
    Test path. Defaults to the tests\ folder next to this script.
#>
[CmdletBinding()]
param(
    [string]$Path
)

if (-not $Path) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Path = Join-Path $root 'tests'
}

$p5 = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending | Select-Object -First 1

if (-not $p5) {
    Write-Host 'Pester 5.x not found. Install it with:' -ForegroundColor Red
    Write-Host '  Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 2
}

Import-Module $p5.Path -Force
Write-Host ("Pester {0}" -f $p5.Version) -ForegroundColor Gray

$cfg = New-PesterConfiguration
$cfg.Run.Path         = $Path
$cfg.Run.PassThru     = $true
$cfg.Output.Verbosity = 'Detailed'

$result = Invoke-Pester -Configuration $cfg
exit $result.FailedCount
