#Requires -Version 5.1
<#
.SYNOPSIS
    Shared functions for VES Post-Deployment Verification.
.DESCRIPTION
    Manifest capture/compare, manifest trust (SSM-anchored hash), and structured
    logging. Imported by all entry-point scripts. Datadog emit (ddog-gov) is
    commented out in place -- see the DATADOG DISABLED block below.
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
$Global:VES_EXIT_OK = 0      # Success / production matches baseline.
$Global:VES_EXIT_DRIFT = 1      # Divergence detected between prod and baseline.
$Global:VES_EXIT_NOBASE = 2      # Baseline missing, unreadable, or failed trust check.
$Global:VES_EXIT_HEALTH = 3      # Functional health failure (independent of baseline).
$Global:VES_EXIT_USAGE = 10     # Caller passed bad/missing parameters.

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

# BOM-less UTF-8 for the JSONL audit logs. Out-File -Encoding utf8 under 5.1 emits a
# BOM when it CREATES a file, so the first line of every log arrived as
# <EF BB BF>{"ts":... and a strict per-line parse (jq, most log shippers) failed on
# line 1 of every audit file. Module-scoped and reused: the encoder is stateless.
$script:VesUtf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false

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
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'DRIFT')][string]$Level,
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
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; DRIFT = 'Magenta' }[$Level]
    # Console line: fixed-width level column keeps multi-line output aligned.
    Write-Host ("[{0}] {1,-5} {2}" -f $ts, $Level, $Message) -ForegroundColor $color

    # Append one compact JSON object per line (JSONL) so logs are grep- and jq-friendly.
    if ($LogFile) {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        # Resolve through the PowerShell provider, not [IO.Path]::GetFullPath: a
        # relative -LogFile must anchor to the session's location, not the process CWD.
        $fullLogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
        [IO.File]::AppendAllText(
            $fullLogPath,
            ($record | ConvertTo-Json -Compress -Depth 6) + [Environment]::NewLine,
            $script:VesUtf8NoBom)
    }
}

