#Requires -Version 5.1
<#
.DESCRIPTION
    Read-only. Runs a set of checks and reports PASS / WARN / FAIL per check:

      aws-cli        the AWS CLI is on PATH (the module shells out to it)
      ssm:<param>    each SSM parameter reads back (auth + KMS decrypt + path +
                     region all exercised by a --with-decryption get-parameter)
      manifest       baseline manifest exists, is self-consistent, and its hash
                     matches the SSM-pinned trusted hash (tamper anchor intact)
      manifest-pattern  baseline holds no entries the current exclude pattern
                     would drop (WARN = captured under older rules, re-capture
                     and re-pin; readiness is not affected)
      config         config contract file parses and declares a known format

    Two ways to invoke:
      -TargetsFile  : check trustParam + manifest + config for every drift target
      per-processor : pass -ApprovedCommitParam / -TrustParam / -ManifestPath etc.

    Exit codes: 0 ready (WARNs allowed), 2 NOT ready (a hard check failed:
    missing CLI, unreadable SSM param, or manifest trust mismatch), 10 usage.
    WARN-level items do not fail the run.
.EXAMPLE
    # before deploying one system
    .\Invoke-Preflight.ps1 -Processor SYSTEM_NAME `
      -ApprovedCommitParam /ves/SYSTEM_NAME/approved-commit `
      -TrustParam /ves/SYSTEM_NAME/baseline-hash `
      -ManifestPath D:\baselines\SYSTEM_NAME.json
.EXAMPLE
    # validate every drift target's SSM + baseline in one shot
    .\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json
#>
[CmdletBinding()]
param(
    [string]$Processor = 'unknown',
    [string]$ApprovedCommitParam,
    [string]$TrustParam,
    [string]$ManifestPath,
    [string]$ConfigContract,
    [string]$TargetsFile,
    [string]$Region = 'us-gov-west-1',
    [string]$LogFile,
    # Optional: probe whether the Datadog agent/API key are in place. WARN-only --
    # monitoring is best-effort, so it never flips readiness. Off by default so
    # boxes not yet wired for Datadog don't emit confusing warnings.
    [switch]$CheckDatadog,
    [switch]$Json
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'

# every check appends one row here; the final exit code is derived from their statuses
$checks = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
    # Status is PASS, WARN, or FAIL. Only FAIL flips the exit code.
    $lvl = @{ PASS='OK'; WARN='WARN'; FAIL='ERROR' }[$Status]
    Write-VesLog $lvl ("{0,-22} {1}" -f $Name, $Detail) -LogFile $LogFile
    $checks.Add([PSCustomObject]@{ check=$Name; status=$Status; detail=$Detail })
}

# --- SSM probe: distinguish "no CLI" / "not found" / "denied" for a real diagnosis ---
$script:awsChecked = $false
function Test-AwsCli {
    if ($script:awsChecked) { return }
    $script:awsChecked = $true
    if (Get-Command aws -ErrorAction SilentlyContinue) {
        Add-Check 'aws-cli' 'PASS' 'AWS CLI found on PATH'
    } else {
        Add-Check 'aws-cli' 'FAIL' 'AWS CLI not on PATH; SSM reads will fail'
    }
}
function Test-SsmParam([string]$ParamName) {
    if ([string]::IsNullOrWhiteSpace($ParamName)) { return }
    Test-AwsCli
    # Invoke-VesAwsCli, not a bare '& aws ... 2>&1': under $ErrorActionPreference
    # ='Stop' the CLI's stderr becomes a TERMINATING error, which used to abort the
    # whole run into the outer catch. That made the classification below dead code
    # on exactly the failures it exists to explain, and (in -TargetsFile mode)
    # aborted on the first bad target instead of reporting every one.
    $r = Invoke-VesAwsCli -Arguments @(
        'ssm','get-parameter','--name',$ParamName,'--with-decryption',
        '--region',$Region,'--query','Parameter.Value','--output','text')
    # success: report readability by length only (the value may be a secret)
    if ($r.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.StdOut)) {
        # don't echo the value; it may be a secret. show length only.
        $val = $r.StdOut.Trim()
        Add-Check "ssm:$ParamName" 'PASS' ("readable ({0} chars)" -f $val.Length)
        return $val
    }
    # failure: translate the CLI's error text into an actionable reason
    $msg = $r.StdErr.Trim()
    if ($msg -match 'ParameterNotFound') { $why = 'parameter does not exist (check path/region)' }
    elseif ($msg -match 'AccessDenied')   { $why = 'access denied (IAM ssm:GetParameter / kms:Decrypt)' }
    elseif ($msg -match 'ExpiredToken|Unable to locate credentials') { $why = 'no/expired credentials on host' }
    elseif ($msg) { $why = ($msg -replace '\s+',' ') }
    else { $why = "unreadable (aws exit $($r.ExitCode), no output)" }
    Add-Check "ssm:$ParamName" 'FAIL' $why
    return $null
}

# --- baseline captured under a superseded exclude pattern? ---------------------
# The exclude pattern once missed top-level logs\ / temp\ / cache\ / .git\ dirs, so
# baselines captured before that fix can carry entries the current pattern drops.
# Such a baseline is intact and trusted, but re-capturing it changes its hash and
# breaks the SSM pin -- so flag it here rather than let a scheduled drift check
# discover it as an exit 2 at 2am. Needs no prod files: it reads the manifest's own
# file list. WARN, never FAIL -- the box is ready, the baseline just needs re-pinning.
function Test-ManifestPatternStale($Manifest) {
    $rels = @($Manifest.Doc.files | ForEach-Object { $_.RelPath })
    # manifest RelPaths are '/'-normalized; test them the way capture would see them
    $stale = @($rels | Where-Object { ($_ -replace '/','\') -match $Global:VES_DEFAULT_EXCLUDE })
    if ($stale.Count) {
        $sample = ($stale | Select-Object -First 3) -join ', '
        Add-Check 'manifest-pattern' 'WARN' ("{0} entr{1} the current exclude pattern would drop (e.g. {2}); re-capture to re-pin" -f `
            $stale.Count, $(if ($stale.Count -eq 1) {'y'} else {'ies'}), $sample)
    } else {
        Add-Check 'manifest-pattern' 'PASS' 'captured under the current exclude pattern'
    }
}

