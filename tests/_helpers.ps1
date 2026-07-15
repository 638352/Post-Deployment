#Requires -Version 5.1
# Shared helpers for the e2e tests.
#   BeforeAll { . (Join-Path $PSScriptRoot '_helpers.ps1') }

function Get-VesRepoRoot {
    Split-Path -Parent $PSScriptRoot   # this file lives in <repo>\tests
}

function Get-WinPowerShellPath {
    $p = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $p)) { throw "powershell.exe not found at $p" }
    $p
}

function Invoke-VesScript {
    # The entry scripts end in `exit <code>`, and you can't read your own exit
    # code, so run them as a child powershell.exe and read the process code back.
    # Returns the exit code, the combined output text, and the -Json line parsed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$Arguments = @()
    )
    $full = Join-Path (Get-VesRepoRoot) $ScriptName
    if (-not (Test-Path -LiteralPath $full)) { throw "Script not found: $full" }

    $allArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $full) + $Arguments
    $out  = & (Get-WinPowerShellPath) @allArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)

    # with -Json the script prints one compressed JSON object among the log lines
    $json = $null
    $line = ($text -split "`r?`n" | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -Last 1)
    if ($line) { try { $json = $line | ConvertFrom-Json } catch { $json = $null } }

    [PSCustomObject]@{ ExitCode = $code; Output = $text; Json = $json }
}

function New-VesTree {
    # small release tree used as a capture/verify target
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path 'bin') -Force | Out-Null
    Set-Content -Path (Join-Path $Path 'app.txt')      -Value 'hello'   -NoNewline
    Set-Content -Path (Join-Path $Path 'bin\lib.dll')  -Value 'libdata' -NoNewline
    $Path
}
