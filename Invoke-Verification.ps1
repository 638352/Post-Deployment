#Requires -Version 5.1
<#
.DESCRIPTION
    Modes:
      Capture       snapshot the UAT-approved release into a manifest and pin its hash to SSM
      VerifyFiles   hash-compare a deployed tree against the baseline manifest
      VerifyConfig  structural check of live config against a sanitized contract
      All           VerifyFiles then VerifyConfig

    Capture archives the release record to Git: -ArchiveRepo <path to a git
    checkout> commits the manifest and optional config contract under
    baselines/<processor>/; -ReleaseTag tags the commit and must match
    <system>/vMAJOR.MINOR.PATCH (e.g. OutboundDBQ/v1.4.0). A capture that
    cannot archive its record must fail closed. When -TrustParam is provided,
    the manifest hash is pinned to SSM so later verifies can detect tampering.

    VerifyFiles/All can source the baseline from the archived record instead of
    a local file: -BaselineRepo <git checkout> with -ReleaseTag reads the
    manifest committed under that tag. The SSM trust anchor still applies when
    -TrustParam is set.

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
    [Parameter(Mandatory)][ValidateSet('Capture', 'VerifyFiles', 'VerifyConfig', 'All')][string]$Mode,
    [string]$ReleaseRoot,
    [string]$ManifestPath,
    [string]$ConfigContract,
    [string]$ConfigPath,
    [string]$TrustParam,
    # Capture only: git checkout to commit the manifest/contract into, and an
    # optional release tag to pin the record under (audit layer; see header)
    [string]$ArchiveRepo,
    [string]$ReleaseTag,
    # Verify only: read the baseline manifest out of -ReleaseTag in this git
    # checkout instead of from -ManifestPath (the tag-archived release record).
    [string]$BaselineRepo,
    # Capture only: push the release commit and tag to the remote immediately;
    # a release record that exists only on one workstation is not an audit trail.
    [switch]$PushRemote,
    [string]$Remote = 'origin',
    [string]$Processor = 'unknown',
    [string]$CommitSha = 'unknown',
    [string]$Environment = 'prod',
    [string]$Region = 'us-gov-west-1',
    # Defaults to $Global:VES_DEFAULT_EXCLUDE, resolved after the module import
    # below. It cannot be the param default: defaults bind BEFORE the script body
    # runs, so the module constant does not exist yet at binding time and would
    # silently bind $null on a fresh session. See the module for the rules --
    # notably .config is excluded by design and checked by Verify-Config.ps1.
    [string]$ExcludePattern,
    [string]$LogFile,
    # Explicit exceptions for local development only. Normal capture fails
    # closed unless the manifest is trust-pinned and archived under a release tag.
    [switch]$AllowUntrustedCapture,
    [switch]$AllowUnarchivedCapture,
    [switch]$Json
)

Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
if (-not $LogFile) { $LogFile = New-VesLogFile -Prefix ("verification-{0}-{1}" -f $Processor, $Mode) }
$runId = [guid]::NewGuid().ToString()
# Now that the module is loaded, fall back to the shared default. Capture and
# compare must agree on this pattern or excluded files resurface as "Extra".
if (-not $ExcludePattern) { $ExcludePattern = $Global:VES_DEFAULT_EXCLUDE }
# accumulates the machine-readable result emitted when -Json is set
$result = [ordered]@{ runId = $runId; mode = $Mode; processor = $Processor; environment = $Environment; releaseTag = $ReleaseTag; status = $null; detail = @{} }
Write-VesLog INFO "RUN START: verification mode=$Mode" `
    -Data @{runId = $runId; script = 'Invoke-Verification.ps1'; processor = $Processor; environment = $Environment; release = $CommitSha; releaseTag = $ReleaseTag } `
    -LogFile $LogFile

