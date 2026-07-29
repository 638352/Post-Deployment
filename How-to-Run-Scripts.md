# How to run these scripts (simple runbook)

This is a **plain-language** guide for people who are not developers.

It answers three questions only:

1. **What** each step does  
2. **Where** you run it (which computer / server)  
3. **How** you run it (what to open, what to type, what “pass” looks like)

> **Note:** This document does **not** replace the detailed technical guides.  
> - For full technical steps: [SCRIPT-TESTING-GUIDE.md](SCRIPT-TESTING-GUIDE.md)  
> - For deep product detail: [README.md](README.md)  
> - For server names and folders: [SERVERS.md](SERVERS.md)

---

## What this tool is for (in one sentence)

These scripts check that the software files on a server still match the version
that was approved in UAT (test), and that the program still looks healthy.

---

## Golden rules (read before anything else)

1. **Only use Windows PowerShell 5.1** — not “PowerShell 7” or other terminals.  
2. **A pass is only the number 0.** Any other number means stop.  
3. **If a blank is still filled with `REPLACE` or `TBD`, stop.** Get the real
   value from your release owner or server owner first.  
4. **Do not run production steps without permission** and a scheduled change
   window.  
5. **Never paste passwords, keys, or secret values** into tickets, email, or
   chat.  
6. **If you are unsure, stop and ask.** That is always the correct action.

---

## Who does what

| Role | When they are needed |
|---|---|
| **You (tester / operator)** | Run the steps, record results, stop on failure |
| **Release owner** | Must be present for UAT baseline capture; helps on production checks |
| **Server owner** | Must approve / support production runs |
| **Repository maintainer / tech lead** | Helps if automated tests fail or commands are unclear |

---

## Where things run (map)

Think of three places. You will move between them in order.

| Place | What kind of computer | What happens there |
|---|---|---|
| **A. Your workstation** | Your normal work PC | Practice / automated tests only — does not change servers |
| **B. UAT server** | Test environment box (for outbound processors, often `VESMSEGRESSUAT`) | Create the official “approved” snapshot after UAT sign-off |
| **C. Target / production server** | The live (or target) box for that system | Compare files, check config, check health |

**Typical path for one release check:**

```
Workstation (A)  →  UAT (B)  →  Target server (C)
   tests OK          save baseline     prove match + health
```

You usually need a **remote desktop (RDP)** session to UAT and production
servers. Use the access method your organization already approved.

---

## What “success” and “failure” mean

After every command, look at the **exit number** (also called exit code).

In PowerShell, type this right after the script finishes:

```powershell
$LASTEXITCODE
```

| Number | Plain meaning | What you do |
| ---: |---|---|
| **0** | Pass — everything checked out | Write it down; continue to the next step |
| **1** | Fail — files or settings do not match | **Stop.** Escalate. |
| **2** | Error — could not trust or reach the baseline / cloud check | **Stop.** Escalate. |
| **3** | Fail — program did not look healthy | **Stop.** Escalate. |
| **10** | Error — command was incomplete or unsafe | Fix the filled-in values with your lead, then try again |

**Only 0 means pass.**

---

## Before you start: fill this form

Do **not** invent folder names. Ask the release owner or use the official
deployment runbook / [SERVERS.md](SERVERS.md).

| # | What you need | Who usually has it | Write it here |
|---|---|---|---|
| 1 | Name of the system / processor | Release owner | |
| 2 | Folder of the **approved UAT** files | Release owner | |
| 3 | Folder of the **target / production** files | Server owner | |
| 4 | Path to the baseline file (ends in `.json`) | Release owner | |
| 5 | Cloud trust parameter name (starts with `/ves/…`) | Release owner / cloud contact | |
| 6 | Release tag (looks like `Name/v1.4.0`) | Release owner | |
| 7 | Approved commit or label text | Release owner | |
| 8 | Cloud region (e.g. `us-gov-west-1` or `us-gov-east-1`) | Cloud / ops contact | |
| 9 | Where the scripts are installed on the server (often `D:\ves-verify`) | Server owner | |
| 10 | Change ticket / authorization number (for production) | Change management | |