function New-VesLogFile {
    <#
    .SYNOPSIS Return a unique JSONL log path and create its parent directory.
    .DESCRIPTION
      Used by scripts that log by default (Deploy-Processor, the drift runner
      and its watchdog) and available to any caller that wants a generated
      path. The read-only verification scripts log only when -LogFile is
      passed. Set VES_AUDIT_LOG_DIR to a durable central share on managed
      hosts; otherwise ProgramData is used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prefix,
        [string]$LogDir
    )
    if ([string]::IsNullOrWhiteSpace($LogDir)) {
        if (-not [string]::IsNullOrWhiteSpace($env:VES_AUDIT_LOG_DIR)) {
            $LogDir = $env:VES_AUDIT_LOG_DIR
        }
        elseif (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
            $LogDir = Join-Path $env:ProgramData 'ves-verify\logs'
        }
        else {
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
    .NOTES
      Drift (1) and health (3) are FAIL: the check ran and production is wrong.
      Trust/usage/unknown (2, 10, …) are ERROR: the check could not prove a
      result. Monitoring should treat ERROR louder than FAIL — silence or a
      broken anchor must never look like a clean deploy.
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
    }
    else {
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
        'processor', 'server', 'environment', 'inventoryStatus', 'releaseTag', 'releaseRoot',
        'manifestPath', 'trustParam', 'configContract', 'configPath'
    )
    $seen = @{}
    foreach ($target in $targets) {
        $label = if ($target.PSObject.Properties['processor']) { "$($target.processor)" } else { '<unnamed>' }
        foreach ($field in $requiredFields) {
            $value = if ($target.PSObject.Properties[$field]) { "$($target.$field)" } else { $null }
            if ([string]::IsNullOrWhiteSpace($value)) {
                $errors.Add("Target '$label' is missing required field '$field'.")
            }
            elseif ($value -match '(?i)(SYSTEM_NAME|CHANGE_ME|<[^>]+>|\bTBD\b|\bCONFIRM\b|\bUNKNOWN\b)') {
                $errors.Add("Target '$label' field '$field' still contains a placeholder: $value")
            }
        }
        $status = if ($target.PSObject.Properties['inventoryStatus']) { "$($target.inventoryStatus)" } else { '' }
        if ($status -ne 'confirmed') {
            $errors.Add("Target '$label' inventoryStatus must be 'confirmed' (found '$status').")
        }
        $environment = if ($target.PSObject.Properties['environment']) { "$($target.environment)".ToLowerInvariant() } else { '' }
        if ($environment -notin @('dev', 'qa', 'uat', 'prod', 'production')) {
            $errors.Add("Target '$label' environment '$environment' is not dev, qa, uat, prod, or production.")
        }
        $server = if ($target.PSObject.Properties['server']) { "$($target.server)" } else { '' }
        $identity = ("{0}|{1}" -f $server, $label).ToLowerInvariant()
        if ($seen.ContainsKey($identity)) {
            $errors.Add("Duplicate server/processor target: $server / $label")
        }
        else {
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
        $relNorm = $rel -replace '\\', '/'
        # SHA-256 of file contents -- the core drift-detection primitive.
        $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        # Record path, hash, and size; size is a cheap secondary sanity signal.
        $out.Add([PSCustomObject]@{ RelPath = $relNorm; Sha256 = $hash; Bytes = $f.Length })
    }
    # Sort for deterministic order (required for a stable manifest hash); leading comma
    # prevents PowerShell from unrolling a single-element result into a scalar.
    return , ($out | Sort-Object RelPath)
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
    try { return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
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
        [string]$Processor = 'unknown',
        # The exclude regex this manifest was captured with. Recorded so verify and
        # the gate can PROVE they are comparing under the same rules instead of
        # assuming it -- see the excludePattern field below.
        [string]$ExcludePattern = $Global:VES_DEFAULT_EXCLUDE
    )
    # Derive the content hash first so it can be embedded inside the document.
    $manifestHash = Get-VesManifestHash -Manifest $Manifest
    # Ordered document: schema version first enables future format migrations.
    #
    # Adding excludePattern does NOT change any existing manifest's hash:
    # Get-VesManifestHash digests only the sorted 'relpath|sha256|bytes' lines, not
    # the JSON around them. Existing SSM pins therefore stay valid and no re-capture
    # is required to adopt this field.
    $doc = [ordered]@{
        schema         = 'ves.manifest.v1'                                          # Format identifier for forward compatibility.
        processor      = $Processor                                                 # Which system this baseline belongs to.
        commitSha      = $CommitSha                                                 # Release commit -- ties baseline to Git history.
        capturedUtc    = (Get-Date).ToUniversalTime().ToString('o')                 # Capture moment (round-trip ISO format).
        capturedBy     = "$env:USERNAME@$env:COMPUTERNAME"                          # Who/where captured -- audit field.
        manifestHash   = $manifestHash                                              # Self-hash; verified on load to detect tamper/corruption.
        excludePattern = $ExcludePattern                                            # Rules this snapshot was taken under; compare-time must match.
        fileCount      = $Manifest.Count                                            # Quick sanity number for humans.
        files          = $Manifest                                                  # The per-file entries themselves.
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

function Test-VesExcludePattern {
    <#
    .SYNOPSIS Confirm a loaded manifest was captured under the exclude rules in force now.
    .DESCRIPTION
      Capture and compare MUST agree on the exclude regex. If they disagree, files
      excluded at capture time resurface as "Extra" at verify time and every check
      reports drift forever -- the exact failure $Global:VES_DEFAULT_EXCLUDE exists
      to prevent. But Invoke-Verification exposes -ExcludePattern as a caller-settable
      parameter, so agreement cannot be assumed; it has to be checked against what the
      manifest actually recorded.

      Known=$false means the manifest predates the excludePattern field. Callers WARN
      rather than fail on that: such a baseline is still legitimately trusted, and
      failing it would break every pin captured before this field existed.
    .OUTPUTS {Known, Recorded, Effective, Match}
    #>
    [CmdletBinding()]
    param(
        # Parsed manifest document (the .Doc of Import-VesManifest / Get-VesManifestFromTag).
        [Parameter(Mandatory)][AllowNull()]$ManifestDoc,
        # The pattern this run would compare with.
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExcludePattern
    )
    $recorded = $null
    if ($ManifestDoc -and $ManifestDoc.PSObject.Properties['excludePattern']) {
        $recorded = "$($ManifestDoc.excludePattern)"
    }
    $known = -not [string]::IsNullOrWhiteSpace($recorded)
    return [PSCustomObject]@{
        Known     = $known
        Recorded  = $recorded
        Effective = $ExcludePattern
        # Ordinal comparison: this is regex SOURCE, not prose. A case-insensitive
        # match would treat (?i)foo and (?-i)FOO as the same rule set.
        Match     = ($known -and [string]::Equals($recorded, $ExcludePattern, [StringComparison]::Ordinal))
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
    $liveMap = @{}; foreach ($l in $live) { $liveMap[$l.RelPath] = $l }

    $missing = New-Object System.Collections.Generic.List[string]  # In baseline, absent in prod (the Storage.Net case).
    $changed = New-Object System.Collections.Generic.List[object]  # Present in both but hash differs.
    $extra = New-Object System.Collections.Generic.List[string]  # In prod, not in baseline (unauthorized addition).

    # Pass 1: everything the baseline says must exist.
    foreach ($rel in $baseMap.Keys) {
        # File in baseline but not in prod -> missing.
        if (-not $liveMap.ContainsKey($rel)) { $missing.Add($rel); continue }
        # File exists in both -> compare content hashes.
        if ($liveMap[$rel].Sha256 -ne $baseMap[$rel].Sha256) {
            # Record both hashes so the operator can see expected vs actual.
            $changed.Add([PSCustomObject]@{ RelPath = $rel; Expected = $baseMap[$rel].Sha256; Actual = $liveMap[$rel].Sha256 })
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
        return [PSCustomObject]@{ StdOut = ''; StdErr = 'AWS CLI not found on PATH'; ExitCode = 127 }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & aws @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        # Restore even if the call blows up, so we never leak 'Continue' to the caller.
        $ErrorActionPreference = $prev
    }
    # Split the merged stream: ErrorRecords came from stderr, everything else is stdout.
    $stdout = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
        ForEach-Object { $_.ToString() }) -join ' '
    return [PSCustomObject]@{ StdOut = $stdout; StdErr = $stderr; ExitCode = $code }
}

function Get-VesTrustedHash {
    <#
    .SYNOPSIS Read the SSM-pinned trust value (manifest hash or approved commit SHA).
    .DESCRIPTION
      Throws on CLI failure or empty value. Callers must map that to exit 2
      (NOBASE / trust failure), never to a pass — a missing anchor is unverified.
      The same helper serves both baseline-hash and approved-commit pins; both
      are SecureString parameters in Parameter Store.
    #>
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
        'ssm', 'get-parameter', '--name', $ParameterName, '--with-decryption',
        '--region', $Region, '--query', 'Parameter.Value', '--output', 'text')
    # Treat CLI failure OR empty value as a trust failure -- never proceed on a blank anchor.
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.StdOut)) {
        throw ("SSM read failed for $ParameterName (region $Region). aws exit=$($r.ExitCode). $($r.StdErr)").Trim()
    }
    # Trim the trailing newline the CLI text output includes.
    return $r.StdOut.Trim()
}

function Set-VesTrustedHash {
    <#
    .SYNOPSIS Pin a trust value to SSM (SecureString, overwrite).
    .DESCRIPTION
      This is the live trust write used by Capture and operator-driven Rollback
      (-RepinTrust). Deploy auto-rollback must never call it: an automated
      rewrite of the anchor after a failed deploy is the most dangerous action
      in the suite. Throws on CLI failure so an unpinned baseline cannot look
      like success.
    #>
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
        'ssm', 'put-parameter', '--name', $ParameterName, '--value', $Value,
        '--type', 'SecureString', '--overwrite', '--region', $Region)
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

# --- Backup / rollback support ------------------------------------------------
# Deploy-Processor backs the live tree up to <BackupRoot>\<stamp>_<Initials>_<Processor>
# before it mirrors the staged tree in. Invoke-Rollback restores from that folder.
# Both the restore picker and the deploy's prune enumerate through the same
# function below so they can never disagree about what counts as a backup.

function Get-VesWorstExitCode {
    <#
    .SYNOPSIS Reduce several stage exit codes to the most severe one.
    .NOTES
      Severity is NOT numeric order. Get-VesOutcome maps 2 to ERROR and 3 to
      FAIL, so 2 outranks 3 even though 3 -gt 2. Ranking: 10 > 2 > 3 > 1 > 0.
      An unknown code is treated as maximally severe rather than ignored.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ExitCode)
    $rank = @{ 0 = 0; 1 = 1; 3 = 2; 2 = 3; 10 = 4 }
    $worst = $Global:VES_EXIT_OK
    $worstRank = 0
    foreach ($code in $ExitCode) {
        $r = if ($rank.ContainsKey($code)) { $rank[$code] } else { 5 }
        if ($r -gt $worstRank) { $worstRank = $r; $worst = $code }
    }
    return $worst
}

