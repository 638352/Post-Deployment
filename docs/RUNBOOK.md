# ves-verify Operational Runbook

Step-by-step procedures for running every script in this suite: **what** each
one does, **where** it runs, and **how** to run it. Follow the sections in
order for a full release; use the per-script sections for one-off tasks.

Need a plain-language version? Use
[RUNBOOK-NON-TECHNICAL.md](RUNBOOK-NON-TECHNICAL.md).

> Scope: OMS .NET executables, PowerBuilder binaries, and their configurations
> deployed by manual file copy — including every Citrix server that receives a
> copy. Gateway cloud services and MERA (`VESMERA01`) are **out of scope**.
> Database objects are a planned fast follow. See [SERVERS.md](../SERVERS.md) for
> the authoritative server/processor path map.

---

## 0. Conventions used in this runbook

| Placeholder                | Meaning                                             | Example                                                  |
| -------------------------- | --------------------------------------------------- | -------------------------------------------------------- |
| `<REPO_ROOT>`              | Where this suite is installed on the box you are on | `D:\ves-verify`                                          |
| `<system>` / `<processor>` | The processor name                                  | `OutboundDBQ`                                            |
| `<releaseRoot>`            | Folder holding the approved/target files            | `C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` |
| `<manifestPath>`           | Baseline manifest JSON                              | `D:\baselines\OutboundDBQ.json`                          |
| `<trustParam>`             | SSM parameter pinning the manifest hash             | `/ves/OutboundDBQ/baseline-hash`                         |
| `<approvedCommitParam>`    | SSM parameter holding the approved commit           | `/ves/OutboundDBQ/approved-commit`                       |
| `<releaseTag>`             | `<system>/vMAJOR.MINOR.PATCH`                       | `OutboundDBQ/v1.4.0`                                     |
| `<region>`                 | GovCloud region                                     | `us-gov-west-1`                                          |

**Fixed install location on servers:** `D:\ves-verify`. On a tester's own
workstation, substitute the path where the repo was cloned.

### Exit codes (the verdict for every run)

| Code | Meaning                                     | Action              |
| ---: | ------------------------------------------- | ------------------- |
|  `0` | PASS — match / healthy / ready              | Record and continue |
|  `1` | FAIL — file or config drift                 | Stop, escalate      |
|  `2` | ERROR — trust / inventory / runtime failure | Stop, escalate      |
|  `3` | FAIL — health probe failed                  | Stop, escalate      |
| `10` | ERROR — usage / unsafe configuration        | Fix inputs, rerun   |

A missing baseline, incomplete inventory, dead check, or unconfigured health
probe is **never** a pass.

---

## 1. Prerequisites (every box, before any run)

**Where:** the box you are about to run on (workstation, UAT server, or PROD
server).

1. Open **Windows PowerShell 5.1** — not PowerShell 7.
2. Confirm the version:

   ```powershell
   $PSVersionTable.PSVersion   # Major must be 5, Minor 1
   ```

3. Go to the install location:

   ```powershell
   Set-Location 'D:\ves-verify'
   ```

4. Record the commit under test:

   ```powershell
   git rev-parse --short HEAD
   ```

5. For any step that reads SSM (preflight, capture, verify, gate, deploy),
   confirm AWS CLI + GovCloud read access is present on this box.
6. Keep the same PowerShell window open for the whole session.

**Approval gates:** capture requires the release owner present; production
verify/deploy requires release owner **and** server owner plus a formal change
window.

---

## 2. Workstation gate — `Invoke-Tests.ps1`

**What:** Runs the Pester suite so the logic is proven before touching any
server.
**Where:** Developer/tester **workstation**.
**How:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

Expected: `0`. If not `0`, **stop** — do not proceed to any server.

---

## 3. Readiness self-check — `Invoke-Preflight.ps1`

**What:** Read-only. Confirms the AWS CLI is present, the SSM parameters read
back (auth + KMS decrypt + correct path/region), and the baseline manifest is
intact and trust-anchored. Touches no prod or staged files.
**Where:** Any box that will run a capture, verify, gate, or deploy — run it
there first.
**How (single processor):**

