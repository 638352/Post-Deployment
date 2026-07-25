#Requires -Version 5.1
<#
.SYNOPSIS
    Shared functions for VES Post-Deployment Verification.
.DESCRIPTION
    Manifest capture/compare, manifest trust (SSM-anchored hash), Datadog emit
    (ddog-gov), and structured logging. Imported by all entry-point scripts.
    Target: Windows PowerShell 5.1. No PowerShell 7+ syntax.
#>

# Enforce strict variable/property resolution so typos fail fast instead of silently returning $null.
Set-StrictMode -Version 2.0

# --- Exit code contract (shared across all entry scripts) --------------------
# 0  OK / match
# 1  DRIFT: files or config diverge from baseline
# 2  NO-BASELINE / trust failure (missing or tampered manifest) -- fail loud
# 3  HEALTH failure (service down / assembly load failure)
# 10 USAGE / parameter error

# Global scope so entry scripts that import this module can reference the constants directly.
$Global:VES_EXIT_OK        = 0      # Success / production matches baseline.
$Global:VES_EXIT_DRIFT     = 1      # Divergence detected between prod and baseline.
$Global:VES_EXIT_NOBASE    = 2      # Baseline missing, unreadable, or failed trust check.
$Global:VES_EXIT_HEALTH    = 3      # Functional health failure (independent of baseline).
$Global:VES_EXIT_USAGE     = 10     # Caller passed bad/missing parameters.

# --- Default manifest exclude pattern (single source of truth) ---------------
# Capture and compare MUST use the same rules: if they disagree, files excluded at
# capture time resurface as "Extra" at verify time and every check reports drift.
# Defined once here; Get-VesManifest and Compare-VesFiles both default to it.
#
# Two rules, OR'd:
#   (^|\\)(logs|temp|cache|\.git)\\   runtime dirs, at the root OR nested. The
#                                     (^|\\) alternation is load-bearing: a bare
#                                     \\ prefix only matches nested dirs, so a
#                                     top-level logs\ leaked into the baseline and
#                                     produced permanent false drift.
#   \.(log|tmp|config)$               churny extensions. .config is excluded by
#                                     design (server-specific log4net paths);
#                                     config is verified structurally by
#                                     Verify-Config.ps1, not by byte-hash.
$Global:VES_DEFAULT_EXCLUDE = '(?i)(^|\\)(logs|temp|cache|\.git)\\|\.(log|tmp|config)$'

# PowerShell 5.1 defaults to SSL3/TLS1.0, which ddog-gov and AWS endpoints reject.
# OR the existing protocol set with Tls12 (rather than replacing) so we add, not remove, protocols.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Write-VesLog {
    <#
    .SYNOPSIS Structured single-line log. Text to host, JSON line to -LogFile.
    #>
    [CmdletBinding()]
    param(
        # Severity level; constrained set keeps downstream log parsing predictable.
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','OK','DRIFT')][string]$Level,
        # Human-readable message for both console and JSON record.
        [Parameter(Mandatory)][string]$Message,
        # Optional structured fields merged into the JSON record (e.g. processor, commit).
        [hashtable]$Data,
        # Optional path; when set, a JSON line is appended for machine consumption.
        [string]$LogFile
    )
    # UTC ISO-8601 timestamp so logs from multiple hosts correlate without timezone math.
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    # Ordered hashtable keeps JSON field order stable (ts, level, msg first) for readability.
    $record = [ordered]@{ ts = $ts; level = $Level; msg = $Message }
    # Merge caller-supplied structured fields into the record, if any were passed.
    if ($Data) { foreach ($k in $Data.Keys) { $record[$k] = $Data[$k] } }

    # Map each level to a console color so operators can scan output visually.
    $color = @{ INFO='Gray'; OK='Green'; WARN='Yellow'; ERROR='Red'; DRIFT='Magenta' }[$Level]
    # Console line: fixed-width level column keeps multi-line output aligned.
    Write-Host ("[{0}] {1,-5} {2}" -f $ts, $Level, $Message) -ForegroundColor $color

    # Append one compact JSON object per line (JSONL) so logs are grep- and jq-friendly.
    if ($LogFile) {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        ($record | ConvertTo-Json -Compress -Depth 6) | Out-File -FilePath $LogFile -Append -Encoding utf8
    }
}

