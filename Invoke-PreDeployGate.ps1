#Requires -Version 5.1
<#
.DESCRIPTION
    Two checks against trusted values:
      1. staged commit equals the UAT-approved commit
      2. staged tree hashes to the trusted manifest, anchored by the SSM-pinned
         hash (-TrustParam), the manifest archived under the Git release tag
         (-BaselineRepo/-ReleaseTag), or both. When both are supplied they must
         agree — a rewritten tag can never relax the gate.

    The gate refuses to pass on the commit string alone: with NEITHER a trust
    parameter NOR a tag source it exits 10 instead of implying the artifact was
    inspected. -AllowCommitOnly is the explicit, logged exception.

    When the content gate fails and -ManifestPath points at the baseline manifest,
    the block message names the exact files at fault ("Deployment blocked:
    bin/Storage.Net.dll is missing from the artifact") instead of only the
    aggregate hash mismatch. The manifest is only used for naming if its own hash
    matches the trusted hash, so a tampered manifest can't mislabel the diff; the
    tag-archived manifest is used the same way when it is the anchor.

    Exit 0 pass, 1 blocked, 2 SSM/trust error, 10 usage.

    -AllowOverride is the break-glass path. It requires -OverrideReason and writes
    an audited OVERRIDE ENGAGED line to the log (who/why/when). Whether break-glass
    is permitted at all is still an open policy decision; Deploy-Processor.ps1 does
    not pass this switch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    [Parameter(Mandatory)][string]$ApprovedCommitParam,
    [string]$TrustParam,
    # baseline manifest path; optional, used only to NAME the files behind a
    # content-gate failure (missing/changed/extra) in the block message
    [string]$ManifestPath,
    # Git checkout holding the archived release records; with -ReleaseTag the
    # content gate reads the baseline manifest out of the tag itself.
    [string]$BaselineRepo,
    # Release tag of the approved baseline (e.g. OutboundDBQ/v1.4.0). Stamped
    # into run evidence; with -BaselineRepo it also anchors the content gate.
    [string]$ReleaseTag,
    # Explicit, logged exception: allow the gate to pass on the commit string
    # alone when no content source is configured. Never use for a real release.
    [switch]$AllowCommitOnly,
    # Relative files/folders that the hash manifest intentionally excludes
    # (notably environment-specific *.config files) but the artifact must carry.
    [string[]]$RequiredArtifactPaths = @(),
    [string]$Processor = 'unknown',
    [string]$Environment = 'prod',
    [string]$Region = 'us-gov-west-1',
    [switch]$AllowOverride,
    [string]$OverrideReason,
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
if (-not $LogFile) { $LogFile = New-VesLogFile -Prefix ("gate-{0}-{1}" -f $Processor, $StagedCommit) }
$runId = [guid]::NewGuid().ToString()
Write-VesLog INFO 'RUN START: pre-deploy gate' `
    -Data @{runId=$runId; script='Invoke-PreDeployGate.ps1'; processor=$Processor; environment=$Environment; release=$StagedCommit; releaseTag=$ReleaseTag} `
    -LogFile $LogFile

# --- DATADOG DISABLED ---------------------------------------------------------
# Low-cardinality tags shared by every gate event emitted to Datadog.
# $ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag -Environment $Environment))
# ------------------------------------------------------------------------------

function Stop-Gate([int]$code) {
    $outcome = Get-VesOutcome -ExitCode $code
    Write-VesLog ($(if ($outcome -eq 'PASS') {'OK'} elseif ($outcome -eq 'FAIL') {'ERROR'} else {'ERROR'})) `
        "RUN END: pre-deploy gate outcome=$outcome exit=$code" `
        -Data @{runId=$runId; outcome=$outcome; exitCode=$code; processor=$Processor; release=$StagedCommit; releaseTag=$ReleaseTag} -LogFile $LogFile
    exit $code
}

# central block path: log the reason, honor an audited break-glass override, else block the deploy
function Fail-Gate([string]$msg) {
    Write-VesLog ERROR "GATE FAIL: $msg" -Data @{processor=$Processor;staged=$StagedCommit} -LogFile $LogFile
    if ($AllowOverride) {
        if ([string]::IsNullOrWhiteSpace($OverrideReason)) {
            Write-VesLog ERROR '-AllowOverride requires -OverrideReason. Refusing.' -LogFile $LogFile
            Stop-Gate $VES_EXIT_USAGE
        }
        # audited bypass: the override is recorded in the log with who/why/when
        Write-VesLog WARN "OVERRIDE ENGAGED by $env:USERNAME: $OverrideReason (staged=$StagedCommit)" `
            -Data @{processor=$Processor;override=$true;by=$env:USERNAME;reason=$OverrideReason} -LogFile $LogFile
        # --- DATADOG DISABLED ---------------------------------------------------
        # Timeline event: an override is the exception worth seeing on the dashboard.
        # Send-VesDatadogEvent -Title "Deploy gate OVERRIDE: $Processor" `
        #     -Text "Break-glass override by $env:USERNAME. Reason: $OverrideReason (staged=$StagedCommit). Gate FAIL was: $msg" `
        #     -AlertType 'warning' -Tags ($ddTags + 'event:gate-override')
        # ------------------------------------------------------------------------
        Stop-Gate $VES_EXIT_OK
    }
    Write-VesLog ERROR "PRE-DEPLOY BLOCKED $Processor" -LogFile $LogFile
    # --- DATADOG DISABLED -------------------------------------------------------
    # Timeline event: a hard block is an error marker on the deploy timeline.
    # Send-VesDatadogEvent -Title "Deploy gate BLOCKED: $Processor" `
    #     -Text "Pre-deploy gate blocked $Processor (staged=$StagedCommit). Reason: $msg" `
    #     -AlertType (Get-VesAlertType -Environment $Environment) -Tags ($ddTags + 'event:gate-blocked')
    # ----------------------------------------------------------------------------
    Stop-Gate $VES_EXIT_DRIFT
}

try {
    # A tag source needs both halves: the repo to read from and the tag to read at.
    if ($BaselineRepo -and [string]::IsNullOrWhiteSpace($ReleaseTag)) {
        Write-VesLog ERROR '-BaselineRepo and -ReleaseTag must be supplied together.' -LogFile $LogFile
        Stop-Gate $VES_EXIT_USAGE
    }

    # Gate 1 (commit): the staged commit must equal the UAT-approved commit pinned in SSM
    $approved = Get-VesTrustedHash -ParameterName $ApprovedCommitParam -Region $Region
    Write-VesLog INFO "Approved commit (SSM): $approved" -LogFile $LogFile

    if ($StagedCommit -ne $approved) {
        Fail-Gate "Staged commit $StagedCommit != approved $approved"
    }
    Write-VesLog OK 'Commit gate PASS.' -LogFile $LogFile

    # Gate 1b (explicit structure/config): config files are excluded from byte
    # hashing because values differ by environment, but their presence must
    # still block deployment. The same mechanism supports required empty folders.
    if ($RequiredArtifactPaths.Count) {
        $stagedFull = [IO.Path]::GetFullPath((Get-Item -LiteralPath $StagedRoot -ErrorAction Stop).FullName).TrimEnd('\')
        $stagedPrefix = $stagedFull + '\'
        foreach ($relativePath in $RequiredArtifactPaths) {
            if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath)) {
                Fail-Gate "Invalid required artifact path '$relativePath'; paths must be non-empty and relative to StagedRoot."
            }
            $candidate = [IO.Path]::GetFullPath((Join-Path $stagedFull $relativePath))
            if (-not $candidate.StartsWith($stagedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Fail-Gate "Invalid required artifact path '$relativePath'; path escapes StagedRoot."
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                Fail-Gate "Deployment blocked: $relativePath is missing from the artifact."
            }
            Write-VesLog OK "Required artifact path present: $relativePath" -LogFile $LogFile
        }
    }

    # Gate 2 (content): the staged bytes must hash to the trusted manifest.
    # The trusted hash comes from SSM (-TrustParam), the tag-archived manifest
    # (-BaselineRepo/-ReleaseTag), or both (which must agree). A commit-string
    # match alone proves nothing about the artifact's contents.
    $useTag = -not [string]::IsNullOrWhiteSpace($BaselineRepo)
    if (-not $TrustParam -and -not $useTag) {
        if ($AllowCommitOnly) {
            Write-VesLog WARN 'AllowCommitOnly engaged: artifact content NOT verified; gate passed on the commit string alone.' `
                -Data @{processor=$Processor; allowCommitOnly=$true} -LogFile $LogFile
        } else {
            Write-VesLog ERROR 'No content check possible: supply -TrustParam or -BaselineRepo/-ReleaseTag, or pass -AllowCommitOnly explicitly (logged, local use only).' -LogFile $LogFile
            Stop-Gate $VES_EXIT_USAGE
        }
    } else {
        $ssmHash = $null
        $tagManifest = $null
        if ($TrustParam) {
            $ssmHash = Get-VesTrustedHash -ParameterName $TrustParam -Region $Region
        }
        if ($useTag) {
            # The archived leaf follows the capture convention <processor>.json
            # unless a -ManifestPath names a different leaf.
            $leafName = if ($ManifestPath) { Split-Path -Leaf $ManifestPath } else { $null }
            $tagManifest = Get-VesManifestFromTag -RepoPath $BaselineRepo -Tag $ReleaseTag -Processor $Processor -FileName $leafName
            if (-not $tagManifest.Consistent) {
                throw "Tag-archived manifest is internally inconsistent (tampered or corrupt): $($tagManifest.Source)"
            }
            Write-VesLog OK ("Baseline manifest read from Git release tag {0} ({1})." -f $ReleaseTag, $tagManifest.Source) -LogFile $LogFile
            if ($ssmHash -and $tagManifest.RecomputedHash -ne $ssmHash) {
                throw ("Tag-archived manifest hash {0} does not match the SSM-trusted hash {1}; a rewritten tag cannot relax the gate. Refusing." -f `
                    $tagManifest.RecomputedHash, $ssmHash)
            }
            if (-not $ssmHash) {
                Write-VesLog WARN 'Content gate anchored to the Git release tag only (no SSM trust parameter).' -LogFile $LogFile
            }
        }
        $trustedHash = if ($ssmHash) { $ssmHash } else { $tagManifest.RecomputedHash }

        $manifest = Get-VesManifest -ReleaseRoot $StagedRoot
        $stagedHash = Get-VesManifestHash -Manifest $manifest
        if ($stagedHash -ne $trustedHash) {
            # Default message when we can't do better than the aggregate hash.
            $msg = "Staged tree hash $stagedHash != trusted $trustedHash"
            # Name the files at fault when a baseline manifest is available AND
            # itself matches the trusted hash (an untrusted manifest could
            # mislabel the diff, so it is not used for naming). The local
            # -ManifestPath is preferred; the tag-archived manifest is the
            # fallback naming source when it is the anchor.
            $namingFiles = $null
            if ($ManifestPath) {
                try {
                    $m = Import-VesManifest -Path $ManifestPath
                    if ($m.Consistent -and $m.RecomputedHash -eq $trustedHash) {
                        $namingFiles = $m.Doc.files
                    } else {
                        # The local manifest disagrees with the anchor: that IS the likely
                        # story behind the hash mismatch, so say so instead of naming files off it.
                        Write-VesLog WARN "Baseline manifest at $ManifestPath is stale or tampered (does not match the trusted hash); cannot name files from it." -LogFile $LogFile
                    }
                } catch {
                    Write-VesLog WARN "Could not read baseline manifest for file-level detail: $($_.Exception.Message)" -LogFile $LogFile
                }
            }
            if (-not $namingFiles -and $tagManifest -and $tagManifest.RecomputedHash -eq $trustedHash) {
                $namingFiles = $tagManifest.Doc.files
            }
            if ($namingFiles) {
                $cmp = Compare-VesFiles -Baseline $namingFiles -ReleaseRoot $StagedRoot
                foreach ($x in $cmp.Missing) { Write-VesLog ERROR "  MISSING from artifact: $x" -LogFile $LogFile }
                foreach ($x in $cmp.Changed) { Write-VesLog ERROR "  CHANGED vs approved:   $($x.RelPath)" -LogFile $LogFile }
                foreach ($x in $cmp.Extra)   { Write-VesLog ERROR "  EXTRA in artifact:     $x" -LogFile $LogFile }
                $counts = '{0} missing, {1} changed, {2} extra' -f $cmp.Missing.Count, $cmp.Changed.Count, $cmp.Extra.Count
                if ($cmp.Missing.Count) {
                    $msg = "Deployment blocked: $($cmp.Missing[0]) is missing from the artifact ($counts)"
                } else {
                    $msg = "Deployment blocked: staged artifact does not match the approved release ($counts)"
                }
            }
            Fail-Gate $msg
        }
        Write-VesLog OK 'Content gate PASS.' -LogFile $LogFile
    }

    # both gates passed: signal the deploy may proceed
    Write-VesLog OK "GATE PASS: deploy may proceed (staged=$StagedCommit approved)." -LogFile $LogFile
    # --- DATADOG DISABLED -------------------------------------------------------
    # Timeline event: gate pass anchors the "authorized change" marker for drift overlay.
    # Send-VesDatadogEvent -Title "Deploy gate PASS: $Processor" `
    #     -Text "Pre-deploy gate passed for $Processor (staged=$StagedCommit, approved)." `
    #     -AlertType 'success' -Tags ($ddTags + 'event:gate-pass')
    # ----------------------------------------------------------------------------
    Stop-Gate $VES_EXIT_OK
}
catch {
    # can't reach SSM or param missing: refuse rather than deploy unanchored
    Write-VesLog ERROR "Gate error (SSM/trust): $($_.Exception.Message)" -LogFile $LogFile
    Stop-Gate $VES_EXIT_NOBASE
}
