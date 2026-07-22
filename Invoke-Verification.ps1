#Requires -Version 5.1
<#
.DESCRIPTION
    Modes:
      Capture       snapshot the UAT-approved release into a manifest and pin its hash to SSM
      VerifyFiles   hash-compare a deployed tree against the baseline manifest
      VerifyConfig  structural check of live config against a sanitized contract
      All           VerifyFiles then VerifyConfig

    Capture can also archive the release record to Git: -ArchiveRepo <path to a
    git checkout> commits the manifest (and the config contract, if -ConfigContract
    is passed) under baselines/<processor>/, and -ReleaseTag tags the commit
    (e.g. OutboundDBQ/v1.4.0). This is the audit layer the brief asks for: the
    manifest and sanitized contract live under a release tag as the rollback/
    audit point. An archive failure fails the capture (exit 2) -- an unrecorded
    baseline must not look captured.

    Exit codes: 0 match, 1 drift, 2 no baseline / trust failure, 10 usage.
    Replaces the earlier Verify-Deployment.ps1 Capture/Verify script.
.EXAMPLE
    .\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot C:\Procs\SYSTEM_NAME `
      -ManifestPath D:\baselines\SYSTEM_NAME.json `
      -TrustParam /ves/PROCESSOR/baseline-hash
.EXAMPLE
    .\Invoke-Verification.ps1 -Mode All -ReleaseRoot C:\Procs\SYSTEM_NAME `
      -ManifestPath D:\baselines\SYSTEM_NAME.json `
      -TrustParam /ves/PROCESSOR/baseline-hash `
      -ConfigContract D:\baselines\PROCESSOR.config.json `
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
    # Capture only: git checkout to commit the manifest/contract into, and an
    # optional release tag to pin the record under (audit layer; see header)
    [string]$ArchiveRepo,
    [string]$ReleaseTag,
    [string]$Processor = 'unknown',
    [string]$CommitSha = 'unknown',
    [string]$Region = 'us-gov-west-1',
    # Defaults to $Global:VES_DEFAULT_EXCLUDE, resolved after the module import
    # below. It cannot be the param default: defaults bind BEFORE the script body
    # runs, so the module constant does not exist yet at binding time and would
    # silently bind $null on a fresh session. See the module for the rules --
    # notably .config is excluded by design and checked by Verify-Config.ps1.
    [string]$ExcludePattern,
    [string]$LogFile,
    [switch]$Json
)

Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
# Now that the module is loaded, fall back to the shared default. Capture and
# compare must agree on this pattern or excluded files resurface as "Extra".
if (-not $ExcludePattern) { $ExcludePattern = $Global:VES_DEFAULT_EXCLUDE }
# accumulates the machine-readable result emitted when -Json is set
$result = [ordered]@{ mode=$Mode; processor=$Processor; status=$null; detail=@{} }

# single exit point: optionally print the JSON result, then exit with the given code
function Out-Result([int]$code) {
    if ($Json) { ($result | ConvertTo-Json -Depth 6 -Compress) }
    exit $code
}

# Run git and throw a readable error on any non-zero exit. Same PS 5.1 trap as
# the AWS CLI: under ErrorActionPreference=Stop, stderr from a native command
# becomes terminating, so scope the preference down around the call.
function Invoke-VesGit([string[]]$GitArgs) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git not found on PATH; required for -ArchiveRepo'
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git @GitArgs 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        throw ("git {0} failed (exit {1}): {2}" -f ($GitArgs -join ' '), $code, ((@($out) | ForEach-Object { "$_" }) -join ' '))
    }
    return (@($out) | ForEach-Object { "$_" }) -join "`n"
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
            # Audit layer: commit the release record (manifest + contract) to Git and
            # optionally tag it. Any failure throws into the outer catch -> exit 2,
            # because a baseline whose record didn't land must not look captured.
            if ($ArchiveRepo) {
                if (-not (Test-Path -LiteralPath (Join-Path $ArchiveRepo '.git'))) {
                    throw "-ArchiveRepo is not a git checkout: $ArchiveRepo"
                }
                $destRel = Join-Path 'baselines' $Processor
                $dest = Join-Path $ArchiveRepo $destRel
                if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                Copy-Item -LiteralPath $ManifestPath -Destination $dest -Force
                if ($ConfigContract) {
                    if (-not (Test-Path -LiteralPath $ConfigContract)) { throw "Config contract to archive not found: $ConfigContract" }
                    Copy-Item -LiteralPath $ConfigContract -Destination $dest -Force
                }
                [void](Invoke-VesGit @('-C', $ArchiveRepo, 'add', '--', $destRel))
                # skip the commit when a re-capture staged nothing new; the tag (if
                # any) then lands on the existing record
                $staged = $true
                try { [void](Invoke-VesGit @('-C', $ArchiveRepo, 'diff', '--cached', '--quiet')); $staged = $false } catch { $staged = $true }
                if ($staged) {
                    [void](Invoke-VesGit @('-C', $ArchiveRepo, 'commit', '-m',
                        ("Baseline capture: {0} commit={1} hash={2}" -f $Processor, $CommitSha, $hash)))
                }
                if ($ReleaseTag) {
                    [void](Invoke-VesGit @('-C', $ArchiveRepo, 'tag', '-a', $ReleaseTag, '-m',
                        ("Baseline {0} manifestHash={1}" -f $Processor, $hash)))
                }
                Write-VesLog OK ("Baseline archived to Git: {0} ({1})" -f $ArchiveRepo, $(if ($ReleaseTag) { "tag $ReleaseTag" } else { 'no tag' })) -LogFile $LogFile
                $result['detail']['archivedTo'] = $ArchiveRepo
                if ($ReleaseTag) { $result['detail']['releaseTag'] = $ReleaseTag }
            }
            $result.status = 'captured'; $result.detail['fileCount'] = $manifest.Count; $result.detail['manifestHash'] = $hash
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
