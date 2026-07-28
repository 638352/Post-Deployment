# Post-Deployment Script Testing Guide

This document replaces the earlier testing instructions. It is a start-to-finish
runbook for a tester who is not expected to read PowerShell code. If the tester
can open Windows PowerShell, copy a complete command block, and compare the
screen with the stated expected result, they can perform the safe portions of
this guide.

Follow the sections in order. Do not skip a failed step. A local test pass does
not authorize a deployment, and a non-technical tester must not make up missing
server names, paths, AWS regions, task names, release tags, or SSM parameters.

Last fully recreated and source-checked: 27 July 2026

## What this guide covers

The live repository is `C:\Users\howardr01\Post-Deployment`. This guide covers
every canonical PowerShell script in that repository:

- the ten runnable scripts in the repository root;
- the two processor scripts under `processors\`;
- the shared `module\VesVerify.psm1` module; and
- the test scripts under `tests\`.

Only Git-tracked scripts in the live tree are considered canonical. Files with
` - Copy` in their names and untracked scratch scripts are personal working
copies, not release scripts. `Post-Deployment-datadog-558667ed\` is a frozen
reference snapshot and is also excluded.

## Read this before testing

Do not begin with a production server. Use this order:

1. Run the syntax check on a development workstation.
2. Run the full automated test suite on that workstation.
3. Run the safe local examples in this guide.
4. Run read-only checks on DEV or UAT.
5. Only a change owner may test a real deployment, and UAT must come before
   PROD.

The labels used in this guide mean:

| Label | Meaning |
|---|---|
| **SAFE** | Uses test files on a workstation. It does not need a server, AWS, or the network. |
| **READ-ONLY** | Reads files, AWS parameters, services, tasks, or logs. It does not deploy files, but it may write an audit log or a best-effort Datadog signal. |
| **CHANGES TEST HOST** | Adds or removes test scheduled tasks. Use an approved DEV/UAT host and an Administrator window. |
| **DEPLOYMENT** | Can stop a process, copy files, or restart a task or service. A change owner must control this test. |

### How to copy and run the command blocks

1. Copy the entire PowerShell block, including every line between the opening
   and closing fences. Do not copy the word `powershell` above the block.
2. Do not copy a prompt such as `PS C:\>` from the screen.
3. A backtick at the far right of a line means the command continues on the
   next line. Copy all continued lines together.
4. If PowerShell shows only `>>` and waits, press **Ctrl+C** once. Then copy the
   complete block again; part of the command was missing.
5. Text such as `REPLACE_WITH_CONFIRMED_REGION` is a stop marker. Do not run the
   command until the release owner supplies that value and the marker is gone.
6. Keep the same Windows PowerShell window open. Variables beginning with `$`
   exist only in that window and are reused by later steps.
7. Immediately after a script finishes, enter `$LASTEXITCODE`, record the
   number, and save the visible output. Running another program first can replace
   the exit code.

### Who must approve the higher-risk steps

| Activity | Person who must approve or be present |
|---|---|
| SAFE workstation tests | Tester or repository maintainer |
| Read-only DEV/UAT server or AWS checks | Application owner and system owner |
| Test scheduled-task installation | Windows administrator on an approved DEV/UAT host |
| UAT `-WhatIf` gate-only test | Release owner with confirmed runbook values |
| Any command without `-WhatIf` that calls a deployment script | Change owner, application owner, and rollback owner |
| Any PROD activity | Formal change authorization; this guide alone is not authorization |

Never paste a password, token, connection string, decrypted SSM value, or API
key into this document or the evidence record.

### Current stop signs

These are expected conditions in the repository, not test surprises:

- `targets.json` has `inventoryComplete` set to `false`. A full inventory
  preflight or drift run should fail closed with exit code `2` until Operations
  confirms every server, including the Citrix servers.
- `processors\Deploy-OutboundDBQ-uat.ps1` contains a scheduled-task name and
  fresh-log path marked `CONFIRM`. Do not pass `-ConfirmedRunbookValues` until
  both have been checked against the current deployment runbook.
- `Deploy-Processor.ps1` uses a mirrored copy. A configuration file below the
  target folder can be replaced by the staged version. Do not run a real PROD
  deployment until the team has decided whether to exclude configuration files
  or stage the correct per-server configuration.
- Confirm whether the required SSM parameters are in `us-gov-east-1` or
  `us-gov-west-1`. Do not guess the region.

### Information that must be collected before any DEV or UAT check

The SAFE workstation tests do not need production values. Before starting a
server, AWS, gate, health, drift, or scheduler check, the tester must obtain the
following from the current runbook or the named owner. Put the answers in the
change ticket or test record, not in this repository.

| Required item | Example shape only | Source or approver |
|---|---|---|
| Environment and server | `uat`, `VESMSEGRESSUAT` | Application/server owner |
| Processor name | `OutboundDBQ` | `SERVERS.md` plus current runbook |
| Staged release folder | `D:\stage\<processor>` | Release owner |
| Target installation folder | `C:\...\Processors\...` | Server runbook |
| Approved commit/release identifier | Git commit SHA | Release owner |
| Release tag | `<processor>/vMAJOR.MINOR.PATCH` | Approved Git release record |
| Baseline manifest or baseline repository | `D:\baselines\<name>.json` or approved Git checkout | Release owner |
| Approved-commit SSM parameter | `/ves/<name>/approved-commit` | AWS/operations owner |
| Baseline-hash SSM parameter | `/ves/<name>/baseline-hash` | AWS/operations owner |
| GovCloud region | `us-gov-east-1` or `us-gov-west-1` | AWS owner; never infer it from an example |
| Configuration contract and live config | Two confirmed file paths | Application owner |
| Required staged config/artifact paths | Paths relative to the staged root | Application owner |
| Task or service name | Exact Task Scheduler or Windows service name | Server runbook |
| Process identity | Executable folder plus RTP/RTPDP argument pattern | Server owner |
| Fresh-log folder or health URL | Exact local path or endpoint | Application owner |
| Backup folder and rollback owner | Approved writable location and named owner | Change owner |
| Audit-log folder | Durable test or central audit location | Operations owner |
| Change ticket and test window | Approved reference and time | Change owner |

Stop if any value required by the selected test is blank, still contains
`REPLACE`, or conflicts with `SERVERS.md`. The release owner must resolve the
conflict before the tester continues.

### Test coverage at a glance

| Script or component | Automated coverage | Additional check in this guide | Highest safety level |
|---|---|---|---|
| `Invoke-Tests.ps1` | Runs every file under `tests\` | Full-suite result and exit code | SAFE |
| `module\VesVerify.psm1` | `VesVerify.Module.Tests.ps1` | Do not run the module directly | SAFE |
| `Verify-Config.ps1` | `Verify-Config.Tests.ps1` | Bundled-fixture configuration check | SAFE |
| `Invoke-Verification.ps1` | `Invoke-Verification.Tests.ps1` | Local config, capture, and file comparison | SAFE |
| `Invoke-Preflight.ps1` | `Invoke-Preflight.Tests.ps1` | Local contract check and read-only inventory check | READ-ONLY |
| `Invoke-PreDeployGate.ps1` | `Invoke-PreDeployGate.Tests.ps1` | UAT gate acceptance | READ-ONLY |
| `Invoke-HealthCheck.ps1` | `Invoke-HealthCheck.Tests.ps1` | Local fresh-log and UAT processor checks | READ-ONLY |
| `Deploy-Processor.ps1` | `Deploy-Processor.Tests.ps1` | UAT gate-only fingerprint check | DEPLOYMENT without `-WhatIf` |
| `processors\Deploy-SYSTEM_NAME.ps1` | Shared engine coverage | Template and placeholder inspection | SAFE |
| `processors\Deploy-OutboundDBQ-uat.ps1` | Shared engine coverage | Safety-lock and UAT gate-only checks | DEPLOYMENT without `-WhatIf` |
| `Start-DriftRunner.ps1` | `Start-DriftRunner.Tests.ps1` | Fail-closed starter-inventory run | READ-ONLY |
| `Test-DriftHeartbeat.ps1` | `Test-DriftHeartbeat.Tests.ps1` | Read the local runner heartbeat | READ-ONLY |
| `Install-DriftTask.ps1` | `Install-DriftTask.Tests.ps1` | Optional DEV/UAT Task Scheduler integration | CHANGES TEST HOST |

## Understanding the result

Most runnable scripts use these exit codes:

| Exit code | Plain-language meaning |
|---:|---|
| `0` | Passed |
| `1` | Files/settings differ, or a deployment gate was blocked |
| `2` | Baseline, trust, inventory, AWS, or runtime problem |
| `3` | Health check failed |
| `10` | Missing input or unsafe setup |

After each command in this guide, enter:

```powershell
$LASTEXITCODE
```

PowerShell will print the exit code. Do not treat a red message by itself as
the final result; record the exit code and the named failure in the output.

The entry scripts also write JSONL audit logs. A normal completed run contains
a `RUN START` line and a `RUN END` line with an outcome and exit code.
Important exceptions:

- `Invoke-Tests.ps1` returns the number of failed Pester tests. Zero is green.
- `Verify-Config.ps1` is a helper that returns an object with a `.pass` field.
  For an ordinary script exit code, test configuration through
  `Invoke-Verification.ps1 -Mode VerifyConfig` as shown later.
- Several safety tests intentionally trigger an error. The test passes when the
  script refuses unsafe input with the expected non-zero result.
- Red text is not enough by itself to classify a result. Record the exact exit
  code, the named error, and the audit-log path.

When a command is important, save the exit code before doing anything else:

```powershell
$RecordedExitCode = $LASTEXITCODE
$RecordedExitCode
```


## One-time workstation setup

### 1. Open the correct PowerShell

Open **Windows PowerShell**, not PowerShell 7. Then enter:

```powershell
$PSVersionTable.PSVersion
```

The first two numbers must be `5` and `1`. Stop and contact the maintainer if
they are not.

### 2. Move to the live repository

```powershell
Set-Location 'C:\Users\howardr01\Post-Deployment'
$RepoRoot = git rev-parse --show-toplevel
$RepoRoot
git status --short
```

Expected result:

- `$RepoRoot` prints `C:/Users/howardr01/Post-Deployment` or the same path with
  backslashes.
- `git status --short` normally prints nothing. If it lists files, save the
  output and ask the maintainer whether those changes are expected before
  testing. Do not delete or reset them.
- If `git` is not recognized, stop. Git is required for the canonical file list,
  release records, and tagged baselines.

Keep this Windows PowerShell window open while following the guide.

### 3. Confirm Pester is available

```powershell
Get-Module -ListAvailable Pester |
    Sort-Object Version -Descending |
    Select-Object -First 1 Name,Version
