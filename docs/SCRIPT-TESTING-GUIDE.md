# Tester system runbook

Step-by-step guide for testers who run the post-deployment scripts **on OMS
systems** (workstation → UAT → production target servers).

**Purpose:** prove that what runs on a target system matches the UAT-approved
release, and stop cleanly when files, config, trust, or health fail.

**Runtime:** Windows PowerShell **5.1** only (`powershell.exe`, not PowerShell 7).

**Authoritative detail:** [README.md](README.md) (exit codes, trust model),
[SERVERS.md](SERVERS.md) (server and processor path map). This guide is the
ordered run path; those docs are the deep reference.

If you want a plain-language walkthrough, start with
[RUNBOOK-NON-TECHNICAL.md](RUNBOOK-NON-TECHNICAL.md).

---

## Scripts a tester may run

| Script                                       | What it does                                            | Where to run           | Risk                                       |
| -------------------------------------------- | ------------------------------------------------------- | ---------------------- | ------------------------------------------ |
| `Invoke-Tests.ps1`                           | Automated file-match unit tests (Pester 5)              | Workstation / CI       | None (local fixtures only)                 |
| `Invoke-Preflight.ps1`                       | Read-only readiness: PS version, AWS CLI, SSM, baseline | UAT, runner, or target | Read-only                                  |
| `Invoke-Verification.ps1 -Mode Capture`      | Build approved UAT baseline + pin hash to SSM           | UAT approval host      | Writes manifest, SSM, optional Git archive |
| `Invoke-Verification.ps1 -Mode VerifyFiles`  | Compare live files to trusted baseline                  | Target server          | Read-only check                            |
| `Invoke-Verification.ps1 -Mode VerifyConfig` | Config contract check (keys/values vs contract + SSM)   | Target server          | Read-only check                            |
| `Invoke-Verification.ps1 -Mode All`          | VerifyFiles + VerifyConfig in one run                   | Target server          | Read-only check                            |
| `Invoke-HealthCheck.ps1`                     | Assembly / process / task / log / endpoint probes       | Target server          | Read-only check                            |
| `processors\Deploy-*.ps1 -WhatIf`            | Pre-deploy gate only (no copy)                          | Target server (pilot)  | Read-only gate                             |
| `processors\Deploy-*.ps1`                    | Gate → stop → backup → copy → restart → verify → health | Target server (pilot)  | **Write path** — change control required   |
| `Start-DriftRunner.ps1`                      | Re-verify every target in inventory                     | Ops runner             | Read-only checks; needs complete inventory |
| `Install-DriftTask.ps1`                      | Register scheduled runner + heartbeat watchdog          | Ops (elevated)         | Writes scheduled tasks                     |

**Default tester path for release validation:** Steps 0–5 below (tests →
preflight → capture → file verify → config → health). Deploy and drift are
optional and higher risk.

---

## Approvals (do not skip)

| Activity                                       | Required approver                                   |
| ---------------------------------------------- | --------------------------------------------------- |
| Local automated tests (`Invoke-Tests.ps1`)     | Repository maintainer (or self for pure local work) |
| Preflight                                      | Tester + server owner if run on shared hosts        |
| UAT baseline capture (`-Mode Capture`)         | **Release owner present** during the run            |
| Production VerifyFiles / VerifyConfig / Health | Release owner **and** server owner                  |
| Deploy (`Deploy-*.ps1` without `-WhatIf`)      | Formal change authorization                         |
| Any production execution window                | Formal change authorization                         |

If a value is blank or still shows `REPLACE` / `TBD`, **stop**.

---

## Prerequisites

1. Open **Windows PowerShell 5.1** (not PowerShell 7).
2. Set location to the repository checkout on that machine:

```powershell
Set-Location 'C:\Users\howardr01\Post-Deployment'
# or the approved path on the server, e.g. D:\ves-verify
```

3. Confirm version:

```powershell
$PSVersionTable.PSVersion
# Major should be 5
```

4. Record the commit under test:

```powershell
git rev-parse --short HEAD
```

5. **Workstation only (Step 0):** Pester 5.x once:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

6. **SSM-dependent steps (1–4):** AWS CLI installed; credentials or instance
   profile can `ssm:GetParameter` (and `ssm:PutParameter` on capture hosts)
   plus `kms:Decrypt` for SecureString parameters in the confirmed GovCloud
   region.

7. Optional durable logs (recommended before production):

```powershell
$env:VES_AUDIT_LOG_DIR = '\\audit-share\ves-verify\logs'
# or a local path such as D:\ves-verify\logs
```

If unset, scripts fall back to `%ProgramData%\ves-verify\logs`.

Keep the **same PowerShell window** for a session so `$LASTEXITCODE` and env
vars stay consistent.

---

## Values worksheet (fill before Step 1)

Pull these from the Outbound Deployment Steps runbook and [SERVERS.md](SERVERS.md).
Do not invent production paths.

| #   | Value                                                     | Example shape                                            | Your value |
| --- | --------------------------------------------------------- | -------------------------------------------------------- | ---------- |
| 1   | Processor name                                            | `OutboundDBQ`                                            |            |
| 2   | UAT approved release folder (`-ReleaseRoot` for Capture)  | `C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` |            |
| 3   | Production (or target) folder (`-ReleaseRoot` for Verify) | From runbook per server                                  |            |
| 4   | Baseline manifest path                                    | `D:\baselines\OutboundDBQ.json`                          |            |
| 5   | SSM trust parameter                                       | `/ves/OutboundDBQ/baseline-hash`                         |            |
| 6   | SSM approved-commit parameter                             | `/ves/OutboundDBQ/approved-commit`                       |            |
| 7   | Release tag                                               | `OutboundDBQ/v1.4.0` (`<system>/vMAJOR.MINOR.PATCH`)     |            |
| 8   | Approved commit / label string                            | Git SHA or TFS label                                     |            |
| 9   | GovCloud region                                           | Confirm `us-gov-west-1` vs `us-gov-east-1`               |            |
| 10  | Archive Git checkout (`-ArchiveRepo` for Capture)         | `D:\ves-verify`                                          |            |
| 11  | Config contract path (if used)                            | `D:\baselines\OutboundDBQ.config.json`                   |            |
| 12  | Live config path (if used)                                | `...\VES.OutboundDBQProcessor.exe.config`                |            |
| 13  | Scheduled task name(s) for health                         | From runbook                                             |            |
| 14  | Fresh log directory for health                            | From runbook                                             |            |
| 15  | Process mode arg pattern                                  | e.g. `\bRTPDP\b` for DBQ                                 |            |

---

## Where processors live (quick map)

Outbound processors share one EXE name (`VES.OutboundDBQProcessor.exe`) and are
distinguished by **folder + mode argument**, not process name alone. See
[SERVERS.md](SERVERS.md) for full paths.

| Tier | Server         | Processors                     |
| ---- | -------------- | ------------------------------ |
| UAT  | VESMSEGRESSUAT | Ack, DBQ, XML (all on one box) |
| PROD | VESEMSEGRESS01 | XML / Outbound Events          |
| PROD | VESEMSEGRESS02 | Ack, DBQ, XML                  |
| PROD | VESEMSEGRESS03 | XML, DBQ                       |

| Processor | Mode arg | Typical health identity                            |
| --------- | -------- | -------------------------------------------------- |
| Ack       | `RTP`    | Working dir under Ack tree + arg pattern `\bRTP\b` |
| DBQ       | `RTPDP`  | Working dir under DBQ tree + `\bRTPDP\b`           |
| XML       | `RTP`    | Working dir under XML tree + folder/batch identity |

Inbound and Citrix targets follow the same script pattern once paths are
confirmed. Do not set `targets.json` `inventoryComplete` to true until every
required server (including Citrix) is confirmed.

---

## Step-by-step run order

### Step 0 — Automated tests (workstation only)

Confirms the file-match logic still works before any server work.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

