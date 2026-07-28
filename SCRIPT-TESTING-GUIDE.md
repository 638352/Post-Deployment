# Post-Deployment Script Testing Guide

This guide is for somebody who can open Windows PowerShell and copy a command,
but does not need to understand the code. It explains what to test, where it is
safe to test it, and what a good result looks like.

Last reviewed: 27 July 2026

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
```

Keep this PowerShell window open while following the guide.

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
    -LogFile (Join-Path $env:TEMP 'ves-guide-config.jsonl')

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
    -LogFile (Join-Path $env:TEMP 'ves-guide-verification-config.jsonl')
$LASTEXITCODE
```

Pass:

- The JSON output contains `"status":"match"`.
- The exit code is `0`.

### Hands-on local capture and file comparison

The two `Allow` switches below are permitted only because this is a temporary
local lab. Never use them to approve a real release.

```powershell
$LabRoot = Join-Path $env:TEMP (
    'ves-guide-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
)
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
    -LogFile (Join-Path $env:TEMP 'ves-guide-preflight.jsonl')
$LASTEXITCODE
```

Pass:

- The summary says `Preflight READY`.
- The JSON contains `"ready":true`.
- The exit code is `0`.

### Current inventory check

Run this only on a workstation approved to perform read-only AWS checks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Preflight.ps1 `
    -TargetsFile .\targets.json `
    -Region 'REPLACE_WITH_CONFIRMED_REGION' `
    -Json
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
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-PreDeployGate.ps1 `
    -StagedRoot 'REPLACE_WITH_UAT_STAGED_FOLDER' `
    -StagedCommit 'REPLACE_WITH_APPROVED_RELEASE_ID' `
    -ApprovedCommitParam '/ves/REPLACE/approved-commit' `
    -TrustParam '/ves/REPLACE/baseline-hash' `
    -ManifestPath 'D:\baselines\REPLACE.json' `
    -RequiredArtifactPaths 'REPLACE_WITH_CONFIG_FILE_NAME' `
    -Processor 'REPLACE_WITH_PROCESSOR' `
    -Environment uat `
    -Region 'REPLACE_WITH_CONFIRMED_REGION'
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
$HealthTestDir = Join-Path $env:TEMP (
    'ves-health-guide-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
)
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
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-HealthCheck.ps1 `
    -Processor 'REPLACE_WITH_PROCESSOR' `
    -ProcessPathRoot 'REPLACE_WITH_EXACT_PROCESSOR_FOLDER' `
    -ProcessArgumentPattern 'REPLACE_WITH_RTP_OR_RTPDP_PATTERN' `
    -ScheduledTasks 'REPLACE_WITH_EXACT_TASK_NAME' `
    -FreshLogDir 'REPLACE_WITH_EXACT_LOG_FOLDER' `
    -FreshLogMaxAgeMinutes 60 `
    -Environment uat `
    -Json
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

First take a read-only fingerprint of the UAT target:

```powershell
$TargetRoot = 'REPLACE_WITH_UAT_TARGET_FOLDER'
$before = Get-ChildItem -LiteralPath $TargetRoot -File -Recurse |
    Get-FileHash -Algorithm SHA256 |
    Sort-Object Path |
    Select-Object Path,Hash
```

Then run the gate-only check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Deploy-Processor.ps1 `
    -Processor 'REPLACE_WITH_PROCESSOR' `
    -StagedRoot 'REPLACE_WITH_UAT_STAGED_FOLDER' `
    -TargetRoot $TargetRoot `
    -StagedCommit 'REPLACE_WITH_APPROVED_RELEASE_ID' `
    -ManifestPath 'D:\baselines\REPLACE.json' `
    -TrustParam '/ves/REPLACE/baseline-hash' `
    -ApprovedCommitParam '/ves/REPLACE/approved-commit' `
    -ConfigContract 'D:\baselines\REPLACE.config.json' `
    -ConfigPath 'REPLACE_WITH_TARGET_CONFIG_PATH' `
    -RequiredArtifactPaths 'REPLACE_WITH_CONFIG_FILE_NAME' `
    -Environment uat `
    -Region 'REPLACE_WITH_CONFIRMED_REGION' `
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
Select-String -Path .\processors\Deploy-REPLACE.ps1 `
    -Pattern 'SYSTEM_NAME|REPLACE|TBD|CONFIRM'
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
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\processors\Deploy-OutboundDBQ-uat.ps1 `
    -StagedRoot 'D:\stage\OutboundDBQ' `
    -StagedCommit 'REPLACE_WITH_APPROVED_RELEASE_ID' `
    -ReleaseTag 'OutboundDBQ/vREPLACE_WITH_VERSION' `
    -BaselineRepo 'REPLACE_WITH_BASELINE_REPOSITORY' `
    -Region 'REPLACE_WITH_CONFIRMED_REGION' `
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
$DriftTestLog = Join-Path $env:TEMP (
    'ves-drift-guide-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
)

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
$TestRunnerTask = 'ves-verify-drift-GUIDE-TEST'
$TestWatchdogTask = 'ves-verify-drift-watchdog-GUIDE-TEST'
$TestTargets = (Resolve-Path .\targets.json).Path
$TestTaskLog = 'C:\Temp\ves-verify-guide-task-logs'

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
```

Wait for the task to finish, then enter:

```powershell
Get-ScheduledTaskInfo -TaskName $TestRunnerTask |
    Select-Object LastRunTime,LastTaskResult

Get-Content -LiteralPath (
    Join-Path $TestTaskLog 'ves-verify-drift.heartbeat.json'
) -Raw
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
