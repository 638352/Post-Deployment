# Testing guide

How to test the ves-verify scripts before they are trusted on a real server.

This guide has two parts. **Part 1** is for anyone — no scripting knowledge
needed; it is copy, paste, and read one line of output. **Part 2** is for
someone comfortable in PowerShell who needs to exercise each script by hand and
sign off on the behavior.

Everything in both parts runs on a workstation. Nothing here touches
production, AWS, a real service, or a real scheduled task.

---

# Part 1 — For everyone (non-technical)

## What these scripts are for, in one paragraph

Some legacy Windows systems are still deployed by copying files by hand. These
scripts take a fingerprint ("baseline") of the version that passed UAT, then
later check that the files sitting in production are byte-for-byte the same
ones, that the settings files say what they are supposed to say, and that the
program is actually running. They do not fix anything. They report: **pass**,
**fail**, or **error**.

## What "testing" means here

The repository ships an automated test suite: a program that runs the scripts
against fake files and checks that each one gives the right answer. Testing =
running that suite and reading whether anything failed.

## One-time setup

You need two things. Both are one-time.

1. **Windows PowerShell 5.1** — already on every Windows machine. Click Start,
   type `Windows PowerShell`, and open the one named exactly that (**not**
   "PowerShell 7", not "Command Prompt").
2. **Pester**, the test tool. In that window, paste this and press Enter:

   ```powershell
   Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
   ```

   If it asks about an untrusted repository, answer `Y` (yes). If it finishes
   with no red text, it worked. If Pester is already installed, this is
   harmless.

## Step-by-step: run the tests

**Step 1.** Open Windows PowerShell (see above).

**Step 2.** Go to the folder that holds the scripts. Paste this, with the path
changed to wherever the repository lives on your machine, and press Enter:

```powershell
cd c:\Users\howardr01\Post-Deployment
```

If you get a red "cannot find path" message, the path is wrong — find the
folder in File Explorer, copy the address bar, and try again.

**Step 3.** Paste this exactly and press Enter:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
```

**Step 4.** Wait. It takes about a minute. Lines will scroll past — that is
normal. Green `[+]` lines are tests that passed. Red `[-]` lines are failures.

**Step 5.** Read the last two lines. A good run ends like this:

```
Tests completed in 58.7s
Tests Passed: 100, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0
```

**The only number that matters is `Failed: 0`.** The passed count will change
as the suite grows; that is fine. `Failed: 0` means everything the suite knows
how to check is working.

If it says `Failed: 3` (or any number above zero), something is broken. Go to
"What to report" below.

**Step 6.** Optional confirmation. Paste this and press Enter:

```powershell
$LASTEXITCODE
```

It prints the number of failed tests. `0` is a clean run.

## If something goes wrong

| What you see | What it means | What to do |
| --- | --- | --- |
| `Pester 5.x not found` | The test tool is not installed | Redo the one-time setup step 2 |
| `cannot be loaded because running scripts is disabled` | Windows blocked the script | Make sure you pasted the command exactly — the `-ExecutionPolicy Bypass` part is what handles this |
| `The term '.\Invoke-Tests.ps1' is not recognized` | You are in the wrong folder | Redo Step 2 |
| Red `[-]` lines and `Failed:` above zero | A real test failure | Report it (below) |

## What to report

Copy the **whole window** — right-click the title bar → Edit → Select All, then
Edit → Copy — and paste it into the ticket or email. Include:

- the date and time you ran it,
- the machine name (`$env:COMPUTERNAME` prints it),
- the last two summary lines,
- the full text of every red `[-]` block.

Do not summarize the error in your own words. Paste the text.

## Reading a result from any of these scripts

If someone asks you to run one of the scripts directly, every one of them
finishes with a number. Run `$LASTEXITCODE` right after it to see the number:

| Number | Plain meaning | Is it OK? |
| --- | --- | --- |
| 0 | Pass — everything matched | Yes |
| 1 | Files or settings do not match the approved version | **No** — escalate |
| 2 | Could not tell: baseline missing, inventory incomplete, or AWS unreachable | **No** — escalate |
| 3 | The program is not healthy (not running, no recent activity) | **No** — escalate |
| 10 | The command was typed wrong or was unsafe, so nothing was checked | **No** — fix the command and rerun |

**A number other than 0 is never "probably fine."** These scripts are written to
refuse to guess: if they cannot prove a pass, they report an error instead.

## Glossary

- **Baseline / manifest** — the fingerprint file of the approved release.
- **Drift** — production quietly stopped matching the approved release.
- **Contract** — a small file listing what a settings file must contain.
- **SSM Parameter Store** — the AWS vault where the fingerprint is pinned so
  nobody can edit the files and the fingerprint together and get away with it.
- **Pester** — the test tool. Only used by testers; production never needs it.
- **Exit code** — the pass/fail number in the table above.

## What a green test run does and does not prove

It proves the scripts behave correctly: they detect changed files, refuse
tampered baselines, block bad deploys, and use the right pass/fail numbers.

It does **not** prove any particular server is healthy, and it does not test
the parts that need real AWS, a real Windows service, or a real scheduled task.
Those are listed in Part 2, section 4, and must be checked on a real box before
production use.

---

# Part 2 — For technical testers

## 0. Preconditions

- Windows PowerShell **5.1** (the target runtime). Verify:
  `$PSVersionTable.PSVersion` → `5.1.x`.
- Pester **5.x or later** (verified against 5.5+ and 6.0.1). The in-box Pester
  3.4 cannot parse the suite.
- A workstation or CI box. **Do not run the test suite on the legacy PS 5.1
  production servers** — it is dev-time only.
- No AWS credentials, service, scheduled task, or network access is required
  for anything in sections 1–3.

## 1. Automated suite

```powershell
cd <repo root>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
$LASTEXITCODE   # 0 = green; otherwise the failed-test count
```

The runner redirects `VES_AUDIT_LOG_DIR` to a temp folder for the run and
restores your value afterward, so the suite does not pollute a real log share.

Narrow to one file when you have touched one script:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1 `
  -Path .\tests\Deploy-Processor.Tests.ps1
