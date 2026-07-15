#Requires -Version 5.1
# Shared functions for post-deployment verification.
# Windows PowerShell 5.1 only, no 7.x syntax.

# Fail on unset variables / bad property access so latent bugs surface loudly
Set-StrictMode -Version 2.0

# Exit codes used by all entry scripts:
#   0 = ok/match, 1 = drift, 2 = no baseline or trust failure, 3 = health failure, 10 = usage
$Global:VES_EXIT_OK     = 0
$Global:VES_EXIT_DRIFT  = 1
$Global:VES_EXIT_NOBASE = 2
$Global:VES_EXIT_HEALTH = 3
$Global:VES_EXIT_USAGE  = 10

# 5.1 defaults to SSL3/TLS1.0 which many current HTTPS endpoints reject
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-VesLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','OK','DRIFT')][string]$Level,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Data,
        [string]$LogFile
    )
    # build the record: UTC timestamp + level + message, then fold in any extra -Data fields
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $record = [ordered]@{ ts = $ts; level = $Level; msg = $Message }
    if ($Data) { foreach ($k in $Data.Keys) { $record[$k] = $Data[$k] } }

    # human-facing console line, colour-coded by level
    $color = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; DRIFT='Magenta' }[$Level]
    Write-Host ("[{0}] {1,-5} {2}" -f $ts, $Level, $Message) -ForegroundColor $color

    # JSONL sidecar for machine consumption
    if ($LogFile) {
        ($record | ConvertTo-Json -Compress -Depth 6) | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
}

function Get-VesManifest {
    # Hash every file under a release root. Relative paths only; absolute paths
    # differ between UAT and prod hosts and cause false mismatches.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        # .config is excluded from the byte-hash on purpose: the legacy OMS
        # App.config/web.config files carry server-specific log4net <file> paths
        # (C:\VLER_Test\Logs\... vs E:\VLER\Logs\...), so hashing them reports
        # drift on every UAT->PROD compare. Config correctness is checked
        # structurally by Verify-Config.ps1 (contract), not by hash. Override
        # -ExcludePattern if a system's config is genuinely byte-identical.
        [string]$ExcludePattern = '(?i)\\(logs|temp|cache|\.git)\\|\.(log|tmp|config)$'
    )
    if (-not (Test-Path -LiteralPath $ReleaseRoot)) {
        throw "ReleaseRoot not found: $ReleaseRoot"
    }
    # normalize the root and enumerate every file beneath it (including hidden)
    $root = (Resolve-Path -LiteralPath $ReleaseRoot).Path.TrimEnd('\')
    $items = Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop

    # hash each in-scope file into a {RelPath, Sha256, Bytes} row, skipping excludes
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in $items) {
        $rel = $f.FullName.Substring($root.Length + 1)
        if ($rel -match $ExcludePattern) { continue }
        $relNorm = $rel -replace '\\','/'
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $out.Add([PSCustomObject]@{ RelPath = $relNorm; Sha256 = $hash; Bytes = $f.Length })
    }
    # sorted so the manifest hash is stable; leading comma stops PS unrolling single-item results
    return ,($out | Sort-Object RelPath)
}

function Get-VesManifestHash {
    # SHA-256 over sorted "relpath|sha256|bytes" lines rather than the JSON text,
    # so whitespace/key-order/BOM differences can't break the trust comparison.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Manifest)
    # serialize the manifest to one canonical "relpath|sha256|bytes" line per file, sorted
    $sb = New-Object System.Text.StringBuilder
    foreach ($e in ($Manifest | Sort-Object RelPath)) {
        [void]$sb.AppendLine(('{0}|{1}|{2}' -f $e.RelPath, $e.Sha256, $e.Bytes))
    }
    # hash the canonical text; dispose the provider deterministically in finally
    $bytes = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [Security.Cryptography.SHA256]::Create()
    try   { return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

function Export-VesManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Manifest,
        [Parameter(Mandatory)][string]$Path,
        [string]$CommitSha = 'unknown',
        [string]$Processor = 'unknown'
    )
    # wrap the file list in a versioned document with provenance (who/when/commit) + its trust hash
    $manifestHash = Get-VesManifestHash -Manifest $Manifest
    $doc = [ordered]@{
        schema       = 'ves.manifest.v1'
        processor    = $Processor
        commitSha    = $CommitSha
        capturedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        capturedBy   = "$env:USERNAME@$env:COMPUTERNAME"
        manifestHash = $manifestHash
        fileCount    = $Manifest.Count
        files        = $Manifest
    }
    # ensure the target directory exists, then write the manifest as JSON
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $Path -Encoding utf8
    # hand the hash back so the caller can pin it to SSM
    return $manifestHash
}

