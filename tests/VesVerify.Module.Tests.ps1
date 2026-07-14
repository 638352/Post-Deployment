#Requires -Version 5.1
# Unit tests for module\VesVerify.psm1 — the pure, side-effect-light functions.
# No AWS / host / network dependency; everything runs against a TestDrive tree.
# Pester 5.x.

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\VesVerify.psm1'
    Import-Module $script:ModulePath -Force

    # Build a small tree under TestDrive with a mix of kept and excluded files.
    # Exclusions per the module default: any path segment logs\ temp\ cache\ .git\,
    # or a file ending .log .tmp .config.
    $script:Tree = Join-Path $TestDrive 'release'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'bin')  -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'logs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree '.git') -Force | Out-Null

    Set-Content -Path (Join-Path $script:Tree 'keep1.txt')      -Value 'alpha' -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'bin\keep2.dll')  -Value 'beta'  -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'app.config')     -Value 'drop-config' -NoNewline  # excluded (.config)
    Set-Content -Path (Join-Path $script:Tree 'trace.log')      -Value 'drop-log'    -NoNewline  # excluded (.log)
    Set-Content -Path (Join-Path $script:Tree 'scratch.tmp')    -Value 'drop-tmp'    -NoNewline  # excluded (.tmp)
    Set-Content -Path (Join-Path $script:Tree 'logs\run.txt')   -Value 'drop-logsdir' -NoNewline # excluded (\logs\)
    Set-Content -Path (Join-Path $script:Tree '.git\HEAD')      -Value 'drop-git'    -NoNewline  # excluded (\.git\)
}

Describe 'Get-VesManifest' {
    BeforeAll { $script:Manifest = Get-VesManifest -ReleaseRoot $script:Tree }

    It 'includes only the non-excluded files' {
        $rels = $script:Manifest.RelPath
        $rels | Should -Contain 'keep1.txt'
        $rels | Should -Contain 'bin/keep2.dll'
        $rels.Count | Should -Be 2
    }

    It 'excludes .config / .log / .tmp / logs\ / .git\ paths' {
        $rels = $script:Manifest.RelPath
        $rels | Should -Not -Contain 'app.config'
        $rels | Should -Not -Contain 'trace.log'
        $rels | Should -Not -Contain 'scratch.tmp'
        $rels | Should -Not -Contain 'logs/run.txt'
        $rels | Should -Not -Contain '.git/HEAD'
    }

    It 'emits forward-slash relative paths (no absolute, no backslash)' {
        foreach ($e in $script:Manifest) {
            $e.RelPath | Should -Not -Match '\\'
            $e.RelPath | Should -Not -Match '^[A-Za-z]:'
        }
    }

    It 'returns entries sorted by RelPath' {
        $rels = @($script:Manifest.RelPath)
        $sorted = @($rels | Sort-Object)
        ($rels -join '|') | Should -Be ($sorted -join '|')
    }

    It 'records a SHA-256 hash and byte length per file' {
        $keep1 = $script:Manifest | Where-Object RelPath -eq 'keep1.txt'
        $keep1.Sha256 | Should -Match '^[0-9A-F]{64}$'
        $keep1.Bytes  | Should -Be 5   # 'alpha'
    }

    It 'throws when the release root does not exist' {
        { Get-VesManifest -ReleaseRoot (Join-Path $TestDrive 'nope') } | Should -Throw
    }
}

Describe 'Get-VesManifestHash' {
    BeforeAll { $script:M = Get-VesManifest -ReleaseRoot $script:Tree }

    It 'is deterministic for the same input' {
        (Get-VesManifestHash -Manifest $script:M) | Should -Be (Get-VesManifestHash -Manifest $script:M)
    }

    It 'is independent of input ordering (function sorts internally)' {
        $reversed = @($script:M | Sort-Object RelPath -Descending)
        (Get-VesManifestHash -Manifest $reversed) | Should -Be (Get-VesManifestHash -Manifest $script:M)
    }

    It 'changes when a file hash changes' {
        $baseline = Get-VesManifestHash -Manifest $script:M
        $mutated  = $script:M | ForEach-Object { [PSCustomObject]@{ RelPath=$_.RelPath; Sha256=$_.Sha256; Bytes=$_.Bytes } }
        $mutated[0].Sha256 = ('0' * 64)
        (Get-VesManifestHash -Manifest $mutated) | Should -Not -Be $baseline
    }
}