```

The version must be `5.0.0` or newer. If nothing is displayed, ask the
workstation owner to approve this one-time installation:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

Do not install modules on a production server.

### 4. Confirm the computer and account

```powershell
$env:COMPUTERNAME
whoami
```

Write both values in the test record. If the computer is a production server,
close the window and move to the approved workstation unless the change owner
has explicitly authorized the exact production check.

### 5. Check the execution policy without changing it

```powershell
Get-ExecutionPolicy -List
```

Record the output. Do not run `Set-ExecutionPolicy` and do not weaken a machine
or domain policy. The test commands use `-ExecutionPolicy Bypass` only for the
new child process they start. If policy or a `Zone.Identifier` still blocks a
script, stop and ask the maintainer for an approved unblocked copy.

### 6. Check AWS CLI only if live SSM checks are planned

SAFE local tests do not require AWS. For a read-only DEV/UAT preflight or gate
check, enter:

```powershell
Get-Command aws -ErrorAction SilentlyContinue
aws --version
```

Expected result: both commands identify the AWS CLI. This does not prove that
the account, KMS permission, parameter path, or region is correct; the live
preflight tests those separately. If AWS is not required for the selected test,
record `AWS CLI: not required for local test` instead of treating it as a pass.

### 7. Create a separate evidence folder

Copy this once in the same PowerShell window:

```powershell
$PreviousAuditLogDir = $env:VES_AUDIT_LOG_DIR
$EvidenceRoot = Join-Path $env:TEMP (
    'ves-testing-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
)
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$env:VES_AUDIT_LOG_DIR = $EvidenceRoot

$SessionRecord = [ordered]@{
    startedUtc = (Get-Date).ToUniversalTime().ToString('o')
    tester = whoami
    computer = $env:COMPUTERNAME
    repository = (Get-Location).Path
    commit = (git rev-parse HEAD)
    powershell = $PSVersionTable.PSVersion.ToString()
}
$SessionRecord | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $EvidenceRoot 'test-session.json')

$EvidenceRoot
Get-ChildItem -LiteralPath $EvidenceRoot
```

Expected result: PowerShell prints a folder below the tester's temporary
folder and lists `test-session.json`. All local audit logs in this guide will be
written there. Do not use a production audit share for workstation tests.

Confirm the tester can write there:

```powershell
$WriteTest = Join-Path $EvidenceRoot 'write-test.txt'
Set-Content -LiteralPath $WriteTest -Value 'test'
Test-Path -LiteralPath $WriteTest
Remove-Item -LiteralPath $WriteTest -Force
```

Expected result: `True`.

### 8. Confirm the bundled test data is present

```powershell
@(
    '.\tests\fixtures\appconfig\contract.json'
    '.\tests\fixtures\json\contract.json'
    '.\tests\fixtures\json\config.json'
    '.\tests\fixtures\keyvalue\contract.json'
    '.\sample.config.json'
    '.\targets.json'
) | ForEach-Object {
    [PSCustomObject]@{
        Path = $_
        Present = Test-Path -LiteralPath $_
    }
} | Format-Table -AutoSize
```

Expected result: every `Present` value is `True`. Stop if any file is missing.

## Test 1: Check the syntax of every canonical script

**Safety:** SAFE

Copy the whole block into Windows PowerShell:

```powershell
$trackedPaths = @(git ls-files -- '*.ps1' '*.psm1')
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the canonical file list from Git.'
}

$files = @(
    $trackedPaths |
        Where-Object { $_ -notlike 'Post-Deployment-datadog-558667ed/*' } |
        ForEach-Object { Get-Item -LiteralPath $_ }
)

