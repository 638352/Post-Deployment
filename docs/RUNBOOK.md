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

> **Changed 2026-08-05:** the trust anchor is the Git baseline archive — the
> release tag and the manifest committed under it. The former SSM parameters
> (`-TrustParam`, `-ApprovedCommitParam`, `-Region`) and every AWS CLI step are
> gone; there is no separate "pin" step, because committing and tagging the
> release record **is** the activation. Procedures below reflect that anchor.

---

## 0. Conventions used in this runbook

| Placeholder                | Meaning                                             | Example                                                  |
| -------------------------- | --------------------------------------------------- | -------------------------------------------------------- |
| `<REPO_ROOT>`              | Where this suite is installed on the box you are on | `D:\ves-verify`                                          |
| `<system>` / `<processor>` | The processor name                                  | `OutboundDBQ`                                            |
| `<releaseRoot>`            | Folder holding the approved/target files            | `C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` |
| `<manifestPath>`           | Baseline manifest JSON                              | `D:\baselines\OutboundDBQ.json`                          |
| `<baselineRepo>`           | Git checkout of the baseline archive (trust anchor) | `D:\ves-verify`                                          |
| `<releaseTag>`             | `<system>/vMAJOR.MINOR.PATCH`                       | `OutboundDBQ/v1.4.0`                                     |

**Fixed install location on servers:** `D:\ves-verify`. On a tester's own
workstation, substitute the path where the repo was cloned.

**The trust anchor:** capture commits the manifest under
`baselines\<processor>\` in `<baselineRepo>` and tags the commit
`<releaseTag>`. The tag **is** the anchor — every later verify, gate, and
deploy reads the approved baseline (and the approved commit) back out of that
tag. The strength of this control is exactly the strength of tag protection on
the archive remote: whoever can move a release tag can author their own
approval, so restrict that permission deliberately (see §1.1).

### Exit codes (the verdict for every run)

| Code | Meaning                                      | Action              |
| ---: | -------------------------------------------- | ------------------- |
|  `0` | PASS — match / healthy / ready               | Record and continue |
|  `1` | FAIL — file or config drift                  | Stop, escalate      |
|  `2` | ERROR — anchor / inventory / runtime failure | Stop, escalate      |
|  `3` | FAIL — health probe failed                   | Stop, escalate      |
| `10` | ERROR — usage / unsafe configuration         | Fix inputs, rerun   |

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

5. For any step that anchors against the approved release (preflight, capture,
   verify, gate, deploy, drift), confirm `git` is on the PATH and the baseline
   archive checkout `<baselineRepo>` is present on this box — and its remote is
   reachable when the step pushes.
6. Keep the same PowerShell window open for the whole session.

**Approval gates:** capture requires the release owner present; production
verify/deploy requires release owner **and** server owner plus a formal change
window.

### 1.1 First-time setup — stand up the baseline archive

Do this **once** per environment, before the first capture. Everything else in
this runbook assumes the archive exists.

1. **Create (or clone) the baseline archive repo** at `<baselineRepo>`. It must
   be a real Git checkout (contains `.git`); capture writes the release record
   under `baselines\<processor>\` and refuses to run against anything else.

   ```powershell
   git clone <archive-remote-url> <baselineRepo>   # or: git init <baselineRepo>
   ```

2. **Decide and enforce who may move release tags** on the archive remote.
   This is the whole control: the tag is the trust anchor, and a deployer who
   can force-push a tag can approve their own release. Restrict tag
   creation/force-push to the release owner role before the first real capture.
3. **Run the first anchored capture** (§4) with `-ArchiveRepo <baselineRepo>`,
   `-ReleaseTag <releaseTag>`, and a real `-CommitSha`. Add `-PushRemote` when
   a remote exists — a release record that lives on one workstation is not an
   audit trail.

There is no further activation step: once the capture has committed and tagged
the record, that release **is** the approved baseline.

---

## 2. Workstation gate — `Invoke-Tests.ps1`

**What:** Runs the Pester suite (103 tests) so the logic is proven before
touching any server.
**Where:** Developer/tester **workstation**.
**How:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

Expected: `0`. If not `0`, **stop** — do not proceed to any server.

---

## 3. Readiness self-check — `Invoke-Preflight.ps1`

**What:** Read-only. Confirms the host runs Windows PowerShell 5.1, the
baseline manifest is intact and agrees with the copy archived under the release
tag, and the config contract parses. In `-TargetsFile` mode it also validates
the server inventory. Touches no prod or staged files.
**Where:** Any box that will run a capture, verify, gate, or deploy — run it
there first.
**How (single processor, anchored to the approved release):**

```powershell
.\Invoke-Preflight.ps1 -Processor <system> `
  -ManifestPath <manifestPath> `
  -BaselineRepo <baselineRepo> -ReleaseTag <releaseTag>
