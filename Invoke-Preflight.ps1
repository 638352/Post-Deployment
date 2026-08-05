#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only self-check: baseline integrity and host readiness before a real run.
.DESCRIPTION
    Read-only. Runs a set of checks and reports PASS / WARN / FAIL per check:

      psversion      the host runs Windows PowerShell 5.1, not 7.x
      manifest       baseline manifest exists, is self-consistent, and -- when a
                     release tag is supplied -- matches the manifest archived
                     under that tag (tamper anchor intact)
      config         config contract file parses and declares a known format

    Two ways to invoke:
      -TargetsFile  : check manifest + config for every drift target
      per-processor : pass -ManifestPath / -ConfigContract / -BaselineRepo etc.

    TRUST ANCHOR: this suite once pinned the approved manifest hash to AWS SSM.
    There is no AWS in this environment and there never was, so those probes are
    gone (they made every box report NOT READY on a missing CLI). The anchor is
    now the manifest archived under the Git release tag: pass -BaselineRepo and
    -ReleaseTag and a mismatch is a hard FAIL. Without them the manifest can only
    be checked for self-consistency, which is NOT tamper evidence -- anyone who
    can edit the manifest can also restore its self-hash -- so that case reports
    WARN 'not anchored' rather than a clean PASS.

    Exit codes: 0 ready (WARNs allowed), 2 NOT ready (a hard check failed:
    wrong PowerShell major version, missing/corrupt manifest, or a manifest that
    disagrees with the tag-archived baseline), 10 usage.
    WARN-level items do not fail the run.
.EXAMPLE
    # before deploying one system, anchored against the approved release tag
    .\Invoke-Preflight.ps1 -Processor SYSTEM_NAME `
      -ManifestPath D:\baselines\SYSTEM_NAME.json `
      -BaselineRepo D:\ves-baselines -ReleaseTag SYSTEM_NAME/v1.4.0
.EXAMPLE
    # validate every drift target's baseline in one shot
    .\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json
#>
[CmdletBinding()]
param(
    [string]$Processor = 'unknown',
    [string]$ManifestPath,
    [string]$ConfigContract,
    [string]$TargetsFile,
    # Git checkout holding the archived release records. With -ReleaseTag this is
    # the trust anchor: the local manifest must agree with the one committed under
    # the tag. This replaced the SSM pin, which never existed in this environment.
    [string]$BaselineRepo,
    [string]$ReleaseTag,
    [string]$LogFile,
    # --- DATADOG DISABLED -----------------------------------------------------
    # Optional: probe whether the Datadog agent/API key are in place. WARN-only --
    # monitoring is best-effort, so it never flips readiness. Off by default so
    # boxes not yet wired for Datadog don't emit confusing warnings.
    # [switch]$CheckDatadog,
    # --------------------------------------------------------------------------
    [switch]$Json
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'
# JSONL audit log is opt-in: pass -LogFile to persist a record of this run.

# every check appends one row here; the final exit code is derived from their statuses
$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
    # Status is PASS, WARN, or FAIL. Only FAIL flips the exit code.
    $lvl = @{ PASS = 'OK'; WARN = 'WARN'; FAIL = 'ERROR' }[$Status]
    Write-VesLog $lvl ("{0,-22} {1}" -f $Name, $Detail) -LogFile $LogFile
    $checks.Add([PSCustomObject]@{ check = $Name; status = $Status; detail = $Detail })
}

# --- host runtime: these scripts are written for Windows PowerShell 5.1 ----------
function Test-PsVersion {
    # '#Requires -Version 5.1' is a floor, not a pin. PowerShell 7 satisfies it and
    # runs, which is the host we specifically don't want. Nothing in the OMS docs
    # records which version is installed on which box, so check it instead of
    # assuming it. Anything below 5.1 can't load the module at all, so by the time
    # this runs the only real question is 5.x vs 7.x.
    $v = $PSVersionTable.PSVersion
    $ed = if ($PSVersionTable.PSObject.Properties['PSEdition']) { $PSVersionTable.PSEdition } else { 'Desktop' }
    if ($v.Major -ne 5) {
        Add-Check 'psversion' 'FAIL' "PowerShell $v ($ed); these scripts target Windows PowerShell 5.1"
    }
    elseif ($v.Minor -lt 1) {
        Add-Check 'psversion' 'WARN' "PowerShell $v ($ed); 5.1 expected, 5.0 is untested here"
    }
    else {
        Add-Check 'psversion' 'PASS' "Windows PowerShell $v ($ed)"
    }
}