$problems = foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    foreach ($error in $errors) {
        [PSCustomObject]@{
            File    = $file.FullName
            Line    = $error.Extent.StartLineNumber
            Problem = $error.Message
        }
    }
}

if ($problems) {
    $problems | Format-Table -AutoSize
} else {
    "SYNTAX PASS: $($files.Count) canonical PowerShell files checked."
}
```

Pass:

- The last line begins with `SYNTAX PASS`.
- No file, line number, or problem is listed.

Fail:

- One or more files are listed with a line number. Stop here and send the full
  table to the maintainer.

### Optional supplemental lint

PSScriptAnalyzer can find style, compatibility, and maintainability problems
that the parser does not. It is supplemental: syntax and Pester results must
still be reported separately.

```powershell
$analyzer = Get-Module -ListAvailable PSScriptAnalyzer |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $analyzer) {
    'LINT NOT RUN: PSScriptAnalyzer is not installed.'
} else {
    Import-Module $analyzer.Path -Force
    $lintResults = foreach ($file in $files) {
        Invoke-ScriptAnalyzer -Path $file.FullName
    }
    $lintResults | Format-Table RuleName,Severity,ScriptName,Line,Message -AutoSize
    "LINT FINDINGS: $(@($lintResults).Count)"
}
```

If the module is unavailable, record `LINT NOT RUN`; do not record a lint pass.
Do not install it on a production server. Any installation on a development
workstation should follow the workstation owner's module-approval process.

## Test 2: Run the full automated test suite

**Script:** `Invoke-Tests.ps1`  
**Safety:** SAFE

This is the main test and should be run before any hands-on script check.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

Pass:

- The Pester summary reports `Failed: 0`.
- The exit code is `0`.

The total number of tests can grow as the repository changes. Zero failed tests
is the important result.

If the result says `Pester 5.x not found`, complete the approved installation
in the setup section and try again.

If the result says `Requested registry access is not allowed`, the restricted
test environment blocked the test setup. Run the same command in an approved
normal Windows PowerShell session. Do not report that as a script defect unless
it also fails there.

If Windows reports that a script is not digitally signed, do not lower the
machine's security policy. Ask the maintainer to provide an approved,
unblocked test copy.

## Test 3: Test the shared module

**Script:** `module\VesVerify.psm1`  
**Safety:** SAFE

The module is a library used by the other scripts. Do not run the `.psm1` file
directly. Test it through its dedicated suite:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\VesVerify.Module.Tests.ps1
$LASTEXITCODE
```

Pass:

- Pester reports `Failed: 0`.
- The exit code is `0`.

This checks manifest creation, hashing, tamper detection, file comparison,
target inventory rules, logging, release-tag validation, AWS command error
handling, and Datadog environment labels.

## Test 4: Test configuration checking

**Script:** `Verify-Config.ps1`  
**Safety:** SAFE when using the bundled fixtures

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Verify-Config.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

### Hands-on passing example

This example uses a test JSON file and contract already in the repository:

```powershell
$configResult = & .\Verify-Config.ps1 `
    -ContractPath .\tests\fixtures\json\contract.json `
    -ConfigPath .\tests\fixtures\json\config.json `
    -LogFile (Join-Path $EvidenceRoot 'verify-config.jsonl')

$configResult | Format-List
```

Pass:

- `pass` is `True`.
- `missingRequired`, `valueMismatch`, and `extraKeys` are empty.

Important: this low-level script returns a result object. For an operational
check with a standard exit code, use `Invoke-Verification.ps1 -Mode
VerifyConfig`, described next.

## Test 5: Test capture and verification

**Script:** `Invoke-Verification.ps1`  
**Safety:** SAFE for automated tests and the local example

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-Verification.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

### Hands-on configuration check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Verification.ps1 `
    -Mode VerifyConfig `
    -ConfigContract .\tests\fixtures\json\contract.json `
    -ConfigPath .\tests\fixtures\json\config.json `
    -Processor GuideTest `
    -Environment dev `
    -Json `
    -LogFile (Join-Path $EvidenceRoot 'verification-config.jsonl')
$LASTEXITCODE
```

Pass:

- The JSON output contains `"status":"match"`.
- The exit code is `0`.

### Hands-on local capture and file comparison

The two `Allow` switches below are permitted only because this is a temporary
local lab. Never use them to approve a real release.

```powershell
$LabRoot = Join-Path $EvidenceRoot 'verification-lab'
$LabRelease = Join-Path $LabRoot 'release'
$LabManifest = Join-Path $LabRoot 'GuideTest.json'
New-Item -ItemType Directory -Path $LabRelease -Force | Out-Null
Set-Content -LiteralPath (Join-Path $LabRelease 'sample.txt') `
    -Value 'approved test content'

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Verification.ps1 `
    -Mode Capture `
    -ReleaseRoot $LabRelease `
    -ManifestPath $LabManifest `
    -Processor GuideTest `
    -CommitSha local-test `
    -Environment dev `
    -AllowUntrustedCapture `
    -AllowUnarchivedCapture `
    -Json `
    -LogFile (Join-Path $LabRoot 'capture.jsonl')
$LASTEXITCODE
```

Pass: the JSON status is `captured`, the manifest exists, and the exit code is
`0`.

Now compare the unchanged folder with that manifest:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Verification.ps1 `
    -Mode VerifyFiles `
    -ReleaseRoot $LabRelease `
    -ManifestPath $LabManifest `
    -Processor GuideTest `
    -Environment dev `
    -Json `
    -LogFile (Join-Path $LabRoot 'verify.jsonl')
$LASTEXITCODE
```

Pass: the JSON status is `match` and the exit code is `0`. A warning about no
trust parameter is expected in this isolated local check.

The automated suite also proves that a changed, missing, or extra file returns
exit code `1`, and that a corrupt or untrusted manifest returns exit code `2`.

### Hands-on drift detection and recovery

This changes only the temporary lab file created above.

```powershell
Set-Content -LiteralPath (Join-Path $LabRelease 'sample.txt') `
    -Value 'deliberately changed test content'

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Verification.ps1 `
    -Mode VerifyFiles `
    -ReleaseRoot $LabRelease `
    -ManifestPath $LabManifest `
    -Processor GuideTest `
    -Environment dev `
    -Json `
    -LogFile (Join-Path $LabRoot 'verify-drift.jsonl')
$LASTEXITCODE
```

Expected result: the JSON status is `drift`, the changed file is named, and the
exit code is `1`. That non-zero result means drift detection worked.

Restore the temporary file and prove the result returns to green:

```powershell
Set-Content -LiteralPath (Join-Path $LabRelease 'sample.txt') `
    -Value 'approved test content'

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Verification.ps1 `
    -Mode VerifyFiles `
    -ReleaseRoot $LabRelease `
    -ManifestPath $LabManifest `
    -Processor GuideTest `
    -Environment dev `
    -Json `
    -LogFile (Join-Path $LabRoot 'verify-recovered.jsonl')
$LASTEXITCODE
```

Expected result: the JSON status is `match` and the exit code is `0`.

## Test 6: Test the preflight check