```

**Covered:** module unit tests (manifest hashing, export/import tamper
detection, `Compare-VesFiles`, fail-closed inventory validation, JSONL log
format) plus end-to-end runs of every entry script as a real `powershell.exe`
child process, asserted against the `0/1/2/3/10` exit contract and the `-Json`
payload. The gate and deploy tests stub SSM with a fake `aws.cmd` on `PATH`.

**Not covered:** real SSM read/write (`Get-`/`Set-VesTrustedHash` against actual
AWS, and verify with `-TrustParam`), and the health check's service /
scheduled-task / HTTP branches. See section 4.

## 2. Manual sandbox lab (no AWS, no prod)

This exercises each script by hand against a throwaway tree, so you see the
behavior rather than trusting the suite. Every command below was run on
Windows PowerShell 5.1 and produced the exit code shown.

### Setup

```powershell
$repo = 'c:\Users\howardr01\Post-Deployment'      # adjust
$lab  = "$env:TEMP\ves-lab"
Remove-Item $lab -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$lab\release\bin","$lab\baselines","$lab\logs","$lab\applogs" -Force | Out-Null
Set-Content "$lab\release\app.txt"     'hello'   -NoNewline
Set-Content "$lab\release\bin\lib.dll" 'libdata' -NoNewline
$env:VES_AUDIT_LOG_DIR = "$lab\logs"              # keep audit JSONL in the lab
cd $repo
```

Check the exit code after each step with `$LASTEXITCODE`.

### T1 — Capture a baseline (local-only exception switches)

```powershell
.\Invoke-Verification.ps1 -Mode Capture -ReleaseRoot "$lab\release" `
  -ManifestPath "$lab\baselines\demo.json" -Processor demo `
  -AllowUntrustedCapture -AllowUnarchivedCapture
```

**Expect 0**, log line `Manifest written: 2 files, hash=...`, and
`$lab\baselines\demo.json` on disk.

`-AllowUntrustedCapture` / `-AllowUnarchivedCapture` exist **only** for this
kind of isolated test. A real capture requires `-TrustParam`, `-ArchiveRepo`,
and `-ReleaseTag`; confirm that by rerunning T1 without the two switches — it
must **exit 10** and refuse.

### T2 — Verify an untouched tree

```powershell
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot "$lab\release" `
  -ManifestPath "$lab\baselines\demo.json" -Processor demo
```

**Expect 0**, `File verify PASS`. Note the `WARN No -TrustParam; skipping trust
anchor` line — correct for a lab, unacceptable in production.