# --- release-tag anchor: read the archived baseline back out of the tag ---------
# Replaces the former SSM probe. Returns the archived manifest object, or $null
# when no anchor is configured or the readback fails; Test-Manifest decides the
# severity so the "no anchor at all" case can never be reported as a clean PASS.
function Get-TagAnchor([string]$ProcessorName, [string]$Tag) {
    if ([string]::IsNullOrWhiteSpace($BaselineRepo) -or [string]::IsNullOrWhiteSpace($Tag)) { return $null }
    if (-not (Test-VesReleaseTag -Tag $Tag)) {
        Add-Check 'release-tag' 'FAIL' "malformed release tag '$Tag'; expected <system>/vMAJOR.MINOR.PATCH"
        return $null
    }
    try {
        $archived = Get-VesManifestFromTag -RepoPath $BaselineRepo -Tag $Tag -Processor $ProcessorName
    }
    catch {
        # A configured anchor that cannot be read is a hard failure, never a pass:
        # it is indistinguishable from a tag that was deleted to hide a change.
        Add-Check 'release-tag' 'FAIL' "cannot read baseline from ${Tag}: $($_.Exception.Message)"
        return $null
    }
    if (-not $archived.Consistent) {
        Add-Check 'release-tag' 'FAIL' ("archived manifest self-hash mismatch at {0}" -f $archived.Source)
        return $null
    }
    Add-Check 'release-tag' 'PASS' ("baseline readable at {0}" -f $archived.Source)
    return $archived
}

# --- baseline captured under a superseded exclude pattern? ---------------------
# The exclude pattern once missed top-level logs\ / temp\ / cache\ / .git\ dirs, so
# baselines captured before that fix can carry entries the current pattern drops.
# Such a baseline is intact and trusted, but re-capturing it changes its hash and
# breaks the tag anchor -- so flag it here rather than let a scheduled drift check
# discover it as an exit 2 later. WARN, never FAIL.
function Test-ManifestPatternStale($Manifest) {
    $rels = @($Manifest.Doc.files | ForEach-Object { $_.RelPath })
    # manifest RelPaths are '/'-normalized; test them the way capture sees them
    $stale = @($rels | Where-Object { ($_ -replace '/', '\\') -match $Global:VES_DEFAULT_EXCLUDE })
    if ($stale.Count) {
        $sample = ($stale | Select-Object -First 3) -join ', '
        Add-Check 'manifest-pattern' 'WARN' ("{0} entr{1} the current exclude pattern would drop (e.g. {2}); re-capture to re-pin" -f `
                $stale.Count, $(if ($stale.Count -eq 1) { 'y' } else { 'ies' }), $sample)
    }
    else {
        Add-Check 'manifest-pattern' 'PASS' 'captured under the current exclude pattern'
    }
}

# --- baseline manifest integrity + trust anchor, no prod files needed ---
function Test-Manifest([string]$Path, [string]$ProcessorName, [string]$Tag) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # must exist, load, and be self-consistent before we bother with the trust anchor
    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Check 'manifest' 'FAIL' "not found: $Path"
        return
    }
    try { $m = Import-VesManifest -Path $Path }
    catch { Add-Check 'manifest' 'FAIL' "unreadable: $($_.Exception.Message)"; return }
    if (-not $m.Consistent) {
        Add-Check 'manifest' 'FAIL' "self-hash mismatch (edited/corrupt): stored=$($m.StoredHash) recomputed=$($m.RecomputedHash)"
        return
    }
    # intact, so it is worth asking whether it was captured under current rules
    Test-ManifestPatternStale $m
    # With a release tag configured, the local manifest must agree with the copy
    # archived under that tag. Disagreement is a hard FAIL: one of the two was
    # edited after the release was approved.
    $anchorName = if ([string]::IsNullOrWhiteSpace($ProcessorName)) { $Processor } else { $ProcessorName }
    # A target's own releaseTag wins over the script-level -ReleaseTag: in
    # -TargetsFile mode each target names the release it is supposed to be at.
    $anchorTag = if ([string]::IsNullOrWhiteSpace($Tag)) { $ReleaseTag } else { $Tag }
    $archived = Get-TagAnchor $anchorName $anchorTag
    if ($null -ne $archived) {
        if ($archived.RecomputedHash -ne $m.RecomputedHash) {
            Add-Check 'manifest' 'FAIL' ("anchor mismatch: {0}={1} local={2}" -f `
                    $anchorTag, $archived.RecomputedHash, $m.RecomputedHash)
        }
        else {
            Add-Check 'manifest' 'PASS' ("intact and anchored to {0} ({1} files)" -f $anchorTag, @($m.Doc.files).Count)
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($BaselineRepo) -or [string]::IsNullOrWhiteSpace($anchorTag)) {
        # No anchor configured at all. Self-consistency is NOT tamper evidence --
        # the self-hash lives inside the file it protects, so anyone who edits the
        # manifest can recompute it. Reporting PASS here would overstate the
        # control, so this is a WARN. It does not flip readiness, because an
        # unanchored baseline is a configuration gap, not a detected compromise.
        Add-Check 'manifest' 'WARN' ("self-consistent ({0} files) but NOT anchored; pass -BaselineRepo and -ReleaseTag to verify against the approved release" -f @($m.Doc.files).Count)
    }
    # else: Get-TagAnchor already logged a FAIL explaining why the anchor is unusable.
}