function Get-VesBackupSet {
    <#
    .SYNOPSIS Enumerate a processor's deploy backups, newest first.
    .DESCRIPTION
      Accepts BOTH folder shapes: the current <yyyyMMddTHHmmss>_<Initials>_<Processor>
      and the older date-only <yyyyMMdd>_<Initials>_<Processor>. Date-only folders
      sort at midnight, so a same-day timestamped backup correctly outranks them.

      rollback-record.json is written LAST by the deploy, so HasRecord=$false also
      means "this backup may be incomplete" -- callers warn on it rather than
      trusting the folder blindly.
    .OUTPUTS
      Array of {Name, FullName, Stamp, StampKind, Initials, HasRecord, Record,
                HasManifest, ManifestPath, FileCount, SizeBytes}, newest first.
      Wrap the call in @(): a single backup arrives as a scalar otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$Processor
    )
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return @() }

    # Named groups keep the two shapes in one pattern; the processor is escaped so a
    # name containing regex metacharacters cannot widen the match to other systems.
    $pattern = '^(?<stamp>\d{8}T\d{6}|\d{8})_(?<initials>.+)_' + [regex]::Escape($Processor) + '$'
    $dirs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $pattern })

    foreach ($dir in $dirs) {
        # -match above already populated $Matches, but re-match explicitly: the
        # foreach body may clobber it before we read the groups.
        $null = $dir.Name -match $pattern
        $stampText = $Matches['stamp']
        $initials = $Matches['initials']

        $stamp = $null
        $stampKind = 'unknown'
        $culture = [Globalization.CultureInfo]::InvariantCulture
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($stampText, 'yyyyMMddTHHmmss', $culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $stamp = $parsed; $stampKind = 'timestamp'
        }
        elseif ([datetime]::TryParseExact($stampText, 'yyyyMMdd', $culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $stamp = $parsed; $stampKind = 'date'
        }
        else {
            # Unparseable stamp: fall back to the folder's own timestamp so it still
            # sorts sanely instead of being dropped from the set.
            $stamp = $dir.LastWriteTime
        }

        $recordPath = Join-Path $dir.FullName 'rollback-record.json'
        $record = $null
        $hasRecord = $false
        if (Test-Path -LiteralPath $recordPath) {
            try {
                $record = Get-Content -LiteralPath $recordPath -Raw -Encoding utf8 | ConvertFrom-Json
                $hasRecord = $true
            }
            catch {
                # A malformed sidecar must not take out the whole listing; report it
                # as "no record" and let the caller decide.
                $record = $null
                $hasRecord = $false
            }
        }

        $manifestPath = Join-Path $dir.FullName 'backup-manifest.json'
        $hasManifest = Test-Path -LiteralPath $manifestPath

        # Count/size the payload only -- the sidecars and the config stash are ours,
        # not part of the restored tree, so they must not inflate either number.
        $fileCount = 0
        $sizeBytes = [long]0
        try {
            $configStash = Join-Path $dir.FullName '_ves-config'
            $files = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.Name -ne 'rollback-record.json' -and $_.Name -ne 'backup-manifest.json' -and
                        -not $_.FullName.StartsWith(($configStash + '\'), [StringComparison]::OrdinalIgnoreCase)
                    })
            $fileCount = $files.Count
            foreach ($f in $files) { $sizeBytes += $f.Length }
        }
        catch { $fileCount = -1 }   # -1 == "could not enumerate", distinct from a genuinely empty backup

        $out.Add([PSCustomObject]@{
                Name         = $dir.Name
                FullName     = $dir.FullName
                Stamp        = $stamp
                StampKind    = $stampKind
                Initials     = $initials
                HasRecord    = $hasRecord
                Record       = $record
                HasManifest  = $hasManifest
                ManifestPath = $(if ($hasManifest) { $manifestPath } else { $null })
                FileCount    = $fileCount
                SizeBytes    = $sizeBytes
            })
    }

    # Newest first. Name breaks ties between two same-day date-only folders (both
    # parse to midnight). Emitted to the pipeline normally, so callers must wrap
    # in @() -- a single backup otherwise arrives as a scalar with no .Count.
    return @($out | Sort-Object -Property @{Expression = 'Stamp'; Descending = $true }, @{Expression = 'Name'; Descending = $true })
}

