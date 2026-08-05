#Requires -Version 5.1
# Invoke-Verification.ps1 file-match checks only, run with -AllowUnanchoredVerify
# because no tag anchor is configured here -- the anchored path is covered by the
# Deploy-Processor, Rollback, and Preflight suites against a real archive repo.
# Checks the file verification contract: 0 match, 1 drift, 2 no baseline, 10 usage.

BeforeAll {
    . (Join-Path $PSScriptRoot '_helpers.ps1')

    $script:Root         = Join-Path $TestDrive 'ver'
    $script:Release      = New-VesTree (Join-Path $script:Root 'release')
    $script:ManifestPath = Join-Path $script:Root 'baseline.json'

    $script:Capture = Invoke-VesScript 'Invoke-Verification.ps1' @(
        '-Mode','Capture',
        '-ReleaseRoot',$script:Release,
        '-ManifestPath',$script:ManifestPath,
        '-Processor','test',
        '-CommitSha', 'testcommit1',
        '-AllowUnarchivedCapture',
        '-Json')
}

Describe 'UAT-to-production file match flow' {
    It 'captures a baseline file list for later comparison' {
        $script:Capture.ExitCode    | Should -Be 0
        $script:Capture.Json.status | Should -Be 'captured'
        Test-Path -LiteralPath $script:ManifestPath | Should -BeTrue
    }

    It 'passes a matching tree' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-AllowUnanchoredVerify','-ReleaseRoot',$script:Release,
            '-ManifestPath',$script:ManifestPath,'-Json')
        $r.ExitCode    | Should -Be 0
        $r.Json.status | Should -Be 'match'
    }

    It 'reports drift on a changed file' {
        $drift = New-VesTree (Join-Path $script:Root 'drift')
        Set-Content -Path (Join-Path $drift 'app.txt') -Value 'CHANGED' -NoNewline
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-AllowUnanchoredVerify','-ReleaseRoot',$drift,
            '-ManifestPath',$script:ManifestPath,'-Json')
        $r.ExitCode    | Should -Be 1
        $r.Json.status | Should -Be 'drift'
        $r.Output      | Should -Match 'File verify FAIL'
    }

    It 'exits 2 on a tampered manifest' {
        $tampered = Join-Path $script:Root 'tampered.json'
        $doc = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        $doc.files[0].Sha256 = ('F' * 64)
        ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $tampered -Encoding utf8
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-AllowUnanchoredVerify','-ReleaseRoot',$script:Release,
            '-ManifestPath',$tampered,'-Json')
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'self-hash mismatch'
    }

    It 'exits 10 without -ManifestPath' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-AllowUnanchoredVerify','-ReleaseRoot',$script:Release,'-Json')
        $r.ExitCode | Should -Be 10
    }
    It 'exits 10 when file verification has no release root' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-AllowUnanchoredVerify',
            '-ManifestPath',$script:ManifestPath,
            '-Json')
        $r.ExitCode | Should -Be 10
        $r.Output   | Should -Match 'ReleaseRoot required'
    }
}

Describe 'capture and compare must use the same exclude rules' {
    # A baseline captured under one exclude pattern and compared under another
    # reports the excluded files as Extra forever -- drift no redeploy can clear.
    # The pattern is now recorded in the manifest so the mismatch is caught and
    # named instead of surfacing as an unexplained permanent failure.
    BeforeAll {
        $script:CustomManifest = Join-Path $script:Root 'custom-pattern.json'
        $script:CustomPattern  = '(?i)\.tmp$'
        $script:CustomCapture  = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','Capture',
            '-ReleaseRoot',$script:Release,
            '-ManifestPath',$script:CustomManifest,
            '-ExcludePattern',$script:CustomPattern,
            '-Processor','test',
            '-CommitSha', 'testcommit1','-AllowUnarchivedCapture','-Json')
    }

    It 'records the pattern it captured under' {
        $script:CustomCapture.ExitCode | Should -Be 0
        $doc = Get-Content -LiteralPath $script:CustomManifest -Raw | ConvertFrom-Json
        $doc.excludePattern | Should -Be $script:CustomPattern
    }

    It 'exits 2 (not 1) when the verify pattern differs from the capture pattern' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-AllowUnanchoredVerify','-ReleaseRoot',$script:Release,
            '-ManifestPath',$script:CustomManifest,'-Json')
        # NOBASE: the baseline is unusable here, production is not wrong
        $r.ExitCode | Should -Be 2
        $r.Output   | Should -Match 'captured under a different exclude pattern'
    }

    It 'passes when the same pattern is supplied again' {
        $r = Invoke-VesScript 'Invoke-Verification.ps1' @(
            '-Mode','VerifyFiles','-AllowUnanchoredVerify','-ReleaseRoot',$script:Release,
            '-ManifestPath',$script:CustomManifest,
            '-ExcludePattern',$script:CustomPattern,'-Json')
        $r.ExitCode    | Should -Be 0
        $r.Json.status | Should -Be 'match'
    }
}
