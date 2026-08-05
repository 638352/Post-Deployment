# Non-Technical Runbook: How to Run the Post-Deployment Scripts

This guide is for testers and operators who are not deeply technical.
It explains **what to run**, **where to run it**, and **how to run it** in clear, simple language.

For detailed technical guidance, use [RUNBOOK.md](RUNBOOK.md).

> **Changed 2026-08-05:** approved releases are now recorded in a **release archive** (a Git repo of tagged releases). The old AWS/SSM values (`-TrustParam`, `-ApprovedCommitParam`, `-Region`) no longer exist; the scripts take `-ArchiveRepo`/`-BaselineRepo` and `-ReleaseTag` instead.

---

## 1) What this process does

You are confirming that:

1. The script suite is healthy.
2. The approved UAT release was recorded in the release archive correctly.
3. Production files match what UAT approved.
4. Health checks pass after deployment.

The release archive is the source of truth for what was approved. Its safety rests on one simple rule: only authorized people may move release tags in that archive. If anything fails, stop and escalate.

---

## 2) Before you start (yes/no checklist)

Check each item before running anything:

- [ ] I am using **Windows PowerShell 5.1** (not PowerShell 7).
- [ ] I am on the **correct machine** for this step (workstation, UAT host, or PROD server).
- [ ] I know where the repo is on this machine (example: `D:\ves-verify`).
- [ ] I know where the **release archive** is on this machine (the folder that holds approved releases).
- [ ] I have the required values (processor name, manifest path, release tag).
- [ ] Required approvers are present for UAT capture or production actions.

---

## 3) Where each script is run

| Script                                       | Where to run it                                    | Why                                                  |
| -------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------- |
| `Invoke-Tests.ps1`                           | Tester workstation                                 | Make sure script logic is healthy first              |
| `Invoke-Preflight.ps1`                       | The machine where you will run verification/deploy | Check PowerShell, the release archive, and baseline readiness |
| `Invoke-Verification.ps1 -Mode Capture`      | UAT approval host                                  | Save and lock approved UAT baseline                  |
| `Invoke-Verification.ps1 -Mode VerifyFiles`  | Production target server                           | Check production files match approved baseline       |
| `Invoke-Verification.ps1 -Mode VerifyConfig` | Production target server                           | Check config values are valid                        |
| `Invoke-HealthCheck.ps1`                     | Production target server                           | Confirm app/process is healthy                       |
| `Invoke-PreDeployGate.ps1`                   | Staging/deploy machine                             | Block unsafe deployment                              |
| `processors\Deploy-<system>.ps1`             | Production target server                           | Perform controlled deploy                            |
| `Start-DriftRunner.ps1`                      | Ops runner or target server                        | Repeat drift checks on schedule                      |
| `Install-DriftTask.ps1`                      | Ops runner or target server (admin)                | Register scheduled checks                            |
| `Test-DriftHeartbeat.ps1`                    | Same machine as drift runner                       | Confirm scheduled drift checks are still running     |

---

## 4) Step-by-step (normal tester flow)

Follow these steps in order.

### Step A — Open PowerShell and go to repo

**Where:** current machine for this step.

```powershell
Set-Location '<path-to-repo-on-this-machine>'
# Example: D:\ves-verify
```

Then confirm PowerShell version:

```powershell
$PSVersionTable.PSVersion
```

Success means Major version is `5`.

---

### Step B — Run unit tests first

**Where:** tester workstation.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

Success means exit code is `0`.

If not `0`: stop and escalate.

---

### Step C — Run preflight readiness check

**Where:** the machine that will run verification/deploy.

```powershell
.\Invoke-Preflight.ps1 -Processor <system> `
  -ManifestPath <manifestPath> `
  -BaselineRepo <releaseArchivePath> `
  -ReleaseTag <releaseTag>
$LASTEXITCODE
```

Success means exit code is `0`.

If not `0`: stop and fix access/paths before moving on.

Note: if the manifest is not yet recorded in the release archive, preflight will show a warning ("NOT anchored") but still pass. If the release archive is named but cannot be read, preflight fails with exit code `2` — stop and escalate.

---

### Step D — Capture approved UAT baseline (approval required)

**Where:** UAT approval host.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode Capture `
 -ReleaseRoot <releaseRoot> `
 -ManifestPath <manifestPath> `
 -ArchiveRepo <releaseArchivePath> `
 -ReleaseTag <releaseTag> `
 -Processor <system> `
 -CommitSha (git rev-parse HEAD) `
 -Environment uat `
 -PushRemote `
 -Json