If any box for the step you are about to run is empty → **stop**.

---

## How to open the right window (every machine)

Do this at the start on **every** computer you use for this work.

### Step A — Open the correct PowerShell

1. On the Windows Start menu, search for **Windows PowerShell**.  
2. Open **Windows PowerShell** (not “PowerShell 7”, not “ISE” unless your lead
   says otherwise).  
3. You should see a blue or black window that accepts typed commands.

### Step B — Go to the script folder

Type the path your lead gave you, then press Enter.

**On many servers:**

```powershell
Set-Location 'D:\ves-verify'
```

**On a personal workstation**, use the folder where this project was copied,
for example:

```powershell
Set-Location 'C:\Users\howardr01\Post-Deployment'
```

### Step C — Confirm PowerShell version

```powershell
$PSVersionTable.PSVersion
```

The first number (Major) should be **5**.  
If it is **7**, close the window and open Windows PowerShell 5.1 instead.

### Step D — Write down the version stamp (optional but recommended)

```powershell
git rev-parse --short HEAD
```

Copy that short code into your test notes.

---

# Main path (do these in order)

These are the steps most testers use to validate a release.

---

## Step 1 — Automated check on your PC (optional but recommended)

| | |
|---|---|
| **Where** | Your **workstation** only — not production |
| **What** | Confirms the checking tools themselves still work |
| **Script** | `Invoke-Tests.ps1` |
| **Risk** | Safe — does not change servers |

### How

1. Open PowerShell and go to the project folder (see above).  
2. Copy and paste this, then press Enter:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

### What good looks like

- The window shows tests running.  
- The last number printed is **`0`**.

### If it is not 0

**Stop.** Contact the repository maintainer. Do not go to UAT or production.

---

## Step 2 — Readiness check (“are we set up correctly?”)

| | |
|---|---|
| **Where** | UAT or the machine that can reach cloud parameters and the baseline file |
| **What** | Confirms cloud access and baseline files are ready — **does not change** application files |
| **Script** | `Invoke-Preflight.ps1` |
| **Risk** | Safe (read-only) |

### How

1. Get the filled-in command from your release owner, **or** use the pattern
   below and replace every `REPLACE_…` with real values.  
2. Run:

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

### What good looks like

- Exit code **`0`** (“ready”).

### If it is not 0

**Stop.** Usually this means login, region, or file path is wrong. Escalate to
the release owner or cloud contact. Do not capture a baseline yet.

---

## Step 3 — Save the official UAT baseline (after UAT is approved)

| | |
|---|---|
| **Where** | **UAT** server / UAT approval host |
| **What** | Takes a fingerprint of the approved files and stores a trusted record |
| **Script** | `Invoke-Verification.ps1` with mode **Capture** |
| **Risk** | Writes the baseline record (and related trust data) — release owner must be present |
| **When** | Only after UAT sign-off is complete |

### How

1. Confirm the **release owner is with you** (in person or on a call).  
2. Confirm UAT was signed off.  
3. Run the capture command your owner provides (pattern below):

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

### What good looks like

- Exit code **`0`**.  
- You can write down: release tag, baseline file path, and any log path shown
  on screen.

### If it is not 0

**Stop.** Do not proceed to production comparison.

### What you must write down from this step

- Date and time  
- Server name  
- Release tag  
- Baseline file path  
- Exit code  
- Path to the log file if shown  

---

## Step 4 — Compare the target server files to the UAT baseline

| | |
|---|---|
| **Where** | The **target / production** server for that system (or the approved runner that can see those folders) |
| **What** | Checks that live files still match the approved UAT snapshot |
| **Script** | `Invoke-Verification.ps1` with mode **VerifyFiles** |
| **Risk** | Safe check (read-only), but production access needs approval |
| **When** | After a deploy, or when validating current production |