function New-VesLogFile {
    <#
    .SYNOPSIS Return a unique JSONL log path and create its parent directory.
    .DESCRIPTION
      Every entry script uses this when -LogFile is omitted so an interactive
      run cannot silently leave no execution evidence. Set VES_AUDIT_LOG_DIR to
      a durable central share on managed hosts; otherwise ProgramData is used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$LogDir
    )
    if ([string]::IsNullOrWhiteSpace($LogDir)) {
        if (-not [string]::IsNullOrWhiteSpace($env:VES_AUDIT_LOG_DIR)) {
            $LogDir = $env:VES_AUDIT_LOG_DIR
        } elseif (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
            $LogDir = Join-Path $env:ProgramData 'ves-verify\logs'
        } else {
            $LogDir = Join-Path ([IO.Path]::GetTempPath()) 'ves-verify\logs'
        }
    }
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $safePrefix = ($Prefix -replace '[^A-Za-z0-9_.-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safePrefix)) { $safePrefix = 'run' }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return Join-Path $LogDir ("{0}_{1}_{2}.jsonl" -f $safePrefix, $stamp, $suffix)
}

function Get-VesOutcome {
    <#
    .SYNOPSIS Map the exit-code contract to PASS, FAIL, or ERROR.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ExitCode)
    if ($ExitCode -eq $Global:VES_EXIT_OK) { return 'PASS' }
    if ($ExitCode -in @($Global:VES_EXIT_DRIFT, $Global:VES_EXIT_HEALTH)) { return 'FAIL' }
    return 'ERROR'
}