### T3 — Detect drift

```powershell
Set-Content "$lab\release\app.txt" 'tampered' -NoNewline
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot "$lab\release" `
  -ManifestPath "$lab\baselines\demo.json" -Processor demo
Set-Content "$lab\release\app.txt" 'hello' -NoNewline    # restore
```

**Expect 1**, with `CHANGED app.txt` named in the output. Also try deleting
`bin\lib.dll` (→ `MISSING`) and adding a new file (→ `EXTRA`).

### T4 — Reject a tampered baseline

```powershell
Copy-Item "$lab\baselines\demo.json" "$lab\baselines\tampered.json"
(Get-Content "$lab\baselines\tampered.json" -Raw) -replace '"sha256":  "([0-9A-Fa-f])','"sha256":  "0' |
  Set-Content "$lab\baselines\tampered.json"
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot "$lab\release" `
  -ManifestPath "$lab\baselines\tampered.json" -Processor demo
```

**Expect 2**, `Manifest self-hash mismatch (tampered/corrupt): stored=... recomputed=...`.
This is the check that stops someone editing prod files and the manifest together.

### T5 — Missing baseline is never a pass

```powershell
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot "$lab\release" `
  -ManifestPath "$lab\baselines\does-not-exist.json" -Processor demo
```

**Expect 2**.

### T6 — Usage guard

```powershell
.\Invoke-Verification.ps1 -Mode VerifyFiles -ManifestPath "$lab\baselines\demo.json"
```

**Expect 10** (`-ReleaseRoot required`). An incomplete invocation must not
produce a green result.

### T7 — Config contract, all three formats

The repo ships fixtures for each format. Run all three:

```powershell
.\Invoke-Verification.ps1 -Mode VerifyConfig -Processor demo `
  -ConfigContract .\tests\fixtures\appconfig\contract.json -ConfigPath .\tests\fixtures\appconfig\app.config

.\Invoke-Verification.ps1 -Mode VerifyConfig -Processor demo `
  -ConfigContract .\tests\fixtures\json\contract.json -ConfigPath .\tests\fixtures\json\config.json

.\Invoke-Verification.ps1 -Mode VerifyConfig -Processor demo `
  -ConfigContract .\tests\fixtures\keyvalue\contract.json -ConfigPath .\tests\fixtures\keyvalue\application.properties
```

**Expect 0** for each.

### T8 — Config drift

```powershell
Copy-Item .\tests\fixtures\keyvalue\application.properties "$lab\bad.properties"
(Get-Content "$lab\bad.properties") -replace 'tls.min=1.2','tls.min=1.0' | Set-Content "$lab\bad.properties"
.\Invoke-Verification.ps1 -Mode VerifyConfig -Processor demo `
  -ConfigContract .\tests\fixtures\keyvalue\contract.json -ConfigPath "$lab\bad.properties"
```

**Expect 1**, with `VALUE tls.min: expected '1.2' actual '1.0'`. Add an
undeclared key to the file and rerun: it must also fail as `UNDECLARED-KEY` —
the contract is exhaustive by default.

### T9–T11 — Health check

```powershell
Set-Content "$lab\applogs\today.log" 'running'
.\Invoke-HealthCheck.ps1 -Processor demo -FreshLogDir "$lab\applogs" -FreshLogMaxAgeMinutes 60   # T9

(Get-Item "$lab\applogs\today.log").LastWriteTime = (Get-Date).AddHours(-5)
.\Invoke-HealthCheck.ps1 -Processor demo -FreshLogDir "$lab\applogs" -FreshLogMaxAgeMinutes 60   # T10