**Script:** `Invoke-Preflight.ps1`  
**Safety:** SAFE for the contract example; READ-ONLY for AWS or inventory checks

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-Preflight.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

### Safe local check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Preflight.ps1 `
    -Processor GuideTest `
    -ConfigContract .\sample.config.json `
    -Json `
    -LogFile (Join-Path $EvidenceRoot 'preflight-local.jsonl')
$LASTEXITCODE
```

Pass:

- The summary says `Preflight READY`.
- The JSON contains `"ready":true`.
- The exit code is `0`.

### Current inventory check

Run this only on a workstation approved to perform read-only AWS checks:

```powershell
$ConfirmedRegion = 'REPLACE_WITH_CONFIRMED_REGION'
if ($ConfirmedRegion -like 'REPLACE_*') {
    throw 'Stop: the AWS owner must supply the confirmed GovCloud region.'
}

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Preflight.ps1 `
    -TargetsFile .\targets.json `
    -Region $ConfirmedRegion `
    -Json `
    -LogFile (Join-Path $EvidenceRoot 'preflight-inventory.jsonl')
$LASTEXITCODE
```

Expected today: exit code `2` and `NOT READY`, because the checked-in inventory
is intentionally incomplete. It is a defect if this incomplete file reports
ready.

## Test 7: Test the pre-deployment gate

**Script:** `Invoke-PreDeployGate.ps1`  
**Safety:** SAFE in the automated suite; READ-ONLY against UAT

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-PreDeployGate.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

The suite checks a passing artifact, wrong commit, missing/changed files,
missing required configuration, unreadable SSM data, tag-based baselines, and
the rule that a commit string alone is not enough.

### UAT read-only acceptance check

Have the release owner replace and verify every value before running:

```powershell
$GateValues = [ordered]@{
    StagedRoot = 'REPLACE_WITH_UAT_STAGED_FOLDER'
    StagedCommit = 'REPLACE_WITH_APPROVED_RELEASE_ID'
    ApprovedCommitParam = '/ves/REPLACE/approved-commit'
    TrustParam = '/ves/REPLACE/baseline-hash'
    ManifestPath = 'D:\baselines\REPLACE.json'
    RequiredArtifactPath = 'REPLACE_WITH_CONFIG_FILE_NAME'
    Processor = 'REPLACE_WITH_PROCESSOR'
    Region = 'REPLACE_WITH_CONFIRMED_REGION'
}

$Unfinished = @(
    $GateValues.GetEnumerator() |
        Where-Object { [string]::IsNullOrWhiteSpace("$($_.Value)") -or $_.Value -match 'REPLACE' }
)
if ($Unfinished.Count -gt 0) {
    $Unfinished | Format-Table Name,Value -AutoSize
    throw 'Stop: the release owner must replace and approve every listed value.'
}
if (-not (Test-Path -LiteralPath $GateValues.StagedRoot)) {
    throw "Stop: staged folder not found: $($GateValues.StagedRoot)"
}
if (-not (Test-Path -LiteralPath $GateValues.ManifestPath)) {
    throw "Stop: manifest not found: $($GateValues.ManifestPath)"
}

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-PreDeployGate.ps1 `
    -StagedRoot $GateValues.StagedRoot `
    -StagedCommit $GateValues.StagedCommit `
    -ApprovedCommitParam $GateValues.ApprovedCommitParam `
    -TrustParam $GateValues.TrustParam `
    -ManifestPath $GateValues.ManifestPath `
    -RequiredArtifactPaths $GateValues.RequiredArtifactPath `
    -Processor $GateValues.Processor `
    -Environment uat `
    -Region $GateValues.Region `
    -LogFile (Join-Path $EvidenceRoot 'predeploy-gate-uat.jsonl')
$LASTEXITCODE
```

Pass: the output contains `Commit gate PASS` and `Content gate PASS`, and the
exit code is `0`.

Do not use `-AllowCommitOnly` or `-AllowOverride` during a normal acceptance
test. Those switches are controlled exceptions, not a way to make a test pass.

## Test 8: Test health checking

**Script:** `Invoke-HealthCheck.ps1`  
**Safety:** SAFE for the fresh-log example; READ-ONLY against UAT

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-HealthCheck.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

### Safe fresh-log check

```powershell
$HealthTestDir = Join-Path $EvidenceRoot 'health-lab'
New-Item -ItemType Directory -Path $HealthTestDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $HealthTestDir 'processor.log') `
    -Value 'test heartbeat'

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-HealthCheck.ps1 `
    -FreshLogDir $HealthTestDir `
    -FreshLogMaxAgeMinutes 5 `
    -Processor GuideTest `
    -Environment dev `
    -Json `
    -LogFile (Join-Path $HealthTestDir 'health.jsonl')
$LASTEXITCODE
```

Pass: the JSON contains `"healthy":true` and the exit code is `0`.

### UAT processor check

Use the exact executable folder and mode from the approved runbook:

```powershell
$HealthValues = [ordered]@{
    Processor = 'REPLACE_WITH_PROCESSOR'
    ProcessPathRoot = 'REPLACE_WITH_EXACT_PROCESSOR_FOLDER'
    ProcessArgumentPattern = 'REPLACE_WITH_RTP_OR_RTPDP_PATTERN'
    ScheduledTask = 'REPLACE_WITH_EXACT_TASK_NAME'
    FreshLogDir = 'REPLACE_WITH_EXACT_LOG_FOLDER'
}

$Unfinished = @(
    $HealthValues.GetEnumerator() |
        Where-Object { [string]::IsNullOrWhiteSpace("$($_.Value)") -or $_.Value -match 'REPLACE' }
)
if ($Unfinished.Count -gt 0) {
    $Unfinished | Format-Table Name,Value -AutoSize
    throw 'Stop: the server owner must replace and approve every listed value.'
}
if (-not (Test-Path -LiteralPath $HealthValues.ProcessPathRoot)) {
    throw "Stop: process folder not found: $($HealthValues.ProcessPathRoot)"
}
if (-not (Test-Path -LiteralPath $HealthValues.FreshLogDir)) {
    throw "Stop: fresh-log folder not found: $($HealthValues.FreshLogDir)"
}
Get-ScheduledTask -TaskName $HealthValues.ScheduledTask -ErrorAction Stop |
    Select-Object TaskName,State

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-HealthCheck.ps1 `
    -Processor $HealthValues.Processor `
    -ProcessPathRoot $HealthValues.ProcessPathRoot `
    -ProcessArgumentPattern $HealthValues.ProcessArgumentPattern `
    -ScheduledTasks $HealthValues.ScheduledTask `
    -FreshLogDir $HealthValues.FreshLogDir `
    -FreshLogMaxAgeMinutes 60 `
    -Environment uat `
    -Json `
    -LogFile (Join-Path $EvidenceRoot 'health-uat.jsonl')
$LASTEXITCODE
```

Pass: every named probe reports OK, the JSON contains `"healthy":true`, and the
exit code is `0`.

Failure: exit code `3` names the failed probe. Exit code `10` means no real
probe was configured. Process name by itself is not enough for an outbound
processor because several instances use the same executable name.

