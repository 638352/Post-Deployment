#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-deploy self-check. Validates the plumbing the deploy/verify scripts depend
    on WITHOUT touching prod files or staging a release, so an operator can confirm
    SSM connectivity and baseline integrity before running a real deploy.
.DESCRIPTION
    Read-only. Runs a set of checks and reports PASS / WARN / FAIL per check:

      aws-cli        the AWS CLI is on PATH (the module shells out to it)
      ssm:<param>    each SSM parameter reads back (auth + KMS decrypt + path +
                     region all exercised by a --with-decryption get-parameter)
      manifest       baseline manifest exists, is self-consistent, and its hash
                     matches the SSM-pinned trusted hash (tamper anchor intact)
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
    [switch]$Json
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'

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
    $out = & aws ssm get-parameter --name $ParamName --with-decryption `
        --region $Region --query 'Parameter.Value' --output text 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0 -and -not [string]::IsNullOrWhiteSpace(($out | Out-String))) {
        # don't echo the value; it may be a secret. show length only.
        $val = ($out | Out-String).Trim()
        Add-Check "ssm:$ParamName" 'PASS' ("readable ({0} chars)" -f $val.Length)
        return $val
    }
    $msg = ($out | Out-String).Trim()
    if ($msg -match 'ParameterNotFound') { $why = 'parameter does not exist (check path/region)' }
    elseif ($msg -match 'AccessDenied')   { $why = 'access denied (IAM ssm:GetParameter / kms:Decrypt)' }
    elseif ($msg -match 'ExpiredToken|Unable to locate credentials') { $why = 'no/expired credentials on host' }
    elseif ($msg) { $why = ($msg -replace '\s+',' ') }
    else { $why = "unreadable (aws exit $code, no output)" }
    Add-Check "ssm:$ParamName" 'FAIL' $why
    return $null
}

# --- baseline manifest integrity + trust anchor, no prod files needed ---
function Test-Manifest([string]$Path, [string]$Trust) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
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

function Test-ConfigContract([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
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
    if ($TargetsFile) {
        if (-not (Test-Path -LiteralPath $TargetsFile)) {
            Write-VesLog ERROR "Targets file not found: $TargetsFile" -LogFile $LogFile
            if ($Json) { @{ status='usage' } | ConvertTo-Json -Compress }
            exit $VES_EXIT_USAGE
        }
        Test-AwsCli
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
    else {
        if (-not $ApprovedCommitParam -and -not $TrustParam -and -not $ManifestPath) {
            Write-VesLog ERROR 'Provide -TargetsFile, or at least one of -ApprovedCommitParam / -TrustParam / -ManifestPath.' -LogFile $LogFile
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
catch {
    Write-VesLog ERROR "Preflight error: $($_.Exception.Message)" -LogFile $LogFile
    if ($Json) { @{ status='error'; error=$_.Exception.Message } | ConvertTo-Json -Compress }
    exit $VES_EXIT_NOBASE
}
