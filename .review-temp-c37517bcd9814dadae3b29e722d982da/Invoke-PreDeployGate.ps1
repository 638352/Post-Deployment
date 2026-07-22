#Requires -Version 5.1
<#
.DESCRIPTION
    Two checks against SSM-pinned values:
      1. staged commit equals the UAT-approved commit
      2. (optional, when -TrustParam set) staged tree hashes to the trusted manifest

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
    [string]$Processor = 'unknown',
    [string]$Region = 'us-gov-west-1',
    [switch]$AllowOverride,
    [string]$OverrideReason,
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'

# Low-cardinality tags shared by every gate event emitted to Datadog.
$ddTags = @("processor:$Processor", (Get-VesDatadogEnvTag))

# central block path: log the reason, honor an audited break-glass override, else block the deploy
function Fail-Gate([string]$msg) {
    Write-VesLog ERROR "GATE FAIL: $msg" -Data @{processor=$Processor;staged=$StagedCommit} -LogFile $LogFile
    if ($AllowOverride) {
        if ([string]::IsNullOrWhiteSpace($OverrideReason)) {
            Write-VesLog ERROR '-AllowOverride requires -OverrideReason. Refusing.' -LogFile $LogFile
            exit $VES_EXIT_USAGE
        }
        # audited bypass: the override is recorded in the log with who/why/when
        Write-VesLog WARN "OVERRIDE ENGAGED by $env:USERNAME: $OverrideReason (staged=$StagedCommit)" `
            -Data @{processor=$Processor;override=$true;by=$env:USERNAME;reason=$OverrideReason} -LogFile $LogFile
        # Timeline event: an override is the exception worth seeing on the dashboard.
        Send-VesDatadogEvent -Title "Deploy gate OVERRIDE: $Processor" `
            -Text "Break-glass override by $env:USERNAME. Reason: $OverrideReason (staged=$StagedCommit). Gate FAIL was: $msg" `
            -AlertType 'warning' -Tags ($ddTags + 'event:gate-override')
        exit $VES_EXIT_OK
    }
    Write-VesLog ERROR "PRE-DEPLOY BLOCKED $Processor" -LogFile $LogFile
    # Timeline event: a hard block is an error marker on the deploy timeline.
    Send-VesDatadogEvent -Title "Deploy gate BLOCKED: $Processor" `
        -Text "Pre-deploy gate blocked $Processor (staged=$StagedCommit). Reason: $msg" `
        -AlertType 'error' -Tags ($ddTags + 'event:gate-blocked')
    exit $VES_EXIT_DRIFT
}

try {
    # Gate 1 (commit): the staged commit must equal the UAT-approved commit pinned in SSM
    $approved = Get-VesTrustedHash -ParameterName $ApprovedCommitParam -Region $Region
    Write-VesLog INFO "Approved commit (SSM): $approved" -LogFile $LogFile

    if ($StagedCommit -ne $approved) {
        Fail-Gate "Staged commit $StagedCommit != approved $approved"
    }
    Write-VesLog OK 'Commit gate PASS.' -LogFile $LogFile

    # Gate 2 (content, optional): the staged bytes must hash to the trusted manifest
    if ($TrustParam) {
        # content gate: right commit label isn't enough, the staged bytes have to match too
        $trustedHash = Get-VesTrustedHash -ParameterName $TrustParam -Region $Region
        $manifest = Get-VesManifest -ReleaseRoot $StagedRoot
        $stagedHash = Get-VesManifestHash -Manifest $manifest
        if ($stagedHash -ne $trustedHash) {
            Fail-Gate "Staged tree hash $stagedHash != trusted $trustedHash"
        }
        Write-VesLog OK 'Content gate PASS.' -LogFile $LogFile
    }

    # both gates passed: signal the deploy may proceed
    Write-VesLog OK "GATE PASS: deploy may proceed (staged=$StagedCommit approved)." -LogFile $LogFile
    # Timeline event: gate pass anchors the "authorized change" marker for drift overlay.
    Send-VesDatadogEvent -Title "Deploy gate PASS: $Processor" `
        -Text "Pre-deploy gate passed for $Processor (staged=$StagedCommit, approved)." `
        -AlertType 'success' -Tags ($ddTags + 'event:gate-pass')
    exit $VES_EXIT_OK
}
catch {
    # can't reach SSM or param missing: refuse rather than deploy unanchored
    Write-VesLog ERROR "Gate error (SSM/trust): $($_.Exception.Message)" -LogFile $LogFile
    exit $VES_EXIT_NOBASE
}