## Test 9: Test the deployment engine

**Script:** `Deploy-Processor.ps1`  
**Safety:** SAFE in the automated suite; READ-ONLY with `-WhatIf`; DEPLOYMENT
without `-WhatIf`

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Deploy-Processor.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

The suite uses temporary folders and checks:

- gate, copy, verification, and health in order;
- `-WhatIf` leaves the target untouched;
- a missing staged configuration blocks before the copy;
- a running console process blocks unless the explicit kill option is set; and
- killed test processes are recorded in the audit log.

### UAT gate-only check

This is the only beginner-safe way to call the deployment engine against a real
environment. `-WhatIf` runs the gate and stops before backup, process/task
changes, copy, verification, or health.

Have the release owner fill in this block. The guard stops on every placeholder:

```powershell
$DeployValues = [ordered]@{
    Processor = 'REPLACE_WITH_PROCESSOR'
    StagedRoot = 'REPLACE_WITH_UAT_STAGED_FOLDER'
    TargetRoot = 'REPLACE_WITH_UAT_TARGET_FOLDER'
    StagedCommit = 'REPLACE_WITH_APPROVED_RELEASE_ID'
    ManifestPath = 'D:\baselines\REPLACE.json'
    TrustParam = '/ves/REPLACE/baseline-hash'
    ApprovedCommitParam = '/ves/REPLACE/approved-commit'
    ReleaseTag = 'REPLACE_WITH_PROCESSOR/v0.0.0'
    BaselineRepo = 'REPLACE_WITH_BASELINE_REPOSITORY'
    ConfigContract = 'D:\baselines\REPLACE.config.json'
    ConfigPath = 'REPLACE_WITH_TARGET_CONFIG_PATH'
    RequiredArtifactPath = 'REPLACE_WITH_STAGED_CONFIG_FILE_NAME'
    Region = 'REPLACE_WITH_CONFIRMED_REGION'
}

$Unfinished = @(
    $DeployValues.GetEnumerator() |
        Where-Object { [string]::IsNullOrWhiteSpace("$($_.Value)") -or $_.Value -match 'REPLACE' }
)
if ($Unfinished.Count -gt 0) {
    $Unfinished | Format-Table Name,Value -AutoSize
    throw 'Stop: the release owner must replace and approve every listed value.'
}
if ($DeployValues.ReleaseTag -notmatch '(^|/)v\d+\.\d+\.\d+$') {
    throw 'Stop: ReleaseTag must end in /vMAJOR.MINOR.PATCH.'
}
foreach ($PathToCheck in @(
    $DeployValues.StagedRoot
    $DeployValues.TargetRoot
    $DeployValues.ManifestPath
    $DeployValues.BaselineRepo
    $DeployValues.ConfigContract
    $DeployValues.ConfigPath
)) {
    if (-not (Test-Path -LiteralPath $PathToCheck)) {
        throw "Stop: required path not found: $PathToCheck"
    }
}

$TargetRoot = $DeployValues.TargetRoot
$before = Get-ChildItem -LiteralPath $TargetRoot -File -Recurse |
    Get-FileHash -Algorithm SHA256 |
    Sort-Object Path |
    Select-Object Path,Hash

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Deploy-Processor.ps1 `
    -Processor $DeployValues.Processor `
    -StagedRoot $DeployValues.StagedRoot `
    -TargetRoot $DeployValues.TargetRoot `
    -StagedCommit $DeployValues.StagedCommit `
    -ManifestPath $DeployValues.ManifestPath `
    -TrustParam $DeployValues.TrustParam `
    -ApprovedCommitParam $DeployValues.ApprovedCommitParam `
    -ReleaseTag $DeployValues.ReleaseTag `
    -BaselineRepo $DeployValues.BaselineRepo `
    -ConfigContract $DeployValues.ConfigContract `
    -ConfigPath $DeployValues.ConfigPath `
    -RequiredArtifactPaths $DeployValues.RequiredArtifactPath `
    -Environment uat `
    -Region $DeployValues.Region `
    -LogFile (Join-Path $EvidenceRoot 'deploy-whatif-uat.jsonl') `
    -WhatIf
$LASTEXITCODE
```

Pass:

- The gate passes.
- The log contains `WhatIf: skipping stop/backup/copy, gate only`.
- The exit code is `0`.

Confirm that the target did not change:

```powershell
$after = Get-ChildItem -LiteralPath $TargetRoot -File -Recurse |
    Get-FileHash -Algorithm SHA256 |
    Sort-Object Path |
    Select-Object Path,Hash

Compare-Object $before $after -Property Path,Hash
```

Pass: `Compare-Object` displays nothing.

Do not remove `-WhatIf` as a beginner test. A real UAT deployment must have a
change ticket, a verified backup/rollback plan, an approved configuration-file
decision, confirmed task/process details, and the application owner present.

## Test 10: Check the processor template

**Script:** `processors\Deploy-SYSTEM_NAME.ps1`  
**Safety:** SAFE for inspection; do not execute the template

This file is a template, not a real deployment script.
Confirm the repository still identifies it as a template:

```powershell
$TemplatePath = '.\processors\Deploy-SYSTEM_NAME.ps1'
Test-Path -LiteralPath $TemplatePath
Select-String -LiteralPath $TemplatePath -Pattern 'TEMPLATE|SYSTEM_NAME' |
    Select-Object LineNumber,Line
```

Expected result: `True` and several matching lines. Those placeholders are
correct in the template. Never supply staged or target values to this file and
never try to make the template itself deployable.


1. Run the syntax check at the start of this guide.
2. Open the file in a text editor.
3. Confirm it is still clearly marked `TEMPLATE`.
4. When onboarding a processor, copy it to a new, clearly named wrapper.
5. Replace every `SYSTEM_NAME`.
6. Confirm the target path, SSM paths, backup path, task or service, exact
   process mode, log folder, assemblies, environment, and region against the
   runbook.
7. Search the new wrapper for anything left unfinished:

```powershell
$NewWrapper = '.\processors\Deploy-REPLACE.ps1'
if ($NewWrapper -match 'REPLACE') {
    throw 'Stop: replace the filename with the approved new wrapper name.'
}
if (-not (Test-Path -LiteralPath $NewWrapper)) {
    throw "Stop: wrapper not found: $NewWrapper"
}
$PlaceholderResults = @(
    Select-String -LiteralPath $NewWrapper `
        -Pattern 'SYSTEM_NAME|REPLACE|TBD|CONFIRM'
)
if ($PlaceholderResults.Count -gt 0) {
    $PlaceholderResults | Select-Object LineNumber,Line
    throw 'Stop: unresolved placeholders remain in the wrapper.'
}
'WRAPPER PLACEHOLDER CHECK PASS'
```

Pass: the completed wrapper has no placeholder results, and a second person has
checked every fixed value.

After that review, test the new wrapper with `-WhatIf` only. Its shared
deployment behavior is covered by `Deploy-Processor.Tests.ps1`.

## Test 11: Check the UAT DBQ wrapper

**Script:** `processors\Deploy-OutboundDBQ-uat.ps1`  
**Safety:** SAFE for the refusal check; READ-ONLY with an approved `-WhatIf`;
DEPLOYMENT without `-WhatIf`

### Confirm the safety lock

Run this without `-ConfirmedRunbookValues`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\processors\Deploy-OutboundDBQ-uat.ps1 `
    -StagedRoot 'C:\NotUsedForThisRefusalCheck' `
    -StagedCommit 'TEST-ONLY'
$LASTEXITCODE
```

