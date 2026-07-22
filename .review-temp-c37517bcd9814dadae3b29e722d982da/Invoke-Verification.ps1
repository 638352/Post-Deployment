#Requires -Version 5.1
<#
.DESCRIPTION
    Modes:
      Capture       snapshot the UAT-approved release into a manifest and pin its hash to SSM
      VerifyFiles   hash-compare a deployed tree against the baseline manifest
      VerifyConfig  structural check of live config against a sanitized contract
      All           VerifyFiles then VerifyConfig

    Exit codes: 0 match, 1 drift, 2 no baseline / trust failure, 10 usage.
    Replaces the earlier Verify-Deployment.ps1 Capture/Verify script.
.EXAMPLE
    .\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot C:\Procs\SYSTEM_NAME \
      -ManifestPath D:\baselines\SYSTEM_NAME.json \
      -TrustParam /ves/PROCESSOR/baseline-hash
.EXAMPLE
    .\Invoke-Verification.ps1 -Mode All -ReleaseRoot C:\Procs\SYSTEM_NAME \
      -ManifestPath D:\baselines\SYSTEM_NAME.json \
      -TrustParam /ves/PROCESSOR/baseline-hash \
      -ConfigContract D:\baselines\PROCESSOR.config.json \
      -ConfigPath E:\apps\PROCESSOR\app.config -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Capture','VerifyFiles','VerifyConfig','All')][string]$Mode,
    [string]$ReleaseRoot,
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
# accumulates the machine-readable result emitted when -Json is set
$result = [ordered]@{ mode=$Mode; processor=$Processor; status=$null; detail=@{} }

# single exit point: optionally print the JSON result, then exit with the given code
function Out-Result([int]$code) {
    if ($Json) { ($result | ConvertTo-Json -Depth 6 -Compress) }
    exit $code
}

# Emit the verify outcome to Datadog as gauges (non-fatal), mirroring Invoke-HealthCheck.
# $ok = prod matches baseline; $mismatch = count of drifted items. Never blocks a verify.
function Send-VerifyMetric([bool]$ok, [int]$mismatch) {
    $ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag), 'check:verify', "mode:$Mode")
    Send-VesDatadogMetric -Metric 'deployment.verify.status'   -Value ([int]$ok) -Tags $ddTags
    Send-VesDatadogMetric -Metric 'deployment.verify.mismatch' -Value $mismatch  -Tags $ddTags
}

try {
    switch ($Mode) {

        # Capture: snapshot the UAT-approved tree into a manifest and (optionally) pin its hash to SSM
        'Capture' {
            if (-not $ReleaseRoot) { Write-VesLog ERROR '-ReleaseRoot required for Capture' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }
            if (-not $ManifestPath) { Write-VesLog ERROR '-ManifestPath required for Capture' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }
            # hash the release tree and write the manifest to disk
            Write-VesLog INFO "Capturing baseline: $ReleaseRoot" -Data @{processor=$Processor} -LogFile $LogFile
            $manifest = Get-VesManifest -ReleaseRoot $ReleaseRoot -ExcludePattern $ExcludePattern
            $hash = Export-VesManifest -Manifest $manifest -Path $ManifestPath -CommitSha $CommitSha -Processor $Processor
            Write-VesLog OK "Manifest written: $($manifest.Count) files, hash=$hash" -LogFile $LogFile
            # anchor trust: pin the manifest hash to SSM so later verifies can detect tampering
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

        # VerifyFiles (and the file leg of All): hash-compare the deployed tree to the baseline
        { $_ -in 'VerifyFiles','All' } {
            if (-not $ReleaseRoot) { Write-VesLog ERROR '-ReleaseRoot required for file verification' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }
            if (-not $ManifestPath) { Write-VesLog ERROR '-ManifestPath required' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }

            # load the baseline and reject it up front if its own self-hash doesn't match
            $m = Import-VesManifest -Path $ManifestPath
            if (-not $m.Consistent) {
                # manifest was edited or corrupted after capture
                Write-VesLog ERROR "Manifest self-hash mismatch (tampered/corrupt): stored=$($m.StoredHash) recomputed=$($m.RecomputedHash)" -LogFile $LogFile
                $result.status='no-baseline'; Out-Result $VES_EXIT_NOBASE
            }

            # trust anchor: confirm the baseline still matches the hash pinned in SSM
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

            # compare live tree vs baseline and record the missing/changed/extra breakdown
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
            # files-only mode returns here; All mode stashes the result and falls through to config
            $filesOk = $cmp.Match
            $fileMismatch = $cmp.Missing.Count + $cmp.Changed.Count + $cmp.Extra.Count
            if ($Mode -eq 'VerifyFiles') {
                $result.status = if ($filesOk) {'match'} else {'drift'}
                Send-VerifyMetric $filesOk $fileMismatch
                Out-Result ($(if ($filesOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
            }
            $script:filesOk = $filesOk               # All mode picks these up below
            $script:fileMismatch = $fileMismatch
        }
    }

    # Config leg: runs for VerifyConfig, or as the second half of All
    if ($Mode -in 'VerifyConfig','All') {
        if (-not $ConfigContract -or -not $ConfigPath) {
            Write-VesLog ERROR '-ConfigContract and -ConfigPath required for config verify' -LogFile $LogFile
            Out-Result $VES_EXIT_USAGE
        }
        # delegate the structural config check to Verify-Config.ps1 and capture its pass/fail
        $cfg = & (Join-Path $PSScriptRoot 'Verify-Config.ps1') -ContractPath $ConfigContract -ConfigPath $ConfigPath -Region $Region -LogFile $LogFile
        $result['detail']['config'] = $cfg
        $configOk = [bool]$cfg.pass
        $cfgMismatch = $cfg.missingRequired.Count + $cfg.valueMismatch.Count
        # config-only mode returns on config alone; All mode requires BOTH files and config to pass
        if ($Mode -eq 'VerifyConfig') {
            $result.status = if ($configOk) {'match'} else {'drift'}
            Send-VerifyMetric $configOk $cfgMismatch
            Out-Result ($(if ($configOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
        }
        $allOk = ($script:filesOk -and $configOk)
        $result.status = if ($allOk) {'match'} else {'drift'}
        Send-VerifyMetric $allOk ($script:fileMismatch + $cfgMismatch)
        Out-Result ($(if ($allOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
    }
}
# any unhandled error (bad SSM read, unreadable tree, etc.) lands here
catch {
    Write-VesLog ERROR "Verification error: $($_.Exception.Message)" -LogFile $LogFile
    $result.status = 'error'; $result['detail']['error'] = $_.Exception.Message
    # errors exit as trust failure, never as a pass
    Out-Result $VES_EXIT_NOBASE
}