### How

1. Confirm you have **change / access authorization** for that server.  
2. Confirm release owner and server owner are aware.  
3. Run:

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

### What good looks like

- Exit code **`0`** — files match.

### If it is not 0

| Number | Plain English |
| ---: |---|
| `1` | Something is missing, changed, or extra compared to UAT |
| `2` | Could not confirm the trusted baseline |
| `10` | The command was incomplete or wrong |

**Stop and escalate.** Attach the command (with secrets removed), exit code,
and any lines that say `MISSING`, `CHANGED`, or `EXTRA`.

---

## Step 5 — Check configuration settings (if your team uses a contract)

| | |
|---|---|
| **Where** | Same **target** server as Step 4 |
| **What** | Checks important settings in config files (paths that are allowed to differ by environment are handled by the contract) |
| **Script** | `Invoke-Verification.ps1` with mode **VerifyConfig** (or **All** for files + config together) |
| **Risk** | Safe check (read-only) |
| **When** | When your release package includes a config contract file |

### How (config only)

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

### What good looks like

- Exit code **`0`**.

### If it is not 0

**Stop and escalate** the same way as Step 4.

If your lead says “we are not using config contracts for this system,” skip
this step and note that in your sign-off form.

---

## Step 6 — Health check (is the program actually running?)

| | |
|---|---|
| **Where** | The **target** server |
| **What** | Confirms the program is running the way operations expects (process, scheduled task, recent log activity, etc.) |
| **Script** | `Invoke-HealthCheck.ps1` |
| **Risk** | Safe check (read-only) |
| **When** | After files (and config, if used) already passed |

### How

Use the exact command your release owner provides for that processor.  
A typical outbound-processor pattern looks like this:

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

### What good looks like

- Exit code **`0`**.

### If it is not 0

- **`3`** means health failed (not running the way it should).  
- **`10`** often means the command was missing required checks.  

**Stop and escalate.**

---

# Optional paths (only if someone assigns them to you)

These are **not** part of the normal “prove the release matches” tester path.
Do them only when ops or change management asks.

---

## Optional A — Trial deploy check (no files copied)

| | |
|---|---|
| **Where** | Usually **UAT** first |
| **What** | Asks “would this deploy be allowed?” without copying files |
| **How** | Run the deploy script with **`-WhatIf`** |
| **Risk** | Low if you use `-WhatIf`; still needs permission |

Example shape (UAT DBQ pilot wrapper):

```powershell
.\processors\Deploy-OutboundDBQ-uat.ps1 `
  -StagedRoot D:\stage\OutboundDBQ `
  -StagedCommit REPLACE_WITH_STAGED_COMMIT `
  -ConfirmedRunbookValues `
  -WhatIf
```

**Expected:** exit code **`0`** for a clean trial.  
If not 0, do **not** run a real deploy.

---

## Optional B — Real deploy (copies files)

| | |
|---|---|
| **Where** | Target server named in the change ticket |
| **What** | Stops the old instance, backs up, copies new files, restarts, then verifies |
| **Risk** | **High** — changes the live system |
| **Required** | Formal change authorization, release owner, server owner |

Only run the real deploy command your lead gives you (without `-WhatIf`).  
If you are not sure whether `-WhatIf` is present, **do not run it**.

---

## Optional C — Drift check (ongoing monitoring)

| | |
|---|---|
| **Where** | Ops runner machine |
| **What** | Re-checks many systems on a schedule |
| **Who** | Usually **operations**, not a one-time tester |
| **Note** | Inventory must be complete before this can claim full coverage |

If asked to run a one-time drift check, ops will give you the exact command.
Typical shape:

```powershell
.\Start-DriftRunner.ps1 -TargetsFile D:\ves-verify\targets.json
```

---

# Which script goes on which machine (quick cheat sheet)