# --- DATADOG DISABLED: reachability probe (was WARN only, never blocked) -------
# function Test-DatadogAgent {
#     # A missing or stopped agent is a WARN, not a FAIL: verification works without
#     # it, monitoring just won't page anyone until it's up.
#     $svc = Get-Service -Name 'datadogagent' -ErrorAction SilentlyContinue
#     if (-not $svc) {
#         Add-Check 'datadog-agent' 'WARN' "service 'datadogagent' not found; drift/health metrics will be dropped"
#     }
#     elseif ($svc.Status -ne 'Running') {
#         Add-Check 'datadog-agent' 'WARN' "service present but $($svc.Status); metrics dropped until it runs"
#     }
#     else {
#         Add-Check 'datadog-agent' 'PASS' 'agent running (DogStatsD 127.0.0.1:8125)'
#     }
#     # Deploy/gate events use the API key (not the local agent), so flag its absence too.
#     if ([string]::IsNullOrWhiteSpace($env:DD_API_KEY)) {
#         Add-Check 'datadog-apikey' 'WARN' 'DD_API_KEY not set; deploy/gate events will be skipped'
#     }
#     else {
#         Add-Check 'datadog-apikey' 'PASS' 'DD_API_KEY present in environment'
#     }
# }
# ------------------------------------------------------------------------------

