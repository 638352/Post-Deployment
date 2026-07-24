#Requires -Version 5.1
# Unit tests for the VesVerify module functions. Everything runs against a
# TestDrive tree; no AWS, host state, or network.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')   # Get-WinPowerShellPath for the child-process case
    $script:ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'module\VesVerify.psm1'
    Import-Module $script:ModulePath -Force

    # two real files plus some the default exclude drops: the *.config/*.log/*.tmp
    # extensions, and the logs\ / temp\ / cache\ / .git\ runtime dirs. The dir rules
    # must bite at BOTH depths - top-level and nested - so the tree covers both.
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
    # top-level runtime dirs: these leaked into the baseline before the (^|\\) fix,
    # and a churning top-level Logs\ meant permanent false drift on every check.
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
        # regression: the old pattern required a separator before the dir name, so
        # only nested dirs matched and a top-level logs\ leaked into the baseline
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
        $keep1.Bytes  | Should -Be 5   # 'alpha'
    }

    It 'throws on a missing release root' {
        { Get-VesManifest -ReleaseRoot (Join-Path $TestDrive 'nope') } | Should -Throw
    }

    It 'gives identical results whether the root is spelled long or 8.3-short' {
        # regression: Resolve-Path PRESERVES 8.3 short names while FileInfo.FullName
        # EXPANDS them, so the old Substring($root.Length + 1) slice came out one
        # char short and every RelPath was silently corrupted -- a clean tree then
        # reported as entirely missing + extra.
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $short = $fso.GetFolder($script:Tree).ShortPath
        if ($short -eq $script:Tree) {
            Set-ItResult -Skipped -Because '8.3 name generation is disabled on this volume'
            return
        }
        $viaLong  = Get-VesManifest -ReleaseRoot $script:Tree
        $viaShort = Get-VesManifest -ReleaseRoot $short
        (@($viaShort.RelPath) -join '|') | Should -Be (@($viaLong.RelPath) -join '|')
        (Get-VesManifestHash -Manifest $viaShort) | Should -Be (Get-VesManifestHash -Manifest $viaLong)
    }

    It 'defaults ExcludePattern to the shared module constant' {
        # capture and compare must never drift apart; pin both to one source
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

Describe 'Invoke-VesAwsCli' {
    BeforeAll {
        # shim an 'aws' on PATH so no real CLI or AWS account is involved
        $script:Shim = Join-Path $TestDrive 'awsshim'
        New-Item -ItemType Directory -Path $script:Shim -Force | Out-Null
        $script:OldPath = $env:PATH
        $env:PATH = "$script:Shim;$env:PATH"
    }
    AfterAll { $env:PATH = $script:OldPath }

    It 'returns instead of throwing when the CLI writes to stderr and fails' {
        # regression: under $ErrorActionPreference='Stop', native stderr became a
        # TERMINATING error (with 2>&1 AND 2>$null), so callers' own error handling
        # never ran and Preflight aborted its whole report.
        Set-Content -Path (Join-Path $script:Shim 'aws.cmd') -Value @(
            '@echo off'
            'echo An error occurred (ParameterNotFound) when calling GetParameter 1>&2'
            'exit /b 254')
        $ErrorActionPreference = 'Stop'
        # assign outside the assertion scriptblock: a scriptblock invoked by
        # Should runs in a child scope, so an assignment inside it would not escape
        { Invoke-VesAwsCli -Arguments @('ssm','get-parameter') } | Should -Not -Throw
        $r = Invoke-VesAwsCli -Arguments @('ssm','get-parameter')
        $r.ExitCode | Should -Be 254
        $r.StdErr   | Should -Match 'ParameterNotFound'
        $r.StdOut   | Should -Not -Match 'ParameterNotFound'
    }

    It 'keeps stderr out of StdOut on a successful call' {
        # the AWS CLI can emit warnings to stderr on exit 0; a naive 2>&1 would
        # splice them into the returned parameter value
        Set-Content -Path (Join-Path $script:Shim 'aws.cmd') -Value @(
            '@echo off'
            'echo WARNING: deprecated flag 1>&2'
            'echo real-parameter-value'
            'exit /b 0')
        $r = Invoke-VesAwsCli -Arguments @('ssm','get-parameter')
        $r.ExitCode      | Should -Be 0
        $r.StdOut.Trim() | Should -Be 'real-parameter-value'
        $r.StdOut        | Should -Not -Match 'deprecated'
        $r.StdErr        | Should -Match 'deprecated'
    }

    It 'surfaces a trust failure message naming the parameter and region' {
        # Get-VesTrustedHash's own throw used to be dead code: native stderr under
        # $ErrorActionPreference='Stop' threw first, losing the param name/region.
        #
        # This MUST run in a child powershell.exe with EAP=Stop set at SCRIPT scope,
        # the way every real caller (Invoke-PreDeployGate, Invoke-Verification) sets
        # it. Setting EAP inside a Pester It does not reach the module the same way,
        # so an in-process version of this test passes even against the broken code.
        Set-Content -Path (Join-Path $script:Shim 'aws.cmd') -Value @(
            '@echo off'
            'echo An error occurred (AccessDeniedException) 1>&2'
            'exit /b 254')
        $driver = Join-Path $TestDrive 'trusted-hash-driver.ps1'
        Set-Content -Path $driver -Value @(
            ('Import-Module ''{0}'' -Force' -f $script:ModulePath)
            '$ErrorActionPreference = ''Stop'''
            'try { Get-VesTrustedHash -ParameterName ''/ves/demo/baseline-hash'' -Region ''us-gov-west-1'' }'
            'catch { $_.Exception.Message }')
        $out = & (Get-WinPowerShellPath) -NoProfile -ExecutionPolicy Bypass -File $driver 2>&1 | Out-String
        $out | Should -Match '/ves/demo/baseline-hash'
        $out | Should -Match 'us-gov-west-1'
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
        if ($rec.ts -is [datetime]) {
            $rec.ts.ToUniversalTime().ToString('o') | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
        } else {
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

Describe 'Get-VesDatadogEnvTag' {
    BeforeEach { $script:OldDdEnv = $env:DD_ENV }
    AfterEach { $env:DD_ENV = $script:OldDdEnv }

    It 'defaults to env:prod when DD_ENV is not set' {
        $env:DD_ENV = $null
        (Get-VesDatadogEnvTag) | Should -Be 'env:prod'
    }

    It 'uses normalized DD_ENV when provided' {
        $env:DD_ENV = '  UAT  '
        (Get-VesDatadogEnvTag) | Should -Be 'env:uat'
    }

    It 'lets an explicit target environment override DD_ENV' {
        $env:DD_ENV = 'prod'
        (Get-VesDatadogEnvTag -Environment 'qa') | Should -Be 'env:qa'
    }
}

Describe 'Import-VesTargetInventory' {
    BeforeEach {
        $script:InventoryPath = Join-Path $TestDrive ('inventory-{0}.json' -f ([guid]::NewGuid().ToString('N')))
        $script:Inventory = [ordered]@{
            schema = 'ves.targets.v1'
            inventoryComplete = $true
            requiredServers = @('server-a')
            targets = @(
                [ordered]@{
                    processor='alpha'; server='server-a'; environment='prod'
                    inventoryStatus='confirmed'; releaseTag='alpha/v1.0.0'
                    releaseRoot='C:\apps\alpha'
                    manifestPath='D:\baselines\alpha.json'; trustParam='/ves/alpha/hash'
                    configContract='D:\baselines\alpha.config.json'
                    configPath='C:\apps\alpha\alpha.exe.config'
                }
            )
        }
    }

    It 'accepts an explicitly complete, covered inventory' {
        ($script:Inventory | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:InventoryPath -Encoding utf8
        $r = Import-VesTargetInventory -Path $script:InventoryPath
        $r.Valid | Should -BeTrue
        $r.Targets.Count | Should -Be 1
    }

    It 'rejects an inventory that is not explicitly complete' {
        $script:Inventory.inventoryComplete = $false
        ($script:Inventory | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:InventoryPath -Encoding utf8
        $r = Import-VesTargetInventory -Path $script:InventoryPath
        $r.Valid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'inventoryComplete'
    }

    It 'rejects a required server with no confirmed target' {
        $script:Inventory.requiredServers = @('server-a','citrix-01')
        ($script:Inventory | ConvertTo-Json -Depth 6) | Out-File -FilePath $script:InventoryPath -Encoding utf8
        $r = Import-VesTargetInventory -Path $script:InventoryPath
        $r.Valid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'citrix-01'
    }
}
