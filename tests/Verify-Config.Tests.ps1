#Requires -Version 5.1
# Verify-Config.ps1 across the three contract formats. It returns an object
# instead of calling exit, so we run it in-process and check .pass. Fixtures have
# no ssmExpectedValues, so no SSM. Failing contracts are built per-test.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')
    $script:VerifyConfig = Join-Path (Get-VesRepoRoot) 'Verify-Config.ps1'
    $script:Fx = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Verify-Config (<Fmt>)' -ForEach @(
    @{ Fmt = 'appconfig'; Config = 'app.config' }
    @{ Fmt = 'json';      Config = 'config.json' }
    @{ Fmt = 'keyvalue';  Config = 'application.properties' }
) {
    BeforeAll {
        $script:ContractPath = Join-Path $script:Fx (Join-Path $Fmt 'contract.json')
        $script:ConfigPath   = Join-Path $script:Fx (Join-Path $Fmt $Config)
    }

    It 'passes when the config meets the contract' {
        $r = & $script:VerifyConfig -ContractPath $script:ContractPath -ConfigPath $script:ConfigPath
        $r.pass | Should -BeTrue
        @($r.missingRequired).Count | Should -Be 0
        @($r.valueMismatch).Count   | Should -Be 0
    }

    It 'fails on a wrong expected value' {
        $bad = Join-Path $TestDrive "bad-value-$Fmt.json"
        $c = Get-Content -LiteralPath $script:ContractPath -Raw | ConvertFrom-Json
        $firstKey = ($c.expectedValues.PSObject.Properties | Select-Object -First 1).Name
        $c.expectedValues.$firstKey = 'DEFINITELY-WRONG'
        ($c | ConvertTo-Json -Depth 6) | Out-File -FilePath $bad -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $bad -ConfigPath $script:ConfigPath
        $r.pass | Should -BeFalse
        @($r.valueMismatch).Count | Should -BeGreaterThan 0
    }

    It 'fails when a required key is absent' {
        $bad = Join-Path $TestDrive "missing-key-$Fmt.json"
        $c = Get-Content -LiteralPath $script:ContractPath -Raw | ConvertFrom-Json
        $c.requiredKeys = @('this.key.is.absent')
        ($c | ConvertTo-Json -Depth 6) | Out-File -FilePath $bad -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $bad -ConfigPath $script:ConfigPath
        $r.pass | Should -BeFalse
        @($r.missingRequired) | Should -Contain 'this.key.is.absent'
    }
}

Describe 'Verify-Config contract strictness and secret handling' {
    It 'rejects a secret value embedded in expectedValues' {
        $fx = Join-Path $script:Fx 'json'
        $c = Get-Content -LiteralPath (Join-Path $fx 'contract.json') -Raw | ConvertFrom-Json
        $firstKey = ($c.expectedValues.PSObject.Properties | Select-Object -First 1).Name
        $c.expectedValues.$firstKey = 'SECRET-EXPECTED-VALUE'
        $c | Add-Member -NotePropertyName sensitiveKeys -NotePropertyValue @($firstKey) -Force
        $bad = Join-Path $TestDrive 'sensitive-contract.json'
        ($c | ConvertTo-Json -Depth 6) | Out-File -FilePath $bad -Encoding utf8

        { & $script:VerifyConfig -ContractPath $bad -ConfigPath (Join-Path $fx 'config.json') } |
            Should -Throw -ExpectedMessage '*stores a sensitive key*'
    }

    It 'treats a present-but-empty sensitive key as missing without reporting its value' {
        $fx = Join-Path $script:Fx 'json'
        $config = Get-Content -LiteralPath (Join-Path $fx 'config.json') -Raw | ConvertFrom-Json
        $config.Outbound.QueueName = ''
        $configPath = Join-Path $TestDrive 'empty-sensitive-config.json'
        ($config | ConvertTo-Json -Depth 6) | Out-File -FilePath $configPath -Encoding utf8

        $contract = Get-Content -LiteralPath (Join-Path $fx 'contract.json') -Raw | ConvertFrom-Json
        $contract | Add-Member -NotePropertyName sensitiveKeys -NotePropertyValue @('Outbound:QueueName') -Force
        $contractPath = Join-Path $TestDrive 'empty-sensitive-contract.json'
        ($contract | ConvertTo-Json -Depth 6) | Out-File -FilePath $contractPath -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $contractPath -ConfigPath $configPath
        $r.pass | Should -BeFalse
        @($r.missingRequired) | Should -Contain 'Outbound:QueueName'
    }

    It 'reports an undeclared live setting as drift' {
        $fx = Join-Path $script:Fx 'json'
        $config = Get-Content -LiteralPath (Join-Path $fx 'config.json') -Raw | ConvertFrom-Json
        $config | Add-Member -NotePropertyName Unexpected -NotePropertyValue 'present' -Force
        $configPath = Join-Path $TestDrive 'extra-setting.json'
        ($config | ConvertTo-Json -Depth 6) | Out-File -FilePath $configPath -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath (Join-Path $fx 'contract.json') -ConfigPath $configPath
        $r.pass | Should -BeFalse
        @($r.extraKeys) | Should -Contain 'Unexpected'
    }

    It 'allows only an explicitly ignored live setting' {
        $fx = Join-Path $script:Fx 'json'
        $config = Get-Content -LiteralPath (Join-Path $fx 'config.json') -Raw | ConvertFrom-Json
        $config | Add-Member -NotePropertyName ExpectedRuntimeMetadata -NotePropertyValue 'present' -Force
        $configPath = Join-Path $TestDrive 'ignored-setting.json'
        ($config | ConvertTo-Json -Depth 6) | Out-File -FilePath $configPath -Encoding utf8

        $contract = Get-Content -LiteralPath (Join-Path $fx 'contract.json') -Raw | ConvertFrom-Json
        $contract | Add-Member -NotePropertyName ignoredKeys -NotePropertyValue @('ExpectedRuntimeMetadata') -Force
        $contractPath = Join-Path $TestDrive 'ignored-setting-contract.json'
        ($contract | ConvertTo-Json -Depth 6) | Out-File -FilePath $contractPath -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $contractPath -ConfigPath $configPath
        $r.pass | Should -BeTrue
    }
}

Describe 'Verify-Config errors' {
    It 'throws on a missing contract file' {
        { & $script:VerifyConfig -ContractPath (Join-Path $TestDrive 'no-contract.json') `
              -ConfigPath (Join-Path $script:Fx 'json\config.json') } | Should -Throw
    }
    It 'throws on a missing config file' {
        { & $script:VerifyConfig -ContractPath (Join-Path $script:Fx 'json\contract.json') `
              -ConfigPath (Join-Path $TestDrive 'no-config.json') } | Should -Throw
    }
}
