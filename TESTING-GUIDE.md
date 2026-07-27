# Script Testing Guide

This guide explains how to test the Post-Deployment PowerShell scripts. It has
two paths:

- The non-technical path runs the standard automated test suite and explains
  how to report the result.
- The technical path adds repository-wide syntax checks, targeted tests, safe
  local smoke tests, and controlled QA/UAT integration tests.

The scripts target Windows PowerShell 5.1. Run development tests on a
workstation, CI runner, or test VM, not on a production application server.

## Last verified

A point-in-time record of the last full local validation. It does not replace
running the layers yourself; re-verify for the commit you are testing.

| Item                  | Result                                              |
| --------------------- | --------------------------------------------------- |
| Commit                | `abec439`                                           |
| Windows PowerShell    | 5.1.26100.8894                                      |
| Pester                | 6.0.1                                               |
| Layer 1-2 parse       | 23 files, `PARSE_ERRORS=0`                          |
| Layer 3 full suite    | 100 passed, 0 failed, exit `0`                      |
| Layer 5 smoke tests   | all 10 steps returned their expected exit codes     |
| PSScriptAnalyzer      | not installed; static analysis not run              |

Live AWS, service, task, and deployment dependencies were not exercised. See
"Known limits of local automation".

## Safety levels

| Level             | Meaning                                      | Examples                                      |
| ----------------- | -------------------------------------------- | --------------------------------------------- |
| Read-only         | Reads repository files or local system state | Syntax check, preflight, health check         |
| Local-write       | Writes temporary files or test logs          | Pester suite, local baseline smoke test       |
| Environment-write | Changes shared or host-level state           | Baseline capture, scheduled-task installation |
| Deployment        | Stops workloads and changes deployed files   | A real deploy or processor-wrapper run        |

The commands below launch entry scripts through a child `powershell.exe`
process. Several scripts intentionally call `exit`; using a child process keeps
the tester's PowerShell window open and makes the result available in
`$LASTEXITCODE`.

## Before anyone starts

### 1. Open the correct shell

Open **Windows PowerShell**, not PowerShell 7. Check the version:

```powershell
$PSVersionTable.PSVersion
```

The result must show major version `5` and minor version `1`.

### 2. Go to the repository root

Replace the example path with the location of this repository:

```powershell
Set-Location 'C:\path\to\Post-Deployment'
Test-Path .\Invoke-Tests.ps1
```

Continue only if `Test-Path` returns `True`.

### 3. Record what is being tested

```powershell
git rev-parse --short HEAD
git status --short
```

Record the commit ID. If `git status --short` displays changes, record them and
confirm they belong in the test. Do not discard someone else's changes.

### 4. Keep secrets out of evidence

Do not paste credentials, connection strings, tokens, or SSM SecureString
values into a ticket. The scripts mask declared sensitive config values, but
the tester must still review captured output.

---

## Non-technical path: standard validation

Use this path to answer, "Did the repository's automated checks pass?" It does
not deploy software, contact real AWS SSM, or manage a real service or task.

### Step 1. Check for Pester

```powershell
Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1 Name, Version
```

If a Pester version is displayed, continue. Both Pester 5.x and 6.x are
supported; do not downgrade a working 6.x installation. If nothing is displayed,
ask a technical administrator to install it. If authorized, use the documented
one-time command:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

Installing a module changes the workstation and may require internet or
repository access. Follow local installation policy.

### Step 2. Run the complete test suite

```powershell
powershell.exe -NoProfile -File .\Invoke-Tests.ps1
$testExit = $LASTEXITCODE
"TEST_EXIT=$testExit"
```

Exception note: only add `-ExecutionPolicy Bypass` when your organization has
explicitly approved a temporary unsigned-script execution-policy exception for
this test host.

Wait for the final Pester summary.

### Step 3. Decide pass or fail

A pass requires both:

- The summary says `Failed: 0`.
- `TEST_EXIT=0`.