**Expected:** `0` (failed-test count).

If not `0`, **stop**. Do not continue to systems.

---

### Step 1 — Preflight (UAT or runner; read-only)

Confirms PowerShell host, AWS CLI, SSM parameters, and baseline integrity.
Touches **no** production or staged files.

**Single processor:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-Preflight.ps1 `
  -Processor REPLACE_WITH_PROCESSOR_NAME `
  -ApprovedCommitParam REPLACE_WITH_APPROVED_COMMIT_PARAM `
  -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
  -ManifestPath REPLACE_WITH_BASELINE_MANIFEST_PATH `
  -Region REPLACE_WITH_CONFIRMED_REGION `
  -Json
$LASTEXITCODE
```

**Or every inventory target (when inventory is filled in):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-Preflight.ps1 `
  -TargetsFile .\targets.json `
  -Region REPLACE_WITH_CONFIRMED_REGION `
  -Json
$LASTEXITCODE
```

**Expected:** `0` = ready. `2` = not ready (SSM, baseline, inventory, or host).

A `manifest-pattern` **WARN** means that baseline may need re-capture after
exclude-rule changes; WARN alone does not fail preflight. See README
“Upgrading: re-pin baselines…”.

If not `0`, **stop** and fix trust/region/paths before Capture or Verify.

---

### Step 2 — Capture approved UAT baseline (UAT; release owner present)

Run only when UAT sign-off is complete. This creates the trusted baseline.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-Verification.ps1 `
  -Mode Capture `
  -ReleaseRoot REPLACE_WITH_UAT_APPROVED_RELEASE_FOLDER `
  -ManifestPath REPLACE_WITH_BASELINE_MANIFEST_PATH `
  -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
  -ArchiveRepo REPLACE_WITH_BASELINE_GIT_CHECKOUT `
  -ReleaseTag REPLACE_WITH_RELEASE_TAG `
  -Processor REPLACE_WITH_PROCESSOR_NAME `
  -CommitSha REPLACE_WITH_APPROVED_COMMIT `
  -Environment uat `
  -Region REPLACE_WITH_CONFIRMED_REGION `
  -Json
$LASTEXITCODE
```

Optionally add `-PushRemote` so the archive commit and tag leave the capture
host immediately (failed push fails the capture).

Also pin the approved commit/label if your process requires it:

```powershell
aws ssm put-parameter --name REPLACE_WITH_APPROVED_COMMIT_PARAM `
  --value REPLACE_WITH_APPROVED_COMMIT `
  --type SecureString --overwrite --region REPLACE_WITH_CONFIRMED_REGION
```

**Expected:** `0`.

If not `0`, **stop**.

**Do not use** `-AllowUntrustedCapture` or `-AllowUnarchivedCapture` for a real
approved release (local tests only).

**Save from this step:**

- Release tag
- Manifest path
- Manifest hash shown in output
- JSONL log path
- Commit / label pinned to SSM

---

### Step 3 — Verify production (or target) files match baseline

Main content check. Run **on the target server** (or against that server’s
release root if your ops model allows a central runner with path access).

**From local manifest + SSM trust:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-Verification.ps1 `
  -Mode VerifyFiles `
  -ReleaseRoot REPLACE_WITH_TARGET_RELEASE_FOLDER `
  -ManifestPath REPLACE_WITH_BASELINE_MANIFEST_PATH `
  -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
  -Processor REPLACE_WITH_PROCESSOR_NAME `
  -Environment prod `
  -Region REPLACE_WITH_CONFIRMED_REGION `
  -Json
$LASTEXITCODE
```

**From Git release tag (SSM pin still applies when both are set):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-Verification.ps1 `
  -Mode VerifyFiles `
  -ReleaseRoot REPLACE_WITH_TARGET_RELEASE_FOLDER `
  -BaselineRepo REPLACE_WITH_BASELINE_GIT_CHECKOUT `
  -ReleaseTag REPLACE_WITH_RELEASE_TAG `
  -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
  -Processor REPLACE_WITH_PROCESSOR_NAME `
  -Environment prod `
  -Region REPLACE_WITH_CONFIRMED_REGION `
  -Json
$LASTEXITCODE
```

