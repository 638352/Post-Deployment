# Cheat Sheet: The Testing Process, in Plain English

**Who this is for:** anyone who needs to understand what this suite does and how
its pieces fit together — testers, release managers, leadership — without
reading any code.

**One sentence:** these scripts prove that what is running in production is
exactly what was approved in UAT, and shout when it is not.

For step-by-step commands, use [RUNBOOK-NON-TECHNICAL.md](RUNBOOK-NON-TECHNICAL.md).
For full technical detail, use [RUNBOOK.md](RUNBOOK.md).

---

## 1. The problem this solves

Some systems here are still deployed by hand — someone copies files onto a
server. Nothing automatically checks that the files and settings that landed in
production match the version that passed UAT. That gap is not theoretical: a
recent release shipped without a required file and nobody noticed for 24 days.

This suite is the safety net. It does not replace the deployment; it inspects it.

---

## 2. Two different things are called "testing" here

This is the single most common point of confusion. Keep them separate.

| | **A. Testing the scripts** | **B. Testing a release** |
| --- | --- | --- |
| Question it answers | "Do our safety checks still work?" | "Does production match what UAT approved?" |
| Run by | Developers / CI | Testers and operators |
| Run where | A workstation or the build server — **never** production | UAT host and production servers |
| Run when | Every time the scripts are changed | Every release, then every 30 minutes forever |
| The tool | `Invoke-Tests.ps1` | All the other scripts |

Think of it as an airport metal detector. **A** is testing the metal detector
itself — walking a known piece of metal through it to confirm it still beeps.
**B** is screening actual passengers. Both are "testing"; only one of them is
about the release.

---

## 3. A — Testing the scripts (`Invoke-Tests.ps1`)

**What it is.** One command that runs the whole automated test suite: about 150
individual checks across 10 test files.

**How it works, conceptually.** Each test builds a small disposable pretend
world in a temporary folder — a miniature "release" of a few files, a real
miniature release archive, fake backup folders, even a real running program to
imitate a file that is locked open. It then runs the *actual* production scripts
against that pretend world and checks that they reach the right verdict.

**What the tests are actually checking.** Not "did the script run" — but "did it
reach the correct conclusion":

- A matching release **passes**.
- A file that was changed, removed, or added is **caught and named**.
- A tampered or missing approval record is **refused**, not quietly accepted.
- The pre-deploy gate **blocks** a package that was not approved.
- A rollback **restores the right thing** and refuses unsafe restores.
- Secrets are **never printed** into logs or reports.
- Missing or nonsensical inputs are **rejected** rather than guessed at.

**Reading the result.** The script's exit code is the number of failed tests.
`0` means everything passed. Anything else means stop and escalate — the safety
net itself is damaged.

**It also runs by itself.** GitHub Actions runs the exact same command on every
push and pull request, so a change that breaks a safety check is caught before
anyone relies on it.

**Two ground rules.** Run it on a workstation or CI host, never on a production
server. And it needs a specific testing tool version installed once (Pester 5.x)
— the runbook has the one-line install command.

---

## 4. B — Testing a release: the flow

The order below is the process. Each step has a plain verdict, and **any failure
stops the line** — that is the whole point.

```
   ONCE PER SYSTEM        EVERY RELEASE                    ALWAYS RUNNING
   ---------------        -------------                    --------------
   set up the             1. self-test the scripts
   release archive        2. preflight (are we ready?)
   and decide who         3. CAPTURE at UAT sign-off  -->  approved record
   may approve                   |                              |
   releases                      v                              v
                          4. GATE (is this approved?)      8. drift check
                                 |                            every 30 min
                                 v                              |
                          5. DEPLOY (backup, copy, restart)     v
                                 |                            watchdog
                                 v                          (is the drift
                          6. VERIFY files + config          check itself
                                 |                           still alive?)
                                 v
                          7. HEALTH CHECK
                                 |
                                 v
                          pass  --or--  9. ROLLBACK
```

### The steps in plain language

| # | Step | What it really means |
| --- | --- | --- |
| 1 | **Self-test** | Confirm the safety net is intact before trusting it. |
| 2 | **Preflight** | Read-only readiness check. Right version of PowerShell? Can we reach the approval record? Does the config contract make sense? Touches nothing. |
| 3 | **Capture** | The approval moment. At UAT sign-off, take a fingerprint of every approved file and file it in the release archive under a version tag. **This is what makes "approved" a fact a machine can check.** There is no separate activation step — filing it *is* approving it. |
| 4 | **Gate** | The bouncer. Before anything is copied, compare the package about to ship against the approved record. If they differ, nothing is copied. If the approval record cannot be read at all, it errors — it never assumes the package is fine. |
| 5 | **Deploy** | Runs as one unattended chain: gate → stop the processor → back up the current version → copy the new files → restart → verify → health check. Any step failing aborts the rest. A dry run (`-WhatIf`) does the gate only. |
| 6 | **Verify** | Re-fingerprint what actually landed on the server and compare it to the approved record, naming any file that is missing, changed, or unexpected. Settings are checked separately against a contract, because production settings legitimately differ from UAT. |
| 7 | **Health check** | Did the thing actually come back up? Is the service running, did its scheduled job succeed, is it still writing to its log? |
| 8 | **Drift check** | The same verification, re-run automatically every 30 minutes forever, plus a second watchdog that notices if the drift check itself dies — so "no drift reported" can never be confused with "nothing is checking." |
| 9 | **Rollback** | Put the previous version back from the backup taken in step 5, then re-verify and re-health-check it, so a rollback proves itself rather than being assumed to have worked. A written reason is required and goes in the audit record. |