$LASTEXITCODE
```

Success means exit code is `0`.

Notes:

- `-CommitSha` must be a real commit id. The script refuses an empty or placeholder value (exit code `10`).
- `-PushRemote` shares the release record with the team's copy of the archive. Leave it off only if the archive has no remote.
- Recording the release under its tag **is** the approval step — there is no separate "pin" or "activate" step afterward.

If not `0`: stop and escalate.

---

### Step E — Verify production files against approved baseline

**Where:** production target server.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode VerifyFiles `
 -ReleaseRoot <releaseRoot> `
 -BaselineRepo <releaseArchivePath> `
 -ReleaseTag <releaseTag> `
 -Processor <system> `
 -Environment prod `
 -Json
$LASTEXITCODE
```

Success means:

- Exit code `0`
- No `MISSING`, `CHANGED`, or `EXTRA` entries

The check reads the approved baseline out of the release archive using the release tag. Do not skip the archive: a check that compares production only against a local manifest file proves the two files agree with each other, not that the release was approved.

If not `0`: stop and escalate with logs.

---

### Step F — Verify config (if in scope)

**Where:** production target server.

```powershell
.\Invoke-Verification.ps1 -Mode VerifyConfig -Processor <system> `
  -ConfigContract <contractPath> `
  -ConfigPath <configPath>
$LASTEXITCODE
```

Success means exit code `0`.

If not `0`: stop and escalate. If the failure message says the contract contains unverifiable keys (`ssmExpectedValues`), the contract file itself needs fixing — ask the contract author to move those keys to `expectedValues` or remove them.

---

### Step G — Run health check after deploy/verify

**Where:** production target server.

```powershell
.\Invoke-HealthCheck.ps1 -Processor <system> `
  -ScheduledTasks <taskName> `
  -ProcessPathRoot <releaseRoot> `
  -FreshLogDir <logDir>
$LASTEXITCODE
```

Success means exit code `0`.

If exit code is `3`: health failed — escalate immediately.

---

## 5) Optional deployment steps

Use these only during an approved change window.

1. Pre-deploy gate on staging/deploy machine:

```powershell
.\Invoke-PreDeployGate.ps1 -StagedRoot <stagedRoot> -StagedCommit <sha> `
  -BaselineRepo <releaseArchivePath> -ReleaseTag <releaseTag> `
  -Processor <system>
$LASTEXITCODE
```

The gate reads the approved release out of the archive using the tag; both `-BaselineRepo` and `-ReleaseTag` are required (exit code `10` without them).

2. Dry-run deploy first on target server:

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot <stagedRoot> -StagedCommit <sha> `
  -ReleaseTag <releaseTag> -BaselineRepo <releaseArchivePath> -WhatIf
$LASTEXITCODE
```

3. Real deploy on target server:

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot <stagedRoot> -StagedCommit <sha> `
  -ReleaseTag <releaseTag> -BaselineRepo <releaseArchivePath>
$LASTEXITCODE
```

---

## 6) Exit code quick help

| Exit Code | Plain meaning                                      | What to do                             |
| --------: | -------------------------------------------------- | -------------------------------------- |
|       `0` | Success                                            | Record result and continue             |
|       `1` | Files/config do not match approved baseline        | Stop and escalate                      |
|       `2` | Approved-release record missing or unreadable (release archive/path/access) | Stop, validate inputs/access, escalate |
|       `3` | Health check failed                                | Stop and escalate immediately          |
|      `10` | Invalid or unsafe usage/input                      | Correct command inputs and rerun       |

---

## 7) What to record for sign-off

For every step, record:

- Date/time
- Server name
- Script name
- Commit (`git rev-parse --short HEAD`)
- Exit code
- Log file path (verification scripts write one only when `-LogFile` is used)

Keep secrets out of notes and screenshots.

---

## 8) Escalation packet (send this when a step fails)

Include:

1. Script and command used
2. Machine/server name
3. Date/time
4. Exit code
5. Output lines showing failures (`MISSING`, `CHANGED`, `EXTRA`, or health errors)
6. Log file path (if one was written)

---

## 9) Related guides

- Technical deep-dive runbook: [RUNBOOK.md](RUNBOOK.md)
- Server/path reference: [SERVERS.md](../SERVERS.md)
- Full behavior and trust model: [README.md](../README.md)
