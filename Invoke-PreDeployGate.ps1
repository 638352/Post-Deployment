#Requires -Version 5.1
<#
.DESCRIPTION
    Two checks against SSM-pinned values:
      1. staged commit equals the UAT-approved commit
      2. (optional, when -TrustParam set) staged tree hashes to the trusted manifest

    When the content gate fails and -ManifestPath points at the baseline manifest,
    the block message names the exact files at fault ("Deployment blocked:
    bin/Storage.Net.dll is missing from the artifact") instead of only the
    aggregate hash mismatch. The manifest is only used for naming if its own hash
    matches the SSM-trusted hash, so a tampered manifest can't mislabel the diff.

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
    -Data @{runId=$runId; script='Invoke-PreDeployGate.ps1'; processor=$Processor; environment=$Environment; release=$StagedCommit} `
    -LogFile $LogFile

# Low-cardinality tags shared by every gate event emitted to Datadog.
$ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag -Environment $Environment))

function Stop-Gate([int]$code) {
    $outcome = Get-VesOutcome -ExitCode $code
    Write-VesLog ($(if ($outcome -eq 'PASS') {'OK'} elseif ($outcome -eq 'FAIL') {'ERROR'} else {'ERROR'})) `
        "RUN END: pre-deploy gate outcome=$outcome exit=$code" `
        -Data @{runId=$runId; outcome=$outcome; exitCode=$code; processor=$Processor; release=$StagedCommit} -LogFile $LogFile
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
        # Timeline event: an override is the exception worth seeing on the dashboard.
        Send-VesDatadogEvent -Title "Deploy gate OVERRIDE: $Processor" `
            -Text "Break-glass override by $env:USERNAME. Reason: $OverrideReason (staged=$StagedCommit). Gate FAIL was: $msg" `
            -AlertType 'warning' -Tags ($ddTags + 'event:gate-override')
        Stop-Gate $VES_EXIT_OK
    }
    Write-VesLog ERROR "PRE-DEPLOY BLOCKED $Processor" -LogFile $LogFile
    # Timeline event: a hard block is an error marker on the deploy timeline.
    Send-VesDatadogEvent -Title "Deploy gate BLOCKED: $Processor" `
        -Text "Pre-deploy gate blocked $Processor (staged=$StagedCommit). Reason: $msg" `
        -AlertType (Get-VesAlertType -Environment $Environment) -Tags ($ddTags + 'event:gate-blocked')
    Stop-Gate $VES_EXIT_DRIFT
}

try {
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

    # Gate 2 (content, optional): the staged bytes must hash to the trusted manifest
    if ($TrustParam) {
        # content gate: right commit label isn't enough, the staged bytes have to match too
        $trustedHash = Get-VesTrustedHash -ParameterName $TrustParam -Region $Region
        $manifest = Get-VesManifest -ReleaseRoot $StagedRoot
        $stagedHash = Get-VesManifestHash -Manifest $manifest
        if ($stagedHash -ne $trustedHash) {
            # Default message when we can't do better than the aggregate hash.
            $msg = "Staged tree hash $stagedHash != trusted $trustedHash"
            # Name the files at fault when the baseline manifest is available AND
            # itself matches the SSM-trusted hash (an untrusted manifest could
            # mislabel the diff, so it is not used for naming).
            if ($ManifestPath) {
                try {
                    $m = Import-VesManifest -Path $ManifestPath
                    if ($m.Consistent -and $m.RecomputedHash -eq $trustedHash) {
                        $cmp = Compare-VesFiles -Baseline $m.Doc.files -ReleaseRoot $StagedRoot
                        foreach ($x in $cmp.Missing) { Write-VesLog ERROR "  MISSING from artifact: $x" -LogFile $LogFile }
                        foreach ($x in $cmp.Changed) { Write-VesLog ERROR "  CHANGED vs approved:   $($x.RelPath)" -LogFile $LogFile }
                        foreach ($x in $cmp.Extra)   { Write-VesLog ERROR "  EXTRA in artifact:     $x" -LogFile $LogFile }
                        $counts = '{0} missing, {1} changed, {2} extra' -f $cmp.Missing.Count, $cmp.Changed.Count, $cmp.Extra.Count
                        if ($cmp.Missing.Count) {
                            $msg = "Deployment blocked: $($cmp.Missing[0]) is missing from the artifact ($counts)"
                        } else {
                            $msg = "Deployment blocked: staged artifact does not match the approved release ($counts)"
                        }
                    } else {
                        # The local manifest disagrees with SSM: that IS the likely story
                        # behind the hash mismatch, so say so instead of naming files off it.
                        Write-VesLog WARN "Baseline manifest at $ManifestPath is stale or tampered (does not match SSM-trusted hash); cannot name files." -LogFile $LogFile
                    }
                } catch {
                    Write-VesLog WARN "Could not read baseline manifest for file-level detail: $($_.Exception.Message)" -LogFile $LogFile
                }
            }
            Fail-Gate $msg
        }
        Write-VesLog OK 'Content gate PASS.' -LogFile $LogFile
    }

    # both gates passed: signal the deploy may proceed
    Write-VesLog OK "GATE PASS: deploy may proceed (staged=$StagedCommit approved)." -LogFile $LogFile
    # Timeline event: gate pass anchors the "authorized change" marker for drift overlay.
    Send-VesDatadogEvent -Title "Deploy gate PASS: $Processor" `
        -Text "Pre-deploy gate passed for $Processor (staged=$StagedCommit, approved)." `
        -AlertType 'success' -Tags ($ddTags + 'event:gate-pass')
    Stop-Gate $VES_EXIT_OK
}
catch {
    # can't reach SSM or param missing: refuse rather than deploy unanchored
    Write-VesLog ERROR "Gate error (SSM/trust): $($_.Exception.Message)" -LogFile $LogFile
    Stop-Gate $VES_EXIT_NOBASE
}
