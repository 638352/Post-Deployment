#Requires -Version 5.1
# Tests for Verify-Config.ps1 across all three contract formats (appconfig / json
# / keyvalue). Unlike the other entry scripts, Verify-Config returns a result
# object instead of calling exit, so we invoke it IN-PROCESS and assert on .pass /
# .missingRequired / .valueMismatch. Fixtures carry no ssmExpectedValues, so no
# AWS is touched. Failing contracts are synthesized per-test under TestDrive.

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

    It 'passes when the config satisfies the contract' {
        $r = & $script:VerifyConfig -ContractPath $script:ContractPath -ConfigPath $script:ConfigPath
        $r.pass | Should -BeTrue
        @($r.missingRequired).Count | Should -Be 0
        @($r.valueMismatch).Count   | Should -Be 0
    }

    It 'fails with a value mismatch when an expected value is wrong' {
        $bad = Join-Path $TestDrive "bad-value-$Fmt.json"
        $c = Get-Content -LiteralPath $script:ContractPath -Raw | ConvertFrom-Json
        $firstKey = ($c.expectedValues.PSObject.Properties | Select-Object -First 1).Name
        $c.expectedValues.$firstKey = 'DEFINITELY-WRONG'
        ($c | ConvertTo-Json -Depth 6) | Out-File -FilePath $bad -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $bad -ConfigPath $script:ConfigPath
        $r.pass | Should -BeFalse
        @($r.valueMismatch).Count | Should -BeGreaterThan 0
    }

    It 'fails with a missing key when a required key is absent from the config' {
        $bad = Join-Path $TestDrive "missing-key-$Fmt.json"
        $c = Get-Content -LiteralPath $script:ContractPath -Raw | ConvertFrom-Json
        $c.requiredKeys = @('this.key.is.absent')
        ($c | ConvertTo-Json -Depth 6) | Out-File -FilePath $bad -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $bad -ConfigPath $script:ConfigPath
        $r.pass | Should -BeFalse
        @($r.missingRequired) | Should -Contain 'this.key.is.absent'
    }
}

Describe 'Verify-Config error handling' {
    It 'throws when the contract file does not exist' {
        { & $script:VerifyConfig -ContractPath (Join-Path $TestDrive 'no-contract.json') `
              -ConfigPath (Join-Path $script:Fx 'json\config.json') } | Should -Throw
    }
    It 'throws when the config file does not exist' {
        { & $script:VerifyConfig -ContractPath (Join-Path $script:Fx 'json\contract.json') `
              -ConfigPath (Join-Path $TestDrive 'no-config.json') } | Should -Throw
    }
}