# --- baseline manifest integrity + trust anchor, no prod files needed ---
function Test-Manifest([string]$Path, [string]$Trust) {
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
    # intact, so it is worth asking whether it was captured under the current rules
    Test-ManifestPatternStale $m
    # if a trust param is given, the manifest hash must match the SSM-pinned value
    if (-not [string]::IsNullOrWhiteSpace($Trust)) {
        $pinned = Test-SsmParam $Trust
        if ($null -eq $pinned) {
            Add-Check 'manifest' 'WARN' 'self-consistent, but trust hash unreadable (see ssm check above)'
        } elseif ($pinned -ne $m.RecomputedHash) {
            Add-Check 'manifest' 'FAIL' "trust mismatch: SSM=$pinned manifest=$($m.RecomputedHash)"
        } else {
            Add-Check 'manifest' 'PASS' "intact and trust-anchored ($($m.Doc.fileCount) files)"
        }
    } else {
        Add-Check 'manifest' 'PASS' "self-consistent ($($m.Doc.fileCount) files); no -TrustParam to anchor against"
    }
}

# --- Datadog reachability (optional; WARN only, never blocks readiness) ---------
function Test-DatadogAgent {
    # A missing or stopped agent is a WARN, not a FAIL: verification works without
    # it, monitoring just won't page anyone until it's up.
    $svc = Get-Service -Name 'datadogagent' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Check 'datadog-agent' 'WARN' "service 'datadogagent' not found; drift/health metrics will be dropped"
    } elseif ($svc.Status -ne 'Running') {
        Add-Check 'datadog-agent' 'WARN' "service present but $($svc.Status); metrics dropped until it runs"
    } else {
        Add-Check 'datadog-agent' 'PASS' 'agent running (DogStatsD 127.0.0.1:8125)'
    }
    # Deploy/gate events use the API key (not the local agent), so flag its absence too.
    if ([string]::IsNullOrWhiteSpace($env:DD_API_KEY)) {
        Add-Check 'datadog-apikey' 'WARN' 'DD_API_KEY not set; deploy/gate events will be skipped'
    } else {
        Add-Check 'datadog-apikey' 'PASS' 'DD_API_KEY present in environment'
    }
}