function Stop-VesProcessorTarget {
    <#
    .SYNOPSIS Quiesce a processor so its target tree can be safely mirrored over.
    .DESCRIPTION
      Lifted verbatim from Deploy-Processor's stop phase so the deploy and the
      rollback quiesce production the same way. Disables the given scheduled
      tasks, stops the service if one is named, then deals with console-EXE
      instances: a running exe under TargetRoot keeps its files locked even after
      its task is disabled and would corrupt the mirror. ExecutablePath-under-
      TargetRoot is the instance identity (the same exe name runs from several
      folders per box); working dir is not exposed by WMI.

      Never throws. Stopped=$false means "do not touch the tree"; the caller's
      finally still hands DisabledTasks to Start-VesProcessorTarget so anything
      we disabled comes back up.
    .OUTPUTS
      {Stopped, DisabledTasks, ServiceStopped, KilledPids, BlockingPids, Errors}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetRoot,
        # Task Scheduler jobs on THIS server to disable. Empty for service-only systems.
        [string[]]$ScheduledTasks = @(),
        [string]$ServiceName,
        # Force-stop instances whose exe lives under TargetRoot. Without it a
        # detected instance blocks the operation instead of fighting a file lock.
        [switch]$KillProcesses,
        # How long to wait for killed instances to release their handles.
        [int]$HandleWaitSeconds = 30,
        # Audit context only; carried into the kill log lines.
        [string]$Processor = 'unknown',
        [string]$LogFile
    )
    $disabled = New-Object System.Collections.Generic.List[string]
    $killed = New-Object System.Collections.Generic.List[int]
    $blocking = New-Object System.Collections.Generic.List[int]
    $errors = New-Object System.Collections.Generic.List[string]
    $serviceStopped = $false
    $stopFailed = $false

    # disable the scheduled tasks that hold the target files open
    foreach ($tn in $ScheduledTasks) {
        try {
            Disable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
            $disabled.Add($tn); Write-VesLog INFO "Disabled task: $tn" -LogFile $LogFile
        }
        catch {
            $msg = "Could not disable task $tn -> $($_.Exception.Message)"
            Write-VesLog ERROR $msg -LogFile $LogFile; $errors.Add($msg); $stopFailed = $true; break
        }
    }
    # stop the Windows service too, for Java-service targets
    if (-not $stopFailed -and $ServiceName) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                $serviceStopped = $true
                Write-VesLog INFO "Stopped service: $ServiceName" -LogFile $LogFile
            }
            catch {
                $msg = "Could not stop service $ServiceName -> $($_.Exception.Message)"
                Write-VesLog ERROR $msg -LogFile $LogFile; $errors.Add($msg); $stopFailed = $true
            }
        }
    }
    # Console-EXE instances holding the tree open.
    if (-not $stopFailed) {
        $targetItem = Get-Item -LiteralPath $TargetRoot -ErrorAction SilentlyContinue
        if ($targetItem) {
            $targetPrefix = $targetItem.FullName.TrimEnd('\') + '\'
            $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                    Where-Object { $_.ExecutablePath -and
                        $_.ExecutablePath.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase) })
            foreach ($p in $running) {
                if ($KillProcesses) {
                    # audit line BEFORE the kill: which instance (mode arg visible in CommandLine)
                    Write-VesLog WARN ("Killing running instance PID {0}: {1}" -f $p.ProcessId, $p.CommandLine) `
                        -Data @{processor = $Processor; pid = $p.ProcessId; commandLine = $p.CommandLine } -LogFile $LogFile
                    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed.Add([int]$p.ProcessId) }
                    catch {
                        $msg = "Could not kill PID $($p.ProcessId) -> $($_.Exception.Message)"
                        Write-VesLog ERROR $msg -LogFile $LogFile; $errors.Add($msg); $stopFailed = $true
                    }
                }
                else {
                    $blocking.Add([int]$p.ProcessId)
                    $msg = ("Running instance holds {0}: PID {1} {2}. Re-run with -KillProcesses to stop it." -f `
                            $TargetRoot, $p.ProcessId, $p.CommandLine)
                    Write-VesLog ERROR $msg -LogFile $LogFile; $errors.Add($msg); $stopFailed = $true
                }
            }
            # wait for killed instances to actually exit and release handles
            if ($KillProcesses -and -not $stopFailed -and $running.Count) {
                $ids = @($running | ForEach-Object { $_.ProcessId })
                $deadline = (Get-Date).AddSeconds($HandleWaitSeconds)
                while ((Get-Date) -lt $deadline -and (Get-Process -Id $ids -ErrorAction SilentlyContinue)) {
                    Start-Sleep -Milliseconds 250
                }
                # Filter nulls: @($null).Count is 1, which would read as "still alive"
                # on a host where the lookup yields a null rather than nothing.
                $alive = @(Get-Process -Id $ids -ErrorAction SilentlyContinue | Where-Object { $_ })
                if ($alive.Count) {
                    $msg = "Instance(s) still alive after kill: $(($alive | ForEach-Object Id) -join ', ')"
                    Write-VesLog ERROR $msg -LogFile $LogFile; $errors.Add($msg); $stopFailed = $true
                }
            }
        }
    }

    return [PSCustomObject]@{
        Stopped        = (-not $stopFailed)
        DisabledTasks  = $disabled.ToArray()
        ServiceStopped = $serviceStopped
        KilledPids     = $killed.ToArray()
        BlockingPids   = $blocking.ToArray()
        Errors         = $errors.ToArray()
    }
}