function Import-VesTargetInventory {
    <#
    .SYNOPSIS Load and fail-closed validate a ves.targets.v1 inventory.
    .DESCRIPTION
      The leadership brief requires every server receiving a deployment copy,
      including Citrix targets, to be inventoried. A bare target array cannot
      prove that assertion, so the supported document has root metadata:

        schema, inventoryComplete, requiredServers, targets

      inventoryComplete must be explicitly true, every required server must have
      a confirmed target, and every target must contain the fields needed for a
      full file+configuration check.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Targets file not found: $Path" }
    try { $doc = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { throw "Targets file is not valid JSON: $($_.Exception.Message)" }

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $targets = @()
    $requiredServers = @()
    $schema = $null
    $inventoryComplete = $false

    if ($doc -is [System.Array]) {
        $targets = @($doc)
        $errors.Add("Legacy bare-array inventory is not accepted; use schema 'ves.targets.v1' and set inventoryComplete=true after server/Citrix review.")
    } else {
        $schema = if ($doc.PSObject.Properties['schema']) { "$($doc.schema)" } else { $null }
        $inventoryComplete = ($doc.PSObject.Properties['inventoryComplete'] -and [bool]$doc.inventoryComplete)
        $targets = @(if ($doc.PSObject.Properties['targets']) { $doc.targets })
        $requiredServers = @(if ($doc.PSObject.Properties['requiredServers']) {
            $doc.requiredServers | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") }
        })
        if ($schema -ne 'ves.targets.v1') {
            $errors.Add("Inventory schema must be 'ves.targets.v1' (found '$schema').")
        }
        if (-not $inventoryComplete) {
            $errors.Add('inventoryComplete is not true; confirm every manual-copy and Citrix target before verification can claim coverage.')
        }
        if ($requiredServers.Count -eq 0) {
            $errors.Add('requiredServers is empty; list every server that receives a deployment copy.')
        }
    }

    if ($targets.Count -eq 0) { $errors.Add('Inventory contains no targets.') }
    $requiredFields = @(
        'processor','server','environment','inventoryStatus','releaseTag','releaseRoot',
        'manifestPath','trustParam','configContract','configPath'
    )
    $seen = @{}
    foreach ($target in $targets) {
        $label = if ($target.PSObject.Properties['processor']) { "$($target.processor)" } else { '<unnamed>' }
        foreach ($field in $requiredFields) {
            $value = if ($target.PSObject.Properties[$field]) { "$($target.$field)" } else { $null }
            if ([string]::IsNullOrWhiteSpace($value)) {
                $errors.Add("Target '$label' is missing required field '$field'.")
            } elseif ($value -match '(?i)(SYSTEM_NAME|CHANGE_ME|<[^>]+>|\bTBD\b|\bCONFIRM\b|\bUNKNOWN\b)') {
                $errors.Add("Target '$label' field '$field' still contains a placeholder: $value")
            }
        }
        $status = if ($target.PSObject.Properties['inventoryStatus']) { "$($target.inventoryStatus)" } else { '' }
        if ($status -ne 'confirmed') {
            $errors.Add("Target '$label' inventoryStatus must be 'confirmed' (found '$status').")
        }
        $environment = if ($target.PSObject.Properties['environment']) { "$($target.environment)".ToLowerInvariant() } else { '' }
        if ($environment -notin @('dev','qa','uat','prod','production')) {
            $errors.Add("Target '$label' environment '$environment' is not dev, qa, uat, prod, or production.")
        }
        $server = if ($target.PSObject.Properties['server']) { "$($target.server)" } else { '' }
        $identity = ("{0}|{1}" -f $server, $label).ToLowerInvariant()
        if ($seen.ContainsKey($identity)) {
            $errors.Add("Duplicate server/processor target: $server / $label")
        } else {
            $seen[$identity] = $true
        }
    }

    $coveredServers = @($targets | ForEach-Object {
        if ($_.PSObject.Properties['server'] -and $_.PSObject.Properties['inventoryStatus'] -and $_.inventoryStatus -eq 'confirmed') {
            "$($_.server)"
        }
    } | Select-Object -Unique)
    foreach ($server in $requiredServers) {
        if ($coveredServers -notcontains "$server") {
            $errors.Add("Required server '$server' has no confirmed target entry.")
        }
    }
    foreach ($server in $coveredServers) {
        if ($requiredServers.Count -gt 0 -and $requiredServers -notcontains "$server") {
            $warnings.Add("Confirmed target server '$server' is not listed in requiredServers.")
        }
    }

    return [PSCustomObject]@{
        Schema            = $schema
        InventoryComplete = $inventoryComplete
        RequiredServers   = $requiredServers
        Targets           = $targets
        Errors            = $errors.ToArray()
        Warnings          = $warnings.ToArray()
        Valid             = ($errors.Count -eq 0)
    }
}

function Get-VesManifest {
    <#
    .SYNOPSIS Enumerate a release root -> array of {RelPath, Sha256, Bytes}.
    .NOTES
      Relative paths only, normalized to '/'. Absolute paths differ between UAT
      and prod hosts and produce false mismatches. ExcludePattern is regex
      matched against the relative path.
    #>
    [CmdletBinding()]
    param(
        # Root of the artifact tree to hash (UAT release dir or prod install dir).
        [Parameter(Mandatory)][string]$ReleaseRoot,
        # Regex of paths to skip; see $Global:VES_DEFAULT_EXCLUDE for the rules.
        [string]$ExcludePattern = $Global:VES_DEFAULT_EXCLUDE
    )
    # Fail early with a clear message if the root doesn't exist (bad path = usage error, not "0 files").
    if (-not (Test-Path -LiteralPath $ReleaseRoot)) {
        throw "ReleaseRoot not found: $ReleaseRoot"
    }
    # Normalize via Get-Item, NOT Resolve-Path. Resolve-Path preserves 8.3 short
    # names (C:\Users\HOWARD~1\...) while the FileInfo.FullName values below expand
    # them (C:\Users\howardr01\...). The prefixes then differ in length and the
    # relative-path slice silently comes out wrong, which manifests as a whole tree
    # reported missing+extra. Get-Item normalizes the same way Get-ChildItem does.
    $root = (Get-Item -LiteralPath $ReleaseRoot).FullName.TrimEnd('\')
    # Recurse all files including hidden (-Force); stop on access errors rather than silently skipping.
    $items = Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop

    # Generic List avoids O(n^2) array += reallocation on large trees.
    $out = New-Object System.Collections.Generic.List[object]
    # Walk every file found under the root.
    foreach ($f in $items) {
        # Guard the prefix assumption instead of trusting it. Strip by separator
        # (TrimStart) rather than by a fixed +1 offset, so any future normalization
        # mismatch fails loud here rather than silently corrupting every RelPath.
        if (-not $f.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Path escapes ReleaseRoot: $($f.FullName) (root: $root)"
        }
        # Compute the path relative to root.
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        # Skip anything matching the exclude regex (checked before hashing to save I/O).
        if ($rel -match $ExcludePattern) { continue }
        # Normalize separators to '/' so manifests hash identically regardless of tooling.
        $relNorm = $rel -replace '\\','/'
        # SHA-256 of file contents -- the core drift-detection primitive.
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        # Record path, hash, and size; size is a cheap secondary sanity signal.
        $out.Add([PSCustomObject]@{ RelPath = $relNorm; Sha256 = $hash; Bytes = $f.Length })
    }
    # Sort for deterministic order (required for a stable manifest hash); leading comma
    # prevents PowerShell from unrolling a single-element result into a scalar.
    return ,($out | Sort-Object RelPath)
}

function Get-VesManifestHash {
    <#
    .SYNOPSIS Deterministic SHA-256 over manifest contents (not the JSON text).
    .NOTES
      Hash of sorted "relpath|sha256|bytes" lines. Immune to JSON whitespace,
      key ordering, or BOM differences that would otherwise break trust checks.
    #>
    [CmdletBinding()]
    param(
        # The manifest entries (output of Get-VesManifest or the .files of a loaded manifest doc).
        [Parameter(Mandatory)][object[]]$Manifest
    )
    # StringBuilder avoids repeated string reallocation while concatenating many lines.
    $sb = New-Object System.Text.StringBuilder
    # Re-sort defensively so the hash is stable even if the caller passed unsorted entries.
    foreach ($e in ($Manifest | Sort-Object RelPath)) {
        # Canonical line format 'relpath|sha256|bytes' -- the thing actually hashed.
        # [void] suppresses StringBuilder's return value from polluting the pipeline.
        [void]$sb.AppendLine(('{0}|{1}|{2}' -f $e.RelPath, $e.Sha256, $e.Bytes))
    }
    # Encode as UTF-8 without BOM so the digest is byte-identical across hosts.
    $bytes = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
    # Create the SHA-256 provider (disposed below -- it holds native crypto handles).
    $sha = [Security.Cryptography.SHA256]::Create()
    # Hash the canonical bytes and render each byte as lowercase hex, joined into one string.
    try   { return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
    # Always release the crypto provider even if hashing throws.
    finally { $sha.Dispose() }
}

function Export-VesManifest {
    <#
    .SYNOPSIS Write manifest JSON + sidecar metadata (commit, hash, timestamp).
    #>
    [CmdletBinding()]
    param(
        # Manifest entries to persist.
        [Parameter(Mandatory)][object[]]$Manifest,
        # Destination JSON path.
        [Parameter(Mandatory)][string]$Path,
        # Git commit of the release captured; 'unknown' if capture ran outside a checkout.
        [string]$CommitSha = 'unknown',
        # Logical processor/system name for traceability.
        [string]$Processor = 'unknown'
    )
    # Derive the content hash first so it can be embedded inside the document.
    $manifestHash = Get-VesManifestHash -Manifest $Manifest
    # Ordered document: schema version first enables future format migrations.
    $doc = [ordered]@{
        schema       = 'ves.manifest.v1'                                            # Format identifier for forward compatibility.
        processor    = $Processor                                                   # Which system this baseline belongs to.
        commitSha    = $CommitSha                                                   # Release commit -- ties baseline to Git history.
        capturedUtc  = (Get-Date).ToUniversalTime().ToString('o')                   # Capture moment (round-trip ISO format).
        capturedBy   = "$env:USERNAME@$env:COMPUTERNAME"                            # Who/where captured -- audit field.
        manifestHash = $manifestHash                                                # Self-hash; verified on load to detect tamper/corruption.
        fileCount    = $Manifest.Count                                              # Quick sanity number for humans.
        files        = $Manifest                                                    # The per-file entries themselves.
    }
    # Ensure the destination directory exists before writing.
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Serialize with enough depth for the nested files array; UTF-8 on disk.
    ($doc | ConvertTo-Json -Depth 6) | Out-File -FilePath $Path -Encoding utf8
    # Return the content hash so the caller can pin it to SSM.
    return $manifestHash
}

function Import-VesManifest {
    <#
    .SYNOPSIS Load a manifest JSON and re-derive its content hash for trust check.
    #>
    [CmdletBinding()]
    param(
        # Path to a manifest previously written by Export-VesManifest.
        [Parameter(Mandatory)][string]$Path
    )
    # Missing baseline is a hard error -- callers map this to exit 2, never to "pass".
    if (-not (Test-Path -LiteralPath $Path)) { throw "Manifest not found: $Path" }
    # Read the whole file and parse JSON into an object graph.
    $doc = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    # Recompute the content hash from the entries actually present in the file.
    $recomputed = Get-VesManifestHash -Manifest $doc.files
    # Return doc plus both hashes; Consistent=false means the file was edited or corrupted after capture.
    return [PSCustomObject]@{
        Doc            = $doc                                    # Full parsed manifest document.
        StoredHash     = $doc.manifestHash                       # Hash recorded at capture time.
        RecomputedHash = $recomputed                             # Hash derived from current file contents.
        Consistent     = ($doc.manifestHash -eq $recomputed)     # Internal integrity verdict.
    }
}

function Compare-VesFiles {
    <#
    .SYNOPSIS Diff a live release root against a baseline manifest.
    .OUTPUTS {Missing[], Extra[], Changed[], Match(bool)}
    #>
    [CmdletBinding()]
    param(
        # Baseline entries from the trusted manifest.
        [Parameter(Mandatory)][object[]]$Baseline,
        # Live production tree to compare.
        [Parameter(Mandatory)][string]$ReleaseRoot,
        # Must match the pattern used at capture, or excluded files appear as extras.
        [string]$ExcludePattern = $Global:VES_DEFAULT_EXCLUDE
    )
    # Hash the live tree with the same rules used at capture time.
    $live = Get-VesManifest -ReleaseRoot $ReleaseRoot -ExcludePattern $ExcludePattern
    # Index baseline by relative path for O(1) lookups.
    $baseMap = @{}; foreach ($b in $Baseline) { $baseMap[$b.RelPath] = $b }
    # Index live tree the same way.
    $liveMap = @{}; foreach ($l in $live)     { $liveMap[$l.RelPath] = $l }

    $missing = New-Object System.Collections.Generic.List[string]  # In baseline, absent in prod (the Storage.Net case).
    $changed = New-Object System.Collections.Generic.List[object]  # Present in both but hash differs.
    $extra   = New-Object System.Collections.Generic.List[string]  # In prod, not in baseline (unauthorized addition).

    # Pass 1: everything the baseline says must exist.
    foreach ($rel in $baseMap.Keys) {
        # File in baseline but not in prod -> missing.
        if (-not $liveMap.ContainsKey($rel)) { $missing.Add($rel); continue }
        # File exists in both -> compare content hashes.
        if ($liveMap[$rel].Sha256 -ne $baseMap[$rel].Sha256) {
            # Record both hashes so the operator can see expected vs actual.
            $changed.Add([PSCustomObject]@{ RelPath=$rel; Expected=$baseMap[$rel].Sha256; Actual=$liveMap[$rel].Sha256 })
        }
    }
    # Pass 2: anything in prod the baseline never declared -> extra.
    foreach ($rel in $liveMap.Keys) { if (-not $baseMap.ContainsKey($rel)) { $extra.Add($rel) } }

    # Aggregate verdict: match only when all three difference sets are empty.
    # Return plain arrays (.ToArray), not Generic.List[T]. Under PS 5.1,
    # @($list) on List[T] throws "Argument types do not match", which broke
    # Invoke-Verification when building the JSON detail payload (exit 2).
    return [PSCustomObject]@{
        Missing = $missing.ToArray()                                             # Files that should exist but don't.
        Changed = $changed.ToArray()                                             # Files whose bytes differ from baseline.
        Extra   = $extra.ToArray()                                               # Files present that baseline doesn't know.
        Match   = (($missing.Count + $changed.Count + $extra.Count) -eq 0)       # True = prod byte-matches baseline.
    }
}

# --- Trust anchor: manifest hash pinned in SSM Parameter Store ----------------
# The manifest file lives next to the artifacts (mutable). The *trusted* hash
# lives in SSM (write-gated). Verify reads the trusted hash from SSM, not the
# file, so an attacker who edits prod files + manifest still fails the check.

function Invoke-VesAwsCli {
    <#
    .SYNOPSIS Run the AWS CLI and return StdOut/StdErr/ExitCode without throwing.
    .NOTES
      Exists because of two Windows PowerShell 5.1 traps that silently broke every
      caller here:

      1. Under $ErrorActionPreference='Stop', a native command writing to stderr
         becomes a *terminating* NativeCommandError -- with '2>&1' AND with '2>$null'.
         Callers' own "if ($LASTEXITCODE -ne 0) { throw <useful message> }" lines
         therefore never ran, and the raw CLI text escaped instead. We scope the
         preference to 'Continue' around the call so control returns to the caller.

      2. Merging streams with '2>&1' splices stderr into the value. The AWS CLI can
         emit warnings to stderr on a *successful* call, which would corrupt a
         parameter value. We split the merged stream back apart by object type, so
         StdOut carries only real output.
    #>
    [CmdletBinding()]
    param(
        # Arguments passed through to the aws executable.
        [Parameter(Mandatory)][string[]]$Arguments
    )
    # Missing CLI is a clean non-zero result, not a CommandNotFoundException that
    # would blow past the caller's error handling.
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ StdOut=''; StdErr='AWS CLI not found on PATH'; ExitCode=127 }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & aws @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        # Restore even if the call blows up, so we never leak 'Continue' to the caller.
        $ErrorActionPreference = $prev
    }
    # Split the merged stream: ErrorRecords came from stderr, everything else is stdout.
    $stdout = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($out | Where-Object { $_ -is  [System.Management.Automation.ErrorRecord] } |
                       ForEach-Object { $_.ToString() }) -join ' '
    return [PSCustomObject]@{ StdOut=$stdout; StdErr=$stderr; ExitCode=$code }
}

function Get-VesTrustedHash {
    [CmdletBinding()]
    param(
        # SSM parameter name holding the pinned value, e.g. /ves/vemsoutbound/baseline-hash.
        [Parameter(Mandatory)][string]$ParameterName,
        # GovCloud region; default matches the VES deployment.
        [string]$Region = 'us-gov-west-1'
    )
    # Call the AWS CLI directly (no AWSPowerShell module dependency on legacy hosts).
    # --with-decryption handles SecureString; failure detected via exit code.
    $r = Invoke-VesAwsCli -Arguments @(
        'ssm','get-parameter','--name',$ParameterName,'--with-decryption',
        '--region',$Region,'--query','Parameter.Value','--output','text')
    # Treat CLI failure OR empty value as a trust failure -- never proceed on a blank anchor.
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.StdOut)) {
        throw ("SSM read failed for $ParameterName (region $Region). aws exit=$($r.ExitCode). $($r.StdErr)").Trim()
    }
    # Trim the trailing newline the CLI text output includes.
    return $r.StdOut.Trim()
}

