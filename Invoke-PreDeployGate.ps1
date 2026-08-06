#Requires -Version 5.1
<#
.SYNOPSIS
    Block a deploy whose staged commit or tree does not match the approved release.
.DESCRIPTION
    Two checks, both anchored to the release record archived under the Git tag
    (-BaselineRepo/-ReleaseTag):
      1. staged commit equals the commitSha recorded in the archived manifest
      2. staged tree hashes to that same archived manifest

    ANCHOR: this gate used to read an SSM-pinned approved commit and an
    SSM-pinned baseline hash. There is no AWS in this environment, which made
    exit 2 the gate's ONLY reachable outcome -- every deploy was blocked, and
    the artifact checks below never executed. The anchor is now the release tag.

    Both checks therefore rest on ONE anchor rather than two independent ones.
    That is a real reduction and it is deliberate: the honest alternative was a
    gate that could not run. The tag's integrity is now the whole control, so
    the archive remote MUST restrict who can move tags. A deployer who can
    force-push a tag can author their own approval.

    The gate refuses to pass without that anchor: no -BaselineRepo/-ReleaseTag
    means exit 10, never a pass. There is no commit-only mode -- without the
    archive there is no approved commit to compare against either, so passing
    on a commit string alone would have proved nothing at all.

    When the content gate fails and -ManifestPath points at the baseline manifest,
    the block message names the exact files at fault ("Deployment blocked:
    bin/Storage.Net.dll is missing from the artifact") instead of only the
    aggregate hash mismatch. The manifest is only used for naming if its own hash
    matches the trusted hash, so a tampered manifest can't mislabel the diff; the
    tag-archived manifest is used the same way when it is the anchor.

    Exit 0 pass, 1 blocked, 2 anchor unreadable/untrustworthy, 10 usage.

    -AllowOverride is the break-glass path. It requires -OverrideReason and writes
    an audited OVERRIDE ENGAGED line to the log (who/why/when). Whether break-glass
    is permitted at all is still an open policy decision; Deploy-Processor.ps1 does
    not pass this switch.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StagedRoot,
    [Parameter(Mandatory)][string]$StagedCommit,
    # baseline manifest path; optional, used only to NAME the files behind a
    # content-gate failure (missing/changed/extra) in the block message
    [string]$ManifestPath,
    # Git checkout holding the archived release records. Required: with
    # -ReleaseTag it supplies BOTH the approved commit and the baseline manifest.
    [string]$BaselineRepo,
    # Release tag of the approved baseline (e.g. OutboundDBQ/v1.4.0). Required.
    [string]$ReleaseTag,
    # Relative files/folders that the hash manifest intentionally excludes
    # (notably environment-specific *.config files) but the artifact must carry.
    [string[]]$RequiredArtifactPaths = @(),
    [string]$Processor = 'unknown',
    [string]$Environment = 'prod',
    [switch]$AllowOverride,
    [string]$OverrideReason,
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
# Deploy-Processor launches this gate with `powershell.exe -File`, which cannot
# carry an array; required artifacts arrive delimiter-joined. Split before use --
# a joined "a\x.config,b\y.config" would be probed as one nonexistent path and
# block every deploy that names two required artifacts.
$RequiredArtifactPaths = Expand-VesList -Value $RequiredArtifactPaths
# JSONL audit log is opt-in: pass -LogFile to persist a record of this run.
$runId = [guid]::NewGuid().ToString()
Write-VesLog INFO 'RUN START: pre-deploy gate' `
    -Data @{runId = $runId; script = 'Invoke-PreDeployGate.ps1'; processor = $Processor; environment = $Environment; release = $StagedCommit; releaseTag = $ReleaseTag } `
    -LogFile $LogFile

# --- DATADOG DISABLED ---------------------------------------------------------
# Low-cardinality tags shared by every gate event emitted to Datadog.
# $ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag -Environment $Environment))
# ------------------------------------------------------------------------------

function Stop-Gate([int]$code) {
    $outcome = Get-VesOutcome -ExitCode $code
    Write-VesLog ($(if ($outcome -eq 'PASS') { 'OK' } elseif ($outcome -eq 'FAIL') { 'ERROR' } else { 'ERROR' })) `
        "RUN END: pre-deploy gate outcome=$outcome exit=$code" `
        -Data @{runId = $runId; outcome = $outcome; exitCode = $code; processor = $Processor; release = $StagedCommit; releaseTag = $ReleaseTag } -LogFile $LogFile
    exit $code
}

# central block path: log the reason, honor an audited break-glass override, else block the deploy
function Deny-Gate([string]$msg) {
    Write-VesLog ERROR "GATE FAIL: $msg" -Data @{processor = $Processor; staged = $StagedCommit } -LogFile $LogFile
    if ($AllowOverride) {
        if ([string]::IsNullOrWhiteSpace($OverrideReason)) {
            Write-VesLog ERROR '-AllowOverride requires -OverrideReason. Refusing.' -LogFile $LogFile
            Stop-Gate $VES_EXIT_USAGE
        }
        # audited bypass: the override is recorded in the log with who/why/when
        Write-VesLog WARN "OVERRIDE ENGAGED by $env:USERNAME: $OverrideReason (staged=$StagedCommit)" `
            -Data @{processor = $Processor; override = $true; by = $env:USERNAME; reason = $OverrideReason } -LogFile $LogFile
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
    # Exit 1 = blocked, same numeric code as post-deploy file/config drift.
    # Monitoring should key off the PRE-DEPLOY BLOCKED log line / script name,
    # not assume every 1 means "prod drifted after install".
    Stop-Gate $VES_EXIT_DRIFT
}

try {
    # The anchor is not optional. Missing either half means there is nothing to
    # gate against, so this exits 10 rather than falling through to a pass.
    if ([string]::IsNullOrWhiteSpace($BaselineRepo) -or [string]::IsNullOrWhiteSpace($ReleaseTag)) {
        Write-VesLog ERROR 'No anchor: -BaselineRepo and -ReleaseTag are both required. The gate has nothing to compare against without them.' -LogFile $LogFile
        Stop-Gate $VES_EXIT_USAGE
    }
    if (-not (Test-VesReleaseTag -Tag $ReleaseTag)) {
        Write-VesLog ERROR "Malformed release tag '$ReleaseTag'; expected <system>/vMAJOR.MINOR.PATCH. A branch name is not a release anchor." -LogFile $LogFile
        Stop-Gate $VES_EXIT_USAGE
    }

    # Read the archived release record ONCE. Any failure here throws into the
    # catch below and exits 2 -- an unreadable anchor is indistinguishable from a
    # tag deleted to hide a change, so it must never degrade to a pass.
    $leafName = if ($ManifestPath) { Split-Path -Leaf $ManifestPath } else { $null }
    $tagManifest = Get-VesManifestFromTag -RepoPath $BaselineRepo -Tag $ReleaseTag -Processor $Processor -FileName $leafName
    if (-not $tagManifest.Consistent) {
        throw "Tag-archived manifest is internally inconsistent (tampered or corrupt): $($tagManifest.Source)"
    }
    Write-VesLog OK ("Release record read from {0} ({1})." -f $ReleaseTag, $tagManifest.Source) -LogFile $LogFile

    # Gate 1 (commit): the staged commit must equal the commitSha recorded in that
    # archived manifest. commitSha sits outside the manifest's own self-hash, but
    # it is inside the git object the tag points at, so it cannot be edited
    # without moving the tag -- the same trust basis as the content check below.
    $approved = "$($tagManifest.Doc.commitSha)".Trim()
    if ([string]::IsNullOrWhiteSpace($approved) -or $approved -eq 'unknown') {
        # A baseline captured without recording its commit cannot authorize
        # anything. Refuse rather than skip the check.
        throw ("Archived manifest at {0} records no commitSha (found '{1}'); it cannot approve a release. Re-capture with a real -CommitSha." -f `
                $tagManifest.Source, $approved)
    }
    Write-VesLog INFO "Approved commit (from ${ReleaseTag}): $approved" -LogFile $LogFile

    if ($StagedCommit -ne $approved) {
        Deny-Gate "Staged commit $StagedCommit != approved $approved"
    }
    Write-VesLog OK 'Commit gate PASS.' -LogFile $LogFile

    # Gate 1b (explicit structure/config): config files are excluded from byte
    # hashing because values differ by environment, but their presence must
    # still block deployment. The same mechanism supports required empty folders.
    if ($RequiredArtifactPaths.Count) {
        $stagedFull = [IO.Path]::GetFullPath((Get-Item -LiteralPath $StagedRoot -ErrorAction Stop).FullName).TrimEnd('\')
        $stagedPrefix = $stagedFull + '\'
        foreach ($relativePath in $RequiredArtifactPaths) {
            # Stop-Gate USAGE, not Deny-Gate: a malformed or rooted path is a caller
            # error, not a property of the artifact. Routing it through Deny-Gate put
            # it behind the break-glass path, where -AllowOverride would turn a typo
            # in -RequiredArtifactPaths into a gate PASS.
            if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath)) {
                Write-VesLog ERROR "Invalid required artifact path '$relativePath'; paths must be non-empty and relative to StagedRoot." -LogFile $LogFile
                Stop-Gate $VES_EXIT_USAGE
            }
            $candidate = [IO.Path]::GetFullPath((Join-Path $stagedFull $relativePath))
            if (-not $candidate.StartsWith($stagedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Write-VesLog ERROR "Invalid required artifact path '$relativePath'; path escapes StagedRoot." -LogFile $LogFile
                Stop-Gate $VES_EXIT_USAGE
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                Deny-Gate "Deployment blocked: $relativePath is missing from the artifact."
            }
            Write-VesLog OK "Required artifact path present: $relativePath" -LogFile $LogFile
        }
    }

    # Gate 2 (content): the staged bytes must hash to the archived manifest.
    # A commit-string match alone proves nothing about the artifact's contents,
    # so this always runs -- there is no mode that skips it.

    # This script has no -ExcludePattern: it always hashes StagedRoot with the
    # module default. A baseline captured under different rules therefore can
    # never match here, and the resulting hash mismatch would be reported as a
    # blocked deploy rather than as the misconfiguration it is.
    $tagPattern = Test-VesExcludePattern -ManifestDoc $tagManifest.Doc -ExcludePattern $Global:VES_DEFAULT_EXCLUDE
    if ($tagPattern.Known -and -not $tagPattern.Match) {
        throw ("Tag-archived manifest was captured under a different exclude pattern ('{0}') than this gate compares with ('{1}'); the comparison would be meaningless. Re-capture and re-tag." -f `
                $tagPattern.Recorded, $tagPattern.Effective)
    }
    $trustedHash = $tagManifest.RecomputedHash

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
                $localPattern = Test-VesExcludePattern -ManifestDoc $m.Doc -ExcludePattern $Global:VES_DEFAULT_EXCLUDE
                if ($localPattern.Known -and -not $localPattern.Match) {
                    # Naming files off a manifest built under other rules would
                    # invent missing/extra entries that are only pattern artefacts.
                    Write-VesLog WARN ("Baseline manifest at $ManifestPath was captured under a different exclude pattern ('{0}'); not naming files from it." -f $localPattern.Recorded) -LogFile $LogFile
                }
                elseif ($m.Consistent -and $m.RecomputedHash -eq $trustedHash) {
                    $namingFiles = $m.Doc.files
                }
                else {
                    # The local manifest disagrees with the anchor: that IS the likely
                    # story behind the hash mismatch, so say so instead of naming files off it.
                    Write-VesLog WARN "Baseline manifest at $ManifestPath is stale or tampered (does not match the trusted hash); cannot name files from it." -LogFile $LogFile
                }
            }
            catch {
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
            foreach ($x in $cmp.Extra) { Write-VesLog ERROR "  EXTRA in artifact:     $x" -LogFile $LogFile }
            $counts = '{0} missing, {1} changed, {2} extra' -f $cmp.Missing.Count, $cmp.Changed.Count, $cmp.Extra.Count
            if ($cmp.Missing.Count) {
                $msg = "Deployment blocked: $($cmp.Missing[0]) is missing from the artifact ($counts)"
            }
            else {
                $msg = "Deployment blocked: staged artifact does not match the approved release ($counts)"
            }
        }
        Deny-Gate $msg
    }
    Write-VesLog OK 'Content gate PASS.' -LogFile $LogFile

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
    # anchor unreadable, inconsistent, or recording no commit: refuse rather than
    # deploy unanchored. Never falls through to a pass.
    Write-VesLog ERROR "Gate error (anchor): $($_.Exception.Message)" -LogFile $LogFile
    Stop-Gate $VES_EXIT_NOBASE
}
