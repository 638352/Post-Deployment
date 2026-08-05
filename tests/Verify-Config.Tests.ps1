#Requires -Version 5.1
# Verify-Config.ps1 across the three contract formats. It returns an object
# instead of calling exit, so we run it in-process and check .pass. Fixtures have
# no ssmExpectedValues (that key fails closed). Failing contracts are built per-test.

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

Describe 'Verify-Config sensitiveKeys masking' {
    It 'reports (masked) for a secret-named key mismatch, never the values' {
        # Sensitive keys cannot live under expectedValues by policy; auto-masking
        # still applies when the key name matches the secret-name pattern.
        $contract = Join-Path $TestDrive 'mask-contract.json'
        $config   = Join-Path $TestDrive 'mask-config.json'
        @{
            format         = 'json'
            requiredKeys   = @('Outbound:QueueName')
            expectedValues = @{ 'Outbound:ApiToken' = 'SECRET-EXPECTED-VALUE' }
        } | ConvertTo-Json -Depth 6 | Out-File -FilePath $contract -Encoding utf8
        @{
            Outbound = @{ QueueName = 'oms-outbound'; ApiToken = 'actual-secret-value' }
        } | ConvertTo-Json -Depth 6 | Out-File -FilePath $config -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $contract -ConfigPath $config
        $r.pass | Should -BeFalse
        $mm = @($r.valueMismatch) | Where-Object { $_.key -eq 'Outbound:ApiToken' }
        $mm | Should -Not -BeNullOrEmpty
        $mm.expected | Should -Be '(masked)'
        $mm.actual   | Should -Be '(masked)'
    }
}

Describe 'Verify-Config ssmExpectedValues rejection' {
    It 'fails closed when a contract still declares ssmExpectedValues' {
        $fx = Join-Path $script:Fx 'json'
        $c = Get-Content -LiteralPath (Join-Path $fx 'contract.json') -Raw | ConvertFrom-Json
        $c | Add-Member -NotePropertyName ssmExpectedValues -NotePropertyValue (
            [PSCustomObject]@{ 'Outbound:QueueName' = '/ves/demo/queue' }
        ) -Force
        $bad = Join-Path $TestDrive 'ssm-contract.json'
        ($c | ConvertTo-Json -Depth 6) | Out-File -FilePath $bad -Encoding utf8

        $r = & $script:VerifyConfig -ContractPath $bad -ConfigPath (Join-Path $fx 'config.json')
        $r.pass | Should -BeFalse
        $r.unverifiable | Should -Match 'Outbound:QueueName'
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