function Start-VesProcessorTarget {
    <#
    .SYNOPSIS Bring a processor back up after Stop-VesProcessorTarget.
    .DESCRIPTION
      Reverse order: service first, then re-enable exactly the tasks we disabled.
      Call this from a finally so a failed copy still leaves production running.
      -StartTasks additionally triggers each re-enabled task now instead of
      waiting for its next scheduled trigger; the caller decides whether the tree
      is fit to run. Never throws -- a restart failure is logged at ERROR and
      collected, because there is nothing useful left to unwind.
    .OUTPUTS {StartedTasks, Errors}
    #>
    [CmdletBinding()]
    param(
        # Exactly the tasks Stop-VesProcessorTarget reported disabling.
        [string[]]$DisabledTasks = @(),
        [string]$ServiceName,
        [switch]$StartTasks,
        [string]$LogFile
    )
    $started = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    if ($ServiceName) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Start-Service -Name $ServiceName -ErrorAction Stop
                Write-VesLog INFO "Started service: $ServiceName" -LogFile $LogFile
            }
            catch {
                $msg = "FAILED to restart service $ServiceName -> $($_.Exception.Message)"
                Write-VesLog ERROR $msg -LogFile $LogFile; $errors.Add($msg)
            }
        }
    }
    foreach ($tn in $DisabledTasks) {
        try {
            Enable-ScheduledTask -TaskName $tn -ErrorAction Stop | Out-Null
            Write-VesLog INFO "Re-enabled task: $tn" -LogFile $LogFile
        }
        catch {
            $msg = "FAILED to re-enable task $tn -> $($_.Exception.Message)"
            Write-VesLog ERROR $msg -LogFile $LogFile; $errors.Add($msg)
        }
    }
    if ($StartTasks) {
        foreach ($tn in $DisabledTasks) {
            try {
                Start-ScheduledTask -TaskName $tn -ErrorAction Stop
                $started.Add($tn)
                Write-VesLog INFO "Started task: $tn" -LogFile $LogFile
            }
            catch {
                # WARN (not ERROR): Enable above already succeeded, so the task will
                # fire on its next trigger. Immediate Start is best-effort relaunch;
                # failing it must not outrank a re-enable failure that leaves the
                # job permanently disabled.
                $msg = "Could not start task $tn -> $($_.Exception.Message)"
                Write-VesLog WARN $msg -LogFile $LogFile; $errors.Add($msg)
            }
        }
    }
    return [PSCustomObject]@{ StartedTasks = $started.ToArray(); Errors = $errors.ToArray() }
}