# single exit point: optionally print the JSON result, then exit with the given code
function Out-Result([int]$code) {
    $outcome = Get-VesOutcome -ExitCode $code
    Write-VesLog ($(if ($outcome -eq 'PASS') { 'OK' } elseif ($outcome -eq 'FAIL') { 'DRIFT' } else { 'ERROR' })) `
        "RUN END: verification outcome=$outcome exit=$code" `
        -Data @{runId = $runId; outcome = $outcome; exitCode = $code; processor = $Processor; release = $CommitSha; releaseTag = $ReleaseTag } -LogFile $LogFile
    if ($Json) { ($result | ConvertTo-Json -Depth 6 -Compress) }
    exit $code
}
# Git plumbing (Invoke-VesGit) comes from the module, shared with the readback path.

# --- DATADOG DISABLED ---------------------------------------------------------
# Emit the verify outcome to Datadog as gauges (non-fatal), mirroring Invoke-HealthCheck.
# $ok = prod matches baseline; $mismatch = count of drifted items. Never blocks a verify.
# function Send-VerifyMetric([bool]$ok, [int]$mismatch) {
#     $ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag -Environment $Environment), 'check:verify', "mode:$Mode")
#     Send-VesDatadogMetric -Metric 'deployment.verify.status'   -Value ([int]$ok) -Tags $ddTags
#     Send-VesDatadogMetric -Metric 'deployment.verify.mismatch' -Value $mismatch  -Tags $ddTags
# }
# ------------------------------------------------------------------------------

