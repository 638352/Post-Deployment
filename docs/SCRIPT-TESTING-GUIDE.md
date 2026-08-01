# Post-Deployment Script Testing Guide

**Who this is for:** Anyone who can open Windows PowerShell and paste a command.
You do not need to understand the code. This guide tells you exactly what to
type, what a good result looks like, and what to do when something goes wrong.

**Last reviewed:** 27 July 2026

---

## Table of Contents

1. [Before You Start — Prerequisite Checklist](#before-you-start--prerequisite-checklist)
2. [One-Time Workstation Setup](#one-time-workstation-setup)
3. [How to Read Results](#how-to-read-results)
4. [Safety Labels Used in This Guide](#safety-labels-used-in-this-guide)
5. [Current Stop Signs](#current-stop-signs)
6. [Test Coverage at a Glance](#test-coverage-at-a-glance)
7. [Test 1 — Syntax Check (All Scripts)](#test-1--syntax-check-all-scripts)
8. [Test 2 — Full Automated Suite](#test-2--full-automated-suite)
9. [Test 3 — Shared Module](#test-3--shared-module)
10. [Test 4 — Configuration Checking](#test-4--configuration-checking)
11. [Test 5 — Capture and File Verification](#test-5--capture-and-file-verification)
12. [Test 6 — Preflight Check](#test-6--preflight-check)
13. [Test 7 — Pre-Deployment Gate](#test-7--pre-deployment-gate)
14. [Test 8 — Health Checking](#test-8--health-checking)
15. [Test 9 — Deployment Engine](#test-9--deployment-engine)
16. [Test 10 — Processor Template](#test-10--processor-template)
17. [Test 11 — UAT DBQ Processor Wrapper](#test-11--uat-dbq-processor-wrapper)
18. [Test 12 — Drift Runner](#test-12--drift-runner)
19. [Test 13 — Heartbeat Watchdog](#test-13--heartbeat-watchdog)
20. [Test 14 — Scheduled Task Installation](#test-14--scheduled-task-installation)
21. [What to Record](#what-to-record)
22. [Final Acceptance Checklist](#final-acceptance-checklist)
23. [Known Gaps, Issues, and Blockers](#known-gaps-issues-and-blockers)

---

## Before You Start — Prerequisite Checklist

Go through every item below **before** running any commands. If any item is not
checked, stop and contact the maintainer.

| # | Requirement | How to confirm |
|---|---|---|
| 1 | You are on a **development workstation**, not a production server. | Look at the computer name in the window title bar. |
| 2 | You have **Windows PowerShell 5.1** available. | See Setup Step 1 below. |
| 3 | The **live repository** is at `C:\Users\howardr01\Post-Deployment`. | Run `Test-Path 'C:\Users\howardr01\Post-Deployment'` — must return `True`. |
| 4 | **Pester 5.x** is installed on the workstation. | See Setup Step 3 below. |
| 5 | You have read the [Current Stop Signs](#current-stop-signs) section. | Read it now before continuing. |
| 6 | You know the SAFE / READ-ONLY / DEPLOYMENT difference. | Read the [Safety Labels](#safety-labels-used-in-this-guide) section. |

> **IMPORTANT:** Always begin with the syntax check (Test 1) and the full
> automated suite (Test 2) on a workstation. A workstation pass is required
> before doing anything against DEV, UAT, or PROD.

---

## One-Time Workstation Setup

Complete these three steps once per workstation before running any test.

### Step 1 — Open the correct PowerShell

Open the **Start Menu** and search for **Windows PowerShell**. Click the result
labeled "Windows PowerShell" (not "PowerShell 7" and not "PowerShell ISE").

In the window that opens, type this and press Enter:

```powershell
$PSVersionTable.PSVersion
```

You should see output like this:

```
Major  Minor  Build  Revision
-----  -----  -----  --------
5      1      19041  4648
```

The first number must be **5** and the second must be **1**.

> **If the numbers are different** (for example `7` and `4`), you are in the
> wrong PowerShell. Close that window and find "Windows PowerShell" from the
> Start Menu again. Do not continue with the wrong version.

### Step 2 — Move to the live repository folder

In the same PowerShell window, paste and press Enter:

```powershell
Set-Location 'C:\Users\howardr01\Post-Deployment'
```

Your prompt should change to show `C:\Users\howardr01\Post-Deployment>`.
**Keep this window open for the rest of the guide.** Every command assumes you
are in this folder.

> **If you see an error** that says the path does not exist, stop and contact
> the maintainer. The repository may not be cloned on this machine.

### Step 3 — Confirm Pester is available

Paste and press Enter:

```powershell
Get-Module -ListAvailable Pester |
    Sort-Object Version -Descending |
    Select-Object -First 1 Name,Version
```

You should see output like this:

```
Name   Version
----   -------
Pester 5.6.1
```

The version number must start with **5**.

> **If nothing is displayed**, Pester is not installed. Ask the workstation
> owner to approve this one-time installation, then run:
>
> ```powershell
> Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
> ```
>
> After it finishes, run the version check again to confirm.
> **Do not install modules on a production server.**

---

## How to Read Results

### Checking the exit code

After every command in this guide, type this and press Enter:

```powershell
$LASTEXITCODE
```

PowerShell prints a number. Use this table:

| Exit code | What it means |
|---:|---|
| `0` | **Passed.** Everything looks good. |
| `1` | **Files or settings differ.** Something changed compared to the baseline. |
| `2` | **Baseline, trust, inventory, AWS, or runtime problem.** The script could not complete reliably. |
| `3` | **Health check failed.** A process, service, or log check did not pass. |
| `10` | **Missing input or unsafe configuration.** A required value was not provided. |

> A red error message in the output is **not** the same as a failed exit code.
> Always record the exit code, not just whether the output looks alarming.

### JSONL audit logs

Most scripts write a `.jsonl` log file when a `-LogFile` path is supplied (or
when the `VES_AUDIT_LOG_DIR` environment variable is set). Each line is one JSON
entry. Open the file in Notepad to review it. Look for a line containing
`"outcome"` or `"status"` to find the final result. A complete run contains a
`RUN START` line and a `RUN END` line.

---

## Safety Labels Used in This Guide

Every test carries one of these labels. Read them carefully before running any
command.

| Label | What it means |
|---|---|
| **SAFE** | Uses only test files on your workstation. No server, no AWS, no network connection needed. Safe to run at any time. |
| **READ-ONLY** | Reads files, AWS parameters, services, tasks, or logs on a real server or AWS. Does not copy or change files, but may write an audit log or send a Datadog metric. Run only on an approved DEV or UAT host. |
| **CHANGES TEST HOST** | Adds or removes scheduled tasks on the test machine. Run only on an approved DEV/UAT host with Administrator rights. |
| **DEPLOYMENT** | Can stop a running process, copy files, and restart a task or service. A **change owner** must control this test. Never run on PROD without a change ticket, backup plan, and the application owner present. |

---

## Current Stop Signs

These are known, expected conditions in the repository right now. They are not
defects unless stated otherwise. They are intentional safety holds until
Operations provides the missing information.

| # | Stop sign | Effect on testing |
|---|---|---|
| 1 | `targets.json` has `"inventoryComplete": false` | Drift runs and inventory preflight checks always return exit code `2`. This is expected and correct behavior. It is a **defect** if this file ever reports ready today. |
| 2 | `processors\Deploy-OutboundDBQ-uat.ps1` has two `# CONFIRM` placeholders | The scheduled-task name and log-folder path must be confirmed from the Outbound Deployment Steps runbook before `-ConfirmedRunbookValues` can be passed. |
| 3 | The AWS SSM region is not confirmed | The GovCloud region may be `us-gov-east-1` or `us-gov-west-1`. Do not guess. Confirm with the team before running any live AWS check. |
| 4 | Configuration-file handling decision is pending | `Deploy-Processor.ps1` mirrors the entire staged folder, which can overwrite a per-server config file. The team must decide whether to exclude config files or stage the correct per-server version before any real PROD deployment. |
| 5 | Citrix server list is incomplete | Citrix server names and processor paths are not in the repository. The inventory cannot be complete until Operations supplies them. |
| 6 | PROD processor paths are not documented | Pull PROD paths from the Outbound Deployment Steps runbook for each server before writing or running any PROD wrapper. |

---

## Test Coverage at a Glance

| Test | Script | Automated Pester suite | Hands-on check | Highest safety level |
|---|---|---|---|---|
| 1 | All `.ps1` / `.psm1` files | No (syntax parser) | Syntax check block | **SAFE** |
| 2 | `Invoke-Tests.ps1` | Runs all suites | Full-suite pass/fail | **SAFE** |
| 3 | `module\VesVerify.psm1` | `VesVerify.Module.Tests.ps1` | Run via Test 2 | **SAFE** |
| 4 | `Verify-Config.ps1` | `Verify-Config.Tests.ps1` | Fixture config check | **SAFE** |
| 5 | `Invoke-Verification.ps1` | `Invoke-Verification.Tests.ps1` | Local capture and compare | **SAFE** |
| 6 | `Invoke-Preflight.ps1` | `Invoke-Preflight.Tests.ps1` | Contract check + inventory | **READ-ONLY** |
| 7 | `Invoke-PreDeployGate.ps1` | `Invoke-PreDeployGate.Tests.ps1` | UAT gate acceptance | **READ-ONLY** |
| 8 | `Invoke-HealthCheck.ps1` | `Invoke-HealthCheck.Tests.ps1` | Local log check + UAT | **READ-ONLY** |
| 9 | `Deploy-Processor.ps1` | `Deploy-Processor.Tests.ps1` | UAT gate-only (`-WhatIf`) | **DEPLOYMENT** without `-WhatIf` |
| 10 | `processors\Deploy-SYSTEM_NAME.ps1` | Shared engine coverage | Placeholder inspection | **SAFE** |
| 11 | `processors\Deploy-OutboundDBQ-uat.ps1` | Shared engine coverage | Safety-lock + gate-only | **DEPLOYMENT** without `-WhatIf` |
| 12 | `Start-DriftRunner.ps1` | `Start-DriftRunner.Tests.ps1` | Fail-closed local run | **READ-ONLY** |
| 13 | `Test-DriftHeartbeat.ps1` | `Test-DriftHeartbeat.Tests.ps1` | Read heartbeat from Test 12 | **READ-ONLY** |
| 14 | `Install-DriftTask.ps1` | `Install-DriftTask.Tests.ps1` | Real task install on DEV/UAT | **CHANGES TEST HOST** |

---

## Test 1 — Syntax Check (All Scripts)

**What it does:** Reads every tracked PowerShell file and checks that each has
valid syntax. Nothing is executed.

**Safety:** SAFE

**Expected time:** Under 30 seconds.

### Steps

1. Confirm you are in the repository folder.
2. Paste the entire block below into your PowerShell window and press Enter:

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

**Pass:** The last line begins with `SYNTAX PASS:` and lists a count of files.
No file names, line numbers, or problem descriptions appear.

**Fail:** One or more rows appear with a file name, line number, and problem.
Stop and send the exact table to the maintainer.

### Optional style linter

PSScriptAnalyzer finds additional style and compatibility issues. Run it after
the syntax check:

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

If the module is not installed, record `LINT NOT RUN`. That is not a failure.
Do not install it on a production server.

---

## Test 2 — Full Automated Suite

**Script:** `Invoke-Tests.ps1`
**Safety:** SAFE

**What it does:** Runs every Pester test in the `tests\` folder. This is the
most important single test. Run it before any hands-on check.

**Expected time:** 1–3 minutes.

### Steps

1. Confirm you are in the repository folder.
2. Paste and press Enter:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

3. Wait for the Pester summary at the bottom of the output.

**Pass:**

- The Pester summary says `Failed: 0`.
- The exit code is `0`.

**Fail:** One or more tests are listed as failed. Stop and send the full output
to the maintainer before running any hands-on tests.

> **Troubleshooting**
>
> | Message | What to do |
> |---|---|
> | `Pester 5.x not found` | Complete Setup Step 3 to install Pester, then try again. |
> | `Requested registry access is not allowed` | Open a normal (non-restricted) Windows PowerShell window and try again. Do not report this as a script defect unless it also fails in a normal window. |
> | `File ... is not digitally signed` | Do not lower the machine's execution policy. Ask the maintainer for an approved unblocked copy of the script. |

---

## Test 3 — Shared Module

**Script:** `module\VesVerify.psm1`
**Safety:** SAFE

**What it does:** The module is a shared library used by all other scripts.
Do not run the `.psm1` file directly — always test it through its Pester suite.

### Steps

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\VesVerify.Module.Tests.ps1
$LASTEXITCODE
```

**Pass:** Pester reports `Failed: 0` and the exit code is `0`.

This suite checks manifest creation, hashing, tamper detection, file
comparison, target inventory rules, logging, release-tag validation, AWS
command error handling, and Datadog environment labels.

---

## Test 4 — Configuration Checking

**Script:** `Verify-Config.ps1`
**Safety:** SAFE when using the bundled test fixtures

**What it does:** Checks that a configuration file matches a contract — a list
of required keys and expected values.

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Verify-Config.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

### Hands-on check with the bundled test files

```powershell
$configResult = & .\Verify-Config.ps1 `
    -ContractPath .\tests\fixtures\json\contract.json `
    -ConfigPath .\tests\fixtures\json\config.json `
    -LogFile (Join-Path $env:TEMP 'ves-guide-config.jsonl')

$configResult | Format-List
```

**Pass:**

- `pass` is `True`.
- `missingRequired`, `valueMismatch`, and `extraKeys` are all empty.

> `Verify-Config.ps1` returns a result object, not a standard exit code.
> To get a standard exit code from a config check, use
> `Invoke-Verification.ps1 -Mode VerifyConfig` (Test 5 below).

---

## Test 5 — Capture and File Verification

**Script:** `Invoke-Verification.ps1`
**Safety:** SAFE for the automated tests and the local example

**What it does:**

- **Capture** — scans a release folder and records a baseline (file hashes).
- **VerifyFiles** — compares a folder against the baseline to detect drift.
- **VerifyConfig** — checks a config file against a contract.

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-Verification.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

### Hands-on: configuration check

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

**Pass:** The JSON output contains `"status":"match"` and the exit code is `0`.

### Hands-on: local capture then file comparison

The two `-Allow` switches below are permitted only in this isolated local test.
**Never use them for a real release.**

**Step 1 — Create a temporary test folder and capture a baseline:**

```powershell
$LabRoot = Join-Path $env:TEMP (
    'ves-guide-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
)
$LabRelease  = Join-Path $LabRoot 'release'
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

**Pass:** The JSON status is `captured`, the manifest file exists at
`$LabManifest`, and the exit code is `0`.

**Step 2 — Verify the unchanged folder matches the baseline:**

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

**Pass:** The JSON status is `match` and the exit code is `0`. A warning about
no trust parameter is expected in this local-only check.

The automated suite also proves that a changed, missing, or extra file returns
exit code `1`, and that a corrupt or untrusted manifest returns exit code `2`.

---

## Test 6 — Preflight Check

**Script:** `Invoke-Preflight.ps1`
**Safety:** SAFE for the contract example; READ-ONLY for AWS or inventory checks

**What it does:** Reads SSM parameters and the baseline manifest to confirm that
everything needed for a deployment is in place. Run this before deploying.

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-Preflight.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

### Safe local contract check (no server or AWS needed)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Preflight.ps1 `
    -Processor GuideTest `
    -ConfigContract .\sample.config.json `
    -Json `
    -LogFile (Join-Path $env:TEMP 'ves-guide-preflight.jsonl')
$LASTEXITCODE
```

**Pass:**

- The summary says `Preflight READY`.
- The JSON contains `"ready":true`.
- The exit code is `0`.

### READ-ONLY: inventory check against the current targets file

> Run this only on a workstation approved for read-only AWS checks. Requires
> the AWS CLI installed and GovCloud credentials configured. Confirm the region
> first — see Current Stop Signs item 3.

Replace `REPLACE_WITH_CONFIRMED_REGION` with the correct region before running:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Preflight.ps1 `
    -TargetsFile .\targets.json `
    -Region 'REPLACE_WITH_CONFIRMED_REGION' `
    -Json
$LASTEXITCODE
```

**Expected result today:** Exit code `2` and `NOT READY`. This is because
`targets.json` is intentionally incomplete. It is a **defect** if this returns
ready.

---

## Test 7 — Pre-Deployment Gate

**Script:** `Invoke-PreDeployGate.ps1`
**Safety:** SAFE in the automated suite; READ-ONLY against UAT

**What it does:** Checks that staged release files match the approved baseline
before allowing a deployment to proceed. Reads from AWS SSM and the manifest;
does not copy any files.

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-PreDeployGate.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

The suite checks: a passing artifact, a wrong commit, missing or changed files,
missing required configuration, unreadable SSM data, tag-based baselines, and
the rule that a commit string alone is not enough.

### READ-ONLY: UAT acceptance check

> A change owner must provide all values. Replace every `REPLACE_WITH_...`
> placeholder before running.

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

**Pass:** The output contains both `Commit gate PASS` and `Content gate PASS`,
and the exit code is `0`.

> **Do not use `-AllowCommitOnly` or `-AllowOverride`** during a normal
> acceptance test. These are controlled exceptions, not a shortcut.

---

## Test 8 — Health Checking

**Script:** `Invoke-HealthCheck.ps1`
**Safety:** SAFE for the fresh-log example; READ-ONLY against UAT

**What it does:** Confirms a processor is healthy — log file updated recently,
correct process running with the correct arguments, required assemblies loadable,
and (for Java services) the health endpoint responds.

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-HealthCheck.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

### Safe local fresh-log check (no server needed)

**Step 1 — Create a test log:**

```powershell
$HealthTestDir = Join-Path $env:TEMP (
    'ves-health-guide-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
)
New-Item -ItemType Directory -Path $HealthTestDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $HealthTestDir 'processor.log') `
    -Value 'test heartbeat'
```

**Step 2 — Run the health check:**

```powershell
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

**Pass:** The JSON contains `"healthy":true` and the exit code is `0`.

### READ-ONLY: UAT processor check

> Use the exact folder path and mode argument from the current runbook.
> Replace every placeholder. Do not guess any value.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-HealthCheck.ps1 `
    -Processor 'REPLACE_WITH_PROCESSOR' `
    -ProcessPathRoot 'REPLACE_WITH_EXACT_PROCESSOR_FOLDER' `
    -ProcessArgumentPattern 'REPLACE_WITH_RTP_OR_RTPDP' `
    -ScheduledTasks 'REPLACE_WITH_EXACT_TASK_NAME' `
    -FreshLogDir 'REPLACE_WITH_EXACT_LOG_FOLDER' `
    -FreshLogMaxAgeMinutes 60 `
    -Environment uat `
    -Json
$LASTEXITCODE
```

**Pass:** Every named probe reports OK, the JSON contains `"healthy":true`,
and the exit code is `0`.

**Exit code `3`:** The output names the specific probe that failed.

**Exit code `10`:** No real probe was configured. Check your placeholder values.

> **Important:** Do not rely on process name alone. Several processor instances
> share the same executable name. Always supply `-ProcessPathRoot` and
> `-ProcessArgumentPattern` from the runbook.

---

## Test 9 — Deployment Engine

**Script:** `Deploy-Processor.ps1`
**Safety:** SAFE in the automated suite; READ-ONLY with `-WhatIf`; DEPLOYMENT without `-WhatIf`

**What it does:** Full deployment sequence — gate check, stop the running
process, back up current files, copy new files, verify the result, and run a
health check. Every step is audited.

> **Never run this without `-WhatIf` unless you are a change owner with a
> change ticket, a verified backup plan, and the application owner present.**

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Deploy-Processor.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

The suite checks: gate → copy → verify → health in order; `-WhatIf` leaves the
target untouched; a missing staged config blocks before copy; a running process
blocks unless the kill option is set; killed processes are logged.

### READ-ONLY: UAT gate-only check (using `-WhatIf`)

This is the only beginner-safe way to call the deployment engine against a real
environment. `-WhatIf` runs the gate and stops before backup, process or task
changes, copy, verification, or health.

**Step 1 — Fingerprint the UAT target before touching it:**

```powershell
$TargetRoot = 'REPLACE_WITH_UAT_TARGET_FOLDER'
$before = Get-ChildItem -LiteralPath $TargetRoot -File -Recurse |
    Get-FileHash -Algorithm SHA256 |
    Sort-Object Path |
    Select-Object Path,Hash
```

**Step 2 — Run the gate-only check (replace all placeholders):**

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

**Pass:**

- The gate passes.
- The log contains `WhatIf: skipping stop/backup/copy, gate only`.
- The exit code is `0`.

**Step 3 — Confirm nothing changed on the target:**

```powershell
$after = Get-ChildItem -LiteralPath $TargetRoot -File -Recurse |
    Get-FileHash -Algorithm SHA256 |
    Sort-Object Path |
    Select-Object Path,Hash

Compare-Object $before $after -Property Path,Hash
```

**Pass:** `Compare-Object` displays nothing (no output = no differences).

---

## Test 10 — Processor Template

**Script:** `processors\Deploy-SYSTEM_NAME.ps1`
**Safety:** SAFE for inspection; do not execute the template file

**What it does:** This is a template, not a real deployment script. Copy it
when onboarding a new processor.

### Steps

1. Run the syntax check (Test 1) to confirm the template has valid syntax.

2. Open the file in Notepad to inspect it:

```powershell
notepad .\processors\Deploy-SYSTEM_NAME.ps1
```

3. Confirm it is still clearly labeled **TEMPLATE** at the top.

4. When onboarding a new processor, copy the template to a new file:

```powershell
Copy-Item .\processors\Deploy-SYSTEM_NAME.ps1 `
    .\processors\Deploy-PROCESSOR_NAME_HERE.ps1
```

5. Open the new file and replace every `SYSTEM_NAME` with the real name.

6. Confirm every fixed value against the runbook — target path, SSM paths,
   backup path, scheduled task or service name, process mode, log folder,
   assemblies, environment, and region.

7. Search the completed wrapper for any remaining placeholders:

```powershell
Select-String -Path .\processors\Deploy-PROCESSOR_NAME_HERE.ps1 `
    -Pattern 'SYSTEM_NAME|REPLACE|TBD|CONFIRM'
```

**Pass:** No results appear. Have a second person confirm every hard-coded value.

8. Test the new wrapper with `-WhatIf` only before a real run.

---

## Test 11 — UAT DBQ Processor Wrapper

**Script:** `processors\Deploy-OutboundDBQ-uat.ps1`
**Safety:** SAFE for the refusal check; READ-ONLY with `-WhatIf`; DEPLOYMENT without `-WhatIf`

**What it does:** A thin wrapper for the DBQ outbound processor on UAT server
`VESMSEGRESSUAT`. Deploys `VES.OutboundDBQProcessor.exe` under
`C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` using the `RTPDP` mode
argument. Has a built-in safety lock that refuses to run until two values are
confirmed from the runbook.

### Check 1 — Confirm the safety lock (SAFE)

Run this command. Do **not** include `-ConfirmedRunbookValues`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\processors\Deploy-OutboundDBQ-uat.ps1 `
    -StagedRoot 'C:\NotUsedForThisRefusalCheck' `
    -StagedCommit 'TEST-ONLY'
$LASTEXITCODE
```

**Pass:** The script refuses to continue and prints a message about confirming
the scheduled-task name and log directory. The exit code is non-zero.

**Fail:** If the script continues past this point without `-ConfirmedRunbookValues`,
report it to the maintainer immediately.

### Check 2 — UAT gate-only acceptance (READ-ONLY, with `-WhatIf`)

> Do **not** run this step until two people have confirmed the two `# CONFIRM`
> values from the Outbound Deployment Steps runbook AND the correct SSM region
> has been confirmed. Replace every `REPLACE_WITH_...` placeholder.

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

**Pass:** The pre-deploy gate passes, the log says the copy was skipped, and
the exit code is `0`.

Do not remove `-WhatIf` until the change owner has completed the pilot checklist
in Test 9 and the configuration-file decision has been resolved.

---

## Test 12 — Drift Runner

**Script:** `Start-DriftRunner.ps1`
**Safety:** SAFE in the automated suite; READ-ONLY for a real inventory

**What it does:** Runs a full verification pass against every target in
`targets.json`, writes a per-target JSONL log, and records a heartbeat file.
Intended to run on a schedule via Task Scheduler (Test 14).

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Start-DriftRunner.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

The suite checks: clean and drift outcomes, incomplete-inventory refusal,
heartbeat writing, and safe pruning of old target logs.

### Safe local run — confirm the inventory fails closed

Run on a development workstation without production Datadog credentials:

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

**Pass for the current starter inventory:**

- The output or log says the inventory is incomplete or invalid.
- The exit code is `2`.
- A heartbeat file exists at `$DriftTestLog\ves-verify-drift.heartbeat.json`.
- The heartbeat records an error, not a clean run.

Once Operations confirms a complete inventory, the same command should return
`0` when all targets match, `1` for drift, or `2` when a target cannot be
checked.

---

## Test 13 — Heartbeat Watchdog

**Script:** `Test-DriftHeartbeat.ps1`
**Safety:** SAFE in the automated suite; READ-ONLY when reading a real heartbeat

**What it does:** Reads the heartbeat file written by the drift runner and
confirms it was updated recently. Raises an alert if the runner has missed its
schedule.

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Test-DriftHeartbeat.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

### Check the heartbeat written in Test 12

Run this in the **same PowerShell window** that ran Test 12 (it reuses
`$DriftTestLog`):

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

**Pass:** The JSON contains `"fresh":true` and the exit code is `0`.

> **Important:** Fresh means the runner completed recently. It does **not** mean
> the runner found everything clean. Read the last runner outcome separately:

```powershell
Get-Content -LiteralPath $Heartbeat -Raw |
    ConvertFrom-Json |
    Format-List completedUtc,outcome,exitCode,targetCount,driftCount,trustFailCount,errorCount
```

With the current incomplete inventory, the heartbeat can be fresh while the
recorded runner outcome is `ERROR` with exit code `2`. That is expected today.

---

## Test 14 — Scheduled Task Installation

**Script:** `Install-DriftTask.ps1`
**Safety:** SAFE in the automated suite; CHANGES TEST HOST for the integration check

**What it does:** Registers two Windows scheduled tasks — the drift runner task
and an independent heartbeat watchdog task. Requires Administrator rights.

### Automated check

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Invoke-Tests.ps1 `
    -Path .\tests\Install-DriftTask.Tests.ps1
$LASTEXITCODE
```

**Pass:** `Failed: 0` and exit code `0`.

This suite uses mocked Task Scheduler. It checks runner and watchdog
registration, uninstallation, interval validation, missing-inventory warnings,
and heartbeat-age arguments without registering a real task.

### DEV/UAT Task Scheduler integration check — CHANGES TEST HOST

> Run these steps only on an approved DEV or UAT host, in a **Windows
> PowerShell window opened as Administrator** (right-click → "Run as
> administrator"). Use the test task names below — do not use the real
> production task names.

**Step 1 — Set test names and paths:**

```powershell
$TestRunnerTask   = 'ves-verify-drift-GUIDE-TEST'
$TestWatchdogTask = 'ves-verify-drift-watchdog-GUIDE-TEST'
$TestTargets      = (Resolve-Path .\targets.json).Path
$TestTaskLog      = 'C:\Temp\ves-verify-guide-task-logs'
```

**Step 2 — Register both test tasks:**

```powershell
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

**Pass:**

- The script reports both tasks were registered.
- The exit code is `0`.
- Both tasks appear when you run:

```powershell
Get-ScheduledTask -TaskName $TestRunnerTask,$TestWatchdogTask |
    Select-Object TaskName,State
```

**Step 3 — Start and inspect the test runner task:**

```powershell
Start-ScheduledTask -TaskName $TestRunnerTask
```

Wait a moment, then check:

```powershell
Get-ScheduledTaskInfo -TaskName $TestRunnerTask |
    Select-Object LastRunTime,LastTaskResult

Get-Content -LiteralPath (
    Join-Path $TestTaskLog 'ves-verify-drift.heartbeat.json'
) -Raw
```

With the current incomplete `targets.json`, `LastTaskResult` should be `2` and
the heartbeat should record an error. With a separately approved, confirmed test
inventory, the clean result is `0`.

**Step 4 — Remove both test tasks (required cleanup):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Install-DriftTask.ps1 `
    -TaskName $TestRunnerTask `
    -WatchdogTaskName $TestWatchdogTask `
    -Uninstall
$LASTEXITCODE
```

**Pass:**

- The script reports both tasks were removed.
- The exit code is `0`.
- This command returns no output (no output = no tasks remain):

```powershell
Get-ScheduledTask -TaskName $TestRunnerTask,$TestWatchdogTask `
    -ErrorAction SilentlyContinue
```

> **Never use the production task names** (`ves-verify-drift` /
> `ves-verify-drift-watchdog`) for this test.

---

## Supporting Test Files

The files under `tests\` are not production scripts. They are loaded by Pester
through `Invoke-Tests.ps1`.

| Test file | What it checks |
|---|---|
| `tests\_helpers.ps1` | Shared helpers. Do not run it directly. |
| `tests\Deploy-Processor.Tests.ps1` | Deployment order, gate-only mode, required config, running-process safety. |
| `tests\Install-DriftTask.Tests.ps1` | Mocked task registration, uninstallation, interval rules, heartbeat-age arguments. |
| `tests\Invoke-HealthCheck.Tests.ps1` | Fresh/stale logs, assemblies, missing probes, exact process paths. |
| `tests\Invoke-PreDeployGate.Tests.ps1` | Commit/content gates, SSM errors, required paths, Git-tag baselines. |
| `tests\Invoke-Preflight.Tests.ps1` | Usage, manifests, contracts, stale patterns, inventory, SSM failure reporting. |
| `tests\Invoke-Verification.Tests.ps1` | Capture, verify, drift, tamper detection, Git archive/tag, config mode. |
| `tests\Start-DriftRunner.Tests.ps1` | Clean/drift exits, inventory refusal, retention, heartbeat writing. |
| `tests\Test-DriftHeartbeat.Tests.ps1` | Fresh, stale, and missing heartbeats. |
| `tests\Verify-Config.Tests.ps1` | All three config formats, required/extra/wrong settings, secret masking. |
| `tests\VesVerify.Module.Tests.ps1` | Manifest, trust, inventory, logging, AWS, and Datadog shared functions. |

The full-suite command in Test 2 is the simplest way to run all of them at once.

---

## What to Record

Keep one row for every test you run:

| Date/time | Tester | Computer | Script / test | Environment | Exit code | Pass or fail | Evidence |
|---|---|---|---|---|---:|---|---|
|  |  |  |  |  |  |  |  |

For any failure, record:

- The exact command you ran with all secrets removed.
- The exit code.
- The complete named error message from the output.
- The JSONL audit log contents if one was written.
- Whether the test ran locally, on DEV, on UAT, or on PROD.
- Confirmation that no real deployment was attempted.

> **Do not copy SSM values, passwords, tokens, connection strings, or other
> secrets into the test record.**

---

## Final Acceptance Checklist

A script set is ready for a controlled UAT pilot only when **all** of these
boxes can be checked:

- [ ] The syntax check reports no errors.
- [ ] The full Pester suite (`Invoke-Tests.ps1`) reports zero failures.
- [ ] The relevant targeted Pester test reports zero failures.
- [ ] The safe hands-on example in this guide behaved as described.
- [ ] Server name, folder paths, scheduled-task or service name, SSM region,
      and release values have been confirmed against the current runbook.
- [ ] The inventory in `targets.json` is complete for the intended test.
- [ ] The audit log has a `RUN START` and a `RUN END` record with the expected
      exit code.
- [ ] Any test scheduled tasks created during testing have been removed.

A passing workstation test does **not** authorize a production deployment.

---

## Known Gaps, Issues, and Blockers

This section documents every known condition that will cause a test to fail or
behave unexpectedly. These are **not** defects in the scripts unless stated.
They are conditions that must be resolved before end-to-end testing is possible.

---

### Gap 1 — `targets.json` is intentionally incomplete; drift checks always fail closed

**Symptom:** `Start-DriftRunner.ps1` and `Invoke-Preflight.ps1 -TargetsFile`
always return exit code `2` and print `NOT READY` or `inventory incomplete`.

**Why:** `targets.json` has `"inventoryComplete": false`. The Citrix server list
and several PROD paths are missing. The file was deliberately checked in this
way to prevent a false "all clear."

**Required to unblock:**

- Operations must supply all Citrix server names and processor paths.
- Confirmed entries for every PROD server must be added to `targets.json` with
  `"inventoryStatus": "confirmed"`.
- `"inventoryComplete"` must be set to `true` only after all required servers
  are confirmed.

---

### Gap 2 — `Deploy-OutboundDBQ-uat.ps1` has two unresolved `# CONFIRM` values

**Symptom:** Running the script without `-ConfirmedRunbookValues` always exits
immediately with an error. This is correct and intentional behavior.

**Why:** Two values in the script are marked `# CONFIRM` and have not yet been
verified from the Outbound Deployment Steps runbook:

- The scheduled task name (`VLER_EM_Realtime_DBQ_Processor` — needs confirmation)
- The fresh-log directory (`C:\VLER_TEST_OUTBOUND\Logs\VES.OutboundProcessor` — needs confirmation)

**Required to unblock:** A team member must look up both values in the runbook,
update the script, and have a second person confirm them before
`-ConfirmedRunbookValues` may be used.

---

### Gap 3 — The AWS SSM region is not confirmed

**Symptom:** Any test that reads from AWS SSM will fail with an access or
parameter-not-found error if the wrong region is used. The current default in
scripts is `us-gov-west-1`.

**Why:** The GovCloud account may use `us-gov-east-1` or `us-gov-west-1`. The
correct region for the OMS SSM parameters has not been confirmed.

**Required to unblock:** Confirm the region with the team or check the AWS
console. Pass the confirmed value via `-Region` when running any live AWS check.

---

### Gap 4 — Configuration file handling decision is pending

**Symptom:** `Deploy-Processor.ps1` copies everything in the staged folder into
the target, which will overwrite the live per-server configuration file.

**Why this is a problem:** The live configuration file on each server may
contain different connection strings, endpoint URLs, or certificate thumbprints.
Overwriting it with a generic staged file could break the processor.

**Required to unblock:** The team must decide one of the following:

- Exclude configuration files from the staged folder so they are not copied, or
- Stage the correct per-server configuration file for each target server.

**Do not run a real PROD deployment until this decision is made and
implemented.**

---

### Gap 5 — Citrix server list is not in the repository

**Symptom:** Any inventory check fails closed. Citrix server entries are absent
from `targets.json`.

**Required to unblock:** Operations must supply all Citrix server names and
their processor folder paths, scheduled task names, and configuration file
paths.

---

### Gap 6 — PROD processor paths are not documented in the repository

**Symptom:** There are no ready-to-run PROD wrapper scripts in `processors\`
for `VESEMSEGRESS01`, `VESEMSEGRESS02`, `VESEMSEGRESS03`, `VESEMSINGRESS01`, or
`VESEMSINGRESS02`.

**Required to unblock:** Pull the exact processor folder paths, scheduled task
names, configuration file paths, and backup root paths from the Outbound
Deployment Steps runbook for each PROD server before writing any PROD wrapper.

---

### Gap 7 — AWS CLI must be installed and authenticated for live checks

**Symptom:** Tests 6, 7, 8, 9, and 11 that contact real SSM parameters fail
with `'aws' is not recognized` or an authentication error.

**Required to unblock:**

1. Confirm the AWS CLI is installed:

   ```powershell
   aws --version
   ```

2. Confirm GovCloud credentials are configured:

   ```powershell
   aws sts get-caller-identity --region us-gov-east-1
   ```

3. The role must have `ssm:GetParameter` and `kms:Decrypt` on the relevant SSM
   parameter paths.

---

### Gap 8 — Windows execution policy may block scripts on locked-down machines

**Symptom:** An error such as:

```
File ... cannot be loaded because running scripts is disabled on this system.
```

**Why:** The machine's execution policy does not allow unsigned scripts.

**What to do:** All commands in this guide use
`powershell.exe -ExecutionPolicy Bypass -File ...`, which bypasses the policy
for that subprocess only. If the error still appears, you may have run the
command without the full wrapper — use the exact commands in this guide.

Do **not** permanently lower the machine's execution policy. Ask the maintainer
for an approved unblocked copy of the script.

---

### Gap 9 — Administrator rights are required for Task Scheduler tests

**Symptom:** Test 14 (Install-DriftTask.ps1) fails with an access-denied error.

**What to do:** Open Windows PowerShell by right-clicking the Start Menu entry
and choosing "Run as administrator." Only the Task Scheduler integration steps
in Test 14 require this. Do not run the full guide as Administrator.

---

### Gap 10 — Datadog credentials are required for real metric signals

**Symptom:** Scripts run and exit cleanly but no metrics appear in Datadog.

**Why:** If the `DD_API_KEY` environment variable is not set to a valid key,
Datadog submissions are silently skipped. This does not affect the exit code
or the JSONL audit log.

**Required to unblock:** Confirm the correct Datadog API key with the monitoring
team and set it on the runner host before a production readiness test.

---

### Gap 11 — Network access to target servers required for real drift checks

**Symptom:** `Start-DriftRunner.ps1` with a confirmed `targets.json` fails with
path-not-found or access-denied errors when trying to read files from target
servers.

**Required to unblock:** Run the drift runner from a machine that has network
access (UNC path or WinRM) to the target servers. Confirm the correct path
format in each `targets.json` entry with the network team.

---

### Gap 12 — Git must be installed for the Test 1 syntax check

**Symptom:** The syntax check block in Test 1 throws
`Could not read the canonical file list from Git.`

**What to do:** Confirm Git is installed and in the PATH:

```powershell
git --version
```

If Git is not installed, ask the workstation owner to install it before
running Test 1.

---

*End of guide.*