.\Invoke-HealthCheck.ps1 -Processor demo                                                          # T11
```

**Expect 0 / 3 / 10.** T11 is the important one: a health check with no probe
configured refuses to report healthy (`No health probes were configured`)
rather than returning a false green.

### T12 — Heartbeat watchdog

```powershell
.\Test-DriftHeartbeat.ps1 -HeartbeatPath "$lab\logs\no-such-heartbeat.json"
```

**Expect 2** — a missing heartbeat means the drift runner never completed, and
that is an alert, not silence.

### T13 — Drift runner fails closed on the shipped inventory

```powershell
.\Start-DriftRunner.ps1 -TargetsFile .\targets.json -LogDir "$lab\logs"
```

**Expect 2.** The checked-in `targets.json` is deliberately incomplete, and the
runner enumerates exactly why:

```
Inventory invalid: inventoryComplete is not true; confirm every manual-copy and Citrix target ...
Inventory invalid: Target 'OutboundDBQProcessor' field 'releaseTag' still contains a placeholder: TBD
Inventory invalid: Target 'OutboundDBQProcessor' inventoryStatus must be 'confirmed' (found 'needs-confirmation').
Inventory invalid: Required server 'VESDEVAPPS01' has no confirmed target entry.
...
Drift run error: Target inventory is incomplete or invalid; no drift target was reported clean.
```

This is the correct result today and must stay this way until operations
supplies the Citrix server list and confirmed production paths.

### T14–T15 — Preflight

```powershell
.\Invoke-Preflight.ps1                                                              # T14
.\Invoke-Preflight.ps1 -Processor demo -ManifestPath "$lab\baselines\demo.json"     # T15
```

**Expect 10** (no target specified) and **0** (manifest self-check: consistent,
captured under the current exclude pattern, `no -TrustParam to anchor against`).
T15 is also the command that flags baselines needing re-capture after the
exclude-pattern fix — look for a `manifest-pattern` **WARN**.

### T16 — Audit logging

```powershell
Get-ChildItem "$lab\logs" | Select-Object Name, Length
Get-Content (Get-ChildItem "$lab\logs\verification-*" | Select-Object -First 1).FullName |
  Select-Object -First 3
```

Every run must have left a JSONL file with `RUN START` / `RUN END` records
carrying a run ID, processor, outcome, and exit code — even though no
`-LogFile` was passed.

### Expected results table

| # | Script / scenario | Exit |
| --- | --- | --- |
| T1 | Capture with local-only switches | 0 |
| T1b | Capture without `-TrustParam`/`-ArchiveRepo` | 10 |
| T2 | VerifyFiles, tree unchanged | 0 |
| T3 | VerifyFiles, one file edited | 1 |
| T4 | VerifyFiles, manifest tampered | 2 |
| T5 | VerifyFiles, manifest missing | 2 |
| T6 | VerifyFiles, `-ReleaseRoot` omitted | 10 |
| T7 | VerifyConfig, appconfig / json / keyvalue fixtures | 0 |
| T8 | VerifyConfig, value mismatch or undeclared key | 1 |
| T9 | HealthCheck, fresh log | 0 |
| T10 | HealthCheck, stale log | 3 |
| T11 | HealthCheck, no probe configured | 10 |
| T12 | Heartbeat missing | 2 |
| T13 | DriftRunner on shipped `targets.json` | 2 |
| T14 | Preflight with no arguments | 10 |
| T15 | Preflight manifest self-check | 0 |
| T17 | Gate pass (section 3) | 0 |
| T18 | Gate block, file missing from artifact | 1 |
| T19 | Gate, unreadable SSM parameter | 2 |

## 3. Gate testing with a stubbed AWS CLI

`Invoke-PreDeployGate.ps1` reads SSM through the AWS CLI, so you can test it
off-network by putting a fake `aws.cmd` first on `PATH` — the same technique
the Pester suite uses. Run this in a **throwaway shell**; it edits `PATH` for
that session only.

```powershell
$hash = (Get-Content "$lab\baselines\demo.json" -Raw | ConvertFrom-Json).manifestHash
New-Item -ItemType Directory -Path "$lab\awsstub" -Force | Out-Null
@(
  '@echo off'
  'if "%~4"=="/ves/demo/approved-commit" echo abc1234& exit /b 0'
  ('if "%~4"=="/ves/demo/baseline-hash" echo {0}& exit /b 0' -f $hash)
  'echo An error occurred (ParameterNotFound) 1>&2'
  'exit /b 254'
) | Set-Content "$lab\awsstub\aws.cmd" -Encoding ascii
$env:PATH = "$lab\awsstub;$env:PATH"
```

**T17 — gate pass:**

```powershell
.\Invoke-PreDeployGate.ps1 -StagedRoot "$lab\release" -StagedCommit abc1234 `
  -ApprovedCommitParam /ves/demo/approved-commit -TrustParam /ves/demo/baseline-hash `
  -ManifestPath "$lab\baselines\demo.json" -Processor demo