Do not use a fixed passing-test count; it may increase as coverage is added.
Treat the run as not passed if tests fail, the command ends before the summary,
Pester is missing, or permissions/setup prevent execution. `Invoke-Tests.ps1`
also returns `2` when compatible Pester is unavailable, so read the message.

### Step 4. Capture and report the result

```powershell
[PSCustomObject]@{
    TestedAt = (Get-Date).ToString('o')
    Computer = $env:COMPUTERNAME
    Commit   = (git rev-parse --short HEAD)
    TestExit = $testExit
} | Format-List
```

Include the commit, command, exit code, Pester summary, computer/timestamp, and
first failure or setup error in the ticket. If the suite does not pass, do not
approve a deployment from that checkout; send the evidence to a reviewer.

---

## Technical path: complete repository validation

Run these layers in order. A targeted check helps diagnose a problem, but it
does not replace the final full-suite run.

## Layer 1. Inventory every PowerShell file

This includes production scripts, the module, processor wrappers, and tests:

```powershell
$powerShellFiles = @(
    Get-ChildItem -LiteralPath . -Recurse -File |
        Where-Object { $_.Extension -in '.ps1', '.psm1' } |
        Sort-Object FullName
)

$powerShellFiles |
    ForEach-Object { $_.FullName.Substring((Get-Location).Path.Length + 1) }

"POWERSHELL_FILE_COUNT=$($powerShellFiles.Count)"
```

Review the list. A repository-wide result is incomplete if a wrapper, module,
or test script was silently omitted.

## Layer 2. Parse every file with Windows PowerShell 5.1

```powershell
$parseErrors = @()

foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )

    foreach ($error in @($errors)) {
        $parseErrors += ('{0}:{1}:{2}: {3}' -f
            $file.FullName,
            $error.Extent.StartLineNumber,
            $error.Extent.StartColumnNumber,
            $error.Message)
    }
}

if ($parseErrors.Count -eq 0) {
    'PARSE_ERRORS=0'
}
else {
    $parseErrors
    "PARSE_ERRORS=$($parseErrors.Count)"
}
```

Pass criterion: `PARSE_ERRORS=0`. A PowerShell 7-only parse is not the
compatibility decision; the production contract is Windows PowerShell 5.1.

## Layer 3. Run the full regression suite

```powershell
powershell.exe -NoProfile -File .\Invoke-Tests.ps1
$fullSuiteExit = $LASTEXITCODE
"FULL_SUITE_EXIT=$fullSuiteExit"
```

Pass criterion: `Failed: 0` and `FULL_SUITE_EXIT=0`.

The suite uses temporary folders and stubs external dependencies where needed.
It does not require live AWS, a real service, a real scheduled task, or network
access.

## Layer 4. Run targeted suites when diagnosing

Use the repository runner so Pester selection and temporary audit-log handling
remain consistent:

```powershell
powershell.exe -NoProfile -File .\Invoke-Tests.ps1 `
    -Path .\tests\Invoke-Verification.Tests.ps1
"TARGET_EXIT=$LASTEXITCODE"
```

Replace the path using this map:

| Script or behavior         | Targeted test file                     |
| -------------------------- | -------------------------------------- |
| `module\VesVerify.psm1`    | `tests\VesVerify.Module.Tests.ps1`     |
| `Invoke-Verification.ps1`  | `tests\Invoke-Verification.Tests.ps1`  |
| `Verify-Config.ps1`        | `tests\Verify-Config.Tests.ps1`        |
| `Invoke-Preflight.ps1`     | `tests\Invoke-Preflight.Tests.ps1`     |
| `Invoke-PreDeployGate.ps1` | `tests\Invoke-PreDeployGate.Tests.ps1` |
| `Invoke-HealthCheck.ps1`   | `tests\Invoke-HealthCheck.Tests.ps1`   |
| `Deploy-Processor.ps1`     | `tests\Deploy-Processor.Tests.ps1`     |
| `Start-DriftRunner.ps1`    | `tests\Start-DriftRunner.Tests.ps1`    |
| `Test-DriftHeartbeat.ps1`  | `tests\Test-DriftHeartbeat.Tests.ps1`  |

After investigating a targeted failure, rerun Layer 3.

## Layer 5. Run safe local smoke tests

These steps exercise real entry scripts against temporary local data. They do
not prove that AWS permissions, services, tasks, or deployment paths are right.

### Step 1. Create an isolated test area

```powershell
$smokeRoot = Join-Path $env:TEMP (
    'ves-smoke-{0}' -f [guid]::NewGuid().ToString('N')
)
$release = Join-Path $smokeRoot 'release'
$manifest = Join-Path $smokeRoot 'baseline.json'
$healthLogs = Join-Path $smokeRoot 'health-logs'
$runLogs = Join-Path $smokeRoot 'run-logs'