```

**How (validate every drift target at once):**

```powershell
.\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json `
  -BaselineRepo <baselineRepo>
```

In targets mode each target anchors against its own `releaseTag` from
`targets.json`.

Expected: `0` = ready, `2` = not ready, `10` = usage. Read the per-check lines:

- A manifest with **no** anchor configured reports **WARN "NOT anchored"** —
  it does not block readiness, but self-consistency is not tamper evidence, so
  supply `-BaselineRepo`/`-ReleaseTag` for a provable check.
- A **configured** anchor that cannot be read (missing tag, unreadable archive,
  or a local manifest that disagrees with the archived one) is a hard **FAIL**,
  exit `2`.
- A `manifest-pattern` **WARN** does not block readiness but flags a baseline
  that needs re-capture (see §9).

---

## 4. Capture the approved baseline — `Invoke-Verification.ps1 -Mode Capture`

**What:** Creates the approved UAT file baseline (manifest), commits it to the
baseline archive under a Git release tag, and writes `release-record.json`.
Tagging the record **is** the approval — there is no separate pin or
activation step, and the `commitSha` recorded in the manifest becomes the
approved commit the pre-deploy gate enforces.
**Where:** **UAT approval host** (e.g. `VESMSEGRESSUAT`), release owner present,
at sign-off.
**How:**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode Capture `
 -ReleaseRoot <releaseRoot> `
 -ManifestPath <manifestPath> `
 -ArchiveRepo <baselineRepo> `
 -ReleaseTag <releaseTag> `
 -Processor <system> `
 -CommitSha (git rev-parse HEAD) `
 -Environment uat `
 -Json
$LASTEXITCODE
```

Expected: `0`. `-ArchiveRepo` and `-ReleaseTag` are **required** — capture
fails closed (exit `10`) if either is missing. `-ReleaseTag` must match
`<system>/vMAJOR.MINOR.PATCH`. `-CommitSha` must be a **real** commit — an
empty or `unknown` value is refused (exit `10`), because that sha is what the
gate later accepts as the approved commit. Add `-PushRemote` to push the
commit and tag off-host immediately (a failed push fails the capture).

Record from output: release tag, manifest path, manifest hash, JSONL log path.

> JSONL logging is opt-in for this script: add `-LogFile <path>` to the command
> above when you need a persisted run record (recommended for approved releases).

> `-AllowUnarchivedCapture` exists **only** for isolated local tests: it skips
> the Git archive entirely, which produces a baseline no gate can ever accept.
> Never use it for an approved release.

---

## 5. Verify files against the baseline — `Invoke-Verification.ps1 -Mode VerifyFiles`

**What:** The main check. Compares production files to the approved baseline by
SHA-256, anchored by the manifest read back out of the Git release tag.
Read-only.
**Where:** The **production target server** for that processor
(`VESEMSEGRESS01/02/03`, `VESEMSINGRESS01/02`, etc. — only the servers that
actually host the processor; see [SERVERS.md](../SERVERS.md)).
**How (anchored — this is the release-evidence form):**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode VerifyFiles `
 -ReleaseRoot <releaseRoot> `
 -BaselineRepo <baselineRepo> `
 -ReleaseTag <releaseTag> `
 -Processor <system> `
 -Environment prod `
 -Json
$LASTEXITCODE
```

Expected: `0` = match. `1` = drift (`MISSING`/`CHANGED`/`EXTRA`), `2` = anchor
failure/baseline unavailable, `10` = bad inputs. Any non-zero: stop and
escalate.

**How (local drift scan only — not release evidence):** without an anchor the
verify exits `2` rather than passing. To compare against a local manifest file
anyway, opt in explicitly:

```powershell
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot <releaseRoot> `
  -ManifestPath <manifestPath> -AllowUnanchoredVerify -Processor <system>