function Set-VesTrustedHash {
    [CmdletBinding()]
    param(
        # SSM parameter to write.
        [Parameter(Mandatory)][string]$ParameterName,
        # The hash (or commit SHA) to pin as trusted.
        [Parameter(Mandatory)][string]$Value,
        # GovCloud region.
        [string]$Region = 'us-gov-west-1'
    )
    # SecureString type gates reads behind kms:Decrypt; --overwrite allows re-pinning on each release.
    $r = Invoke-VesAwsCli -Arguments @(
        'ssm','put-parameter','--name',$ParameterName,'--value',$Value,
        '--type','SecureString','--overwrite','--region',$Region)
    # Surface CLI failure as a hard error -- an unpinned baseline must not look like success.
    if ($r.ExitCode -ne 0) {
        throw ("SSM write failed for $ParameterName. aws exit=$($r.ExitCode). $($r.StdErr)").Trim()
    }
}

# --- Git archive readback: baseline from the release tag ---------------------
# Capture commits the manifest under baselines/<processor>/ in the archive repo
# and tags the commit. These helpers read that record back at a given tag so
# the gate and verification can source their baseline from the release tag
# itself instead of only a local file. When SSM is also configured, the tag
# manifest must agree with the pinned hash; the tag never replaces the anchor.

function Invoke-VesGit {
    <#
    .SYNOPSIS Run git and throw a readable error on any non-zero exit.
    .NOTES
      Same PS 5.1 trap as the AWS CLI: under ErrorActionPreference=Stop, stderr
      from a native command becomes terminating, so scope the preference down
      around the call and surface the real exit code + output instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$GitArgs)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git not found on PATH'
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git @GitArgs 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) {
        throw ("git {0} failed (exit {1}): {2}" -f ($GitArgs -join ' '), $code, ((@($out) | ForEach-Object { "$_" }) -join ' '))
    }
    return (@($out) | ForEach-Object { "$_" }) -join "`n"
}