# --- DATADOG DISABLED ---------------------------------------------------------
# Telemetry emit is commented out in place. Every call site across the entry
# scripts is disabled to match; uncomment both sides together to restore.
#
# function Send-VesDatadogMetric {
#     <#
#     .SYNOPSIS DogStatsD gauge via local agent UDP:8125. Non-fatal on failure.
#     .NOTES Emit counts per host/processor -- never per-file tags (cardinality).
#     #>
#     [CmdletBinding()]
#     param(
#         # Metric name, e.g. deployment.verify.mismatch.
#         [Parameter(Mandatory)][string]$Metric,
#         # Gauge value to report.
#         [Parameter(Mandatory)][double]$Value,
#         # Tags such as processor:/env:/version: -- keep cardinality low.
#         [string[]]$Tags = @(),
#         # Local Datadog agent address (DogStatsD listener).
#         [string]$AgentHost = '127.0.0.1',
#         # DogStatsD UDP port.
#         [int]$Port = 8125
#     )
#     # Monitoring must never break verification -- all failures here are warnings only.
#     $udp = $null
#     try {
#         # Drop blank tags so the wire payload never contains empty tag values.
#         $cleanTags = @($Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
#         # Build the tag suffix only when tags exist ('|#tag1,tag2' per DogStatsD wire format).
#         $tagStr = if ($cleanTags.Count) { '|#' + ($cleanTags -join ',') } else { '' }
#         # Format numeric values with invariant culture so decimal separators stay DogStatsD-safe.
#         $valueText = [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
#         # DogStatsD gauge wire format: name:value|g|#tags.
#         $payload = "{0}:{1}|g{2}" -f $Metric, $valueText, $tagStr
#         # Open a UDP client aimed at the local agent.
#         $udp = New-Object System.Net.Sockets.UdpClient
#         $udp.Connect($AgentHost, $Port)
#         # DogStatsD is ASCII on the wire.
#         $bytes = [Text.Encoding]::ASCII.GetBytes($payload)
#         # Fire-and-forget send; [void] discards the byte count return value.
#         [void]$udp.Send($bytes, $bytes.Length)
#     } catch {
#         # Log and continue -- a down agent must not fail the verify run.
#         Write-Warning "Datadog metric emit failed (non-fatal): $($_.Exception.Message)"
#     } finally {
#         # Always release the UDP socket, including exception paths.
#         if ($udp) { $udp.Close() }
#     }
# }
#
# function Get-VesDatadogEnvTag {
#     <#
#     .SYNOPSIS Returns the Datadog env tag, defaulting to env:prod.
#     #>
#     [CmdletBinding()]
#     param([string]$Environment)
#     # An explicit target environment outranks DD_ENV. Fall back to prod for
#     # stable dashboards when neither is supplied.
#     $envTagValue = if (-not [string]::IsNullOrWhiteSpace($Environment)) {
#         $Environment.Trim().ToLowerInvariant()
#     } elseif ([string]::IsNullOrWhiteSpace($env:DD_ENV)) {
#         'prod'
#     } else {
#         $env:DD_ENV.Trim().ToLowerInvariant()
#     }
#     return "env:$envTagValue"
# }
# ------------------------------------------------------------------------------