```powershell
.\Invoke-Preflight.ps1 -Processor <system> `
  -ApprovedCommitParam <approvedCommitParam> `
  -TrustParam <trustParam> `
  -ManifestPath <manifestPath>
```

**How (validate every drift target at once):**

```powershell
.\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json
```

Expected: `0` = ready, `2` = not ready. A `manifest-pattern` **WARN** does not
block readiness but flags a baseline that needs re-capture (see §9).

---

## 4. Capture the approved baseline — `Invoke-Verification.ps1 -Mode Capture`

**What:** Creates the approved UAT file baseline (manifest), pins its hash to
SSM, commits the record under a Git release tag, and writes
`release-record.json`.
**Where:** **UAT approval host** (e.g. `VESMSEGRESSUAT`), release owner present,
at sign-off.
**How:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode Capture `
 -ReleaseRoot <releaseRoot> `
 -ManifestPath <manifestPath> `
 -TrustParam <trustParam> `
 -ArchiveRepo D:\ves-verify `
 -ReleaseTag <releaseTag> `
 -Processor <system> `
 -CommitSha (git rev-parse HEAD) `
 -Environment uat `
 -Region <region> `
 -Json
$LASTEXITCODE
```

Then pin the approved commit:

```powershell
aws ssm put-parameter --name <approvedCommitParam> --value <sha> `
  --type SecureString --overwrite --region <region>
```

Expected: `0`. `-TrustParam`, `-ArchiveRepo`, and `-ReleaseTag` are **required**
— capture fails closed (exit 10) if any is missing. `-ReleaseTag` must match
`<system>/vMAJOR.MINOR.PATCH`. Add `-PushRemote` to push the commit and tag
off-host immediately (a failed push fails the capture).

Record from output: release tag, manifest path, manifest hash, JSONL log path.

> JSONL logging is opt-in for this script: add `-LogFile <path>` to the command
> above when you need a persisted run record (recommended for approved releases).

> `-AllowUntrustedCapture` / `-AllowUnarchivedCapture` exist **only** for
> isolated local tests and must never be used for an approved release.

---

## 5. Verify files against the baseline — `Invoke-Verification.ps1 -Mode VerifyFiles`

**What:** The main check. Compares production files to the approved baseline by
SHA-256, anchored by the SSM-pinned hash. Read-only.
**Where:** The **production target server** for that processor
(`VESEMSEGRESS01/02/03`, `VESEMSINGRESS01/02`, etc. — only the servers that
actually host the processor; see [SERVERS.md](../SERVERS.md)).
**How (baseline from a local manifest):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode VerifyFiles `
 -ReleaseRoot <releaseRoot> `
 -ManifestPath <manifestPath> `
 -TrustParam <trustParam> `
 -Processor <system> `
 -Environment prod `
 -Region <region> `
 -Json
$LASTEXITCODE
```

**How (baseline read back from the Git release tag):**

```powershell
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot <releaseRoot> `
  -BaselineRepo D:\ves-verify -ReleaseTag <releaseTag> `
  -TrustParam <trustParam> -Processor <system>
```

Expected: `0` = match. `1` = drift (`MISSING`/`CHANGED`/`EXTRA`), `2` = trust
failure/baseline unavailable, `10` = bad inputs. Any non-zero: stop and
escalate.

> Other modes of the same script: `-Mode VerifyConfig` (config contract only),
> `-Mode All` (files + config). Config files (`*.config`) are checked by
> contract, not by hash — see §8.

---

## 6. Pre-deploy gate — `Invoke-PreDeployGate.ps1`

**What:** Blocks a deploy that doesn't match the approved release. Checks (1)
staged commit == approved commit, and (2) staged tree hashes to the trusted
manifest (anchored by SSM, the tag, or both).
**Where:** The **staging/deploy box** for the target server, before copying
files.
**How:**

```powershell
.\Invoke-PreDeployGate.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> `
  -ApprovedCommitParam <approvedCommitParam> `
  -BaselineRepo D:\ves-verify -ReleaseTag <releaseTag> `
  -TrustParam <trustParam> -Processor <system>
```