Describe 'Export-VesManifest / Import-VesManifest' {
    BeforeEach {
        $script:M   = Get-VesManifest -ReleaseRoot $script:Tree
        $script:Out = Join-Path $TestDrive ('manifest-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        $script:Pinned = Export-VesManifest -Manifest $script:M -Path $script:Out -CommitSha 'abc123' -Processor 'unit'
    }

    It 'writes a manifest whose stored hash equals the returned pin' {
        $imp = Import-VesManifest -Path $script:Out
        $imp.StoredHash | Should -Be $script:Pinned
    }

    It 'round-trips as self-consistent' {
        $imp = Import-VesManifest -Path $script:Out
        $imp.Consistent | Should -BeTrue
        $imp.StoredHash | Should -Be $imp.RecomputedHash
        $imp.Doc.fileCount | Should -Be $script:M.Count
        $imp.Doc.commitSha | Should -Be 'abc123'
    }

    It 'detects a manifest edited after capture (tamper)' {
        # flip one file hash in the persisted JSON, leave the stored manifestHash as-is
        $doc = Get-Content -LiteralPath $script:Out -Raw | ConvertFrom-Json
        $doc.files[0].Sha256 = ('F' * 64)
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:Out -Encoding utf8

        $imp = Import-VesManifest -Path $script:Out
        $imp.Consistent | Should -BeFalse
        $imp.StoredHash | Should -Not -Be $imp.RecomputedHash
    }

    It 'throws on a missing manifest path' {
        { Import-VesManifest -Path (Join-Path $TestDrive 'absent.json') } | Should -Throw
    }
}

Describe 'Compare-VesFiles' {
    BeforeEach {
        # fresh baseline captured from the canonical tree
        $script:Baseline = Get-VesManifest -ReleaseRoot $script:Tree
        # a live copy we can mutate per test
        $script:Live = Join-Path $TestDrive ('live-{0}' -f ([guid]::NewGuid().ToString('N')))
        Copy-Item -Path $script:Tree -Destination $script:Live -Recurse
    }

    It 'reports Match when the tree is byte-identical to the baseline' {
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match | Should -BeTrue
        $cmp.Missing.Count | Should -Be 0
        $cmp.Changed.Count | Should -Be 0
        $cmp.Extra.Count   | Should -Be 0
    }

    It 'detects a missing file' {
        Remove-Item (Join-Path $script:Live 'keep1.txt')
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match   | Should -BeFalse
        $cmp.Missing | Should -Contain 'keep1.txt'
    }

    It 'detects a changed file' {
        Set-Content -Path (Join-Path $script:Live 'keep1.txt') -Value 'ALPHA-CHANGED' -NoNewline
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match | Should -BeFalse
        @($cmp.Changed.RelPath) | Should -Contain 'keep1.txt'
    }

    It 'detects an extra file' {
        Set-Content -Path (Join-Path $script:Live 'surprise.txt') -Value 'new' -NoNewline
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match | Should -BeFalse
        $cmp.Extra | Should -Contain 'surprise.txt'
    }

    It 'returns plain arrays for the result lists (StrictMode 2.0 safe)' {
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        # @() on a List[object] throws under StrictMode 2.0; the module returns .ToArray()
        { @($cmp.Missing); @($cmp.Changed); @($cmp.Extra) } | Should -Not -Throw
        ,$cmp.Changed | Should -BeOfType [System.Array]
    }
}

Describe 'Write-VesLog' {
    It 'writes a single-line JSON record with ts/level/msg to the log file' {
        $log = Join-Path $TestDrive ('log-{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))
        Write-VesLog -Level OK -Message 'hello world' -LogFile $log
        $rec = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
        $rec.level | Should -Be 'OK'
        $rec.msg   | Should -Be 'hello world'
        $rec.ts    | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
    }

    It 'merges -Data keys into the record' {
        $log = Join-Path $TestDrive ('log-{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))
        Write-VesLog -Level INFO -Message 'with data' -Data @{ processor = 'demo'; count = 3 } -LogFile $log
        $rec = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
        $rec.processor | Should -Be 'demo'
        $rec.count     | Should -Be 3
    }

    It 'rejects a level outside the ValidateSet' {
        { Write-VesLog -Level BOGUS -Message 'x' } | Should -Throw
    }
}