function Test-VesReleaseTag {
    <#
    .SYNOPSIS True when a tag matches <prefix/>vMAJOR.MINOR.PATCH, e.g. OutboundDBQ/v1.4.0.
    #>
    [CmdletBinding()]
    param([string]$Tag)
    return ($Tag -match '^(?:[A-Za-z0-9._-]+/)?v\d+\.\d+\.\d+$')
}

function Get-VesManifestFromTag {
    <#
    .SYNOPSIS Load the archived baseline manifest from a release tag via git show.
    .DESCRIPTION
      Reads baselines/<Processor>/<FileName> at the given tag and returns the
      same {Doc; StoredHash; RecomputedHash; Consistent} shape as
      Import-VesManifest so callers reuse identical trust logic. FileName
      defaults to <Processor>.json, the capture convention. Any git failure
      (missing tag, missing path, not a checkout) throws; callers map that to
      exit 2, never a pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Processor,
        [string]$FileName
    )
    if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
        throw "Baseline repo is not a git checkout: $RepoPath"
    }
    if ([string]::IsNullOrWhiteSpace($FileName)) { $FileName = "$Processor.json" }
    $relPath = 'baselines/{0}/{1}' -f $Processor, $FileName
    $text = Invoke-VesGit @('-C', $RepoPath, 'show', ('{0}:{1}' -f $Tag, $relPath))
    $doc = $text | ConvertFrom-Json
    $recomputed = Get-VesManifestHash -Manifest $doc.files
    return [PSCustomObject]@{
        Doc            = $doc
        StoredHash     = $doc.manifestHash
        RecomputedHash = $recomputed
        Consistent     = ($doc.manifestHash -eq $recomputed)
        Source         = ('{0}:{1}' -f $Tag, $relPath)
    }
}