```

**Expect 0**, `GATE PASS: deploy may proceed (staged=abc1234 approved).`

**T18 — gate blocks and names the file:**

```powershell
Copy-Item "$lab\release" "$lab\staged" -Recurse -Force
Remove-Item "$lab\staged\bin\lib.dll" -Force
.\Invoke-PreDeployGate.ps1 -StagedRoot "$lab\staged" -StagedCommit abc1234 `
  -ApprovedCommitParam /ves/demo/approved-commit -TrustParam /ves/demo/baseline-hash `
  -ManifestPath "$lab\baselines\demo.json" -Processor demo
```

**Expect 1**, `GATE FAIL: Deployment blocked: bin/lib.dll is missing from the
artifact (1 missing, 0 changed, 0 extra)`. Naming the file is a brief
requirement — confirm the filename actually appears.

**T19 — unreadable SSM parameter is an error, not a pass:**

```powershell
.\Invoke-PreDeployGate.ps1 -StagedRoot "$lab\release" -StagedCommit abc1234 `
  -ApprovedCommitParam /ves/demo/no-such-param -Processor demo
```

**Expect 2**, `Gate error (SSM/trust): SSM read failed for ... aws exit=254`.

Close this shell when done so the stub leaves `PATH`.

## 4. What cannot be tested off-box

These need a real environment and must be signed off separately before
production. None of them are exercised by the suite or by sections 2–3.

- [ ] **Real SSM read/write** — `Set-VesTrustedHash` at capture and
      `Get-VesTrustedHash` at verify, against GovCloud with the actual
      parameter path, region, and KMS decrypt rights. Confirm the region
      question in the README's Open items first (`us-gov-west-1` vs
      `us-gov-east-1`).
- [ ] **`Invoke-Preflight -TargetsFile`** against a completed inventory, on a
      box with the AWS CLI and credentials.
- [ ] **Health check service branch** — `-ServiceName` against a real Windows
      service, and `-HealthUrl` against a live Spring Boot actuator endpoint.
- [ ] **Health check scheduled-task branch** — `-ScheduledTasks` against a real
      Task Scheduler job (enabled + last run result 0).
- [ ] **Exact console-EXE identity** — `-ProcessPathRoot` /
      `-ProcessArgumentPattern` where the same `VES.OutboundDBQProcessor.exe`
      runs 2–3 times per box from different folders.
- [ ] **`Install-DriftTask.ps1`** — registers the runner and watchdog as SYSTEM;
      needs an elevated shell on a real host. Verify with `Get-ScheduledTask`,
      then `-Uninstall` to clean up.
- [ ] **`Deploy-Processor.ps1` end to end** — stop, backup, robocopy, restart,
      verify, health. Pilot on the UAT egress box (vesemsegressuat) before any
      PROD use, including the `-KillProcesses` / `-StartTasksAfter` paths.
- [ ] **Capture with `-ArchiveRepo` / `-ReleaseTag`** against the real audit
      checkout, confirming the commit, tag, and `release-record.json`.
- [ ] **Central log destination** — set `VES_AUDIT_LOG_DIR` to the approved
      share and confirm the JSONL files land there and are readable by whoever
      watches them.

One standing caveat worth repeating on any sign-off: **Datadog is disabled this
release.** Exit codes and JSONL logs are the only signal — nothing reaches a
dashboard and no alert can fire, so a human has to watch the logs.

## 5. Cleanup

```powershell
Remove-Item "$env:TEMP\ves-lab" -Recurse -Force
Remove-Item Env:\VES_AUDIT_LOG_DIR
```

Also close any shell where you prepended the AWS stub to `PATH`.

## 6. Sign-off template

```
ves-verify test record
Date/time (UTC):
Tester:
Machine / OS:
PowerShell version:            (must be 5.1.x)
Pester version:
Repo commit:                   git rev-parse HEAD

Automated suite:               PASS / FAIL   Failed count: ___   Duration: ___
Manual lab T1-T16:             PASS / FAIL   Deviations: ___
Gate with AWS stub T17-T19:    PASS / FAIL   Deviations: ___
Section 4 items attempted:     (list, with environment and result)

Notes / anything that did not match the expected exit code:
```

Attach the full console output for any failure. Do not paraphrase errors.
