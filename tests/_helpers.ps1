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

# New-VesAwsStub / Get-VesStubCalls used to fabricate an `aws.cmd` on PATH so the
# SSM trust anchor could be exercised. There is no AWS in this environment, so
# those tests were asserting against the stub rather than against any real
# behaviour. They are gone; the anchor is now a real git archive built by
# New-VesBaselineArchive below, which needs no faking.

function New-VesBaselineArchive {
    # A real baseline archive repo: the manifest committed under a release tag.
    # This IS the trust anchor the gate, verification, preflight and the drift
    # runner all read, so tests exercise the true mechanism end to end.
    # Returns the repo path; pass it as -BaselineRepo.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Processor,
        # Manifest file to archive (the capture output).
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Tag
    )
    $dest = Join-Path $Path ("baselines\{0}" -f $Processor)
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $leaf = Join-Path $dest ("{0}.json" -f $Processor)
    # Checked copy, and then TOUCH the leaf. The flake this kills: Copy-Item
    # preserves the SOURCE's mtime, two fixture manifests are the same byte
    # length and were captured within the same wall-clock second, and git on
    # Windows compares index mtimes at whole-second granularity -- so replacing
    # the leaf between archive calls looked stat-identical, `git add` staged
    # nothing, commit said "working tree clean", and the OLD release got tagged
    # with the NEW tag. Bumping the mtime to now forces git to re-read the file.
    $srcHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
    $tries = 0
    while ($true) {
        try {
            Copy-Item -LiteralPath $ManifestPath -Destination $leaf -Force -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $leaf -Algorithm SHA256).Hash -eq $srcHash) { break }
        } catch {}
        if (++$tries -ge 10) { throw "New-VesBaselineArchive: could not copy $ManifestPath into the archive after $tries tries" }
        Start-Sleep -Milliseconds 200
    }
    (Get-Item -LiteralPath $leaf).LastWriteTimeUtc = [DateTime]::UtcNow
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        & git -C $Path init -q . 2>&1 | Out-Null
        & git -C $Path config user.email 'test@ves.local'
        & git -C $Path config user.name 'ves tests'
        # No background maintenance in a test fixture: a post-commit gc can hold
        # index.lock just long enough to make the NEXT archive call's `git add`
        # fail, which silently tags the wrong commit (observed as a flake).
        & git -C $Path config gc.auto 0
        & git -C $Path config maintenance.auto false
    }
    # Every step checked. A helper that can fail partway produces a tag pointing
    # at the wrong baseline -- the exact corruption the anchor exists to catch --
    # so retry the lock-prone steps briefly and then fail LOUDLY, never quietly.
    foreach ($step in @(
            @('add', '-A'),
            @('commit', '-qm', ("baseline {0}" -f $Tag)),
            @('tag', $Tag))) {
        $tries = 0
        do {
            $out = & git -C $Path @step 2>&1
            if ($LASTEXITCODE -eq 0) { break }
            $tries++
            Start-Sleep -Milliseconds 200
        } while ($tries -lt 5)
        if ($LASTEXITCODE -ne 0) {
            # Dump enough state to diagnose: what git thinks changed, what is
            # committed at HEAD for this leaf, and the bytes on disk right now.
            $siblings = Get-ChildItem -LiteralPath (Split-Path -Parent $ManifestPath) -Filter '*.json' -ErrorAction SilentlyContinue |
                ForEach-Object { "  sibling {0}: {1}  mtime={2:o}" -f $_.Name, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.Substring(0, 12), $_.LastWriteTimeUtc }
            $diag = @(
                "status: " + ((& git -C $Path status --porcelain 2>&1) -join ' ; ')
                "log: " + ((& git -C $Path log --oneline --decorate 2>&1) -join ' ; ')
                "leaf-on-disk: " + (Get-FileHash -LiteralPath $leaf -Algorithm SHA256).Hash.Substring(0, 12)
                "src-manifest:  " + (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash.Substring(0, 12)
                "src-content: " + ((Get-Content -LiteralPath $ManifestPath -Raw) -replace '\s+', ' ')
            ) + $siblings -join "`n"
            throw ("New-VesBaselineArchive: git {0} failed after {1} tries: {2}`n{3}" -f ($step -join ' '), $tries, ($out | Out-String), $diag)
        }
    }
    # Prove the tag serves the manifest we were given, byte-for-byte semantics
    # (compare the recorded manifestHash, which ignores BOM/EOL differences).
    $archived = (& git -C $Path show ("{0}:baselines/{1}/{1}.json" -f $Tag, $Processor)) -join "`n"
    $wantHash = (Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json).manifestHash
    $gotHash = ($archived -replace '^\xEF\xBB\xBF|^﻿', '' | ConvertFrom-Json).manifestHash
    if ($gotHash -ne $wantHash) {
        throw ("New-VesBaselineArchive: tag {0} serves manifestHash {1}, expected {2} -- the archive is corrupt, do not run tests against it." -f $Tag, $gotHash, $wantHash)
    }
    $Path
}

function Remove-VesBaselineArchive {
    # git writes loose objects read-only; Pester's TestDrive teardown does a plain
    # Delete() and fails the whole container on them even when every test passed.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.IsReadOnly = $false } catch {} }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
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
            incomingManifestHash = $null
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
