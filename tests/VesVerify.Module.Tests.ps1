#Requires -Version 5.1
# Unit tests for VesVerify module functions. Everything runs against a
# TestDrive tree; no host state or network. AWS/SSM helpers are gone — trust
# is exercised via New-VesBaselineArchive in the e2e suites.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\VesVerify.psm1'
    Import-Module $script:ModulePath -Force

    $script:Tree = Join-Path $TestDrive 'release'
    New-Item -ItemType Directory -Path $script:Tree -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'bin')       -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'logs')      -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'temp')      -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'cache')     -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree '.git')      -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'sub\logs')  -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Tree 'sub\.git')  -Force | Out-Null

    Set-Content -Path (Join-Path $script:Tree 'keep1.txt')        -Value 'alpha' -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'bin\keep2.dll')    -Value 'beta'  -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'app.config')       -Value 'drop-config'  -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'trace.log')        -Value 'drop-log'     -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'scratch.tmp')      -Value 'drop-tmp'     -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'sub\logs\run.txt') -Value 'drop-logsdir' -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'sub\.git\HEAD')    -Value 'drop-git'     -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'logs\run.txt')     -Value 'drop-toplogs'  -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'temp\scratch.dat') -Value 'drop-toptemp'  -NoNewline
    Set-Content -Path (Join-Path $script:Tree 'cache\blob.bin')   -Value 'drop-topcache' -NoNewline
    Set-Content -Path (Join-Path $script:Tree '.git\HEAD')        -Value 'drop-topgit'   -NoNewline
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

    It 'drops TOP-LEVEL logs\ / temp\ / cache\ / .git\ dirs, not just nested ones' {
        $rels = $script:Manifest.RelPath
        $rels | Should -Not -Contain 'logs/run.txt'
        $rels | Should -Not -Contain 'temp/scratch.dat'
        $rels | Should -Not -Contain 'cache/blob.bin'
        $rels | Should -Not -Contain '.git/HEAD'
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
        $keep1.Bytes  | Should -Be 5
    }

    It 'throws on a missing release root' {
        { Get-VesManifest -ReleaseRoot (Join-Path $TestDrive 'nope') } | Should -Throw
    }

    It 'gives identical results whether the root is spelled long or 8.3-short' {
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($script:Tree).ShortPath
        if ($short -eq $script:Tree) {
            Set-ItResult -Skipped -Because '8.3 name generation is disabled on this volume'
            return
        }
        $viaLong = Get-VesManifest -ReleaseRoot $script:Tree
        $viaShort = Get-VesManifest -ReleaseRoot $short
        (@($viaShort.RelPath) -join '|') | Should -Be (@($viaLong.RelPath) -join '|')
        (Get-VesManifestHash -Manifest $viaShort) | Should -Be (Get-VesManifestHash -Manifest $viaLong)
    }

    It 'defaults ExcludePattern to the shared module constant' {
        $d = (Get-Command Get-VesManifest).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ExcludePattern' }
        $d.DefaultValue.Extent.Text | Should -Be '$Global:VES_DEFAULT_EXCLUDE'
    }
}

Describe 'Compare-VesFiles exclude default' {
    It 'defaults ExcludePattern to the same shared module constant' {
        $d = (Get-Command Compare-VesFiles).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ExcludePattern' }
        $d.DefaultValue.Extent.Text | Should -Be '$Global:VES_DEFAULT_EXCLUDE'
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
        $mutated = $script:M | ForEach-Object {
            [PSCustomObject]@{ RelPath = $_.RelPath; Sha256 = $_.Sha256; Bytes = $_.Bytes }
        }
        $mutated[0].Sha256 = ('0' * 64)
        (Get-VesManifestHash -Manifest $mutated) | Should -Not -Be $baseline
    }
}

Describe 'Export-VesManifest / Import-VesManifest' {
    BeforeEach {
        $script:M = Get-VesManifest -ReleaseRoot $script:Tree
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
        $cmp = Compare-VesFiles -Baseline $script:Baseline -ReleaseRoot $script:Live
        { @($cmp.Missing); @($cmp.Changed); @($cmp.Extra) } | Should -Not -Throw
        , $cmp.Changed | Should -BeOfType [System.Array]
    }
}

Describe 'Write-VesLog' {
    It 'writes one JSON record with ts/level/msg' {
        $log = Join-Path $TestDrive ('log-{0}.jsonl' -f ([guid]::NewGuid().ToString('N')))
        Write-VesLog -Level OK -Message 'hello world' -LogFile $log
        $rec = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
        $rec.level | Should -Be 'OK'
        $rec.msg   | Should -Be 'hello world'
        if ($rec.ts -is [datetime]) {
            $rec.ts.ToUniversalTime().ToString('o') | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
        }
        else {
            ([string]$rec.ts) | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3,7}Z$'
        }
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

Describe 'Import-VesTargetInventory' {
    It 'rejects a legacy bare-array inventory' {
        $path = Join-Path $TestDrive 'legacy-array.json'
        '[{"processor":"x"}]' | Set-Content -LiteralPath $path -Encoding utf8
        $inv = Import-VesTargetInventory -Path $path
        $inv.Valid | Should -BeFalse
        ($inv.Errors -join ' ') | Should -Match 'Legacy bare-array'
    }

    It 'accepts a complete ves.targets.v1 document' {
        $path = Join-Path $TestDrive 'good-inv.json'
        $doc = [ordered]@{
            schema            = 'ves.targets.v1'
            inventoryComplete = $true
            requiredServers   = @('BOX01')
            targets           = @(
                [ordered]@{
                    processor       = 'demo'
                    server          = 'BOX01'
                    environment     = 'uat'
                    inventoryStatus = 'confirmed'
                    releaseTag      = 'demo/v1.0.0'
                    releaseRoot     = 'C:\demo'
                    manifestPath    = 'D:\baselines\demo.json'
                    configContract  = 'D:\baselines\demo.config.json'
                    configPath      = 'C:\demo\app.config'
                }
            )
        }
        ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $path -Encoding utf8
        $inv = Import-VesTargetInventory -Path $path
        $inv.Valid | Should -BeTrue
        $inv.Targets.Count | Should -Be 1
    }
}