**Expected:** `0`.

| Exit | Meaning                               | Action                               |
| ---: | ------------------------------------- | ------------------------------------ |
|  `0` | Files match trusted baseline          | Continue to config/health as planned |
|  `1` | Drift (`MISSING`, `CHANGED`, `EXTRA`) | Stop and escalate                    |
|  `2` | Trust/baseline failure                | Stop and escalate                    |
| `10` | Bad/incomplete command                | Fix inputs and rerun                 |

---

### Step 4 — Verify config contract (when a contract exists)

Config files (`*.config`) are **excluded** from file-hash compare on purpose
(environment-specific paths). Check them with the contract.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-Verification.ps1 `
  -Mode VerifyConfig `
  -ConfigContract REPLACE_WITH_CONFIG_CONTRACT_PATH `
  -ConfigPath REPLACE_WITH_LIVE_CONFIG_PATH `
  -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
  -Processor REPLACE_WITH_PROCESSOR_NAME `
  -Environment prod `
  -Region REPLACE_WITH_CONFIRMED_REGION `
  -Json
$LASTEXITCODE
```

Or combine files + config:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-Verification.ps1 `
  -Mode All `
  -ReleaseRoot REPLACE_WITH_TARGET_RELEASE_FOLDER `
  -ManifestPath REPLACE_WITH_BASELINE_MANIFEST_PATH `
  -ConfigContract REPLACE_WITH_CONFIG_CONTRACT_PATH `
  -ConfigPath REPLACE_WITH_LIVE_CONFIG_PATH `
  -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
  -Processor REPLACE_WITH_PROCESSOR_NAME `
  -Environment prod `
  -Region REPLACE_WITH_CONFIRMED_REGION `
  -Json
$LASTEXITCODE
```

**Expected:** `0`. Same stop rules as Step 3 (`1` drift, `2` trust, `10` usage).

Contract shape: [sample.config.json](sample.config.json). Sensitive values are
masked in reports; never paste secrets into the worksheet or ticket.

---

### Step 5 — Health check (target server)

Proves the instance is alive after files/config match. An invocation with
**no probes** exits `10` (not a false green).

**Outbound console EXE (no HTTP endpoint)** — match by folder + mode arg:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\Invoke-HealthCheck.ps1 `
  -Processor REPLACE_WITH_PROCESSOR_NAME `
  -ProcessPathRoot REPLACE_WITH_TARGET_RELEASE_FOLDER `
  -ProcessArgumentPattern 'REPLACE_WITH_MODE_REGEX' `
  -ScheduledTasks REPLACE_WITH_TASK_NAME `
  -FreshLogDir REPLACE_WITH_LOG_DIR `
  -FreshLogMaxAgeMinutes 60 `
  -RequiredAssemblies REPLACE_WITH_EXE_PATH `
  -Environment prod `
  -Json
$LASTEXITCODE
```

Example shapes (confirm against runbook before use):

- DBQ mode pattern: `\bRTPDP\b`
- Ack / XML mode pattern: often `\bRTP\b` (folder distinguishes them)

**Expected:** `0`. Health failure is **`3`**.

Java/gateway service profile (out of current OMS manual-copy scope; retained
for later work) uses `-ServiceName` and `-HealthUrl` instead of process/task/log.

---

### Step 6 — Optional: deploy pilot (UAT first; change control)

Use only with formal authorization. Prefer the thin wrapper for the box:

```powershell
# Gate only — no copy
.\processors\Deploy-OutboundDBQ-uat.ps1 `
  -StagedRoot D:\stage\OutboundDBQ `
  -StagedCommit REPLACE_WITH_STAGED_COMMIT `
  -ConfirmedRunbookValues `
  -WhatIf

# Real deploy after WhatIf is clean
.\processors\Deploy-OutboundDBQ-uat.ps1 `
  -StagedRoot D:\stage\OutboundDBQ `
  -StagedCommit REPLACE_WITH_STAGED_COMMIT `
  -ConfirmedRunbookValues
