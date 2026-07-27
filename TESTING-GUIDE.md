# Testing Guide (ves-verify)

Step-by-step instructions for checking that the post-deployment verification
scripts work as expected. Written for two audiences:

| Audience | Start here | Goal |
|----------|------------|------|
| **Non-technical** | [Part A](#part-a-non-technical--run-the-standard-check) | Run the built-in automated suite and report pass/fail |
| **Technical** | [Part B](#part-b-technical--full-validation) | Diagnose failures, run targeted tests, and smoke-check individual scripts |

All steps use **Windows PowerShell 5.1** (the same engine production uses).
Do **not** use PowerShell 7 (`pwsh`) for these tests.

---

## What you are testing (plain language)

This repository checks that legacy Windows systems still match the UAT-approved
release after files are copied by hand. The automated tests below:

- Run on a **developer workstation or CI machine**
- Do **not** need AWS, a production server, or a live Windows service
- Do **not** change production files
- Prove that the scripts follow the exit-code contract and main logic paths

They are **not** a full production dry-run. Live SSM trust, real services,
scheduled tasks, and HTTP health endpoints need a separate environment check
(see [Part C](#part-c-environment-smoke-checks-technical--ops)).

---

## Before you start

### Always

- [ ] You are on a Windows machine with **Windows PowerShell 5.1**
- [ ] You can open a PowerShell window and change to the **repository root**
      (the folder that contains `Invoke-Tests.ps1`, `README.md`, and `tests\`)
- [ ] You will **not** run deploy or capture commands against production unless
      an owner has asked for a controlled pilot

### For automated tests only

- [ ] You may install Pester 5.x once (instructions in Part A)
- [ ] Internet access is only needed for that one-time Pester install

### For environment / production-adjacent smoke checks

- [ ] AWS CLI on `PATH` and GovCloud credentials that can read SSM (if testing trust)
- [ ] Correct host, paths, and service/task names for the processor under test
- [ ] Approval before any deploy, kill-process, or scheduled-task install

---

## Part A — Non-technical: run the standard check

Use this path when you only need to confirm “the test suite is green” and hand
results to a reviewer.

### A1. Open Windows PowerShell 5.1

1. Press **Start**, type **Windows PowerShell**, open **Windows PowerShell**
   (not “PowerShell 7” / `pwsh`).
2. Confirm the version:

```powershell
$PSVersionTable.PSVersion
```

You should see a **5.1.x** major/minor version (for example `5.1.20348.x`).
If you see `7.x`, close the window and open Windows PowerShell 5.1 instead.

### A2. Go to the repository root

```powershell
Set-Location "<path-to-ves-verify-repo>"
```

Replace `<path-to-ves-verify-repo>` with the folder that contains
`Invoke-Tests.ps1`. Confirm you are in the right place:

```powershell
Get-ChildItem Invoke-Tests.ps1, tests, README.md
```

You should see those three items listed. If any are missing, you are not in the
repository root.

### A3. Install the test framework (one time per machine)

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

- If Windows asks about an untrusted repository (PSGallery), choose **Yes** /
  **Yes to All** for this install.
- If the command says Pester is already installed, continue to A4.

### A4. Run the full automated suite

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
```

This launches a fresh PowerShell 5.1 process, runs every file under `tests\`,
and prints detailed pass/fail lines.

**How long?** Usually a few minutes on a normal workstation. Wait until the
prompt returns.

### A5. Read the result

| Exit code | Meaning | What to do |
|-----------|---------|------------|
| **0** | All tests passed | Record a pass (A6) |
| **1 or higher** | That many tests failed | Do **not** treat as ready; send output to a technical reviewer (A7) |
| **2** | Pester 5.x not found | Re-run A3, then A4 |

Quick way to see the exit code after the run:

```powershell
echo $LASTEXITCODE
```

In the output, look for lines like:

- `Tests Passed: …, Failed: …, Skipped: …`
- Individual `[-] …` blocks for failures

**Pass** means failed count is **0**.

### A6. Capture evidence (pass or fail)

Copy this block into email, a ticket, or chat:

```text
ves-verify automated test report
Date/time:     <YYYY-MM-DD HH:mm>
Machine:       <hostname>
Repo path:     <full path>
Commit SHA:    <paste from git rev-parse HEAD if available>
Command:       powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
Exit code:     <0 or number>
Summary:       Passed / Failed / Skipped counts from the last Pester summary line
Result:        PASS or FAIL
```

Optional but useful:

```powershell
hostname
Get-Date -Format "yyyy-MM-dd HH:mm:ss"
git rev-parse HEAD
echo $LASTEXITCODE
```

### A7. If tests fail

1. **Stop.** Do not run deployment scripts or mark a release ready.
2. Save the **full** terminal output (or at least the first failing test block).
3. Send the report from A6 plus the first failure text to a technical reviewer.
4. Do not reinstall modules or change production paths unless asked.

You are done with the non-technical path.

---

## Part B — Technical: full validation

Use this path when developing, reviewing a PR, or diagnosing a failure from Part A.

### B1. Full regression (same as Part A)

```powershell
Set-Location "<path-to-ves-verify-repo>"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
if ($LASTEXITCODE -ne 0) { throw "Suite failed with exit $LASTEXITCODE" }
```

`Invoke-Tests.ps1` exits with the **failed-test count** (0 = green). It also
redirects audit logs to a temp folder for the duration of the run so local
`%ProgramData%\ves-verify\logs` is not polluted.

### B2. Map scripts → automated tests

| Area | Production script(s) | Primary test file(s) |
|------|----------------------|----------------------|
| Shared helpers | `module\VesVerify.psm1` | `tests\VesVerify.Module.Tests.ps1` |
| Capture / file verify | `Invoke-Verification.ps1` | `tests\Invoke-Verification.Tests.ps1` |
| Config contracts | `Verify-Config.ps1` | `tests\Verify-Config.Tests.ps1` |
| Preflight readiness | `Invoke-Preflight.ps1` | `tests\Invoke-Preflight.Tests.ps1` |
| Pre-deploy gate | `Invoke-PreDeployGate.ps1` | `tests\Invoke-PreDeployGate.Tests.ps1` |
| Deploy pipeline | `Deploy-Processor.ps1` | `tests\Deploy-Processor.Tests.ps1` |
| Health probes | `Invoke-HealthCheck.ps1` | `tests\Invoke-HealthCheck.Tests.ps1` |
| Scheduled drift | `Start-DriftRunner.ps1` | `tests\Start-DriftRunner.Tests.ps1` |
| Missed-run watchdog | `Test-DriftHeartbeat.ps1` | `tests\Test-DriftHeartbeat.Tests.ps1` |

There is no dedicated Pester file for `Install-DriftTask.ps1` or the thin
wrappers under `processors\`; those are validated by review plus a controlled
pilot (Part C).

### B3. Targeted Pester runs (when diagnosing)

Prefer the full suite for sign-off. Use single files only while debugging.

```powershell
# Requires Pester 5 already imported in this session
Import-Module Pester -MinimumVersion 5.0 -Force

Invoke-Pester -Path .\tests\Invoke-Verification.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\Verify-Config.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\Invoke-Preflight.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\Invoke-PreDeployGate.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\Deploy-Processor.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\Invoke-HealthCheck.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\Start-DriftRunner.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\Test-DriftHeartbeat.Tests.ps1 -Output Detailed
Invoke-Pester -Path .\tests\VesVerify.Module.Tests.ps1 -Output Detailed
```

Or re-run one file through the same runner used in CI/local sign-off:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1 -Path .\tests\Deploy-Processor.Tests.ps1
```

### B4. Local script smoke checks (safe, no AWS)

These exercises use a throwaway folder under `%TEMP%`. They do **not** pin SSM
or touch production. Use only for learning behavior and validating exit codes.

#### B4.1 Capture and file verify

```powershell
$root     = Join-Path $env:TEMP ("ves-smoke-{0}" -f $PID)
$release  = Join-Path $root "release"
$manifest = Join-Path $root "baseline.json"
New-Item -ItemType Directory -Path (Join-Path $release "bin") -Force | Out-Null
Set-Content -Path (Join-Path $release "app.txt")     -Value "hello"   -NoNewline
Set-Content -Path (Join-Path $release "bin\lib.dll") -Value "libdata" -NoNewline

# Capture (local-only switches — never use these for a real approved release)
.\Invoke-Verification.ps1 -Mode Capture `
  -ReleaseRoot $release -ManifestPath $manifest -Processor smoke `
  -AllowUntrustedCapture -AllowUnarchivedCapture -Json
# Expect: exit 0, status "captured", warning that capture is NOT trust-anchored

# Verify match
.\Invoke-Verification.ps1 -Mode VerifyFiles `
  -ReleaseRoot $release -ManifestPath $manifest -Json
# Expect: exit 0, status "match"

# Introduce drift
Set-Content -Path (Join-Path $release "app.txt") -Value "changed" -NoNewline
.\Invoke-Verification.ps1 -Mode VerifyFiles `
  -ReleaseRoot $release -ManifestPath $manifest -Json
# Expect: exit 1, status "drift"
```

#### B4.2 Preflight usage and manifest self-check

```powershell
# Usage guard (nothing meaningful passed)
.\Invoke-Preflight.ps1 -Json
# Expect: exit 10

# Manifest-only self-check (no SSM params → no AWS required for this path)
.\Invoke-Preflight.ps1 -ManifestPath $manifest -Processor smoke -Json
# Expect: exit 0 when the manifest from B4.1 is intact
```

#### B4.3 Config contract (fixtures already in the repo)

```powershell
$fx = Join-Path (Get-Location) "tests\fixtures\appconfig"
& .\Verify-Config.ps1 `
  -ContractPath (Join-Path $fx "contract.json") `
  -ConfigPath   (Join-Path $fx "app.config")
# Expect: object with .pass = $true

# Same for json and keyvalue fixtures under tests\fixtures\
```

#### B4.4 Health check (local probes only)

```powershell
$logDir = Join-Path $env:TEMP ("ves-hc-{0}" -f $PID)
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Set-Content -Path (Join-Path $logDir "today.log") -Value "alive"

.\Invoke-HealthCheck.ps1 -FreshLogDir $logDir -Processor smoke -Json
# Expect: exit 0, healthy = true

# No probe configured → must not report healthy
.\Invoke-HealthCheck.ps1 -Processor smoke -Json
# Expect: exit 10
```

#### B4.5 Cleanup smoke artifacts

```powershell
Remove-Item -LiteralPath $root, $logDir -Recurse -Force -ErrorAction SilentlyContinue
```

### B5. What automated tests deliberately skip

No automated test requires:

- Real AWS SSM Parameter Store
- A live Windows service or Task Scheduler job
- A listening HTTP actuator endpoint
- Network access to GovCloud

Covered without live infra (via stubs/temp trees): gate commit/hash checks
(fake `aws.cmd` on PATH), deploy copy/kill paths, inventory fail-closed rules,
config formats, capture/verify/drift exit codes, heartbeat freshness.

For real trust and host health, continue to Part C.

---

## Part C — Environment smoke checks (technical / ops)

Run only on the correct host (or a dedicated pilot host) with paths from
[SERVERS.md](SERVERS.md) and inventory from `targets.json`. Prefer **UAT/DEV**
before any production pilot.

### C1. Preflight against real SSM + baseline

```powershell
.\Invoke-Preflight.ps1 -Processor <system> `
  -ApprovedCommitParam /ves/<system>/approved-commit `
  -TrustParam /ves/<system>/baseline-hash `
  -ManifestPath D:\baselines\<system>.json

# Or every drift target at once:
.\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json
```

| Exit | Meaning |
|------|---------|
| 0 | Ready (WARN allowed, e.g. old exclude-pattern baseline) |
| 2 | Not ready (CLI missing, SSM unreadable, trust mismatch, etc.) |
| 10 | Bad usage |

### C2. File / config verify on a live release root

```powershell
.\Invoke-Verification.ps1 -Mode VerifyFiles `
  -ReleaseRoot <prod-or-uat-root> -ManifestPath <baseline.json> `
  -TrustParam /ves/<system>/baseline-hash -Json

.\Invoke-Verification.ps1 -Mode VerifyConfig `
  -ConfigPath <live-config> -ContractPath <contract.json> -Json

.\Invoke-Verification.ps1 -Mode All ...
```

| Exit | Meaning |
|------|---------|
| 0 | Match |
| 1 | Drift |
| 2 | Trust / baseline / runtime error |
| 10 | Usage / unsafe configuration |

### C3. Health check by target type

**Outbound console EXE** (task last-run + fresh log; match process by folder/mode):

```powershell
.\Invoke-HealthCheck.ps1 -Processor OutboundDBQ `
  -ScheduledTasks VLER_EM_Real_Time_Outbound_Processor `
  -ProcessPathRoot C:\VLER_Test\Processors\VES.OutboundProcessor `
  -ProcessArgumentPattern '\bRTPDP\b' `
  -FreshLogDir C:\VLER_Test\Logs\VES.OutboundProcessor -FreshLogMaxAgeMinutes 60
```

**Java / Spring Boot service**:

```powershell
.\Invoke-HealthCheck.ps1 -Processor pagecount `
  -ServiceName oms-vems-pagecount-prod `
  -HealthUrl http://localhost:9191/actuator/health
```

| Exit | Meaning |
|------|---------|
| 0 | Healthy |
| 3 | Unhealthy |
| 10 | No probe configured (refuses a false green) |

### C4. Deploy dry-run (gate only — no copy)

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> -WhatIf
```

Expect exit 0 only if the staged tree matches the approved release; the target
tree must remain untouched.

### C5. Drift runner and heartbeat (manual, not install)

```powershell
.\Start-DriftRunner.ps1 -TargetsFile D:\ves-verify\targets.json -LogDir <approved-log-dir>
.\Test-DriftHeartbeat.ps1 -LogDir <approved-log-dir> -MaxAgeMinutes 45
```

Do **not** register scheduled tasks with `Install-DriftTask.ps1` until the
interval, log share, and inventory are approved. That installer requires
elevation and creates SYSTEM tasks.

### C6. Capture (approved release only)

Never use `-AllowUntrustedCapture` / `-AllowUnarchivedCapture` for a real
sign-off. Capture requires `-TrustParam`, `-ArchiveRepo`, and `-ReleaseTag`.
See the Capture section in [README.md](README.md).

---

## Exit code cheat sheet

Shared contract for production scripts:

| Code | Outcome class | Typical meaning |
|------|---------------|-----------------|
| **0** | PASS | Match / ready / healthy / deploy succeeded |
| **1** | FAIL | File or config drift; gate blocked a bad staged tree |
| **2** | ERROR | Trust failure, missing baseline, inventory/runtime error, missed drift heartbeat |
| **3** | FAIL | Health probe failed |
| **10** | ERROR | Usage error or unsafe configuration |

Special case: **`Invoke-Tests.ps1`** exits with the **number of failed tests**
(0 = all green). Missing Pester 5.x also exits **2**.

Brief mapping: PASS = 0; FAIL = 1 or 3; ERROR = 2 or 10.

---

## Recommended sign-off checklist

Before calling a change “tested”:

- [ ] Full suite: `Invoke-Tests.ps1` exit code **0**
- [ ] Commit SHA recorded
- [ ] Host name and timestamp recorded
- [ ] If the change touches a specific script, targeted Pester file also green
- [ ] If the change affects live behavior, Part C smoke results attached for the
      intended environment (at least preflight + relevant verify/health)
- [ ] No use of local-only capture exceptions on an approved baseline

Sign-off template:

```text
ves-verify test sign-off
Commit:     <sha>
Command:    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
Exit:       0
Pester:     Passed=<n> Failed=0 Skipped=<n>
Env smoke:  <none | preflight 0 | verify 0 | health 0 | …>
Host:       <name>
When:       <timestamp>
Tester:     <name>
```

---

## Related docs

- [README.md](README.md) — overview, usage, trust model, Testing section summary
- [SERVERS.md](SERVERS.md) — server and processor path map for environment checks
- [sample.config.json](sample.config.json) — config contract shape
- [targets.json](targets.json) — inventory schema starter (intentionally incomplete)
- [AGENTS.md](AGENTS.md) — agent/contributor conventions

---

## Quick reference card

| I want to… | Do this |
|------------|---------|
| Prove the suite is green | Part A, steps A1–A6 |
| Debug one failing area | Part B3 targeted Pester |
| Learn capture/verify exit codes offline | Part B4.1 |
| Check a host is ready for deploy | Part C1 preflight |
| Confirm prod matches baseline | Part C2 verify |
| Confirm process/service is alive | Part C3 health |
| Dry-run a deploy without copying | Part C4 `-WhatIf` |
| Report results | Sign-off template above |
