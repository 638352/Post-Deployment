#Requires -Version 5.1
# Unit tests for the VesVerify module functions. Everything runs against a
# TestDrive tree; no AWS, host state, or network.

BeforeAll {
    $script:ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\VesVerify.psm1'
    Import-Module $script:ModulePath -Force

    # two real files plus some the default exclude drops: the *.config/*.log/*.tmp
    # extensions, and nested logs\ / .git\ dirs. The dir rules need \logs\ / \.git\
    # with a leading separator, so they only bite below the root - hence sub\.
    $script:Tree = Join-Path $TestDrive 'release'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'bin')       -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'sub\logs')  -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'sub\.git')  -Force | Out-Null

    Set-Content -Path (Join-Path $script:Tree 'keep1.txt')        -Value 'alpha' -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'bin\keep2.dll')    -Value 'beta'  -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'app.config')       -Value 'drop-config'  -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'trace.log')        -Value 'drop-log'     -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'scratch.tmp')      -Value 'drop-tmp'     -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'sub\logs\run.txt') -Value 'drop-logsdir' -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'sub\.git\HEAD')    -Value 'drop-git'     -NoNewline
}

Describe 'Get-VesManifest' {
    BeforeAll { $script:Manifest = Get-VesManifest -ReleaseRoot $script:Tree }

    It 'includes only the non-excluded files' {
        $rels = $script:Manifest.RelPath
        $rels | Should -Contain 'keep1.txt'
        $rels | Should -Contain 'bin/keep2.dll'
        $rels.Count | Should -Be 2
    }

    It 'drops .config / .log / .tmp files and nested logs\ / .git\ dirs' {
        $rels = $script:Manifest.RelPath
        $rels | Should -Not -Contain 'app.config'
        $rels | Should -Not -Contain 'trace.log'
        $rels | Should -Not -Contain 'scratch.tmp'
        $rels | Should -Not -Contain 'sub/logs/run.txt'
        $rels | Should -Not -Contain 'sub/.git/HEAD'
    }

    It 'uses forward-slash relative paths' {
        foreach ($e in $script:Manifest) {
            $e.RelPath | Should -Not -Match '\\'
            $e.RelPath | Should -Not -Match '^[A-Za-z]:'
        }
    }

    It 'sorts by RelPath' {
        $rels = @($script:Manifest.RelPath)
        ($rels -join '|') | Should -Be ((@($rels | Sort-Object)) -join '|')
    }

    It 'records hash and byte length' {
        $keep1 = $script:Manifest | Where-Object RelPath -eq 'keep1.txt'
        $keep1.Sha256 | Should -Match '^[0-9A-F]{64}$'
        $keep1.Bytes  | Should -Be 5   # 'alpha'
    }

    It 'throws on a missing release root' {
        { Get-VesManifest -ReleaseRoot (Join-Path $TestDrive 'nope') } | Should -Throw
    }
}

Describe 'Get-VesManifestHash' {
    BeforeAll { $script:M = Get-VesManifest -ReleaseRoot $script:Tree }

    It 'is stable for the same input' {
        (Get-VesManifestHash -Manifest $script:M) | Should -Be (Get-VesManifestHash -Manifest $script:M)
    }

    It 'ignores input ordering' {
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

    It 'stores the hash it returned' {
        (Import-VesManifest -Path $script:Out).StoredHash | Should -Be $script:Pinned
    }

    It 'round-trips as self-consistent' {
        $imp = Import-VesManifest -Path $script:Out
        $imp.Consistent | Should -BeTrue
        $imp.StoredHash | Should -Be $imp.RecomputedHash
        $imp.Doc.fileCount | Should -Be $script:M.Count
        $imp.Doc.commitSha | Should -Be 'abc123'
    }

    It 'flags a manifest edited after capture' {
        # change a file hash but leave the stored manifestHash alone
        $doc = Get-Content -LiteralPath $script:Out -Raw | ConvertFrom-Json
        $doc.files[0].Sha256 = ('F' * 64)
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:Out -Encoding utf8

        $imp = Import-VesManifest -Path $script:Out
        $imp.Consistent | Should -BeFalse
        $imp.StoredHash | Should -Not -Be $imp.RecomputedHash
    }

    It 'throws on a missing path' {
        { Import-VesManifest -Path (Join-Path $TestDrive 'absent.json') } | Should -Throw
    }
}

Describe 'Compare-VesFiles' {
    BeforeEach {
        $script:Baseline = Get-VesManifest -ReleaseRoot $script:Tree
        $script:Live = Join-Path $TestDrive ('live-{0}' -f ([guid]::NewGuid().ToString('N')))
        Copy-Item -Path $script:Tree -Destination $script:Live -Recurse
    }

    It 'matches an identical tree' {
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match | Should -BeTrue
        $cmp.Missing.Count | Should -Be 0
        $cmp.Changed.Count | Should -Be 0
        $cmp.Extra.Count   | Should -Be 0
    }

    It 'catches a missing file' {
        Remove-Item (Join-Path $script:Live 'keep1.txt')
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match   | Should -BeFalse
        $cmp.Missing | Should -Contain 'keep1.txt'
    }

    It 'catches a changed file' {
        Set-Content -Path (Join-Path $script:Live 'keep1.txt') -Value 'ALPHA-CHANGED' -NoNewline
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match | Should -BeFalse
        @($cmp.Changed.RelPath) | Should -Contain 'keep1.txt'
    }

    It 'catches an extra file' {
        Set-Content -Path (Join-Path $script:Live 'surprise.txt') -Value 'new' -NoNewline
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        $cmp.Match | Should -BeFalse
        $cmp.Extra | Should -Contain 'surprise.txt'
    }

    It 'hands back plain arrays' {
        # the module returns .ToArray() so @() on the results is safe under StrictMode 2.0
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        { @($cmp.Missing); @($cmp.Changed); @($cmp.Extra) } | Should -Not -Throw
        ,$cmp.Changed | Should -BeOfType [System.Array]
    }
}

Describe 'Write-VesLog' {
    It 'writes one JSON record with ts/level/msg' {
        $log = Join-Path $TestDrive ('log-{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))
        Write-VesLog -Level OK -Message 'hello world' -LogFile $log
        $rec = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
        $rec.level | Should -Be 'OK'
        $rec.msg   | Should -Be 'hello world'
        $rec.ts    | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
    }

    It 'folds -Data keys into the record' {
        $log = Join-Path $TestDrive ('log-{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))
        Write-VesLog -Level INFO -Message 'with data' -Data @{ processor = 'demo'; count = 3 } -LogFile $log
        $rec = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
        $rec.processor | Should -Be 'demo'
        $rec.count     | Should -Be 3
    }

    It 'rejects an unknown level' {
        { Write-VesLog -Level BOGUS -Message 'x' } | Should -Throw
    }
}
