#Requires -Version 5.1
# Shared helpers for the end-to-end tests. Dot-source from a test's BeforeAll:
#     BeforeAll { . (Join-Path $PSScriptRoot '_helpers.ps1') }
#
# The entry scripts are top-level param() scripts that call exit, so the only
# faithful way to assert the exit-code contract (0/1/2/3/10) is to run each one
# as a child process and read its real process exit code. We deliberately launch
# Windows PowerShell 5.1 (powershell.exe), the target runtime, not pwsh.

function Get-VesRepoRoot {
    # this file lives in <repo>\tests
    Split-Path -Parent $PSScriptRoot
}

function Get-WinPowerShellPath {
    $p = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $p)) { throw "Windows PowerShell 5.1 not found at $p" }
    $p
}

function Invoke-VesScript {
    <#
      Runs <repo>\<ScriptName> under Windows PowerShell 5.1 with the given args and
      returns a result object:
        .ExitCode  the child process exit code (the contract under test)
        .Output    full combined stdout+stderr text (human log lines + JSON)
        .Json      the parsed -Json result object, or $null if none / unparseable
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$Arguments = @()
    )
    $full  = Join-Path (Get-VesRepoRoot) $ScriptName
    if (-not (Test-Path -LiteralPath $full)) { throw "Script under test not found: $full" }
    $psExe = Get-WinPowerShellPath

    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $full) + $Arguments
    $out  = & $psExe @allArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)

    # The scripts print human log lines ("[ts] LEVEL msg") plus, with -Json, a
    # single compressed JSON object. Pull the last brace-wrapped line and parse it.
    $json = $null
    $jsonLine = ($text -split "`r?`n" | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -Last 1)
    if ($jsonLine) { try { $json = $jsonLine | ConvertFrom-Json } catch { $json = $null } }

    [PSCustomObject]@{ ExitCode = $code; Output = $text; Json = $json }
}

function New-VesTree {
    # Create a small release tree under a fresh directory; returns its path.
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path 'bin') -Force | Out-Null
    Set-Content -Path (Join-Path $Path 'app.txt')      -Value 'hello' -NoNewline
    Set-Content -Path (Join-Path $Path 'bin\lib.dll')  -Value 'libdata' -NoNewline
    $Path
}
