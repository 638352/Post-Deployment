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
    param(
        [Parameter(Mandatory)][string]$Path,
        # content of app.txt, so two trees can be made deliberately different
        [string]$Marker = 'hello'
    )
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path 'bin') -Force | Out-Null
    Set-Content -Path (Join-Path $Path 'app.txt')      -Value $Marker   -NoNewline
    Set-Content -Path (Join-Path $Path 'bin\lib.dll')  -Value 'libdata' -NoNewline
    $Path
}

function New-VesAwsStub {
    # Fake `aws` on PATH. Answers ssm get-parameter for the names in -Parameters,
    # accepts any put-parameter, and fails like a real ParameterNotFound otherwise.
    # Every invocation is appended to -CallLog so a test can assert that no write
    # was issued -- "we did not touch the trust anchor" has to be provable, not
    # inferred from the absence of an error.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        # @{ '/ves/x/baseline-hash' = '<hash>' }
        [hashtable]$Parameters = @{},
        [string]$CallLog
    )
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('@echo off')
    # %* keeps the whole command line; the caller greps it for 'put-parameter'
    $lines.Add('if not "%VES_STUB_LOG%"=="" echo %*>>"%VES_STUB_LOG%"')
    # writes always succeed -- the point of the log is proving whether we called it
    $lines.Add('if "%~2"=="put-parameter" exit /b 0')
    foreach ($name in $Parameters.Keys) {
        # %~4 is the value of --name in `ssm get-parameter --name <x> ...`
        $lines.Add(('if "%~4"=="{0}" echo {1}& exit /b 0' -f $name, $Parameters[$name]))
    }
    $lines.Add('echo An error occurred (ParameterNotFound) 1>&2')
    $lines.Add('exit /b 254')
    $lines | Set-Content -Path (Join-Path $Path 'aws.cmd') -Encoding ascii

    if ($CallLog) {
        if (Test-Path -LiteralPath $CallLog) { Remove-Item -LiteralPath $CallLog -Force }
        $env:VES_STUB_LOG = $CallLog
    }
    $env:PATH = "$Path;$env:PATH"
    $Path
}

function Get-VesStubCalls {
    # Text of every stubbed aws invocation so far ('' when none were made).
    param([Parameter(Mandatory)][string]$CallLog)
    if (-not (Test-Path -LiteralPath $CallLog)) { return '' }
    (Get-Content -LiteralPath $CallLog -Raw)
}

function New-VesBackupFolder {
    # Build a deploy backup by hand, in either folder shape, with or without the
    # sidecars. Used to exercise the restore picker without running a deploy.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Processor,
        # 'yyyyMMddTHHmmss' (current shape) or 'yyyyMMdd' (legacy, still restorable)
        [Parameter(Mandatory)][string]$Stamp,
        [string]$Initials = 'TT',
        # tree copied in as the backup payload; omit for an empty backup
        [string]$SourceTree,
        [switch]$NoRecord,
        [hashtable]$Record = @{}
    )
    $dir = Join-Path $BackupRoot ("{0}_{1}_{2}" -f $Stamp, $Initials, $Processor)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if ($SourceTree) {
        robocopy $SourceTree $dir /E /NP /R:0 /W:0 | Out-Null
        $global:LASTEXITCODE = 0
    }
    if (-not $NoRecord) {
        $doc = [ordered]@{
            schema           = 'ves.rollback-record.v1'
            processor        = $Processor
            createdUtc       = (Get-Date).ToUniversalTime().ToString('o')
            createdBy        = "test@$env:COMPUTERNAME"
            initials         = $Initials
            sourceTargetRoot = ''
            priorSsm         = [ordered]@{ trustHash = $null; trustHashRead = $false; approvedCommit = $null; approvedCommitRead = $false; readError = $null }
        }
        foreach ($k in $Record.Keys) { $doc[$k] = $Record[$k] }
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path $dir 'rollback-record.json') -Encoding utf8
    }
    $dir
}

function Start-VesLockedInstance {
    # A real long-lived process whose ExecutablePath sits under $TargetRoot, the
    # way a deployed console EXE does. That path IS the instance identity, so a
    # copy of powershell.exe in the folder reproduces the file-lock case exactly.
    param([Parameter(Mandatory)][string]$TargetRoot)
    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    $exe = Join-Path $TargetRoot 'locked-instance.exe'
    Copy-Item -LiteralPath (Get-WinPowerShellPath) -Destination $exe -Force
    Start-Process -FilePath $exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300' -WindowStyle Hidden -PassThru
}