function Test-ConfigContract([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # the contract must exist, be valid JSON, and declare a format the verifier understands
    if (-not (Test-Path -LiteralPath $Path)) { Add-Check 'config' 'FAIL' "contract not found: $Path"; return }
    try { $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { Add-Check 'config' 'FAIL' "contract not valid JSON: $($_.Exception.Message)"; return }
    $fmt = if ($c.PSObject.Properties['format']) { $c.format } else { $null }
    if ($fmt -in 'appconfig', 'json', 'keyvalue') {
        Add-Check 'config' 'PASS' "contract parses, format=$fmt"
    }
    else {
        Add-Check 'config' 'FAIL' "contract format missing/unknown: '$fmt' (want appconfig|json|keyvalue)"
    }
}

try {
    # Host runtime first. Everything below assumes 5.1 behavior, and a wrong-version
    # host is worth reporting even when the run stops at the usage guard.
    Test-PsVersion

    # DATADOG DISABLED: optional agent reachability check ran in either mode when requested.
    # if ($CheckDatadog) { Test-DatadogAgent }

    # Mode A: -TargetsFile validates manifest + contract for every drift target at once
    if ($TargetsFile) {
        if (-not (Test-Path -LiteralPath $TargetsFile)) {
            Write-VesLog ERROR "Targets file not found: $TargetsFile" -LogFile $LogFile
            if ($Json) { @{ status = 'usage' } | ConvertTo-Json -Compress }
            exit $VES_EXIT_USAGE
        }
        # Import-VesTargetInventory, NOT a raw ConvertFrom-Json. Under the
        # ves.targets.v1 schema the parsed document is the ROOT object, so
        # `foreach ($t in $targets)` iterated it once as if it were a target:
        # every per-target field resolved to $null, Test-Manifest and
        # Test-ConfigContract both returned on their IsNullOrWhiteSpace guards,
        # and preflight exited 0 READY having checked no parameter, no manifest,
        # and no contract. Sharing the runner's validator also means the two can
        # never disagree about what counts as a complete inventory.
        $inventory = Import-VesTargetInventory -Path $TargetsFile
        foreach ($warning in $inventory.Warnings) { Add-Check 'inventory' 'WARN' $warning }
        foreach ($problem in $inventory.Errors) { Add-Check 'inventory' 'FAIL' $problem }
        if ($inventory.Valid) {
            Add-Check 'inventory' 'PASS' ("{0} confirmed target(s) covering {1} required server(s)" -f `
                @($inventory.Targets).Count, @($inventory.RequiredServers).Count)
        }
        # Per-target checks run even on an invalid inventory: the FAIL rows above
        # already decide readiness, and an operator fixing the inventory wants the
        # manifest/contract diagnosis in the same run rather than one round trip later.
        foreach ($t in $inventory.Targets) {
            $p = if ($t.PSObject.Properties['processor']) { $t.processor } else { '?' }
            Write-VesLog INFO "--- target: $p ---" -LogFile $LogFile
            $mp = if ($t.PSObject.Properties['manifestPath']) { $t.manifestPath }   else { $null }
            $cc = if ($t.PSObject.Properties['configContract']) { $t.configContract } else { $null }
            $rt = if ($t.PSObject.Properties['releaseTag']) { $t.releaseTag }     else { $null }
            Test-Manifest $mp $p $rt       # anchors against the target's own releaseTag
            Test-ConfigContract $cc
        }
    }
    # Mode B: per-processor invocation validates whichever of the params were supplied
    else {
        if (-not $ManifestPath -and -not $ConfigContract) {
            Write-VesLog ERROR 'Provide -TargetsFile, or at least one of -ManifestPath / -ConfigContract.' -LogFile $LogFile
            if ($Json) { @{ status = 'usage' } | ConvertTo-Json -Compress }
            exit $VES_EXIT_USAGE
        }
        Test-Manifest $ManifestPath $Processor    # anchors against -ReleaseTag when supplied
        Test-ConfigContract $ConfigContract
    }

    # tally the results: any FAIL means NOT READY (exit 2); WARNs are allowed
    $fails = @($checks | Where-Object { $_.status -eq 'FAIL' })
    $warns = @($checks | Where-Object { $_.status -eq 'WARN' })
    $ready = ($fails.Count -eq 0)
    $summary = "Preflight {0}: {1} pass, {2} warn, {3} fail" -f `
    ($(if ($ready) { 'READY' } else { 'NOT READY' })), `
    (@($checks | Where-Object { $_.status -eq 'PASS' }).Count), $warns.Count, $fails.Count
    Write-VesLog ($(if ($ready) { 'OK' } else { 'ERROR' })) $summary -LogFile $LogFile

    if ($Json) {
        [PSCustomObject]@{ processor = $Processor; ready = $ready; checks = $checks.ToArray() } | ConvertTo-Json -Depth 5 -Compress
    }
    exit ($(if ($ready) { $VES_EXIT_OK } else { $VES_EXIT_NOBASE }))
}
# unexpected failure (bad targets JSON, module error, etc.): treat as not-ready
catch {
    Write-VesLog ERROR "Preflight error: $($_.Exception.Message)" -LogFile $LogFile
    if ($Json) { @{ status = 'error'; error = $_.Exception.Message } | ConvertTo-Json -Compress }
    exit $VES_EXIT_NOBASE
}
