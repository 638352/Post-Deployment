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
# accumulates the machine-readable result emitted when -Json is set
$result = [ordered]@{ mode=$Mode; processor=$Processor; status=$null; detail=@{} }

# single exit point: emit the outcome gauges, optionally print the JSON result,
# then exit with the given code
function Out-Result([int]$code) {
    # every verify outcome goes out as a pair of gauges, tagged by mode.
    # Capture and usage errors are not verifies, so they emit nothing.
    if ($Mode -ne 'Capture' -and $code -ne $VES_EXIT_USAGE) {
        $mismatch = 0
        if ($result['detail'] -is [hashtable] -and $result['detail'].ContainsKey('files')) {
            $f = $result['detail']['files']
            $mismatch = @($f.missing).Count + @($f.changed).Count + @($f.extra).Count
        }
        $tags = @("processor:$Processor", "mode:$Mode")
        Send-VesDatadogMetric -Metric 'deployment.verify.status' `
            -Value ($(if ($code -eq $VES_EXIT_OK) { 1 } else { 0 })) -Tags $tags
        Send-VesDatadogMetric -Metric 'deployment.verify.mismatch' -Value $mismatch -Tags $tags
    }
    if ($Json) { ($result | ConvertTo-Json -Depth 6 -Compress) }
    exit $code
}

try {
    # mode dispatch
    switch ($Mode) {

        # Capture: snapshot the UAT-approved tree into a manifest and (optionally) pin its hash to SSM
        'Capture' {
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
                # the SSM pin is the authority, not the file sitting on disk
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
            # two-step assignment: chained index-set into the ordered dict is
            # unreliable under the PS7 binder; identical behavior on 5.1
            $detail = $result['detail']
            # .ToArray() rather than @(): the array subexpression over a generic
            # List of PSCustomObjects misbinds under the PS7 binder
            $detail['files'] = @{ missing=$cmp.Missing.ToArray(); changed=$cmp.Changed.ToArray(); extra=$cmp.Extra.ToArray() }
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
            if ($Mode -eq 'VerifyFiles') {
                $result.status = if ($filesOk) {'match'} else {'drift'}
                Out-Result ($(if ($filesOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
            }
            $script:filesOk = $filesOk   # All mode picks this up below
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
        $detail = $result['detail']
        $detail['config'] = $cfg
        $configOk = [bool]$cfg.pass
        # config-only mode returns on config alone; All mode requires BOTH files and config to pass
        if ($Mode -eq 'VerifyConfig') {
            $result.status = if ($configOk) {'match'} else {'drift'}
            Out-Result ($(if ($configOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
        }
        $allOk = ($script:filesOk -and $configOk)
        $result.status = if ($allOk) {'match'} else {'drift'}
        Out-Result ($(if ($allOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
    }
}
# any unhandled error (bad SSM read, unreadable tree, etc.) lands here
catch {
    Write-VesLog ERROR "Verification error: $($_.Exception.Message)" -LogFile $LogFile
    $result.status = 'error'; $detail = $result['detail']; $detail['error'] = $_.Exception.Message
    # errors exit as trust failure, never as a pass
    Out-Result $VES_EXIT_NOBASE
}