function Get-VesAlertType {
    <#
    .SYNOPSIS Production failures are errors; lower environments are warnings.
    .NOTES Currently unused: its only consumers were the disabled event emits.
           Kept exported so the disabled blocks can be restored as written.
    #>
    [CmdletBinding()]
    param([string]$Environment)
    $value = if ([string]::IsNullOrWhiteSpace($Environment)) { 'prod' } else { $Environment.Trim().ToLowerInvariant() }
    if ($value -in @('prod', 'production')) { return 'error' }
    return 'warning'
}

# --- DATADOG DISABLED ---------------------------------------------------------
# function Send-VesDatadogEvent {
#     <#
#     .SYNOPSIS Post a deploy/verify event to the ddog-gov Events API. Non-fatal.
#     #>
#     [CmdletBinding()]
#     param(
#         # Event title shown in the Datadog event stream.
#         [Parameter(Mandatory)][string]$Title,
#         # Event body text.
#         [Parameter(Mandatory)][string]$Text,
#         # Tags for filtering/overlaying on dashboards.
#         [string[]]$Tags = @(),
#         # Datadog alert type controls event color/severity.
#         [ValidateSet('info','success','warning','error')][string]$AlertType = 'info',
#         # API key from environment by default -- never hardcoded, never committed.
#         [string]$ApiKey = $env:DD_API_KEY,
#         # GovCloud Datadog site.
#         [string]$Site = 'ddog-gov.com'
#     )
#     # No key -> skip quietly with a warning; events are best-effort telemetry.
#     if ([string]::IsNullOrWhiteSpace($ApiKey)) {
#         Write-Warning 'DD_API_KEY not set; skipping Datadog event.'
#         return
#     }
#     # Same non-fatal posture as metrics.
#     try {
#         # Drop blank tags so event metadata is deterministic and easy to filter.
#         $cleanTags = @($Tags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
#         # Assemble the Events API payload.
#         $body = @{ title=$Title; text=$Text; tags=$cleanTags; alert_type=$AlertType } | ConvertTo-Json -Depth 4
#         # Events API v1 endpoint on the GovCloud site; key passed as query param per API contract.
#         $uri  = "https://api.$Site/api/v1/events?api_key=$([Uri]::EscapeDataString($ApiKey))"
#         # POST and discard the response body -- only success/failure matters here.
#         Invoke-RestMethod -Uri $uri -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 10 | Out-Null
#     } catch {
#         # Log and continue -- Datadog outage must not block a deploy or verify.
#         Write-Warning "Datadog event emit failed (non-fatal): $($_.Exception.Message)"
#     }
# }
# ------------------------------------------------------------------------------

# Export only the public surface; anything not listed stays module-private.
Export-ModuleMember -Function `
    Write-VesLog, New-VesLogFile, Get-VesOutcome, Import-VesTargetInventory, `
    Get-VesManifest, Get-VesManifestHash, Export-VesManifest, `
    Import-VesManifest, Test-VesExcludePattern, Compare-VesFiles, `
    Get-VesTrustedHash, Set-VesTrustedHash, `
    Invoke-VesAwsCli, Invoke-VesGit, Test-VesReleaseTag, Get-VesManifestFromTag, `
    Get-VesWorstExitCode, Get-VesBackupSet, `
    Stop-VesProcessorTarget, Start-VesProcessorTarget, `
    Get-VesAlertType
# DATADOG DISABLED: Send-VesDatadogMetric, Send-VesDatadogEvent, Get-VesDatadogEnvTag