New-Item -ItemType Directory -Path $release, $healthLogs, $runLogs -Force |
    Out-Null
Set-Content -LiteralPath (Join-Path $release 'app.txt') `
    -Value 'approved-content' -NoNewline
```

### Step 2. Capture a local-only baseline

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-Verification.ps1 `
    -Mode Capture `
    -ReleaseRoot $release `
    -ManifestPath $manifest `
    -Processor smoke `
    -AllowUntrustedCapture `
    -AllowUnarchivedCapture `
    -Json

$captureExit = $LASTEXITCODE
"CAPTURE_EXIT=$captureExit"
```

Expected: `CAPTURE_EXIT=0`. The two `Allow...` switches are development
exceptions. Never use them for an approved release.

### Step 3. Verify an unchanged tree

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-Verification.ps1 `
    -Mode VerifyFiles `
    -ReleaseRoot $release `
    -ManifestPath $manifest `
    -Processor smoke `
    -Json

$matchExit = $LASTEXITCODE
"MATCH_EXIT=$matchExit"
```

Expected: `MATCH_EXIT=0`.

### Step 4. Prove that drift is detected

```powershell
Set-Content -LiteralPath (Join-Path $release 'app.txt') `
    -Value 'changed-content' -NoNewline

powershell.exe -NoProfile `
    -File .\Invoke-Verification.ps1 `
    -Mode VerifyFiles `
    -ReleaseRoot $release `
    -ManifestPath $manifest `
    -Processor smoke `
    -Json

$driftExit = $LASTEXITCODE
"DRIFT_EXIT=$driftExit"
```

Expected: `DRIFT_EXIT=1`, with `app.txt` identified as changed. Restore it:

```powershell
Set-Content -LiteralPath (Join-Path $release 'app.txt') `
    -Value 'approved-content' -NoNewline
```

### Step 5. Test config verification with repository fixtures

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-Verification.ps1 `
    -Mode VerifyConfig `
    -ConfigContract .\tests\fixtures\appconfig\contract.json `
    -ConfigPath .\tests\fixtures\appconfig\app.config `
    -Processor smoke `
    -Json

$configExit = $LASTEXITCODE
"CONFIG_EXIT=$configExit"
```

Expected: `CONFIG_EXIT=0`. `Verify-Config.ps1` returns an object with `.pass`;
the wrapper is used here because it also applies the exit-code contract.

### Step 6. Test a local preflight

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-Preflight.ps1 `
    -Processor smoke `
    -ManifestPath $manifest `
    -ConfigContract .\tests\fixtures\appconfig\contract.json `
    -Json

$preflightExit = $LASTEXITCODE
"PREFLIGHT_EXIT=$preflightExit"
```

Expected: `PREFLIGHT_EXIT=0`. This validates local manifest/contract structure,
not SSM authorization.

### Step 7. Test fresh-log health evidence

```powershell
Set-Content -LiteralPath (Join-Path $healthLogs 'processor.log') `
    -Value 'processor started'

powershell.exe -NoProfile `
    -File .\Invoke-HealthCheck.ps1 `
    -FreshLogDir $healthLogs `
    -FreshLogMaxAgeMinutes 5 `
    -Processor smoke `
    -Json

$healthExit = $LASTEXITCODE
"HEALTH_EXIT=$healthExit"
```

Expected: `HEALTH_EXIT=0`. Also prove a no-probe check fails closed:

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-HealthCheck.ps1 -Processor smoke -Json
"NO_PROBE_EXIT=$LASTEXITCODE"
```