Expected: `0` = pass, `1` = blocked (names the offending files when
`-ManifestPath` is supplied), `2` = SSM/trust error, `10` = usage. With neither
a trust parameter nor a tag source the gate exits `10` rather than passing on
the commit string alone; `-AllowCommitOnly` is the explicit, logged exception.

---

## 7. Deploy a processor — `Deploy-Processor.ps1` (via `processors\Deploy-<system>.ps1`)

**What:** Full deploy pipeline: gate → stop → backup → robocopy → restart →
verify → health. Any stage failing aborts with that stage's exit code.
**Where:** The **target server** hosting that processor. Pilot in **DEV/UAT
egress first** before any PROD use.
**How (dry run — gate only, no copy):**

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> -WhatIf
```

**How (real deploy):**

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha>
```

Each system's thin wrapper in `processors/` pins the fixed per-server values
(`TargetRoot`, `ScheduledTasks`, paths) and calls `Deploy-Processor.ps1`. Copy
`processors/Deploy-SYSTEM_NAME.ps1` to onboard a new system.

**Console-EXE note:** the same `VES.OutboundDBQProcessor.exe` runs 2–3 times per
box from different folders. The deploy stops only the instance whose executable
path is under `TargetRoot`. If an instance holds files open the deploy aborts
unless `-KillProcesses` is set; `-StartTasksAfter` relaunches via the scheduled
task after a clean copy. Pass only the `-ScheduledTasks` that live on **this**
server.

---

## 8. Config contract check — `Verify-Config.ps1`

**What:** Validates a config file against its contract (missing/mismatched/
undeclared keys). Called automatically by verify/deploy; can be run directly.
**Where:** The server holding the config file.
**How:** invoked through `Invoke-Verification.ps1 -Mode VerifyConfig` (or
`-Mode All`). Contract `format` is `appconfig`, `json`, or `keyvalue` (a Java
`application.properties` is `keyvalue`). Secret-bearing keys are compared on
real values but reported as `(masked)`; use `ssmExpectedValues` for secure
comparisons and never embed secrets in the contract. The contract is exhaustive
— every live key must be declared or it is reported as drift. See
[sample.config.json](../sample.config.json) and the
[Verify-Config.ps1](../Verify-Config.ps1) header.

---

## 9. Re-pin a baseline after the exclude-pattern fix

**What:** Baselines captured under the old exclude pattern that had a top-level
`logs\`, `temp\`, `cache\`, or `.git\` folder need re-capture (their hash
changed, breaking the SSM pin → exit 2).
**Where:** UAT approval host.
**How:** run preflight against the targets file (§3); any target reporting a
`manifest-pattern` **WARN** needs re-capture. For each flagged target, repeat
the §4 capture. Baselines with no such directory are unaffected.

---

## 10. Health check — `Invoke-HealthCheck.ps1`

**What:** Proves the deployed processor is alive. Any failure exits `3`. A run
with no probe configured exits `10` (never a false green).
**Where:** The **target server** hosting the processor.
**How (outbound .exe processor — no endpoint):**

```powershell
.\Invoke-HealthCheck.ps1 -Processor <system> `
  -ScheduledTasks VLER_EM_Real_Time_Outbound_Processor `
  -ProcessPathRoot <releaseRoot> `
  -ProcessArgumentPattern '\bRTPDP\b' `
  -FreshLogDir C:\VLER_Test\Logs\VES.OutboundProcessor -FreshLogMaxAgeMinutes 60
```

**How (Java/Spring Boot service — out of scope now, profile retained):**

```powershell
.\Invoke-HealthCheck.ps1 -Processor pagecount `
  -ServiceName oms-vems-pagecount-prod `
  -HealthUrl http://localhost:9191/actuator/health