try {
    switch ($Mode) {

        # Capture: snapshot the UAT-approved tree into a manifest and (optionally) pin its hash to SSM
        'Capture' {
            if (-not $ReleaseRoot) { Write-VesLog ERROR '-ReleaseRoot required for Capture' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }
            if (-not $ManifestPath) { Write-VesLog ERROR '-ManifestPath required for Capture' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }
            if (-not $TrustParam -and -not $AllowUntrustedCapture) {
                Write-VesLog ERROR 'Capture requires -TrustParam so the baseline is tamper-anchored. Use -AllowUntrustedCapture only for local development.' -LogFile $LogFile
                Out-Result $VES_EXIT_USAGE
            }
            elseif (-not $TrustParam) {
                Write-VesLog WARN 'No -TrustParam given; baseline is NOT trust-anchored because -AllowUntrustedCapture was supplied.' -LogFile $LogFile
            }
            if ((-not $ArchiveRepo -or -not $ReleaseTag) -and -not $AllowUnarchivedCapture) {
                Write-VesLog ERROR 'Capture requires -ArchiveRepo and -ReleaseTag so the approved baseline has a Git release record. Use -AllowUnarchivedCapture only for local development.' -LogFile $LogFile
                Out-Result $VES_EXIT_USAGE
            }
            elseif (-not $ArchiveRepo -or -not $ReleaseTag) {
                Write-VesLog WARN 'Archive/release-tag metadata is missing, but -AllowUnarchivedCapture was supplied so capture will proceed without Git archival.' -LogFile $LogFile
            }
            if ($ReleaseTag -and -not (Test-VesReleaseTag -Tag $ReleaseTag)) {
                Write-VesLog ERROR "-ReleaseTag must match <system>/vMAJOR.MINOR.PATCH (e.g. OutboundDBQ/v1.4.0); got '$ReleaseTag'." -LogFile $LogFile
                Out-Result $VES_EXIT_USAGE
            }
            # hash the release tree and write the manifest to disk
            Write-VesLog INFO "Capturing baseline: $ReleaseRoot" -Data @{processor = $Processor } -LogFile $LogFile
            $manifest = Get-VesManifest -ReleaseRoot $ReleaseRoot -ExcludePattern $ExcludePattern
            $hash = Export-VesManifest -Manifest $manifest -Path $ManifestPath -CommitSha $CommitSha -Processor $Processor
            Write-VesLog OK "Manifest written: $($manifest.Count) files, hash=$hash" -LogFile $LogFile
            # Audit layer: commit the release record (manifest + contract) to Git and
            # tag it BEFORE updating the active SSM trust pin. If archival fails,
            # the currently approved baseline remains active instead of pointing
            # at an unrecorded manifest.
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
                # Human- and machine-readable release note stored under the tag.
                # The tag commit already contains the verification scripts; this
                # record ties those scripts to the captured manifest and approval.
                $releaseRecord = [ordered]@{
                    schema       = 'ves.release-record.v1'
                    processor    = $Processor
                    environment  = $Environment
                    releaseTag   = $ReleaseTag
                    sourceCommit = $CommitSha
                    manifestHash = $hash
                    fileCount    = $manifest.Count
                    capturedUtc  = (Get-Date).ToUniversalTime().ToString('o')
                    capturedBy   = "$env:USERNAME@$env:COMPUTERNAME"
                    trustParam   = $TrustParam
                    note         = 'Tagged rollback points begin with the first verified release; anything shipped before that still needs a safe baseline determined manually.'
                }
                ($releaseRecord | ConvertTo-Json -Depth 5) |
                Out-File -FilePath (Join-Path $dest 'release-record.json') -Encoding utf8
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
                # Make the record durable off-host. A failed push fails the
                # capture: a release record on one workstation is not an audit trail.
                if ($PushRemote) {
                    # Explicit HEAD refspec: works on a checkout whose branch has
                    # no upstream configured yet (fresh archive repos).
                    [void](Invoke-VesGit @('-C', $ArchiveRepo, 'push', '--follow-tags', $Remote, 'HEAD'))
                    Write-VesLog OK ("Release record pushed to remote '{0}' (--follow-tags)." -f $Remote) -LogFile $LogFile
                    $result['detail']['pushedTo'] = $Remote
                }
            }
            # Activate only after the Git release record is durable.
            if ($TrustParam) {
                Set-VesTrustedHash -ParameterName $TrustParam -Value $hash -Region $Region
                Write-VesLog OK "Trusted hash pinned to SSM $TrustParam" -LogFile $LogFile
            }
            $result.status = 'captured'; $result.detail['fileCount'] = $manifest.Count; $result.detail['manifestHash'] = $hash
            Out-Result $VES_EXIT_OK
        }

        # VerifyFiles (and the file leg of All): hash-compare the deployed tree to the baseline
        { $_ -in 'VerifyFiles', 'All' } {
            if (-not $ReleaseRoot) { Write-VesLog ERROR '-ReleaseRoot required for file verification' -LogFile $LogFile; Out-Result $VES_EXIT_USAGE }
            $useTag = -not [string]::IsNullOrWhiteSpace($BaselineRepo)
            if ($useTag -and [string]::IsNullOrWhiteSpace($ReleaseTag)) {
                Write-VesLog ERROR '-BaselineRepo requires -ReleaseTag to locate the archived baseline.' -LogFile $LogFile
                Out-Result $VES_EXIT_USAGE
            }
            if (-not $ManifestPath -and -not $useTag) {
                Write-VesLog ERROR '-ManifestPath required (or -BaselineRepo/-ReleaseTag to read the tag-archived baseline)' -LogFile $LogFile
                Out-Result $VES_EXIT_USAGE
            }

            # load the baseline from the Git release tag when -BaselineRepo is set,
            # else from the local manifest file. Both paths yield the same shape,
            # so the self-hash and SSM trust checks below apply equally.
            if ($useTag) {
                $leafName = if ($ManifestPath) { Split-Path -Leaf $ManifestPath } else { $null }
                $m = Get-VesManifestFromTag -RepoPath $BaselineRepo -Tag $ReleaseTag -Processor $Processor -FileName $leafName
                Write-VesLog OK ("Baseline manifest read from Git release tag {0} ({1})." -f $ReleaseTag, $m.Source) -LogFile $LogFile
            }
            elseif ($ManifestPath) {
                $m = Import-VesManifest -Path $ManifestPath
            }
            else {
                Write-VesLog ERROR '-ManifestPath required when -BaselineRepo is not used' -LogFile $LogFile
                Out-Result $VES_EXIT_USAGE
            }
            # reject the baseline up front if its own self-hash doesn't match
            if (-not $m.Consistent) {
                # manifest was edited or corrupted after capture
                Write-VesLog ERROR "Manifest self-hash mismatch (tampered/corrupt): stored=$($m.StoredHash) recomputed=$($m.RecomputedHash)" -LogFile $LogFile
                $result.status = 'no-baseline'; Out-Result $VES_EXIT_NOBASE
            }

            # trust anchor: confirm the baseline still matches the hash pinned in SSM
            if ($TrustParam) {
                $trusted = Get-VesTrustedHash -ParameterName $TrustParam -Region $Region
                if ($m.RecomputedHash -ne $trusted) {
                    Write-VesLog ERROR "Manifest not trusted: SSM=$trusted manifest=$($m.RecomputedHash)" -LogFile $LogFile
                    $result.status = 'no-baseline'; Out-Result $VES_EXIT_NOBASE
                }
                Write-VesLog OK 'Manifest trust verified against SSM.' -LogFile $LogFile
            }
            else {
                Write-VesLog WARN 'No -TrustParam; skipping trust anchor (drift-only check).' -LogFile $LogFile
            }

            # compare live tree vs baseline and record the missing/changed/extra breakdown
            $cmp = Compare-VesFiles -Baseline $m.Doc.files -ReleaseRoot $ReleaseRoot -ExcludePattern $ExcludePattern
            $result['detail']['files'] = @{ missing = @($cmp.Missing); changed = @($cmp.Changed); extra = @($cmp.Extra) }
            if ($cmp.Match) {
                Write-VesLog OK 'File verify PASS: prod matches baseline.' -LogFile $LogFile
            }
            else {
                Write-VesLog DRIFT ("File verify FAIL: {0} missing, {1} changed, {2} extra" -f `
                        $cmp.Missing.Count, $cmp.Changed.Count, $cmp.Extra.Count) -LogFile $LogFile
                foreach ($x in $cmp.Missing) { Write-VesLog DRIFT "  MISSING $x" -LogFile $LogFile }
                foreach ($x in $cmp.Changed) { Write-VesLog DRIFT "  CHANGED $($x.RelPath)" -LogFile $LogFile }
                foreach ($x in $cmp.Extra) { Write-VesLog DRIFT "  EXTRA   $x" -LogFile $LogFile }
            }
            # files-only mode returns here; All mode stashes the result and falls through to config
            $filesOk = $cmp.Match
            if ($Mode -eq 'VerifyFiles') {
                $result.status = if ($filesOk) { 'match' } else { 'drift' }
                Out-Result ($(if ($filesOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
            }
            $script:filesOk = $filesOk               # All mode picks this up below
        }
    }

    # Config leg: runs for VerifyConfig, or as the second half of All
    if ($Mode -in 'VerifyConfig', 'All') {
        if (-not $ConfigContract -or -not $ConfigPath) {
            Write-VesLog ERROR '-ConfigContract and -ConfigPath required for config verify' -LogFile $LogFile
            Out-Result $VES_EXIT_USAGE
        }
        # delegate the structural config check to Verify-Config.ps1 and capture its pass/fail
        $cfg = & (Join-Path $PSScriptRoot 'Verify-Config.ps1') -ContractPath $ConfigContract -ConfigPath $ConfigPath -Region $Region -LogFile $LogFile
        $result['detail']['config'] = $cfg
        $configOk = [bool]$cfg.pass
        # config-only mode returns on config alone; All mode requires BOTH files and config to pass
        if ($Mode -eq 'VerifyConfig') {
            $result.status = if ($configOk) { 'match' } else { 'drift' }
            Out-Result ($(if ($configOk) { $VES_EXIT_OK } else { $VES_EXIT_DRIFT }))
        }
        $allOk = ($script:filesOk -and $configOk)
        $result.status = if ($allOk) { 'match' } else { 'drift' }
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