```

`-ConfirmedRunbookValues` is required on the UAT DBQ wrapper until task name and
log directory are confirmed against the runbook.

Deploy flow: gate → stop matching instance → backup → copy → restart task →
verify → health. Pilot on **UAT egress** before any PROD use.

---

### Step 7 — Optional: drift runner (ops)

Inventory is **fail-closed**. The checked-in `targets.json` has
`inventoryComplete: false` until Citrix and production paths are confirmed.
The runner will not claim full coverage while incomplete.

```powershell
# One-shot re-verify of inventory targets
.\Start-DriftRunner.ps1 -TargetsFile D:\ves-verify\targets.json

# Register scheduled runner + independent heartbeat watchdog (elevated, ops)
.\Install-DriftTask.ps1 -TargetsFile D:\ves-verify\targets.json `
  -IntervalMinutes 30 -LogDir \\audit-share\ves-verify\logs
```

Telemetry push is **disabled** today; exit codes and JSONL logs are the only
signal. Configure a durable log directory before production reliance.

---

## Exit codes (plain language)

| Code | Outcome | Meaning                                        | Action                        |
| ---: | ------- | ---------------------------------------------- | ----------------------------- |
|  `0` | PASS    | Check succeeded                                | Record and continue or finish |
|  `1` | FAIL    | File or config drift                           | Stop and escalate             |
|  `2` | ERROR   | Trust, inventory, baseline, or runtime failure | Stop and escalate             |
|  `3` | FAIL    | Health probe failed                            | Stop and escalate             |
| `10` | ERROR   | Usage error or unsafe configuration            | Fix inputs and rerun          |

A missing baseline, incomplete inventory, dead check, or empty health probe is
**never** a pass.

---

## What to record each time

For every run:

1. Script name, mode, date/time (UTC preferred)
2. Server or workstation name
3. `git rev-parse --short HEAD`
4. Processor, release tag, environment, region
5. Exact command used (**sanitize** secrets)
6. `$LASTEXITCODE`
7. Any `MISSING`, `CHANGED`, or `EXTRA` lines (or health failure reasons)
8. JSONL log path (console or default under `%ProgramData%\ves-verify\logs` /
   `VES_AUDIT_LOG_DIR`)

**Never** copy passwords, tokens, connection strings, or raw SSM secret values
into the record.

---

## Escalation packet

When a run does not end in `0`, hand over:

1. Script name and sanitized command
2. Date/time and host name
3. Commit hash and release tag
4. Exit code
5. Full drift or failure lines
6. JSONL log file path
7. Screenshot of the final output section

---

## Sign-off block

| Field                                    | Value |
| ---------------------------------------- | ----- |
| Tester                                   |       |
| Repository maintainer                    |       |
| Release owner                            |       |
| Server owner                             |       |
| Date                                     |       |
| Steps completed (0–5 / 6 / 7)            |       |
| Final result (`PASS` / `FAIL` / `ERROR`) |       |
| Exit code of last critical step          |       |

---

## Quick summary for non-technical operators

1. **Workstation:** run automated tests — must be `0`.
2. **UAT:** preflight, then capture the approved baseline with the release owner.
3. **Target system:** verify files (and config if used), then health.
4. A pass is only exit code **`0`**.
5. Any other number means **stop** and hand over the escalation packet.
6. Deploy and scheduled drift are optional, higher-risk, ops-owned paths.

---

## Do nots

- Do not run under PowerShell 7 for production checks.
- Do not use untrusted/unarchived capture switches for real releases.
- Do not invent PROD paths; pull them from the runbook / SERVERS.md.
- Do not treat incomplete `targets.json` as full inventory coverage.
- Do not log secrets or paste SSM SecureString values into tickets.
- Do not skip formal change control for deploy (Step 6) or production windows.