Expected: `NO_PROBE_EXIT=10`.

### Step 8. Test the heartbeat watchdog

```powershell
$heartbeat = Join-Path $smokeRoot 'ves-verify-drift.heartbeat.json'

[PSCustomObject]@{
    schema       = 'ves.drift-heartbeat.v1'
    completedUtc = [DateTime]::UtcNow.ToString('o')
    outcome      = 'PASS'
    exitCode     = 0
} | ConvertTo-Json | Set-Content -LiteralPath $heartbeat -Encoding UTF8

powershell.exe -NoProfile `
    -File .\Test-DriftHeartbeat.ps1 `
    -HeartbeatPath $heartbeat `
    -MaxAgeMinutes 5 `
    -LogFile (Join-Path $runLogs 'watchdog.jsonl') `
    -Json
"WATCHDOG_EXIT=$LASTEXITCODE"
```

Expected: `WATCHDOG_EXIT=0`.

### Step 9. Prove the checked-in inventory fails closed

The checked-in `targets.json` is intentionally incomplete:

```powershell
powershell.exe -NoProfile `
    -File .\Start-DriftRunner.ps1 `
    -TargetsFile .\targets.json `
    -LogDir $runLogs `
    -HeartbeatPath (Join-Path $smokeRoot 'incomplete-inventory-heartbeat.json') `
    -LogRetentionDays 0
"INCOMPLETE_INVENTORY_EXIT=$LASTEXITCODE"
```

Expected: `INCOMPLETE_INVENTORY_EXIT=2`. This is a successful negative test.
Do not change `inventoryComplete` to `true` merely to make it green.

### Step 10. Remove the temporary test area

Display and review the path first:

```powershell
$smokeRoot
```

If it is the `ves-smoke-...` folder created under the temporary directory:

```powershell
Remove-Item -LiteralPath $smokeRoot -Recurse -Force
```

## Layer 6. Confirm every entry script was covered

| File                                    | Minimum check                                       | Live integration needed?                    |
| --------------------------------------- | --------------------------------------------------- | ------------------------------------------- |
| `Invoke-Tests.ps1`                      | Full suite reaches summary and returns failed count | No                                          |
| `module\VesVerify.psm1`                 | Module Pester suite                                 | Yes, for real AWS trust operations          |
| `Invoke-Verification.ps1`               | Pester plus local capture/match/drift/config        | Yes, for SSM pinning and Git archival       |
| `Verify-Config.ps1`                     | Config tests for all three formats                  | Yes, for SSM-backed values                  |
| `Invoke-Preflight.ps1`                  | Pester plus local manifest/contract check           | Yes, for AWS/KMS/path/region                |
| `Invoke-PreDeployGate.ps1`              | Gate Pester suite                                   | Yes, for real SSM parameters                |
| `Invoke-HealthCheck.ps1`                | Pester plus local fresh-log check                   | Yes, for host probes                        |
| `Deploy-Processor.ps1`                  | Deploy Pester suite, including `-WhatIf` and locks  | Yes, first in QA/UAT                        |
| `processors\Deploy-SYSTEM_NAME.ps1`     | Parse and manual placeholder review                 | Never execute; it is a template             |
| `processors\Deploy-OutboundDBQ-uat.ps1` | Parse and runbook review                            | Yes, UAT after guarded values are confirmed |
| `Start-DriftRunner.ps1`                 | Pester plus incomplete-inventory negative test      | Yes, with reviewed inventory                |
| `Test-DriftHeartbeat.ps1`               | Pester plus fresh-heartbeat check                   | Yes, after a real run                       |
| `Install-DriftTask.ps1`                 | Windows PowerShell 5.1 parse                        | Yes, on elevated test VM                    |

`Install-DriftTask.ps1` has no dedicated Pester test. Do not describe task
registration as validated until the controlled host test below is complete.

## Optional static analysis

PSScriptAnalyzer is separate and is not installed by the repository:

