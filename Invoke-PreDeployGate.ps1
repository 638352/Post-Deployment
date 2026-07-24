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

# central block path: log the reason, honor an audited break-glass override, else block the deploy
function Fail-Gate([string]$msg) {
    Write-VesLog ERROR "GATE FAIL: $msg" -Data @{processor=$Processor;staged=$StagedCommit} -LogFile $LogFile
    if ($AllowOverride) {
        if ([string]::IsNullOrWhiteSpace($OverrideReason)) {
            Write-VesLog ERROR '-AllowOverride requires -OverrideReason. Refusing.' -LogFile $LogFile
            exit $VES_EXIT_USAGE
        }
        # audited bypass: the override is recorded in the log with who/why/when,
        # and announced on the Datadog timeline so an override is never quiet
        Write-VesLog WARN "OVERRIDE ENGAGED by $env:USERNAME: $OverrideReason (staged=$StagedCommit)" `
            -Data @{processor=$Processor;override=$true;by=$env:USERNAME;reason=$OverrideReason} -LogFile $LogFile
        Send-VesDatadogEvent -Title "Pre-deploy gate OVERRIDE: $Processor" `
            -Text "Break-glass by $env:USERNAME. Reason: $OverrideReason. Staged=$StagedCommit. Original failure: $msg" `
            -AlertType warning -Tags @("processor:$Processor")
        exit $VES_EXIT_OK
    }
    Write-VesLog ERROR "PRE-DEPLOY BLOCKED $Processor" -LogFile $LogFile
    Send-VesDatadogEvent -Title "Pre-deploy gate BLOCKED: $Processor" `
        -Text "Staged=$StagedCommit refused. $msg" -AlertType error -Tags @("processor:$Processor")
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

    # both gates passed: signal the deploy may proceed, and mark it on the timeline
    Write-VesLog OK "GATE PASS: deploy may proceed (staged=$StagedCommit approved)." -LogFile $LogFile
    Send-VesDatadogEvent -Title "Pre-deploy gate PASS: $Processor" `
        -Text "Staged=$StagedCommit matches the approved baseline." -AlertType success -Tags @("processor:$Processor")
    exit $VES_EXIT_OK
}
catch {
    # can't reach SSM or param missing: refuse rather than deploy unanchored
    Write-VesLog ERROR "Gate error (SSM/trust): $($_.Exception.Message)" -LogFile $LogFile
    exit $VES_EXIT_NOBASE
}