```

`-AllowUnanchoredVerify` is loudly logged. A pass here proves only that the
tree matches that manifest file — the manifest sits next to the tree it
describes, so an edit that rewrote both is undetectable. Use it as a local
drift-scan tool, **never** as evidence that production matches the approved
release.

> Other modes of the same script: `-Mode VerifyConfig` (config contract only),
> `-Mode All` (files + config). Config files (`*.config`) are checked by
> contract, not by hash — see §8.

---

## 6. Pre-deploy gate — `Invoke-PreDeployGate.ps1`

**What:** Blocks a deploy that doesn't match the approved release. Checks (1)
staged commit == the `commitSha` recorded in the tag-archived manifest, and (2)
staged tree hashes to that same archived manifest. Both checks rest on the one
anchor: the release tag.
**Where:** The **staging/deploy box** for the target server, before copying
files.
**How:**

```powershell
.\Invoke-PreDeployGate.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> `
  -BaselineRepo <baselineRepo> -ReleaseTag <releaseTag> -Processor <system>
```

Expected: `0` = pass, `1` = blocked (names the offending files when
`-ManifestPath` is supplied), `2` = anchor unreadable/untrustworthy, `10` =
usage. `-BaselineRepo` and `-ReleaseTag` are **required**: without them (or
with a malformed tag) the gate exits `10` — there is no commit-only mode,
because without the archive there is no approved commit to compare against
either.

> Break-glass: `-AllowOverride` with a mandatory `-OverrideReason` turns a
> block into an audited pass (an `OVERRIDE ENGAGED` line records who/why/when).
> Whether break-glass is permitted at all is an open policy decision;
> `Deploy-Processor.ps1` does not pass it.

---

## 7. Deploy a processor — `Deploy-Processor.ps1` (via `processors\Deploy-<system>.ps1`)

**What:** Full deploy pipeline: gate → stop → backup → robocopy → restart →
verify → health. Any stage failing aborts with that stage's exit code.
**Where:** The **target server** hosting that processor. Pilot in **DEV/UAT
egress first** before any PROD use.
**How (dry run — gate only, no copy):**

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> `
  -ReleaseTag <releaseTag> -BaselineRepo <baselineRepo> -WhatIf
```

**How (real deploy):**

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> `
  -ReleaseTag <releaseTag> -BaselineRepo <baselineRepo>
```

`-ReleaseTag` and `-BaselineRepo` are **mandatory** on the wrappers and
required by `Deploy-Processor.ps1` itself (exit `10` without them) — there is
no unanchored deploy. Deploy mode uses the staged-release parameters
(`-StagedRoot`, `-StagedCommit`, `-ReleaseTag`, `-BaselineRepo`,
`-ManifestPath`) and does not use rollback-only parameters.

With `-BackupRoot` set (the wrappers set it), the pre-copy backup is the
restore point, recorded by a `rollback-record.json` sidecar naming what it
replaced — including the `baselineRepo` and the `incomingManifestHash` of the
release that overwrote it.

Each system's thin wrapper in `processors/` pins the fixed per-server values
(`TargetRoot`, `ScheduledTasks`, paths) and calls `Deploy-Processor.ps1`. Copy
`processors/Deploy-SYSTEM_NAME.ps1` to onboard a new system.

**Console-EXE note:** the same `VES.OutboundDBQProcessor.exe` runs 2–3 times per
box from different folders. The deploy stops only the instance whose executable
path is under `TargetRoot`. If an instance holds files open the deploy aborts
unless `-KillProcesses` is set; `-StartTasksAfter` relaunches via the scheduled
task after a clean copy. Pass only the `-ScheduledTasks` that live on **this**
server.

### 7.1 Roll back a deploy — `Invoke-Rollback.ps1`

**What:** Restores the processor from a dated deploy backup, then **proves**
the restore by re-running verification and the health check. `-Reason` is
required and audited.
**Where:** The **target server** that was deployed to.
**How (list the restore points first):**

```powershell
.\Invoke-Rollback.ps1 -Processor <system> -BackupRoot <backupRoot> -ListBackups
```

**How (restore, proven against the prior release):**

```powershell
.\Invoke-Rollback.ps1 -Processor <system> -TargetRoot <releaseRoot> `
  -BackupRoot <backupRoot> -Reason 'VEMS-1234 bad release' `
  -BaselineRepo <baselineRepo> -ReleaseTag <priorReleaseTag>
```