function Test-ConfigContract([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    # the contract must exist, be valid JSON, and declare a format the verifier understands
    if (-not (Test-Path -LiteralPath $Path)) { Add-Check 'config' 'FAIL' "contract not found: $Path"; return }
    try { $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { Add-Check 'config' 'FAIL' "contract not valid JSON: $($_.Exception.Message)"; return }
    $fmt = if ($c.PSObject.Properties['format']) { $c.format } else { $null }
    if ($fmt -in 'appconfig','json','keyvalue') {
        Add-Check 'config' 'PASS' "contract parses, format=$fmt"
    } else {
        Add-Check 'config' 'FAIL' "contract format missing/unknown: '$fmt' (want appconfig|json|keyvalue)"
    }
}

try {
    # Optional agent reachability check runs in either mode when requested.
    if ($CheckDatadog) { Test-DatadogAgent }

    # Mode A: -TargetsFile validates SSM + manifest + contract for every drift target at once
    if ($TargetsFile) {
        if (-not (Test-Path -LiteralPath $TargetsFile)) {
            Write-VesLog ERROR "Targets file not found: $TargetsFile" -LogFile $LogFile
            if ($Json) { @{ status='usage' } | ConvertTo-Json -Compress }
            exit $VES_EXIT_USAGE
        }
        Test-AwsCli
        # run the manifest + config checks per target, reading each target's own params
        $targets = Get-Content -LiteralPath $TargetsFile -Raw | ConvertFrom-Json
        foreach ($t in $targets) {
            $p = if ($t.PSObject.Properties['processor']) { $t.processor } else { '?' }
            Write-VesLog INFO "--- target: $p ---" -LogFile $LogFile
            $tp = if ($t.PSObject.Properties['trustParam'])     { $t.trustParam }     else { $null }
            $mp = if ($t.PSObject.Properties['manifestPath'])   { $t.manifestPath }   else { $null }
            $cc = if ($t.PSObject.Properties['configContract']) { $t.configContract } else { $null }
            Test-Manifest $mp $tp          # also reads trustParam from SSM
            Test-ConfigContract $cc
        }
    }
    # Mode B: per-processor invocation validates whichever of the params were supplied
    else {
        if (-not $ApprovedCommitParam -and -not $TrustParam -and -not $ManifestPath -and -not $ConfigContract -and -not $CheckDatadog) {
            Write-VesLog ERROR 'Provide -TargetsFile, or at least one of -ApprovedCommitParam / -TrustParam / -ManifestPath / -ConfigContract / -CheckDatadog.' -LogFile $LogFile
            if ($Json) { @{ status='usage' } | ConvertTo-Json -Compress }
            exit $VES_EXIT_USAGE
        }
        # $null = : these probe for their PASS/FAIL side effect; discard the
        # returned parameter value so a (possibly sensitive) SSM value never leaks
        # to stdout/console.
        $null = Test-SsmParam $ApprovedCommitParam
        Test-Manifest $ManifestPath $TrustParam   # reads TrustParam from SSM if set
        if ($TrustParam -and -not $ManifestPath) { $null = Test-SsmParam $TrustParam }  # still probe the param
        Test-ConfigContract $ConfigContract
    }

    # tally the results: any FAIL means NOT READY (exit 2); WARNs are allowed
    $fails = @($checks | Where-Object { $_.status -eq 'FAIL' })
    $warns = @($checks | Where-Object { $_.status -eq 'WARN' })
    $ready = ($fails.Count -eq 0)
    $summary = "Preflight {0}: {1} pass, {2} warn, {3} fail" -f `
        ($(if ($ready) {'READY'} else {'NOT READY'})), `
        (@($checks | Where-Object { $_.status -eq 'PASS' }).Count), $warns.Count, $fails.Count
    Write-VesLog ($(if ($ready) {'OK'} else {'ERROR'})) $summary -LogFile $LogFile

    if ($Json) {
        [PSCustomObject]@{ processor=$Processor; ready=$ready; checks=$checks.ToArray() } | ConvertTo-Json -Depth 5 -Compress
    }
    exit ($(if ($ready) { $VES_EXIT_OK } else { $VES_EXIT_NOBASE }))
}
# unexpected failure (bad targets JSON, module error, etc.): treat as not-ready
catch {
    Write-VesLog ERROR "Preflight error: $($_.Exception.Message)" -LogFile $LogFile
    if ($Json) { @{ status='error'; error=$_.Exception.Message } | ConvertTo-Json -Compress }
    exit $VES_EXIT_NOBASE
}