```

Match on `-ProcessPathRoot` (+ optional `-ProcessArgumentPattern`), not process
name — the same EXE runs several times per box.

---

## 11. Scheduled drift detection — `Start-DriftRunner.ps1` / `Install-DriftTask.ps1`

**What:** Re-verifies every target on a cadence and writes per-target JSONL
logs. `Install-DriftTask.ps1` registers the runner **and** an independent
heartbeat watchdog that exits `2` and alerts if the runner misses its window.
**Where:** Each target server, or a central runner reaching targets over WinRM.
**How (register once, elevated — runs as SYSTEM):**

```powershell
.\Install-DriftTask.ps1 -TargetsFile D:\ves-verify\targets.json `
  -IntervalMinutes 30 -LogDir \\audit-share\ves-verify\logs
```

**How (run the runner by hand):**

```powershell
.\Start-DriftRunner.ps1 -TargetsFile D:\ves-verify\targets.json
```

The runner refuses to run until `targets.json` (`ves.targets.v1` schema) marks
`inventoryComplete=true` with every required server confirmed — including all
Citrix targets.

---

## 12. Missed-run watchdog — `Test-DriftHeartbeat.ps1`

**What:** Independent check that the drift runner completed on time. Exits `2`
and emits an alert on a missing or stale heartbeat.
**Where:** Registered automatically by `Install-DriftTask.ps1`; can be run
manually on the same box.
**How:**

```powershell
.\Test-DriftHeartbeat.ps1
```

The drift runner atomically updates `ves-verify-drift.heartbeat.json`; this
watchdog reads it.

---

## 13. What to record for every run

1. Script name and date/time.
2. `git rev-parse --short HEAD`.
3. `$LASTEXITCODE`.
4. Any `MISSING`, `CHANGED`, or `EXTRA` lines.
5. JSONL log path if `-LogFile` was passed (deploys and drift runs log by
   default under `%ProgramData%\ves-verify\logs` or the `VES_AUDIT_LOG_DIR`
   central share; verification scripts log only when `-LogFile` is given).

Never copy passwords, tokens, connection strings, or raw SSM secret values into
the record.

---

## 14. Escalation packet (any non-zero exit)

1. Script name and exact command used (sanitized).
2. Date/time and server/workstation name.
3. Commit hash.
4. Exit code.
5. Full list of `MISSING` / `CHANGED` / `EXTRA` lines.
6. JSONL log file path (if `-LogFile` was passed).
7. Screenshot of the final output section.

---

## 15. Sign-off block

- Tester:
- Repository maintainer:
- Release owner:
- Server owner (production):
- Date:
- Final result (`PASS` / `FAIL`):

---

## Quick reference — script, where, verdict

| Step              | Script                                         | Runs on                 | Pass       |
| ----------------- | ---------------------------------------------- | ----------------------- | ---------- |
| Gate logic        | `Invoke-Tests.ps1`                             | Workstation             | `0`        |
| Readiness         | `Invoke-Preflight.ps1`                         | Any run box             | `0`        |
| Capture baseline  | `Invoke-Verification.ps1 -Mode Capture`        | UAT approval host       | `0`        |
| Verify files      | `Invoke-Verification.ps1 -Mode VerifyFiles`    | PROD target server      | `0`        |
| Pre-deploy gate   | `Invoke-PreDeployGate.ps1`                     | Staging/deploy box      | `0`        |
| Deploy            | `processors\Deploy-<system>.ps1`               | Target server           | `0`        |
| Config            | `Verify-Config.ps1` (via `-Mode VerifyConfig`) | Server with config      | `0`        |
| Health            | `Invoke-HealthCheck.ps1`                       | Target server           | `0`        |
| Drift (manual)    | `Start-DriftRunner.ps1`                        | Target / central runner | `0`        |
| Drift (scheduled) | `Install-DriftTask.ps1`                        | Target / central runner | registered |
| Watchdog          | `Test-DriftHeartbeat.ps1`                      | Same box as runner      | `0`        |