Pass: it refuses to continue and displays a message telling the operator to
confirm the scheduled-task name and fresh-log directory.

### UAT gate-only acceptance

Do not perform this step until two people have confirmed the values marked
`CONFIRM` in the script and the correct SSM region.

```powershell
$DbqValues = [ordered]@{
    StagedRoot = 'REPLACE_WITH_UAT_STAGED_FOLDER'
    StagedCommit = 'REPLACE_WITH_APPROVED_RELEASE_ID'
    ReleaseTag = 'OutboundDBQ/v0.0.0'
    BaselineRepo = 'REPLACE_WITH_BASELINE_REPOSITORY'
    Region = 'REPLACE_WITH_CONFIRMED_REGION'
}

$Unfinished = @(
    $DbqValues.GetEnumerator() |
        Where-Object { [string]::IsNullOrWhiteSpace("$($_.Value)") -or $_.Value -match 'REPLACE' }
)
if ($Unfinished.Count -gt 0) {
    $Unfinished | Format-Table Name,Value -AutoSize
    throw 'Stop: the release owner must replace and approve every listed value.'
}
if ($DbqValues.ReleaseTag -notmatch '^OutboundDBQ/v\d+\.\d+\.\d+$') {
    throw 'Stop: ReleaseTag must be OutboundDBQ/vMAJOR.MINOR.PATCH.'
}
foreach ($PathToCheck in @($DbqValues.StagedRoot,$DbqValues.BaselineRepo)) {
    if (-not (Test-Path -LiteralPath $PathToCheck)) {
        throw "Stop: required path not found: $PathToCheck"
    }
}

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\processors\Deploy-OutboundDBQ-uat.ps1 `
    -StagedRoot $DbqValues.StagedRoot `
    -StagedCommit $DbqValues.StagedCommit `
    -ReleaseTag $DbqValues.ReleaseTag `
    -BaselineRepo $DbqValues.BaselineRepo `
    -Region $DbqValues.Region `
    -AuditLogDir $EvidenceRoot `
    -ConfirmedRunbookValues `
    -WhatIf
$LASTEXITCODE
```

Pass: the pre-deploy gate passes, the log says the copy was skipped, and the
exit code is `0`.

Do not remove `-WhatIf` until the change owner has completed the real UAT pilot
checklist in the deployment-engine section.

## Test 12: Test the drift runner

**Script:** `Start-DriftRunner.ps1`  
**Safety:** SAFE in the automated suite; READ-ONLY for a real inventory, apart
from its own logs and heartbeat

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Start-DriftRunner.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

The suite checks clean and drift outcomes, incomplete-inventory refusal,
heartbeat writing, and safe pruning of only the runner's own old target logs.

### Confirm the current inventory fails closed

Run this on a development workstation without production Datadog credentials:

```powershell
$DriftTestLog = Join-Path $EvidenceRoot 'drift-lab'

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Start-DriftRunner.ps1 `
    -TargetsFile .\targets.json `
    -LogDir $DriftTestLog `
    -LogRetentionDays 0
$LASTEXITCODE
```

Pass for the current starter inventory:

- The output/log says the inventory is incomplete or invalid.
- The exit code is `2`.
- `$DriftTestLog\ves-verify-drift.heartbeat.json` exists.
- The heartbeat records an error instead of claiming a clean run.

Once Operations supplies a fully confirmed inventory, the same command should
return `0` when every target matches, `1` for drift, or `2` when a target cannot
be trusted or checked.

## Test 13: Test the heartbeat watchdog

**Script:** `Test-DriftHeartbeat.ps1`  
**Safety:** SAFE in the automated suite; READ-ONLY when checking a real
heartbeat

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Test-DriftHeartbeat.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

### Check the heartbeat made in Test 12

```powershell
$Heartbeat = Join-Path $DriftTestLog 'ves-verify-drift.heartbeat.json'

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Test-DriftHeartbeat.ps1 `
    -HeartbeatPath $Heartbeat `
    -MaxAgeMinutes 15 `
    -Environment dev `
    -Json `
    -LogFile (Join-Path $DriftTestLog 'watchdog.jsonl')
$LASTEXITCODE
```

Pass: the JSON contains `"fresh":true` and the watchdog exit code is `0`.

Fresh means the runner completed recently. It does **not** mean the runner found
everything clean. Read the last runner outcome as a separate check:

```powershell
Get-Content -LiteralPath $Heartbeat -Raw |
    ConvertFrom-Json |
    Format-List completedUtc,outcome,exitCode,targetCount,driftCount,trustFailCount,errorCount
```

With the current incomplete inventory, the heartbeat can be fresh while its
recorded runner outcome is `ERROR` with exit code `2`. That is expected.

## Test 14: Test scheduled drift-task installation

**Script:** `Install-DriftTask.ps1`  
**Safety:** SAFE in the automated suite; CHANGES TEST HOST for the integration
check

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Install-DriftTask.Tests.ps1
$LASTEXITCODE
```

Pass: `Failed: 0` and exit code `0`.

This suite mocks Task Scheduler. It checks runner/watchdog registration,
uninstallation, interval validation, missing-inventory warnings, and default or
explicit heartbeat age without registering a real task or requiring
Administrator rights.

### DEV/UAT Task Scheduler integration check

The remaining steps exercise the real Windows Task Scheduler integration. Run
them only on an approved DEV/UAT host in **Windows PowerShell as
Administrator**. Use unique test task names so the real drift tasks are not
replaced.

### Install two test tasks

```powershell
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
if (-not $IsAdmin) {
    throw 'Stop: reopen Windows PowerShell by using Run as administrator.'
}

$TaskSuffix = [guid]::NewGuid().ToString('N').Substring(0,8)
$TestRunnerTask = "ves-verify-drift-GUIDE-$TaskSuffix"
$TestWatchdogTask = "ves-verify-drift-watchdog-GUIDE-$TaskSuffix"
$TestTargets = (Resolve-Path .\targets.json).Path
$TestTaskLog = "C:\Temp\ves-verify-guide-task-logs-$TaskSuffix"