Here `-ReleaseTag` names the release being **restored** — the prior one — not
the release you are backing out. Exit codes: `0` restored and proven, `1`
restored but the post-rollback verify drifted, `2` restore not proven, `3`
restored but unhealthy, `10` usage.

**After a proven restore, one manual step remains.** The run ends with an
**ATTESTATION** naming the restored release — but the archive still marks the
rolled-back release as approved. **Re-point the approved release tag by hand**
(release owner, on the archive remote) before the next deploy, or the gate will
compare against the release you just removed. Nothing automated ever moves a
tag; that is deliberate — moving a tag is an approval decision.

> `Deploy-Processor.ps1 -Rollback` (with `-RollbackReason`, and
> `-RollbackReleaseTag`/`-RollbackManifestPath` to name the prior release) is a
> thin alias for the same script; `-AutoRollback` restores automatically when a
> deploy's own verify or health stage fails, and the same attestation and
> manual tag re-point apply.

---

## 8. Config contract check — `Verify-Config.ps1`

**What:** Validates a config file against its contract (missing/mismatched/
undeclared keys). Called automatically by verify/deploy; can be run directly.
**Where:** The server holding the config file.
**How:** invoked through `Invoke-Verification.ps1 -Mode VerifyConfig` (or
`-Mode All`). Contract `format` is `appconfig`, `json`, or `keyvalue` (a Java
`application.properties` is `keyvalue`). Sensitive keys are compared on real
values but reported as `(masked)`; never embed a secret value in the contract —
declare secrets under `requiredKeys` (presence-only) or `machineKeys` instead.
The contract is exhaustive — every live key must be declared or it is reported
as drift. See [sample.config.json](../sample.config.json) and the
[Verify-Config.ps1](../Verify-Config.ps1) header.

> **Contract authors:** a contract that declares `ssmExpectedValues` now
> **fails loudly as unverifiable** — there is no Parameter Store in this
> environment, so those values cannot be checked, and skipping them silently
> would make those keys invisible to every check. Move each such key to
> `expectedValues` (non-secret values only) or remove it and cover the setting
> another way. Do not leave it declared and unchecked.

---

## 9. Re-capture a baseline after the exclude-pattern fix

**What:** Baselines captured under the old exclude pattern that had a top-level
`logs\`, `temp\`, `cache\`, or `.git\` folder need re-capture (their hash
changed, so they no longer agree with the tag-archived record → exit 2).
**Where:** UAT approval host.
**How:** run preflight against the targets file (§3); any target reporting a
`manifest-pattern` **WARN** needs re-capture. For each flagged target, repeat
the §4 capture under a new release tag. Baselines with no such directory are
unaffected.

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
  -BaselineRepo <baselineRepo> `
  -IntervalMinutes 30 -LogDir \\audit-share\ves-verify\logs
```

**How (run the runner by hand):**

```powershell
.\Start-DriftRunner.ps1 -TargetsFile D:\ves-verify\targets.json `
  -BaselineRepo <baselineRepo>
```

Each target anchors against its own `releaseTag` from `targets.json`
(`releaseTag` is a required field of the `ves.targets.v1` schema). A target
that cannot be anchored — no `-BaselineRepo`, or a placeholder `releaseTag` —
is checked against its local manifest only and gets a loud **UNANCHORED**
WARN in the run log: that mode catches accidental drift but not a deliberate
edit that rewrote both sides.

The runner refuses to run until `targets.json` marks `inventoryComplete=true`
with every required server confirmed — including all Citrix targets.

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

Never copy passwords, tokens, connection strings, or other raw secret values
into the record.

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
| Rollback          | `Invoke-Rollback.ps1`                          | Target server           | `0` + tag re-point |
| Config            | `Verify-Config.ps1` (via `-Mode VerifyConfig`) | Server with config      | `0`        |
| Health            | `Invoke-HealthCheck.ps1`                       | Target server           | `0`        |
| Drift (manual)    | `Start-DriftRunner.ps1`                        | Target / central runner | `0`        |
| Drift (scheduled) | `Install-DriftTask.ps1`                        | Target / central runner | registered |
| Watchdog          | `Test-DriftHeartbeat.ps1`                      | Same box as runner      | `0`        |
