#Requires -Version 5.1
<#
.SYNOPSIS
    Baseline capture and post-deployment verification for manual-copy systems.
.DESCRIPTION
    Modes:
      Capture       snapshot the UAT-approved release into a manifest and pin its hash to SSM
      VerifyFiles   hash-compare a deployed tree against the baseline manifest
      VerifyConfig  structural check of live config against a sanitized contract
      All           VerifyFiles then VerifyConfig

    Exit codes: 0 match, 1 drift, 2 no baseline / trust failure, 10 usage.
    Replaces the earlier Verify-Deployment.ps1 Capture/Verify script.
.EXAMPLE
    # at UAT sign-off
    .\Invoke-Verification.ps1 -Mode Capture -ReleaseRoot D:\uat\PROCESSOR -ManifestPath D:\baselines\PROCESSOR.json -TrustParam /ves/PROCESSOR/baseline-hash -Processor PROCESSOR -CommitSha (git rev-parse HEAD)
.EXAMPLE
    # in prod after deploy
    .\Invoke-Verification.ps1 -Mode All -ReleaseRoot E:\apps\PROCESSOR -ManifestPath D:\baselines\PROCESSOR.json -TrustParam /ves/PROCESSOR/baseline-hash -ConfigContract D:\baselines\PROCESSOR.config.json -ConfigPath E:\apps\PROCESSOR\app.config -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Capture','VerifyFiles','VerifyConfig','All')][string]$Mode,
    [Parameter(Mandatory)][string]$ReleaseRoot,
    [string]$ManifestPath,
    [string]$ConfigContract,
    [string]$ConfigPath,
    [string]$TrustParam,
    [string]$Processor = 'unknown',
    [string]$CommitSha = 'unknown',
    [string]$Region = 'us-gov-west-1',
    # .config excluded from the byte-hash by design (server-specific log4net
    # paths); config is verified structurally by Verify-Config.ps1. See the
    # module's Get-VesManifest for the rationale.
    [string]$ExcludePattern = '(?i)\\(logs|temp|cache|\.git)\\|\.(log|tmp|config)$',
    [string]$LogFile,
    [switch]$Json
)

Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
$result = [ordered]@{ mode=$Mode; processor=$Processor; status=$null; detail=@{} }

function Out-Result([int]$code) {
    if ($Json) { ($result | ConvertTo-Json -Depth 6 -Compress) }
    exit $code
}

try {
    switch ($Mode) {

        'Capture' {
            if (-not $ManifestPath) { Write-VesLog ERROR '-ManifestPath required for Capture' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }
            Write-VesLog INFO "Capturing baseline: $ReleaseRoot" -Data @{processor=$Processor} -LogFile $LogFile
            $manifest = Get-VesManifest -ReleaseRoot $ReleaseRoot -ExcludePattern $ExcludePattern
            $hash = Export-VesManifest -Manifest $manifest -Path $ManifestPath -CommitSha $CommitSha -Processor $Processor
            Write-VesLog OK "Manifest written: $($manifest.Count) files, hash=$hash" -LogFile $LogFile
            if ($TrustParam) {
                Set-VesTrustedHash -ParameterName $TrustParam -Value $hash -Region $Region
                Write-VesLog OK "Trusted hash pinned to SSM $TrustParam" -LogFile $LogFile
            } else {
                # without the SSM pin this baseline detects drift but not tampering
                Write-VesLog WARN 'No -TrustParam given; baseline is NOT trust-anchored.' -LogFile $LogFile
            }
            $result.status = 'captured'; $result.detail = @{ fileCount=$manifest.Count; manifestHash=$hash }
            Out-Result $VES_EXIT_OK
        }

        { $_ -in 'VerifyFiles','All' } {
            if (-not $ManifestPath) { Write-VesLog ERROR '-ManifestPath required' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }

            $m = Import-VesManifest -Path $ManifestPath
            if (-not $m.Consistent) {
                # manifest was edited or corrupted after capture
                Write-VesLog ERROR "Manifest self-hash mismatch (tampered/corrupt): stored=$($m.StoredHash) recomputed=$($m.RecomputedHash)" -LogFile $LogFile
                $result.status='no-baseline'; Out-Result $VES_EXIT_NOBASE
            }

            if ($TrustParam) {
                $trusted = Get-VesTrustedHash -ParameterName $TrustParam -Region $Region
                if ($m.RecomputedHash -ne $trusted) {
                    Write-VesLog ERROR "Manifest not trusted: SSM=$trusted manifest=$($m.RecomputedHash)" -LogFile $LogFile
                    $result.status='no-baseline'; Out-Result $VES_EXIT_NOBASE
                }
                Write-VesLog OK 'Manifest trust verified against SSM.' -LogFile $LogFile
            } else {
                Write-VesLog WARN 'No -TrustParam; skipping trust anchor (drift-only check).' -LogFile $LogFile
            }

            $cmp = Compare-VesFiles -Baseline $m.Doc.files -ReleaseRoot $ReleaseRoot -ExcludePattern $ExcludePattern
            $result['detail']['files'] = @{ missing=@($cmp.Missing); changed=@($cmp.Changed); extra=@($cmp.Extra) }
            if ($cmp.Match) {
                Write-VesLog OK 'File verify PASS: prod matches baseline.' -LogFile $LogFile
            } else {
                Write-VesLog DRIFT ("File verify FAIL: {0} missing, {1} changed, {2} extra" -f `
                    $cmp.Missing.Count, $cmp.Changed.Count, $cmp.Extra.Count) -LogFile $LogFile
                foreach ($x in $cmp.Missing) { Write-VesLog DRIFT "  MISSING $x" -LogFile $LogFile }
                foreach ($x in $cmp.Changed) { Write-VesLog DRIFT "  CHANGED $($x.RelPath)" -LogFile $LogFile }
                foreach ($x in $cmp.Extra)   { Write-VesLog DRIFT "  EXTRA   $x" -LogFile $LogFile }
            }
            $filesOk = $cmp.Match
            if ($Mode -eq 'VerifyFiles') {
                $result.status = if ($filesOk) {'match'} else {'drift'}
                Out-Result ($(if ($filesOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
            }
            $script:filesOk = $filesOk   # All mode picks this up below
        }
    }

    if ($Mode -in 'VerifyConfig','All') {
        if (-not $ConfigContract -or -not $ConfigPath) {
            Write-VesLog ERROR '-ConfigContract and -ConfigPath required for config verify' -LogFile $LogFile
            Out-Result $VES_EXIT_USAGE
        }
        $cfg = & (Join-Path $PSScriptRoot 'Verify-Config.ps1') -ContractPath $ConfigContract -ConfigPath $ConfigPath -Region $Region -LogFile $LogFile
        $result['detail']['config'] = $cfg
        $configOk = [bool]$cfg.pass
        if ($Mode -eq 'VerifyConfig') {
            $result.status = if ($configOk) {'match'} else {'drift'}
            Out-Result ($(if ($configOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
        }
        $allOk = ($script:filesOk -and $configOk)
        $result.status = if ($allOk) {'match'} else {'drift'}
        Out-Result ($(if ($allOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
    }
}
catch {
    Write-VesLog ERROR "Verification error: $($_.Exception.Message)" -LogFile $LogFile
    $result.status = 'error'; $result['detail']['error'] = $_.Exception.Message
    # errors exit as trust failure, never as a pass
    Out-Result $VES_EXIT_NOBASE
}