$ExistingTasks = @(
    Get-ScheduledTask -TaskName $TestRunnerTask,$TestWatchdogTask `
        -ErrorAction SilentlyContinue
)
if ($ExistingTasks.Count -gt 0) {
    $ExistingTasks | Select-Object TaskName,State
    throw 'Stop: one of the unique test task names already exists.'
}

powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Install-DriftTask.ps1 `
    -TargetsFile $TestTargets `
    -IntervalMinutes 30 `
    -TaskName $TestRunnerTask `
    -WatchdogTaskName $TestWatchdogTask `
    -LogDir $TestTaskLog `
    -Environment uat
$LASTEXITCODE
```

Pass:

- The script reports that both tasks were registered.
- The exit code is `0`.
- Both tasks appear here:

```powershell
Get-ScheduledTask -TaskName $TestRunnerTask,$TestWatchdogTask |
    Select-Object TaskName,State
```

### Start and inspect the test runner

```powershell
Start-ScheduledTask -TaskName $TestRunnerTask
$Deadline = (Get-Date).AddMinutes(2)
do {
    Start-Sleep -Seconds 5
    $TaskState = (Get-ScheduledTask -TaskName $TestRunnerTask).State
    "Task state: $TaskState"
} while ($TaskState -eq 'Running' -and (Get-Date) -lt $Deadline)

if ($TaskState -eq 'Running') {
    Write-Warning 'The test task is still running after two minutes. Record this and continue to cleanup.'
}

$TaskInfo = Get-ScheduledTaskInfo -TaskName $TestRunnerTask
$TaskInfo | Select-Object LastRunTime,LastTaskResult

$TaskHeartbeat = Join-Path $TestTaskLog 'ves-verify-drift.heartbeat.json'
if (Test-Path -LiteralPath $TaskHeartbeat) {
    Get-Content -LiteralPath $TaskHeartbeat -Raw
} else {
    Write-Warning "Heartbeat not found: $TaskHeartbeat"
}

$TaskEvidence = Join-Path $EvidenceRoot "scheduled-task-$TaskSuffix"
New-Item -ItemType Directory -Path $TaskEvidence -Force | Out-Null
if (Test-Path -LiteralPath $TestTaskLog) {
    Get-ChildItem -LiteralPath $TestTaskLog -File |
        Copy-Item -Destination $TaskEvidence -Force
}
```

With the current incomplete `targets.json`, `LastTaskResult` should settle on
`2`, and the heartbeat should record an error. With a separately approved,
complete test inventory, the clean result is `0`.

### Remove the test tasks

Cleanup is part of this test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Install-DriftTask.ps1 `
    -TaskName $TestRunnerTask `
    -WatchdogTaskName $TestWatchdogTask `
    -Uninstall
$LASTEXITCODE
```

Pass:

- The script reports that both test tasks were removed.
- The exit code is `0`.
- This command returns no tasks:

```powershell
Get-ScheduledTask -TaskName $TestRunnerTask,$TestWatchdogTask `
    -ErrorAction SilentlyContinue
```

Never use the production task names for this installation/removal test.

## Supporting test scripts

The files under `tests\` are not run as production scripts. `Invoke-Tests.ps1`
loads them through Pester.

| Test file | What it checks |
|---|---|
| `tests\_helpers.ps1` | Shared temporary-folder and child-process helpers. Do not run it by itself. |
| `tests\Deploy-Processor.Tests.ps1` | Deployment order, gate-only mode, required configuration, and running-process safety. |
| `tests\Install-DriftTask.Tests.ps1` | Mocked runner/watchdog registration, uninstallation, interval rules, and heartbeat-age arguments. |
| `tests\Invoke-HealthCheck.Tests.ps1` | Fresh/stale logs, assemblies, missing probes, and exact process paths. |
| `tests\Invoke-PreDeployGate.Tests.ps1` | Commit/content gates, SSM errors, required paths, and Git-tag baselines. |
| `tests\Invoke-Preflight.Tests.ps1` | Usage, manifests, contracts, stale patterns, inventory, and SSM failure reporting. |
| `tests\Invoke-Verification.Tests.ps1` | Capture, verify, drift, tamper detection, Git archive/tag, and config mode. |
| `tests\Start-DriftRunner.Tests.ps1` | Clean/drift exits, inventory refusal, retention, and heartbeat writing. |
| `tests\Test-DriftHeartbeat.Tests.ps1` | Fresh, stale, and missing heartbeats. |
| `tests\Verify-Config.Tests.ps1` | All three formats, required/extra/wrong settings, and secret masking. |
| `tests\VesVerify.Module.Tests.ps1` | Shared manifest, trust, inventory, logging, AWS, and Datadog functions. |

The full-suite command in Test 2 is the simplest way to test all of them.

## What to record

Keep one row for every test:

| Date/time | Tester | Computer | Script/test | Environment | Exit code | Pass or fail | Audit log or evidence |
|---|---|---|---|---|---:|---|---|
|  |  |  |  |  |  |  |  |

For a failure, attach:

- the exact command with secrets removed;
- the exit code;
- the complete named error;
- the JSONL audit log;
- whether the test was local, DEV, UAT, or PROD; and
- confirmation that no real deployment was attempted.

Do not copy SSM values, passwords, tokens, connection strings, or other secrets
into the test record.

## Finish the test session and package the evidence

1. List the files that were created:

```powershell
Get-ChildItem -LiteralPath $EvidenceRoot -Recurse |
    Select-Object FullName,Length,LastWriteTime
```

2. Save the final repository status without changing it:

```powershell
$FinalRepositoryStatus = @(git status --short)
$FinalRepositoryStatus |
    Set-Content -LiteralPath (Join-Path $EvidenceRoot 'git-status-final.txt')
$FinalRepositoryStatus
```

Unexpected new or changed script files must be reviewed. Do not use `git reset`,
`git checkout`, or deletion to make the result look clean.

3. Restore the audit-log environment variable for this PowerShell window:

```powershell
$env:VES_AUDIT_LOG_DIR = $PreviousAuditLogDir
```

4. Attach the evidence folder to the approved test record. Keep it until the
   release owner accepts the result. The local verification, health, and drift
   lab folders are inside it, so no separate cleanup is needed on the
   workstation.
5. If the scheduled-task integration test was run, confirm both unique test
   tasks are gone and the copied task evidence exists before the administrator
   removes the temporary `C:\Temp\ves-verify-guide-task-logs-<suffix>` folder.

## Final acceptance checklist

A script set is ready for a controlled UAT pilot only when:

- the canonical syntax check reports no errors;
- the full Pester suite reports zero failures;
- the relevant targeted test reports zero failures;
- the safe hands-on example behaves as described;
- the server, path, scheduled-task/service, region, and release values have
  been checked against the current runbook;
- the inventory is complete for the intended full-inventory or drift test;
- the audit log has a start and end record with the expected exit code; and
- any host changes made for testing have been removed.

A passing workstation test does not authorize a production deployment.

## Gaps and issues to expect during initial testing

This section is intentionally last so the tester reviews it immediately before
requesting a UAT pilot. A green workstation suite does not close these items.

### Known repository and operational gaps

| Gap or unresolved decision | Effect on testing | Required action before relying on the result |
|---|---|---|
| `targets.json` is intentionally incomplete and has `inventoryComplete=false`. Citrix server names and several production paths are missing. | Full inventory preflight and drift runs must return exit code `2`; they cannot prove estate-wide coverage. | Operations must add every manual-copy server and processor, mark each entry confirmed, and set completeness only after independent review. |
| Processor coverage is incomplete. The repository has a template and one UAT DBQ wrapper, not a confirmed wrapper for every in-scope system/server copy. | Shared code can pass while an actual system still has no safe operator entry point. | Create and review one wrapper per confirmed processor/server combination, then run syntax, targeted Pester, placeholder, and `-WhatIf` checks. |
| `Deploy-OutboundDBQ-uat.ps1` still marks the scheduled-task name and fresh-log directory `CONFIRM`. | `-ConfirmedRunbookValues` would be an unsupported assertion until those values are checked. | Two people must compare both values with the current Outbound Deployment Steps runbook. |
| GovCloud examples disagree: defaults use `us-gov-west-1`, while OMS conventions in the documentation may require `us-gov-east-1`. | SSM checks can report missing or denied parameters even when credentials are otherwise valid. | The AWS owner must confirm the parameter path and region as a pair for each environment. |
| `Deploy-Processor.ps1` uses `robocopy /MIR`. A configuration file under the target root is replaced by the staged copy. | A technically successful copy could place the wrong server-specific configuration on the host. | Before any real deployment, approve either config exclusion or a staged per-server config and prove rollback. |
| Console-process stop/restart logic exists, but the real outbound-processor UAT pilot is still pending. | Automated tests prove the mechanism with test processes, not the actual RTP/RTPDP workload. | Pilot on the approved UAT egress server with the application owner watching process identity, task restart, logs, and rollback. |
| Real SSM read/write and KMS behavior is not exercised by the normal automated suite. | Fake AWS commands prove error handling but not the live account, role, parameter, encryption, network, or region. | Run the read-only preflight first; allow capture/write testing only under an approved UAT release procedure. |
| Service, real scheduled-task, and HTTP health branches are not fully automated against live hosts. | The workstation suite cannot prove a particular service name, task history, endpoint, firewall, or application response. | Run the matching read-only health probe on DEV/UAT with confirmed values. |
| `Install-DriftTask.Tests.ps1` mocks Task Scheduler. | Unit coverage cannot prove SYSTEM permissions, legacy-host trigger serialization, task history, or monitor pickup. | Complete the unique-name administrator integration test on an approved DEV/UAT host and remove the tasks afterward. |
| Central audit-log destination, Datadog agent/API key, monitor, and on-call routing remain operations-owned. | Primary exit codes and JSONL logs work, but alerts may not reach a dashboard or person. | Confirm `VES_AUDIT_LOG_DIR`, log shipping, agent/API key, monitors, and routing before production activation. |
| Break-glass policy is not finalized. The gate supports audited `-AllowOverride`, but `Deploy-Processor.ps1` does not pass it through. | Operators may not know whether a failed gate is an absolute block or who can authorize an exception. | Change governance must decide the policy; testers must not use `-AllowOverride` or `-AllowCommitOnly` to obtain a pass. |
| `Verify-Config.ps1` returns a `.pass` object rather than enforcing the repository exit-code contract by itself. | A tester who looks only at `$LASTEXITCODE` after calling the helper can misclassify drift. | Use `.pass` for the direct helper test and `Invoke-Verification.ps1 -Mode VerifyConfig` for operational exit codes. |
| PSScriptAnalyzer is optional and may not be installed on the workstation. | Parser and Pester can pass without a lint result. | Report `LINT NOT RUN` when unavailable; never report an unavailable lint check as passed. |
| Continuous-integration execution is not confirmed in this repository. | The test suite may depend on a person running it before a release. | Add an approved Windows PowerShell 5.1 CI job or retain a signed manual test record for every change. |
| Tagged rollback history starts with the first captured and archived verified release. | Older deployments may not have a trustworthy Git-tagged rollback point. | The release owner must identify a safe manual baseline for pre-adoption releases. |

### Common first-run issues and what the tester should do

| What the tester sees | Likely meaning | Correct response |
|---|---|---|
| `Pester 5.x not found` | No supported Pester module is available. | Stop. Obtain approval to install Pester 5.5 or newer on the development workstation, then rerun Test 2. |
| `Requested registry access is not allowed` before tests start | The restricted test environment blocked Pester setup. | Rerun in an approved normal Windows PowerShell session. Do not classify it as a script defect unless it repeats there. |
| `script is not digitally signed`, `RemoteSigned`, or `Zone.Identifier` errors | Host policy blocked downloaded files. | Do not weaken policy. Ask for an approved unblocked repository copy. |
| `aws` is not recognized | AWS CLI is missing or not on `PATH`. | Local tests may continue; live SSM tests must stop until the workstation owner installs/configures the approved CLI. |
| `AccessDenied`, KMS decrypt error, `ParameterNotFound`, or SSM trust failure | Wrong role, path, region, encryption permission, or baseline hash. | Record the full named error without secret values and send it to the AWS and release owners. Do not try random regions or parameters. |
| Current inventory preflight or drift run exits `2` | Expected fail-closed behavior while `targets.json` is incomplete. | Record as an expected safety result. It becomes a defect only if the incomplete inventory reports ready/clean. |
| Gate exits `1` and names missing, changed, or extra files | The staged artifact does not match the approved release. | Stop. Give the named file list to the release owner; do not use an override. |
| Gate exits `10` with no content source | Commit-only validation was refused. | Supply the approved trust parameter or tagged baseline. Do not add `-AllowCommitOnly` for acceptance. |
| Health check exits `3` | At least one configured probe failed. | Record the exact assembly, service, process, task, log, or endpoint failure and stop the deployment decision. |
| Health check exits `10` | No meaningful probe was configured or input was unsafe. | Obtain the exact probe values from the server/application owner. |
| `-WhatIf` gate passes but an audit log or Datadog event appears | Expected: gate-only mode avoids target changes but still records evidence. | Verify the before/after hashes are identical and retain the log. |
| Drift heartbeat is fresh but its stored runner outcome is `ERROR`/`2` | The runner completed recently but could not verify the inventory or trust. | Treat freshness and verification outcome as separate results; investigate the runner error. |
| Scheduled task `LastTaskResult` is `2` with the checked-in inventory | Expected because the inventory is incomplete. | Confirm the heartbeat records the same error, save evidence, then remove the unique test tasks. |
| Scheduled task remains `Running` past two minutes | The runner may be blocked, hung, or waiting on a host dependency. | Record task state/history and logs, then have the Windows administrator stop and remove only the unique test tasks. |
| Audit log cannot be created | Folder is missing or the account/SYSTEM identity lacks permission. | Stop and have the owner provide an approved writable test/audit directory. |
| PSScriptAnalyzer is unavailable | Lint was not executed. | Record `LINT NOT RUN`; parser and Pester results remain separate. |
| `git status --short` lists unexpected files after testing | A test, tool, or another user changed the checkout. | Preserve the output and ask the maintainer to review. Do not delete, reset, or hide the files. |

### Minimum escalation packet for an unresolved failure

Send the maintainer or owning team all of the following:

- test number and script name;
- date/time, tester, computer, and environment;
- sanitized command with all secrets removed;
- immediate `$LASTEXITCODE`;
- complete named error and relevant console output;
- JSONL audit-log path and the log itself;
- Git commit and release tag used;
- whether the action was SAFE, READ-ONLY, CHANGES TEST HOST, or DEPLOYMENT;
- before/after hash comparison for a `-WhatIf` deployment check; and
- confirmation that no unauthorized deployment or policy change was attempted.

Do not request a production pilot until every blocking gap that applies to the
selected system has an owner, an approved resolution, and recorded evidence.
