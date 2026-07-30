# Non-Technical Runbook: How to Run the Post-Deployment Scripts

This guide is for testers and operators who are not deeply technical.
It explains **what to run**, **where to run it**, and **how to run it** in clear, simple language.

For detailed technical guidance, use [RUNBOOK.md](RUNBOOK.md).

---

## 1) What this process does

You are confirming that:

1. The script suite is healthy.
2. The approved UAT release was captured correctly.
3. Production files match what UAT approved.
4. Health checks pass after deployment.

If anything fails, stop and escalate.

---

## 2) Before you start (yes/no checklist)

Check each item before running anything:

- [ ] I am using **Windows PowerShell 5.1** (not PowerShell 7).
- [ ] I am on the **correct machine** for this step (workstation, UAT host, or PROD server).
- [ ] I know where the repo is on this machine (example: `D:\ves-verify`).
- [ ] I have the required values (processor name, manifest path, SSM paths, release tag, region).
- [ ] Required approvers are present for UAT capture or production actions.

---

## 3) Where each script is run

| Script                                       | Where to run it                                    | Why                                                  |
| -------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------- |
| `Invoke-Tests.ps1`                           | Tester workstation                                 | Make sure script logic is healthy first              |
| `Invoke-Preflight.ps1`                       | The machine where you will run verification/deploy | Check PowerShell, AWS access, and baseline readiness |
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
  -ApprovedCommitParam <approvedCommitParam> `
  -TrustParam <trustParam> `
  -ManifestPath <manifestPath>
$LASTEXITCODE
```

Success means exit code is `0`.

If not `0`: stop and fix access/paths before moving on.

---

### Step D — Capture approved UAT baseline (approval required)

**Where:** UAT approval host.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode Capture `
 -ReleaseRoot <releaseRoot> `
 -ManifestPath <manifestPath> `
 -TrustParam <trustParam> `
 -ArchiveRepo <repoRoot> `
 -ReleaseTag <releaseTag> `
 -Processor <system> `
 -CommitSha (git rev-parse HEAD) `
 -Environment uat `
 -Region <region> `
 -Json
$LASTEXITCODE
```

Success means exit code is `0`.

If not `0`: stop and escalate.

---

### Step E — Verify production files against approved baseline

**Where:** production target server.

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

Success means:

- Exit code `0`
- No `MISSING`, `CHANGED`, or `EXTRA` entries

If not `0`: stop and escalate with logs.

---

### Step F — Verify config (if in scope)

**Where:** production target server.

```powershell
.\Invoke-Verification.ps1 -Mode VerifyConfig -Processor <system>
$LASTEXITCODE
```

Success means exit code `0`.

If not `0`: stop and escalate.

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
  -ApprovedCommitParam <approvedCommitParam> `
  -BaselineRepo <repoRoot> -ReleaseTag <releaseTag> `
  -TrustParam <trustParam> -Processor <system>
$LASTEXITCODE
```

2. Dry-run deploy first on target server:

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot <stagedRoot> -StagedCommit <sha> -WhatIf
$LASTEXITCODE
```

3. Real deploy on target server:

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot <stagedRoot> -StagedCommit <sha>
$LASTEXITCODE
```

---

## 6) Exit code quick help

| Exit Code | Plain meaning                                      | What to do                             |
| --------: | -------------------------------------------------- | -------------------------------------- |
|       `0` | Success                                            | Record result and continue             |
|       `1` | Files/config do not match approved baseline        | Stop and escalate                      |
|       `2` | Trust/access/runtime issue (often SSM/path/access) | Stop, validate inputs/access, escalate |
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
- Log file path

Keep secrets out of notes and screenshots.

---

## 8) Escalation packet (send this when a step fails)

Include:

1. Script and command used
2. Machine/server name
3. Date/time
4. Exit code
5. Output lines showing failures (`MISSING`, `CHANGED`, `EXTRA`, or health errors)
6. Log file path

---

## 9) Related guides

- Technical deep-dive runbook: [RUNBOOK.md](RUNBOOK.md)
- Server/path reference: [SERVERS.md](../SERVERS.md)
- Full behavior and trust model: [README.md](../README.md)
