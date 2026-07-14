#Requires -Version 5.1
# End-to-end tests for Invoke-Verification.ps1 — filesystem-only paths (no AWS).
# We omit -TrustParam throughout so nothing calls SSM; the trust-anchored paths
# are covered by the separate "comprehensive + mocked SSM" scope. Each case runs
# the script as a real child process and asserts the documented exit code
# (0 match / 1 drift / 2 no-baseline / 10 usage) plus -Json status.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root         = Join-Path $TestDrive 'ver'
    $script:Release      = New-VesTree (Join-Path $script:Root 'release')
    $script:ManifestPath = Join-Path $script:Root 'baseline.json'

    $script:Cap = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode','Capture','-ReleaseRoot',$script:Release,
        '-ManifestPath',$script:ManifestPath,'-Processor','test','-Json')
}

Describe 'Invoke-Verification Capture' {
    It 'captures a baseline and exits 0' {
        $script:Cap.ExitCode   | Should -Be 0
        $script:Cap.Json.status | Should -Be 'captured'
    }
    It 'writes the manifest file' {
        Test-Path -LiteralPath $script:ManifestPath | Should -BeTrue
    }
    It 'warns that the baseline is not trust-anchored (no -TrustParam)' {
        $script:Cap.Output | Should -Match 'NOT trust-anchored'
    }
}

Describe 'Invoke-Verification VerifyFiles' {
    It 'passes when prod matches the baseline (exit 0, status match)' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,
            '-ManifestPath',$script:ManifestPath,'-Json')
        $r.ExitCode    | Should -Be 0
        $r.Json.status | Should -Be 'match'
    }

    It 'reports drift when a file changes (exit 1, status drift)' {
        $drift = New-VesTree (Join-Path $script:Root 'drift')
        Set-Content -Path (Join-Path $drift 'app.txt') -Value 'CHANGED' -NoNewline
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$drift,
            '-ManifestPath',$script:ManifestPath,'-Json')
        $r.ExitCode    | Should -Be 1
        $r.Json.status | Should -Be 'drift'
        $r.Output      | Should -Match 'File verify FAIL'
    }

    It 'exits 2 (no-baseline) on a tampered manifest' {
        $tampered = Join-Path $script:Root 'tampered.json'
        $doc = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        $doc.files[0].Sha256 = ('F' * 64)   # edit content but leave manifestHash claim intact
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $tampered -Encoding utf8
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,
            '-ManifestPath',$tampered,'-Json')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'self-hash mismatch'
    }

    It 'exits 10 (usage) when -ManifestPath is omitted' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-ReleaseRoot',$script:Release,'-Json')
        $r.ExitCode | Should -Be 10
    }
}
