#Requires -Version 5.1
<#
.SYNOPSIS
    Structural config check against a sanitized contract.
.DESCRIPTION
    Prod config legitimately differs from UAT (endpoints, secrets, thumbprints),
    so hashing config files just produces false positives. This checks a contract
    instead:

      requiredKeys       keys that must exist, value ignored
      machineKeys        allowed to differ per host, listed for documentation
      expectedValues     keys pinned to exact values in the contract file
      ssmExpectedValues  keys pinned to values read from SSM Parameter Store at
                         check time (config key -> parameter name). Use for
                         values that must be tamper-resistant: editing the
                         contract file alongside the config won't fool this one.
      sensitiveKeys      keys whose values must never appear in logs/reports.
                         Comparison still happens on the real values, but any
                         mismatch is reported as '(masked)'. Keys checked via
                         ssmExpectedValues are ALWAYS reported masked (they are
                         SecureString-gated in Parameter Store), whether or not
                         they are listed here.

    Contract example:
    {
      "format": "appconfig",
      "requiredKeys":  ["Storage:Provider","Outbound:QueueName"],
      "machineKeys":   ["Storage:ConnectionString","Endpoint:Url"],
      "expectedValues":{ "Outbound:Enabled": "true", "Tls:MinVersion": "1.2" },
      "ssmExpectedValues": { "Outbound:QueueName": "/ves/SYSTEM/config/queue-name" },
      "sensitiveKeys": ["Outbound:ApiToken"]
    }

    format is one of: appconfig, json, keyvalue.
    Returns an object with .pass; called by Invoke-Verification.
    An SSM read failure throws, which the caller maps to exit 2 (trust failure),
    never a pass.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ContractPath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$Region = 'us-gov-west-1',
    [string]$LogFile
)
Import-Module (Join-Path $PSScriptRoot 'module\VesVerify.psm1') -Force
$ErrorActionPreference = 'Stop'

# both inputs must exist; then load the contract that says what the config must satisfy
if (-not (Test-Path -LiteralPath $ContractPath)) { throw "Contract not found: $ContractPath" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
$contract = Get-Content $ContractPath -Raw | ConvertFrom-Json

function Get-FlatConfig([string]$path, [string]$format) {
    # flatten whatever format into key -> value, keys colon-delimited
    $map = @{}
    switch ($format) {
        # .NET App.config/web.config: pull appSettings and connectionStrings entries
        'appconfig' {
            [xml]$xml = Get-Content -LiteralPath $path -Raw
            foreach ($n in $xml.SelectNodes('//appSettings/add')) { $map[$n.key] = $n.value }
            foreach ($n in $xml.SelectNodes('//connectionStrings/add')) { $map["ConnectionStrings:$($n.name)"] = $n.connectionString }
        }
        # JSON config: recursively flatten nested objects into colon-joined leaf keys
        'json' {
            $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            function Walk($o, $prefix) {
                foreach ($p in $o.PSObject.Properties) {
                    $key = if ($prefix) { "$prefix`:$($p.Name)" } else { $p.Name }
                    if ($p.Value -is [psobject] -and $p.Value.PSObject.Properties.Count) { Walk $p.Value $key }
                    else { $script:__m[$key] = "$($p.Value)" }
                }
            }
            $script:__m = @{}; Walk $obj ''; $map = $script:__m
        }
        # Java .properties style: key=value per line, skipping comments
        'keyvalue' {
            foreach ($line in (Get-Content -LiteralPath $path)) {
                if ($line -match '^\s*#') { continue }
                if ($line -match '^\s*([^=]+?)\s*=\s*(.*)$') { $map[$Matches[1]] = $Matches[2] }
            }
        }
        default { throw "Unknown contract format: $format" }
    }
    return $map
}

# flatten the live config once, then accumulate the two failure kinds below
$live = Get-FlatConfig -path $ConfigPath -format $contract.format
$missingRequired = New-Object System.Collections.Generic.List[string]
$valueMismatch = New-Object System.Collections.Generic.List[object]

# sensitiveKeys: their values never reach a log or report ("secrets are never
# written to any report" — only presence/equality is recorded). Comparison below
# still uses the real values; only the REPORTED value is masked.
$sensitiveKeys = @{}
if ($contract.PSObject.Properties['sensitiveKeys'] -and $contract.sensitiveKeys) {
    foreach ($k in @($contract.sensitiveKeys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $sensitiveKeys[$k] = $true
    }
}
function Get-ReportValue([string]$key, [string]$value) {
    if ($sensitiveKeys.ContainsKey($key)) { '(masked)' } else { $value }
}

# requiredKeys: presence only, value irrelevant. Filter out $null/blank so a
# contract that omits requiredKeys doesn't pass $null to Hashtable.ContainsKey
# (which throws "Key cannot be null" -> caller maps it to a false exit 2).
foreach ($k in @($contract.requiredKeys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    if (-not $live.ContainsKey($k)) { $missingRequired.Add($k) }
}
# expectedValues: must be present AND equal to the value pinned in the contract file
foreach ($p in $contract.expectedValues.PSObject.Properties) {
    if (-not $live.ContainsKey($p.Name)) { $missingRequired.Add($p.Name); continue }
    if ($live[$p.Name] -ne $p.Value) {
        $valueMismatch.Add([PSCustomObject]@{
            key = $p.Name
            expected = (Get-ReportValue $p.Name $p.Value)
            actual   = (Get-ReportValue $p.Name $live[$p.Name])
        })
    }
}
# machineKeys deliberately not compared

# expected values held in Parameter Store rather than the contract file, so a
# tampered contract can't relax them. Get-VesTrustedHash is the generic SSM
# SecureString reader; a failed read throws and the run ends as trust failure.
if ($contract.PSObject.Properties['ssmExpectedValues'] -and $contract.ssmExpectedValues) {
    foreach ($p in $contract.ssmExpectedValues.PSObject.Properties) {
        $expected = Get-VesTrustedHash -ParameterName $p.Value -Region $Region
        if (-not $live.ContainsKey($p.Name)) { $missingRequired.Add($p.Name); continue }
        if ($live[$p.Name] -ne $expected) {
            # actual is ALWAYS masked here: the pinned value is SecureString-gated
            # in SSM, so the live value it diverged from is treated as sensitive too.
            $valueMismatch.Add([PSCustomObject]@{ key = $p.Name; expected = "(ssm:$($p.Value))"; actual = '(masked)' })
        }
    }
}

# pass only when there are zero missing keys and zero value mismatches; log the breakdown
$pass = (($missingRequired.Count + $valueMismatch.Count) -eq 0)
if ($pass) {
    Write-VesLog OK 'Config verify PASS.' -LogFile $LogFile
}
else {
    Write-VesLog DRIFT ("Config verify FAIL: {0} missing, {1} value mismatch" -f `
            $missingRequired.Count, $valueMismatch.Count) -LogFile $LogFile
    foreach ($k in $missingRequired) { Write-VesLog DRIFT "  MISSING-KEY $k" -LogFile $LogFile }
    foreach ($v in $valueMismatch) { Write-VesLog DRIFT "  VALUE $($v.key): expected '$($v.expected)' actual '$($v.actual)'" -LogFile $LogFile }
}

# structured result the caller (Invoke-Verification) folds into its own report
[PSCustomObject]@{
    pass               = $pass
    # .ToArray(), not @(): on PS 5.1, @() on a List[object] holding PSCustomObjects
    # throws "Argument types do not match" (valueMismatch is such a list).
    missingRequired    = $missingRequired.ToArray()
    valueMismatch      = $valueMismatch.ToArray()
    machineKeysIgnored = @($contract.machineKeys)
}