---

## 5. The scripts at a glance

| Script | Its one job | Where it runs |
| --- | --- | --- |
| `Invoke-Tests.ps1` | Tests the scripts themselves | Workstation / CI |
| `Invoke-Preflight.ps1` | "Are we ready to run?" — read-only | Wherever the next step runs |
| `Invoke-Verification.ps1` | Capture the approved baseline, or verify files/settings against it | UAT host (capture), target server (verify) |
| `Verify-Config.ps1` | Checks settings against an approved contract | Target server |
| `Invoke-PreDeployGate.ps1` | Blocks anything not approved | Staging / deploy machine |
| `Deploy-Processor.ps1` (via `processors\Deploy-<system>.ps1`) | The controlled deploy chain | Target server |
| `Invoke-HealthCheck.ps1` | "Is it actually alive?" | Target server |
| `Invoke-Rollback.ps1` | Restore a backup and prove the restore | Target server |
| `Start-DriftRunner.ps1` | The scheduled re-check of every target | Ops runner / target server |
| `Test-DriftHeartbeat.ps1` | Watchdog: is the drift check still running? | Same machine as the runner |
| `Install-DriftTask.ps1` | Sets up the two scheduled jobs above (once) | Target server, as admin |

---

## 6. Reading the verdict

Every script ends with a number. That number **is** the result — there is no
"looks fine to me."

| Code | Plain meaning | What to do |
| ---: | --- | --- |
| `0` | Pass | Record it and continue |
| `1` | Files or settings do **not** match what was approved | Stop, escalate |
| `2` | The approval record is missing, unreadable, or untrustworthy — **we cannot prove anything** | Stop, escalate |
| `3` | It is not healthy / did not come back up | Stop, escalate immediately |
| `10` | The command was given bad or unsafe inputs | Fix the inputs and rerun |

The design rule behind all of it: **the scripts fail closed.** A missing
baseline, an unreadable approval record, an incomplete server list, or a health
check with nothing to check will report an error. None of them will ever quietly
report a pass.

---

## 7. Glossary (five terms, then you can read anything here)

- **Baseline / manifest** — the fingerprint list of every approved file. Think
  packing list plus tamper seal.
- **Release archive** — the Git repository where approved releases are filed.
  The source of truth for "what was approved."
- **Release tag** — the version label (e.g. `OutboundDBQ/v1.4.0`) that a release
  is filed under. **The tag is the approval record.**
- **Drift** — production quietly no longer matching what was approved. Someone
  edited a file on the server, or a release shipped incomplete.
- **Contract** — the rules a settings file must satisfy (these keys must exist,
  these must have exactly these values, these may differ per server).

---

## 8. What this does and does not prove

Worth being straight about, because it shapes what you can claim in an audit.

**It proves:** production contains exactly the bytes and settings that UAT
approved, and that the approval record was not edited after the fact.

**It does not prove those bytes were correct.** If UAT approved a bug, this will
faithfully confirm the bug reached production. The health check is the only
layer that catches a defect UAT missed — which is why its probes must stay
populated.

**Three known gaps today:**

1. **Detection is automated; notification is not.** Findings land in log files
   and exit codes. Nothing pages anyone yet, so reviewing the logs has to be a
   named person's job until alerting is wired up.
2. **Everything rests on the release tag.** Whoever can move a release tag in
   the archive can author their own approval. Restricting that permission is the
   control the rest of this depends on.
3. **The server list is incomplete** (Citrix servers are not yet documented), so
   the suite refuses to claim full coverage rather than overstating it.

---

## 9. Related guides

- [RUNBOOK-NON-TECHNICAL.md](RUNBOOK-NON-TECHNICAL.md) — the exact commands, step by step
- [RUNBOOK.md](RUNBOOK.md) — full technical runbook
- [AUTOMATION-POSTURE.md](AUTOMATION-POSTURE.md) — what is automated vs. still manual
- [UAT-PILOT-CHECKLIST.md](UAT-PILOT-CHECKLIST.md) — the first UAT pilot
- [README.md](../README.md) — full behavior and trust model