```powershell
Get-Module -ListAvailable PSScriptAnalyzer |
    Sort-Object Version -Descending |
    Select-Object -First 1 Name, Version
```

If installed, run `Invoke-ScriptAnalyzer -Path . -Recurse` and record findings
and version. Otherwise report: "PSScriptAnalyzer unavailable; static analysis
not run." Never report lint as passed when the tool did not run.

---

## Controlled QA/UAT integration testing

This section verifies dependencies that local tests stub or avoid. Use an
approved QA/UAT host and change record. Do not start in production.

## Integration prerequisites

Confirm and record:

- Processor, environment, server, and maintenance window.
- GovCloud region for the actual SSM parameter path.
- Staged root, target root, manifest, config contract, and config path.
- Baseline-hash and approved-commit SSM parameter names.
- Required artifact paths that hashing intentionally excludes.
- Service name or scheduled-task names.
- Exact executable folder and argument pattern when identical executable names
  run in multiple folders.
- Fresh-log directory, health URL, and expected response where applicable.
- Audit-log directory, backup root, retention, and rollback owner.

Repository examples use both a `us-gov-west-1` default and an
`us-gov-east-1` OMS convention. Confirm the parameter path and region together;
do not guess.

Set the approved audit-log destination for the session:

```powershell
$env:VES_AUDIT_LOG_DIR = 'D:\approved-test-log-location'
```

### Step 1. Validate trusted baseline inputs

Preflight is read-only apart from its log:

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-Preflight.ps1 `
    -Processor '<processor>' `
    -ApprovedCommitParam '/ves/<processor>/approved-commit' `
    -TrustParam '/ves/<processor>/baseline-hash' `
    -ManifestPath 'D:\baselines\<processor>.json' `
    -ConfigContract 'D:\baselines\<processor>.config.json' `
    -Region '<confirmed-region>' `
    -Json

$preflightExit = $LASTEXITCODE
"PREFLIGHT_EXIT=$preflightExit"
```

Expected: exit `0` and required checks ready. Exit `2` means not ready; do not
continue to deployment.

### Step 2. Validate staged content with the gate

This reads SSM and staged files and writes an audit log. It does not copy:

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-PreDeployGate.ps1 `
    -StagedRoot 'D:\stage\<processor>' `
    -StagedCommit '<approved-release-id>' `
    -ApprovedCommitParam '/ves/<processor>/approved-commit' `
    -TrustParam '/ves/<processor>/baseline-hash' `
    -ManifestPath 'D:\baselines\<processor>.json' `
    -RequiredArtifactPaths '<relative-config-path>' `
    -Processor '<processor>' `
    -Environment 'uat' `
    -Region '<confirmed-region>'

$gateExit = $LASTEXITCODE
"GATE_EXIT=$gateExit"
```

Expected: `GATE_EXIT=0`. Exit `1` is a deliberate block, `2` is a trust/SSM
error, and `10` is unsafe or incomplete usage.

Do not use `-AllowOverride` as a testing shortcut. It is an audited break-glass
path, and its production policy remains open.

### Step 3. Run the processor wrapper with `-WhatIf`

Prefer a reviewed wrapper over a long direct `Deploy-Processor.ps1` command.
`-WhatIf` runs the gate but skips stop, backup, copy, and restart.

For the checked-in UAT DBQ wrapper:

```powershell
powershell.exe -NoProfile `
    -File .\processors\Deploy-OutboundDBQ-uat.ps1 `
    -StagedRoot 'D:\stage\OutboundDBQ' `
    -StagedCommit '<approved-release-id>' `
    -ConfirmedRunbookValues `
    -AuditLogDir $env:VES_AUDIT_LOG_DIR `
    -Region '<confirmed-region>' `
    -WhatIf