| Script (short name) | Workstation | UAT | Production / target | Safe for beginners? |
|---|:---:|:---:|:---:|---|
| Automated tests (`Invoke-Tests.ps1`) | Yes | No | No | Yes |
| Preflight (`Invoke-Preflight.ps1`) | Sometimes | Yes | Sometimes | Yes (read-only) |
| Capture baseline (`… -Mode Capture`) | No* | **Yes** | No | Only with release owner |
| Compare files (`… -Mode VerifyFiles`) | No* | Yes | **Yes** | Yes with approval |
| Check config (`… -Mode VerifyConfig`) | No* | Yes | **Yes** | Yes with approval |
| Health (`Invoke-HealthCheck.ps1`) | No* | Yes | **Yes** | Yes with approval |
| Deploy trial (`Deploy-… -WhatIf`) | No | Prefer | Only if assigned | Only if assigned |
| Real deploy (`Deploy-…`) | No | Pilot first | Only with change ticket | **No — lead only** |
| Drift runner | No | Ops | Ops | Ops only |

\* Some checks can be run from a central runner if it can see the folders; your
team will tell you if that applies.

---

# What to write down every time (your evidence)

Copy this into a ticket, spreadsheet, or paper log for **each** run:

```
Date / time (include time zone if you know it):
Computer / server name:
Step number (1–6 or optional):
Script name:
Release / processor name:
Release tag:
Authorization / ticket number:
Exit code:
Pass or Fail:
Log file path (if shown):
Any error text (do not include secrets):
Your name:
```

---

# If something fails — what to hand over

Send this package to the release owner or on-call contact:

1. Which step you were on  
2. Server name and date/time  
3. Exit code  
4. The command you ran (**remove any secrets first**)  
5. Screenshot of the end of the PowerShell window  
6. Log file path if the screen printed one  
7. Any lines that say `MISSING`, `CHANGED`, `EXTRA`, or health failure reasons  

Then **wait**. Do not try random different commands.

---

# Final sign-off form

| Field | Fill in |
|---|---|
| Tester name | |
| Date | |
| System / processor | |
| Release tag | |
| Step 1 (workstation tests) result | Pass / Fail / Skipped |
| Step 2 (preflight) result | Pass / Fail / Skipped |
| Step 3 (UAT capture) result | Pass / Fail / Skipped |
| Step 4 (file compare) result | Pass / Fail |
| Step 5 (config) result | Pass / Fail / Not used |
| Step 6 (health) result | Pass / Fail |
| Final overall result | **PASS** only if all required steps were 0 |
| Release owner initials | |
| Server owner initials (prod) | |
| Notes | |

---

# Super-short version (wall chart)

1. Open **Windows PowerShell 5.1**.  
2. Go to the script folder.  
3. On your **PC**, run tests if asked → need **0**.  
4. On **UAT**, run preflight → need **0**.  
5. On **UAT**, with the release owner, capture the baseline → need **0**.  
6. On the **target server**, compare files → need **0**.  
7. If used, check config → need **0**.  
8. Check health → need **0**.  
9. Write down results.  
10. Any number other than **0** = **stop and escalate**.

---

# Helpful tips

- **Copy and paste commands carefully.** One wrong folder name can cause a
  failure that looks scary but is just a typo.  
- **Keep one PowerShell window open** for the whole session.  
- **Do not close the window** until you have copied the exit code and any log
  path.  
- **Ask for a filled-in command** if placeholders confuse you — that is normal.  
- **Deploy and drift work are optional** and usually owned by operations or a
  technical lead.

---

# Where to get more detail (if you want it later)

| Document | Audience |
|---|---|
| [How-to-Run-Scripts.md](How-to-Run-Scripts.md) (this file) | Non-technical / first-time operators |
| [SCRIPT-TESTING-GUIDE.md](SCRIPT-TESTING-GUIDE.md) | Testers who want full technical command detail |
| [README.md](README.md) | Full product explanation |
| [SERVERS.md](SERVERS.md) | Server names and folder map |