# --- Datadog (ddog-gov) -------------------------------------------------------
function Send-VesDatadogMetric {
    <#
    .SYNOPSIS DogStatsD gauge via local agent UDP:8125. Non-fatal on failure.
    .NOTES Emit counts per host/processor -- never per-file tags (cardinality).
    #>
    [CmdletBinding()]
    param(
        # Metric name, e.g. deployment.verify.mismatch.
        [Parameter(Mandatory)][string]$Metric,
        # Gauge value to report.
        [Parameter(Mandatory)][double]$Value,
        # Tags such as processor:/env:/version: -- keep cardinality low.
        [string[]]$Tags = @(),
        # Local Datadog agent address (DogStatsD listener).
        [string]$AgentHost = '127.0.0.1',
        # DogStatsD UDP port.
        [int]$Port = 8125
    )
    # Monitoring must never break verification -- all failures here are warnings only.
    $udp = $null
    try {
        # Drop blank tags so the wire payload never contains empty tag values.
        $cleanTags = @($Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        # Build the tag suffix only when tags exist ('|#tag1,tag2' per DogStatsD wire format).
        $tagStr = if ($cleanTags.Count) { '|#' + ($cleanTags -join ',') } else { '' }
        # Format numeric values with invariant culture so decimal separators stay DogStatsD-safe.
        $valueText = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
        # DogStatsD gauge wire format: name:value|g|#tags.
        $payload = "{0}:{1}|g{2}" -f $Metric, $valueText, $tagStr
        # Open a UDP client aimed at the local agent.
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Connect($AgentHost, $Port)
        # DogStatsD is ASCII on the wire.
        $bytes = [Text.Encoding]::ASCII.GetBytes($payload)
        # Fire-and-forget send; [void] discards the byte count return value.
        [void]$udp.Send($bytes, $bytes.Length)
    } catch {
        # Log and continue -- a down agent must not fail the verify run.
        Write-Warning "Datadog metric emit failed (non-fatal): $($_.Exception.Message)"
    } finally {
        # Always release the UDP socket, including exception paths.
        if ($udp) { $udp.Close() }
    }
}

function Get-VesDatadogEnvTag {
    <#
    .SYNOPSIS Returns the Datadog env tag, defaulting to env:prod.
    #>
    [CmdletBinding()]
    param([string]$Environment)
    # An explicit target environment outranks DD_ENV. Fall back to prod for
    # stable dashboards when neither is supplied.
    $envTagValue = if (-not [string]::IsNullOrWhiteSpace($Environment)) {
        $Environment.Trim().ToLowerInvariant()
    } elseif ([string]::IsNullOrWhiteSpace($env:DD_ENV)) {
        'prod'
    } else {
        $env:DD_ENV.Trim().ToLowerInvariant()
    }
    return "env:$envTagValue"
}

function Get-VesAlertType {
    <#
    .SYNOPSIS Production failures are errors; lower environments are warnings.
    #>
    [CmdletBinding()]
    param([string]$Environment)
    $value = if ([string]::IsNullOrWhiteSpace($Environment)) { 'prod' } else { $Environment.Trim().ToLowerInvariant() }
    if ($value -in @('prod','production')) { return 'error' }
    return 'warning'
}

function Send-VesDatadogEvent {
    <#
    .SYNOPSIS Post a deploy/verify event to the ddog-gov Events API. Non-fatal.
    #>
    [CmdletBinding()]
    param(
        # Event title shown in the Datadog event stream.
        [Parameter(Mandatory)][string]$Title,
        # Event body text.
        [Parameter(Mandatory)][string]$Text,
        # Tags for filtering/overlaying on dashboards.
        [string[]]$Tags = @(),
        # Datadog alert type controls event color/severity.
        [ValidateSet('info','success','warning','error')][string]$AlertType = 'info',
        # API key from environment by default -- never hardcoded, never committed.
        [string]$ApiKey = $env:DD_API_KEY,
        # GovCloud Datadog site.
        [string]$Site = 'ddog-gov.com'
    )
    # No key -> skip quietly with a warning; events are best-effort telemetry.
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        Write-Warning 'DD_API_KEY not set; skipping Datadog event.'
        return
    }
    # Same non-fatal posture as metrics.
    try {
        # Drop blank tags so event metadata is deterministic and easy to filter.
        $cleanTags = @($Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
        # Assemble the Events API payload.
        $body = @{ title=$Title; text=$Text; tags=$cleanTags; alert_type=$AlertType } | ConvertTo-Json -Depth 4
        # Events API v1 endpoint on the GovCloud site; key passed as query param per API contract.
        $uri  = "https://api.$Site/api/v1/events?api_key=$([Uri]::EscapeDataString($ApiKey))"
        # POST and discard the response body -- only success/failure matters here.
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 | Out-Null
    } catch {
        # Log and continue -- Datadog outage must not block a deploy or verify.
        Write-Warning "Datadog event emit failed (non-fatal): $($_.Exception.Message)"
    }
}

# Export only the public surface; anything not listed stays module-private.
Export-ModuleMember -Function `
    Write-VesLog, New-VesLogFile, Get-VesOutcome, Import-VesTargetInventory, `
    Get-VesManifest, Get-VesManifestHash, Export-VesManifest, `
    Import-VesManifest, Compare-VesFiles, Get-VesTrustedHash, Set-VesTrustedHash, `
    Invoke-VesAwsCli, Invoke-VesGit, Test-VesReleaseTag, Get-VesManifestFromTag, `
    Send-VesDatadogMetric, Send-VesDatadogEvent, `
    Get-VesDatadogEnvTag, Get-VesAlertType