$whatIfExit = $LASTEXITCODE
"WHATIF_EXIT=$whatIfExit"
```

Only pass `-ConfirmedRunbookValues` after checking the task name and fresh-log
directory against the current runbook. `-WhatIf` still reads SSM, validates
staged content, and writes logs; it is not an offline simulation.

Never execute `processors\Deploy-SYSTEM_NAME.ps1` as-is. It contains template
placeholders.

### Step 4. Exercise each real health probe independently

A health run with no configured probe must return exit `10`. For an outbound
scheduled-task processor, use its exact target folder and mode:

```powershell
powershell.exe -NoProfile `
    -File .\Invoke-HealthCheck.ps1 `
    -ScheduledTasks '<confirmed-task-name>' `
    -ProcessPathRoot 'C:\confirmed\processor\folder' `
    -ProcessArgumentPattern '\b<confirmed-mode>\b' `
    -FreshLogDir 'C:\confirmed\log\folder' `
    -FreshLogMaxAgeMinutes 60 `
    -Processor '<processor>' `
    -CommitSha '<approved-release-id>' `
    -Environment 'uat' `
    -Json

$healthExit = $LASTEXITCODE
"HEALTH_EXIT=$healthExit"
```

For a Windows service with an endpoint, use `-ServiceName`, `-HealthUrl`, and
`-ExpectedStatus 200`. Expected result is exit `0`; exit `3` means a configured
probe failed. Do not weaken the probe list merely to obtain a pass.

### Step 5. Perform an approved QA/UAT deployment

This is a deployment action. It may stop a service/task, kill a matched console
process, back up files, copy staged content, restart the workload, verify files
and config, run health checks, and prune older matching backups after success.

Before removing `-WhatIf`, confirm:

- The gate-only run passed for the same staged content and release ID.
- Target, backup, task, process, and health values were peer-reviewed.
- The rollback owner is present.
- The audit log is being written to the approved location.
- The change window authorizes stop/copy/restart activity.

Rerun the reviewed wrapper without `-WhatIf`. Record the final exit code and
complete JSONL audit-log path. Exit `0` is required; otherwise begin the
approved recovery procedure and preserve all evidence.

### Step 6. Test a complete drift inventory

The checked-in `targets.json` must remain fail-closed until operations supplies
the missing server/Citrix details. Use a separately reviewed QA/UAT inventory.
For the first integration run, disable pruning:

```powershell
powershell.exe -NoProfile `
    -File .\Start-DriftRunner.ps1 `
    -TargetsFile 'D:\ves-verify\targets.qa.json' `
    -LogDir $env:VES_AUDIT_LOG_DIR `
    -HeartbeatPath (Join-Path $env:VES_AUDIT_LOG_DIR 'ves-verify-drift.heartbeat.json') `
    -LogRetentionDays 0

$driftRunnerExit = $LASTEXITCODE
"DRIFT_RUNNER_EXIT=$driftRunnerExit"
```

Expected: exit `0`, one result per target, and a completion heartbeat. Exit `1`
means drift. Exit `2` means baseline, trust, inventory, or runtime could not be
established.

Test the resulting heartbeat:

```powershell
powershell.exe -NoProfile `
    -File .\Test-DriftHeartbeat.ps1 `
    -HeartbeatPath (Join-Path $env:VES_AUDIT_LOG_DIR 'ves-verify-drift.heartbeat.json') `
    -MaxAgeMinutes 75 `
    -Environment 'uat' `
    -Json
"WATCHDOG_EXIT=$LASTEXITCODE"
```

### Step 7. Test scheduled-task installation on an elevated test VM

`Install-DriftTask.ps1` registers or overwrites two tasks running as SYSTEM. Do
not perform the first test on a shared or production host.

From an elevated Windows PowerShell window:

```powershell
powershell.exe -NoProfile `
    -File .\Install-DriftTask.ps1 `
    -TargetsFile 'D:\ves-verify\targets.qa.json' `
    -IntervalMinutes 30 `
    -TaskName 'ves-verify-drift-test' `
    -WatchdogTaskName 'ves-verify-drift-watchdog-test' `
    -LogDir 'D:\ves-verify\logs-test' `
    -Environment 'uat'
```

Confirm registration and results:

```powershell
Get-ScheduledTask -TaskName 'ves-verify-drift-test',
    'ves-verify-drift-watchdog-test'
Get-ScheduledTaskInfo -TaskName 'ves-verify-drift-test'
Get-ScheduledTaskInfo -TaskName 'ves-verify-drift-watchdog-test'
```

Confirm the actions use the intended repository, inventory, and log paths. When
the tasks run, verify last-run results, JSONL logs, and heartbeat.

To remove only the test tasks after the test-VM exercise:

```powershell
powershell.exe -NoProfile `
    -File .\Install-DriftTask.ps1 `
    -TaskName 'ves-verify-drift-test' `
    -WatchdogTaskName 'ves-verify-drift-watchdog-test' `
    -Uninstall
```

`-Uninstall` removes the named tasks. Never use production task names in a
cleanup command unless removal is explicitly authorized.

---

## Exit-code reference

| Exit | Meaning                                                                               |
| ---: | ------------------------------------------------------------------------------------- |
|  `0` | Pass                                                                                  |
|  `1` | File/config drift or deployment gate block                                            |
|  `2` | Missing/untrusted baseline, incomplete inventory, SSM/trust failure, or runtime error |
|  `3` | Health failure                                                                        |
| `10` | Usage error or unsafe configuration                                                   |

Special cases:

- `Invoke-Tests.ps1` returns the failed-test count; `0` is green. It also
  returns `2` when compatible Pester is missing, so read the output.
- `Verify-Config.ps1` returns an object with `.pass`; use
  `Invoke-Verification.ps1 -Mode VerifyConfig` when an OS exit code is needed.
- `Install-DriftTask.ps1` throws on invalid setup and otherwise returns after
  registering or removing the requested tasks.

## Known limits of local automation

Local success does not prove:

- Real AWS CLI authentication, SSM read/write, or KMS decryption.
- Correct production parameter paths or GovCloud region.
- Rights of the real service account or SYSTEM scheduled task.
- Correct service, task, process, log, and HTTP identities.
- Production file locks, stop/start timing, backup capacity, or rollback.
- Complete Citrix/server inventory or task registration on the target OS.

Datadog delivery is disabled in this release. Exit codes and JSONL logs are the
only toolkit signals, so an operator or external log monitor must observe them.

## Troubleshooting

### `Pester 5.0+ not found`

Install an approved Pester version of at least 5.0, or use the maintained test
workstation/CI runner. The repository installation example uses 5.5.0.

### `Requested registry access is not allowed`

Pester may be unable to create temporary registry state in a restricted
sandbox. Treat this as an environment/setup failure, not automatically as a
script failure. Rerun in an approved environment with required registry access.

### Execution is blocked by policy or `Zone.Identifier`

Do not weaken organization policy. Confirm the repository is trusted, inspect
the effective policy, and ask an administrator to unblock or stage an approved
local copy. `MachinePolicy` can override a command-line execution-policy value.

### `Start-DriftRunner.ps1` exits `2` with checked-in `targets.json`

This is expected while `inventoryComplete=false` and entries are unconfirmed.
Complete and peer-review the data; do not bypass the fail-closed check.

### A `-WhatIf` deploy fails

`-WhatIf` skips stop, backup, copy, and restart, but the gate still runs. Check
AWS access, region, approved commit, trusted hash, staged content, manifest,
and required artifact paths.

### A health check returns `10`

No valid probe was configured, or required usage data was missing. Configure a
real probe; never treat a no-probe run as healthy.

### The test count differs from an older report

Counts change as coverage is added. Compare commit IDs and require zero
failures rather than matching an old count.

---

## Test sign-off template

```text
Repository/branch:
Commit tested:
Uncommitted changes included:
Tester:
Computer:
Windows PowerShell version:
Pester version:
Date/time:

PowerShell files inventoried:
Parser result:
Full-suite result:
Targeted suites run:
Local smoke-test results:
QA/UAT integration results:
Live dependencies not tested:

Exit codes:
Audit-log paths:
First failure or setup error:
Known exceptions:

Decision: PASS / FAIL / BLOCKED
Reviewer:
```