function Import-VesManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Manifest not found: $Path" }
    # load the stored document, then recompute its hash so callers can detect a manifest edited after capture
    $doc = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    $recomputed = Get-VesManifestHash -Manifest $doc.files
    # Consistent = the stored hash still matches the file list it claims to describe
    return [PSCustomObject]@{
        Doc            = $doc
        StoredHash     = $doc.manifestHash
        RecomputedHash = $recomputed
        Consistent     = ($doc.manifestHash -eq $recomputed)
    }
}

function Compare-VesFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Baseline,
        [Parameter(Mandatory)][string]$ReleaseRoot,
        # must match the pattern used at capture or excluded files show up as extras
        # .config is excluded from the byte-hash on purpose: the legacy OMS
        # App.config/web.config files carry server-specific log4net <file> paths
        # (C:\VLER_Test\Logs\... vs E:\VLER\Logs\...), so hashing them reports
        # drift on every UAT->PROD compare. Config correctness is checked
        # structurally by Verify-Config.ps1 (contract), not by hash. Override
        # -ExcludePattern if a system's config is genuinely byte-identical.
        [string]$ExcludePattern = '(?i)\\(logs|temp|cache|\.git)\\|\.(log|tmp|config)$'
    )
    # hash the live tree the same way, then index both sides by relative path for lookup
    $live = Get-VesManifest -ReleaseRoot $ReleaseRoot -ExcludePattern $ExcludePattern
    $baseMap = @{}; foreach ($b in $Baseline) { $baseMap[$b.RelPath] = $b }
    $liveMap = @{}; foreach ($l in $live)     { $liveMap[$l.RelPath] = $l }

    $missing = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[object]
    $extra   = New-Object System.Collections.Generic.List[string]

    # walk the baseline: anything absent live is missing, anything with a different hash is changed
    foreach ($rel in $baseMap.Keys) {
        if (-not $liveMap.ContainsKey($rel)) { $missing.Add($rel); continue }
        if ($liveMap[$rel].Sha256 -ne $baseMap[$rel].Sha256) {
            $changed.Add([PSCustomObject]@{ RelPath=$rel; Expected=$baseMap[$rel].Sha256; Actual=$liveMap[$rel].Sha256 })
        }
    }
    # anything live that the baseline never recorded is an unexpected extra
    foreach ($rel in $liveMap.Keys) { if (-not $baseMap.ContainsKey($rel)) { $extra.Add($rel) } }

    # Return plain arrays, not List[object]. Under Set-StrictMode 2.0 the @() and
    # unary-comma operators throw "Argument types do not match" on a List[object]
    # (List[string] is unaffected), which would break every caller that wraps
    # .Changed in @(). .ToArray() is safe for empty and populated lists alike.
    return [PSCustomObject]@{
        Missing = $missing.ToArray()
        Changed = $changed.ToArray()
        Extra   = $extra.ToArray()
        Match   = (($missing.Count + $changed.Count + $extra.Count) -eq 0)
    }
}

# Trust anchor. The manifest file sits next to the artifacts and is editable by
# anyone who can edit the artifacts, so verification reads the trusted hash from
# SSM Parameter Store (write-gated) instead of trusting the file's own claim.
# Note: uat and sandbox share a GovCloud account, so scope ssm:PutParameter by
# path per environment. IAM grants alone are the boundary there.

function Get-VesTrustedHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [string]$Region = 'us-gov-west-1'
    )
    # read the SecureString parameter (KMS-decrypted) via the AWS CLI rather than
    # the AWSPowerShell module; legacy hosts won't have the module
    $raw = & aws ssm get-parameter --name $ParameterName --with-decryption `
        --region $Region --query 'Parameter.Value' --output text 2>$null
    # a non-zero exit or empty value means auth/KMS/path failure: throw, never return blank
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "SSM read failed for $ParameterName (region $Region). aws exit=$LASTEXITCODE"
    }
    return $raw.Trim()
}

function Set-VesTrustedHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParameterName,
        [Parameter(Mandatory)][string]$Value,
        [string]$Region = 'us-gov-west-1'
    )
    # pin the value as a SecureString, overwriting any prior pin; throw if the write is rejected
    & aws ssm put-parameter --name $ParameterName --value $Value --type SecureString `
        --overwrite --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "SSM write failed for $ParameterName. aws exit=$LASTEXITCODE" }
}

# public surface: only these functions are callable by the entry scripts
Export-ModuleMember -Function `
    Write-VesLog, Get-VesManifest, Get-VesManifestHash, Export-VesManifest, `
    Import-VesManifest, Compare-VesFiles, Get-VesTrustedHash, Set-VesTrustedHash
