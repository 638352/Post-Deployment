# Post-Deployment Verification — Script-by-Script Walkthrough

**Audience:** leadership and reviewers who need to explain what this code does without reading PowerShell.
**Date:** 2026-07-30
**Scope:** every script in the `ves-verify` suite (11 scripts + 1 shared library + the per-system deploy wrappers).

## How to read this document

Each script gets four things:

1. **In one sentence** — what job it does.
2. **Why it matters** — the control it enforces, in leadership terms.
3. **Line-by-line walkthrough** — a table of line ranges and what each does. Line numbers refer to the files in the repository root (the canonical copy; `Post-Deployment-datadog-558667ed/` is a frozen snapshot).
4. **How it fails** — what a bad outcome looks like and what exit code it produces.

Everything is Windows PowerShell 5.1, on-premises Windows servers, with AWS GovCloud SSM Parameter Store as the trust anchor.

---

## The 60-second version

| Script | Job | A failure means |
|---|---|---|
| `module/VesVerify.psm1` | Shared library: hashing, trust, logging | (library — not run directly) |
| `Invoke-Preflight.ps1` | Read-only readiness check before anything else | Host or AWS access is not ready |
| `Invoke-Verification.ps1` | Capture a baseline, or prove production matches it | Production drifted from the approved release |
| `Verify-Config.ps1` | Prove settings match a declared contract | A setting is missing, wrong, or undeclared |
| `Invoke-PreDeployGate.ps1` | Refuse to deploy anything not UAT-approved | The artifact is not the approved release |
| `Deploy-Processor.ps1` | Gate → stop → back up → copy → restart → verify → health | The deployment was stopped or is unproven |
| `Invoke-HealthCheck.ps1` | Prove the system is actually alive after deploy | The processor is down or silent |
| `Start-DriftRunner.ps1` | Scheduled re-check of every target | Something changed outside a deployment |
| `Test-DriftHeartbeat.ps1` | Independent watchdog on the scheduled check | The scheduled check itself stopped running |
| `Install-DriftTask.ps1` | Registers the two scheduled tasks | Scheduling was not set up |
| `Invoke-Tests.ps1` | Developer test runner | The suite has failing tests |
| `processors/Deploy-*.ps1` | Thin per-system wrapper with fixed paths | (delegates to `Deploy-Processor.ps1`) |

### The five outcomes every script speaks

Defined once in `module/VesVerify.psm1:23-27`:

| Code | Meaning | Leadership reading |
|---|---|---|
| `0` | Pass | Production matches the approved release |
| `1` | Drift | Files or settings diverged — **FAIL** |
| `2` | No baseline / trust failure | We cannot prove anything — **ERROR**, never a pass |
| `3` | Health failure | Files are right but the system isn't running — **FAIL** |
| `10` | Usage / unsafe configuration | Someone ran it wrong or with no real checks — **ERROR** |

The design rule throughout: **a check that cannot run is never reported as a pass.**

---

## 1. `module/VesVerify.psm1` — the shared library

**In one sentence:** the common toolbox every other script imports — file hashing, the tamper-proof trust anchor, the server inventory validator, and structured logging.

**Why it matters:** the integrity guarantee lives here, in one place. Capture and verify must use *identical* rules or every check would report false drift, so those rules are defined once rather than copied into each script.

| Lines | What happens |
|---|---|
| 13 | `Set-StrictMode -Version 2.0` — a typo in a variable name becomes an immediate error instead of a silent `$null`. Prevents a check quietly doing nothing. |
| 23–27 | Defines the five exit codes as globals so all scripts speak the same contract. |
| 44 | The single exclude pattern: skip `logs\`, `temp\`, `cache\`, `.git\` (top level *or* nested) and `.log`/`.tmp`/`.config` files. `.config` is excluded on purpose — legacy configs carry server-specific paths and are checked by contract instead of by bytes. |
| 48–49 | Forces TLS 1.2. PowerShell 5.1 defaults to protocols AWS rejects. |
| 51–86 | `Write-VesLog` — every log line goes to the console for a human *and* as one JSON object per line to a file for machines. UTC timestamps so logs from many servers correlate. |
| 88–118 | `New-VesLogFile` — invents a unique log path for the scripts that log by default (deploy, drift runner, watchdog). The read-only verification scripts log only when `-LogFile` is passed. Prefers `VES_AUDIT_LOG_DIR`, falls back to `ProgramData`. |
| 120–129 | `Get-VesOutcome` — maps exit codes to the brief's three words: PASS / FAIL / ERROR. |
| 131–238 | `Import-VesTargetInventory` — validates the server inventory **fail-closed**: schema must be `ves.targets.v1` (169–171), `inventoryComplete` must be explicitly `true` (172–174), `requiredServers` must be non-empty (175–177), a legacy bare array is rejected outright (159–161). |
| 181–195 | Every target must carry all ten required fields, and any leftover placeholder (`SYSTEM_NAME`, `TBD`, `CONFIRM`, `UNKNOWN`) is an error — a half-filled inventory cannot claim coverage. |
| 196–211 | Each target must be marked `confirmed`, name a valid environment, and be unique per server/processor pair (no double-counting). |
| 213–222 | Cross-check: every server on the required list must have a confirmed target. This is the control that stops us claiming full Citrix coverage before the Citrix servers are actually listed. |
| 240–292 | `Get-VesManifest` — walks a folder and records `path | SHA-256 | size` for every file. Paths are stored relative and slash-normalized (283) so a UAT capture compares cleanly against a PROD folder. |
| 259–264 | Uses `Get-Item` rather than `Resolve-Path` deliberately — the latter keeps DOS 8.3 short names, which silently corrupted every relative path and reported whole trees as missing. |
| 275–277 | Guards the path-prefix assumption and throws loudly rather than producing a wrong manifest. |
| 294–322 | `Get-VesManifestHash` — one deterministic SHA-256 over the sorted file list. Immune to JSON formatting, key order, or byte-order marks, so the trust pin doesn't break for cosmetic reasons. |
| 324–359 | `Export-VesManifest` — writes the baseline document: schema, processor, commit, capture time, who captured it, the self-hash, file count, and the file entries. |
| 361–383 | `Import-VesManifest` — loads a baseline and **recomputes** its hash. `Consistent = false` means the file was edited after capture. |
| 385–433 | `Compare-VesFiles` — the actual drift diff: **Missing** (baseline says it should be there), **Changed** (bytes differ), **Extra** (present but never approved). `Match` is true only when all three are empty. |
| 440–482 | `Invoke-VesAwsCli` — wraps the AWS CLI to work around two PowerShell 5.1 traps that had silently broken every caller: stderr becoming a fatal error, and warnings being spliced into a parameter value. |
| 484–503 | `Get-VesTrustedHash` — reads the pinned hash from SSM Parameter Store with decryption. A failed read or an empty value **throws** — we never proceed on a blank anchor. |
| 505–523 | `Set-VesTrustedHash` — writes the pin as an encrypted SecureString at capture time. |
| 532–553 | `Invoke-VesGit` — same defensive wrapper for Git. |
| 555–562 | `Test-VesReleaseTag` — enforces the `<system>/vMAJOR.MINOR.PATCH` tag format. |
| 564–597 | `Get-VesManifestFromTag` — reads the baseline back out of the Git release tag, returning the same shape as a local file so identical trust logic applies. |
| 599–729 | The Datadog telemetry functions, **commented out in place**. Exit codes and JSONL logs are the only signal today. |

**The trust model in one paragraph (lines 435–438):** the baseline file sits next to the artifacts, so by itself it proves nothing — anyone who can edit production files can edit it too. At UAT sign-off, the baseline's content hash is pinned into AWS SSM Parameter Store, which is write-gated. Verification reads the trusted hash from SSM, not from the file. That closes the "edited the files *and* the manifest" case.

---

## 2. `Invoke-Preflight.ps1` — read-only readiness check

**In one sentence:** answers "could a real check even run on this box right now?" without touching a single production or staged file.

**Why it matters:** it separates "we checked and it's clean" from "we couldn't check." Exit 0 = ready, exit 2 = not ready.

| Lines | What happens |
|---|---|
| 33–49 | Parameters: either a whole targets file, or the individual SSM parameter / manifest / contract paths for one system. |
| 52 | Creates its own JSONL log if none was supplied. |
| 55–61 | `Add-Check` — every probe appends one row (name, PASS/WARN/FAIL, detail). Only FAIL affects the exit code. |
| 64–81 | `Test-PsVersion` — confirms Windows PowerShell **5.1**, not 7.x. `#Requires -Version 5.1` is a floor, not a pin: PowerShell 7 would satisfy it and then behave differently. No OMS document records which version is on which box, so it is checked rather than assumed. |
| 85–94 | `Test-AwsCli` — is the AWS CLI even on PATH? Without it, every SSM read fails. |
| 95–120 | `Test-SsmParam` — performs a real decrypting read of each parameter, exercising credentials, KMS decrypt, path, and region in one shot. |
| 105–110 | On success it reports **only the value's length**, never the value — these can be secrets. |
| 112–118 | On failure it translates AWS error text into an actionable reason: parameter doesn't exist (check path/region), access denied (IAM), or expired credentials. |
| 128–140 | `Test-ManifestPatternStale` — flags baselines captured under the older, buggy exclude pattern. Re-capturing changes their hash and would break the SSM pin, so this surfaces it as a **WARN** here rather than as an exit 2 during a 2 a.m. scheduled run. |
| 143–174 | `Test-Manifest` — the core check: the baseline must exist (146–149), load (150–151), be self-consistent (152–155), and its hash must equal the SSM-pinned value (159–169). A trust mismatch is a hard FAIL. |
| 200–213 | `Test-ConfigContract` — the contract file must exist, be valid JSON, and declare a format the verifier understands (`appconfig`, `json`, or `keyvalue`). |
| 218 | Host runtime is checked first, before anything can short-circuit the run. |
| 224–242 | **Mode A** (`-TargetsFile`): loops the targets and checks each one's manifest and contract. |
| 244–257 | **Mode B** (per-processor): checks whichever parameters were supplied; refuses with exit 10 if given nothing to check (245–249). Note line 253 — the returned SSM value is deliberately discarded so a secret can never reach the console. |
| 260–271 | Tallies results. Any FAIL ⇒ NOT READY (exit 2). WARNs are allowed through. |
| 274–278 | Any unexpected error is treated as not-ready, never as ready. |

**Known gap (worth knowing before you present):** in Mode A this script parses the targets file directly (line 232) instead of using the validating `Import-VesTargetInventory` that the drift runner uses. With the current `ves.targets.v1` file shape, that loop finds no per-target fields and silently checks nothing. The README claims preflight also rejects incomplete inventories; today only `Start-DriftRunner.ps1` does. Per-processor mode (Mode B) is unaffected. This is a small, self-contained fix.

---

## 3. `Invoke-Verification.ps1` — capture and compare

**In one sentence:** one script with four modes — `Capture` (snapshot the UAT-approved release), `VerifyFiles` (prove production matches it), `VerifyConfig`, and `All`.

**Why it matters:** this is the core evidence-producing control. Capture creates the approval record; verify produces the proof.

| Lines | What happens |
|---|---|
| 37–69 | Parameters. `-Mode` is mandatory and constrained to the four values. |
| 63 | `-ExcludePattern` deliberately has **no** default: parameter defaults bind before the module loads, so it would silently bind `$null` on a fresh session. Resolved at line 78 instead. |
| 72–74 | Imports the module, sets errors to be fatal, creates a log file if none given. |
| 80 | Builds the machine-readable result object returned when `-Json` is used. |
| 81–83 | Writes the `RUN START` record with run ID, processor, environment, release, and release tag. |
| 86–93 | `Out-Result` — the single exit point. Every run therefore ends with a matching `RUN END` record carrying outcome and exit code. |
| 111–130 | **Capture guardrails.** Requires `-ReleaseRoot` and `-ManifestPath`; requires `-TrustParam` so the baseline is tamper-anchored (113–116); requires `-ArchiveRepo` + `-ReleaseTag` so the approval leaves a Git record (120–123); enforces the tag format (127–130). The `-Allow*` escape hatches exist only for local testing and log a warning when used. |
| 132–135 | Hashes the release tree and writes the baseline manifest. |
| 140–151 | Copies the manifest (and the config contract, if supplied) into `baselines/<processor>/` in the archive repository. |
| 155–169 | Generates `release-record.json`: release tag, source commit, manifest hash, file count, capture time, who captured it, trust parameter, and the explicit note that **tagged rollback points begin with the first verified release** — anything shipped earlier still needs a safe baseline determined manually. |
| 170–182 | Stages, commits, and tags the record. If a re-capture staged nothing new, the commit is skipped and the tag lands on the existing record (174). |
| 188–194 | `-PushRemote` makes the record durable off-host; a failed push fails the capture, because a release record on one workstation is not an audit trail. |
| 196–200 | **Order matters:** the SSM trust pin is updated only *after* the Git record is durable. If archiving fails, the previously approved baseline stays active rather than pointing at an unrecorded manifest. |
| 207–216 | **Verify guardrails:** needs a release root, and either a local manifest or a `-BaselineRepo`/`-ReleaseTag` pair. |
| 221–232 | Loads the baseline either from the Git release tag or from the local file. Both produce the same shape, so the integrity checks below apply equally. |
| 234–238 | Rejects a baseline whose own self-hash doesn't match — edited or corrupt ⇒ exit 2. |
| 241–251 | The trust anchor: the baseline hash must equal the SSM-pinned hash. Mismatch ⇒ exit 2. Without `-TrustParam` it logs a WARN and downgrades to a drift-only check. |
| 254–265 | Runs the comparison and logs every missing, changed, and extra file by name. |
| 268–272 | `VerifyFiles` returns here (0 or 1). `All` stores the file result and falls through to config. |
| 277–290 | The config leg delegates to `Verify-Config.ps1` and folds its result into the report. |
| 291–293 | In `All` mode both files **and** config must pass. |
| 297–301 | Any unhandled error — unreadable SSM, unreadable tree — exits 2. Errors never exit 0. |

---

## 4. `Verify-Config.ps1` — settings by contract, not by bytes

**In one sentence:** compares live configuration against a declared contract, because production configs legitimately differ from UAT (endpoints, thumbprints, secrets) and hashing them would only produce false alarms.

**Why it matters:** this is the "settings are exhaustive and sanitized" control. It catches a missing or wrong setting, and it is written so a secret can never land in a log or report.

| Lines | What happens |
|---|---|
| 10–27 | The contract's five sections: `requiredKeys` (must exist), `machineKeys` (may differ per host but must be present), `expectedValues` (pinned exactly), `ssmExpectedValues` (pinned in Parameter Store), `sensitiveKeys` (compared for real, reported masked). |
| 46–49 | Takes the contract path, the live config path, and the AWS region. |
| 59–61 | Both files must exist; the contract is loaded as JSON. |
| 63–95 | `Get-FlatConfig` — flattens three formats into one key/value map: `.NET` App.config appSettings and connectionStrings (69–71), nested JSON flattened to colon-joined keys (75–83), and Java `.properties` key=value lines (87–90). An unknown format throws (92). |
| 98–101 | Flattens the live config once, then accumulates three failure kinds: missing, mismatched, undeclared. |
| 106–111 | Builds the explicit sensitive-key list from the contract. |
| 117–120 | **Defense in depth:** any key whose *name* looks like a secret (password, token, credential, api-key, connection string…) is auto-masked in reports even when the contract forgot to declare it. |
| 121–123 | `Get-ReportValue` — the single place that decides whether a real value or `(masked)` reaches the log. |
| 134–141 | **Refuses** a contract that stores a sensitive key under `expectedValues` — that would commit a secret to Git. Directs the author to `requiredKeys` or `ssmExpectedValues` instead. |
| 146–148 | `requiredKeys`: presence only. Blank entries are filtered out so an omitted section can't crash the run into a false exit 2. |
| 150–159 | `expectedValues`: must be present *and* equal. Mismatches are recorded with expected vs actual (masked where appropriate). |
| 162–167 | `machineKeys`: values may differ by environment, but the setting must still exist and be non-empty. |
| 172–185 | `ssmExpectedValues`: the expected value is read from Parameter Store at check time, so editing the contract file alongside the config cannot fool this comparison. Mismatches are **always** masked (180–182). |
| 190–201 | **Exhaustiveness:** every live setting must appear in one of the declared sections or the explicit `ignoredKeys` allowlist. Anything else is reported as drift rather than silently trusted. |
| 204 | Pass requires zero missing, zero mismatched, and zero undeclared. |
| 209–213 | On failure, names every problem: `MISSING-KEY`, `VALUE` (with expected/actual), `UNDECLARED-KEY`. |
| 220–229 | Returns a structured result that `Invoke-Verification.ps1` folds into its own report. |

An SSM read failure here throws, which the caller maps to exit 2 — a trust failure, never a pass.

---

## 5. `Invoke-PreDeployGate.ps1` — the deploy gate

**In one sentence:** refuses to let a deployment proceed unless the staged artifact *is* the UAT-approved release, by commit **and** by content.

**Why it matters:** this is the control that stops an unapproved or modified build from reaching production. Exit 0 = may proceed; exit 1 = blocked.

| Lines | What happens |
|---|---|
| 31–55 | Parameters. The staged root, staged commit, and the SSM parameter holding the approved commit are all mandatory. |
| 70–76 | `Stop-Gate` — single exit point; always writes a `RUN END` record with outcome and exit code. |
| 79–105 | `Fail-Gate` — the central block path. Logs the reason, honors an audited break-glass override if `-AllowOverride` is used, otherwise blocks. |
| 81–85 | `-AllowOverride` without `-OverrideReason` is refused outright. |
| 87–88 | An engaged override writes an `OVERRIDE ENGAGED` line with **who, why, and when** — the bypass is auditable, not silent. |
| 109–112 | A tag source needs both halves (`-BaselineRepo` + `-ReleaseTag`) or it's a usage error. |
| 115–121 | **Gate 1 (commit):** reads the approved commit from SSM and requires the staged commit to match exactly. |
| 126–142 | **Gate 1b (required files):** configuration files are excluded from byte hashing, but their *absence* must still block. Each required relative path is validated (130–136, including a path-escape guard) and must exist (137–139). |
| 148–156 | **The gate never passes on a commit string alone.** With neither an SSM trust parameter nor a tag source, it exits 10 rather than implying the artifact was inspected. `-AllowCommitOnly` is the explicit, logged exception. |
| 160–162 | Reads the trusted hash from SSM when configured. |
| 163–171 | Reads the tag-archived manifest when configured, and rejects it if internally inconsistent. |
| 172–175 | When **both** anchors exist they must agree — a rewritten Git tag can never relax the gate. |
| 176–178 | Tag-only anchoring is allowed but logged as such. |
| 182–184 | **Gate 2 (content):** hashes the staged tree and compares it to the trusted hash. |
| 186–221 | On mismatch, names the files at fault rather than only reporting an aggregate hash difference — but only if the naming manifest itself matches the trusted hash (196–202), so a tampered manifest cannot mislabel the diff. Output reads like "Deployment blocked: bin/Storage.Net.dll is missing from the artifact." |
| 228–235 | Both gates passed: logs `GATE PASS: deploy may proceed`. |
| 237–241 | Cannot reach SSM, or the parameter is missing ⇒ exit 2. It refuses rather than deploying unanchored. |

---

## 6. `Deploy-Processor.ps1` — the deployment itself

**In one sentence:** the five-stage deployment — gate, stop, back up, copy, restart, verify, health — where any stage failing aborts with that stage's exit code.

**Why it matters:** the deployment and its proof are the same operation. You cannot deploy without the gate, and you cannot finish without verification and a liveness check.

| Lines | What happens |
|---|---|
| 38–81 | Parameters. Seven are mandatory: processor, staged root, target root, staged commit, manifest path, trust parameter, approved-commit parameter. Nothing runs half-configured. |
| 86–90 | Log file and `RUN START` record. |
| 93–98 | Fails closed before any stage runs if `-BaselineRepo` was given without `-ReleaseTag`. |
| 105–111 | `Stop-Deploy` — single exit point with a matching `RUN END` record. |
| 113–136 | Assembles the list of files that must exist in the artifact. If the live config sits inside the target folder, its relative path is derived automatically (126–131) so a missing config blocks *before* the copy — even though `.config` is excluded from hashing. |
| 139–156 | `Step` — runs a named stage and aborts the whole deploy with that stage's exit code on failure. |
| 161–174 | **Stage 1 — pre-deploy gate.** Invoked as a separate `powershell.exe` child process on purpose (line 173): that way `exit N` inside the gate ends only the child, letting this script log the failure. |
| 177 | `-WhatIf` short-circuits here: the gate runs, then the script reports success without touching production. |
| 180–192 | **Stage 2 — dated backup** to `<BackupRoot>\<yyyyMMdd>_<Initials>_<Processor>`. A failed backup aborts *before* the copy (186). |
| 197–199 | Tracks what was disabled so the `finally` block can undo it. |
| 202–208 | Disables the scheduled tasks holding the target files open. |
| 210–219 | Stops the Windows service, for Java-service targets. |
| 224–246 | **The console-EXE problem.** Disabling a scheduled task does not kill an already-running instance. The same executable name runs 2–3 times per box from different folders, so the *folder* is the instance identity: any process whose executable path lives under the target root is detected (228–230). Without `-KillProcesses` the deploy aborts (241–244) rather than letting robocopy fight a file lock. With it, each instance is force-stopped after an audit line recording **PID and full command line** — so the RTP/RTPDP mode is on record (234–236). |
| 248–259 | Waits up to 30 seconds for killed instances to actually release their handles, and fails if any survive. |
| 263–270 | **Stage 3 — the copy.** `robocopy /MIR` so stale files are removed. Robocopy exit codes 0–7 are success variants, 8+ is failure (267–268). |
| 272–302 | The `finally` block — guaranteed to run even if the copy fails: restarts the service (274–283), re-enables every task that was disabled (284–290). Production is never left down by a failed deploy. |
| 293–301 | `-StartTasksAfter` relaunches the processor immediately, but **only after a clean stop and copy** — a failed deploy is never auto-started onto a possibly broken tree. |
| 304–305 | A failed stop or copy aborts here, with the processor already restored. |
| 315–337 | **Stage 4 — post-deploy verify.** Runs `All` when a config contract was supplied, otherwise `VerifyFiles`, so a config-less system verifies files rather than failing with a usage error. |
| 340–357 | **Stage 5 — health check.** Builds the probe list from what this system actually has: assemblies, service, tasks, fresh-log directory, process path, endpoint. |
| 363–375 | **Backup pruning happens last, and only after a fully green deploy** — a failed deploy must never eat its own restore point. Keeps the newest N dated folders for this processor. |
| 377–385 | `DEPLOY COMPLETE: <processor> @ <commit> verified+healthy`, exit 0. |

---

## 7. `Invoke-HealthCheck.ps1` — is it actually running?

**In one sentence:** proves the deployed system is alive and functioning, using whichever of five probes fits the target type.

**Why it matters:** file verification proves production has the same bytes UAT approved. It does *not* prove those bytes work. This is the only layer that can catch a defect UAT missed. Any failure exits 3.

| Lines | What happens |
|---|---|
| 12–22 | The two health profiles: Java/Spring Boot services get an HTTP actuator probe; the outbound `.exe` processors have **no endpoint at all** and must prove life through process identity, scheduled-task result, and a fresh log line. |
| 31–54 | Parameters, one per probe type, all optional. |
| 64 | Every failing check appends a reason here; a non-empty list at the end means unhealthy. |
| 68–80 | **A health check with no probes configured exits 10, not 0.** A misconfigured deploy cannot receive a false green result. |
| 83–102 | **Probe 1 — assemblies.** Loads each required .NET assembly and then calls `GetTypes()` (89), which forces the loader to resolve references *now*. That is what surfaces a missing dependency; loading alone is lazy and would pass. |
| 92–97 | A type-load failure reports the actual missing assembly name from `LoaderExceptions`. |
| 105–112 | **Probe 2a — Windows service** must exist and be `Running`. |
| 113–136 | **Probe 2b — exact process identity.** Matches processes whose executable path lives under the given root, optionally also matching the mode argument by pattern (117–121). Process name alone is not sufficient when the same EXE runs several times per box. |
| 137–143 | **Probe 2c — process name** (the weaker legacy fallback). |
| 147–172 | **Probe 3 — scheduled tasks.** Healthy = enabled and last result `0` (155–156). `267009`/`0x41301` means "currently running" and is also healthy (158–161). Anything else, including "has not run yet," is a failure (162–166). A disabled task is a failure (152–154). A missing task is a failure (168–171). |
| 176–199 | **Probe 4 — fresh log.** For endpoint-less processors, liveness is a recent log write: the newest file under the log directory must be younger than the threshold (189–196). A missing directory or an empty one is a failure (177–187). |
| 202–216 | **Probe 5 — HTTP endpoint.** Optional actuator probe with a 15-second timeout; a wrong status code or any exception is a failure. `-UseBasicParsing` avoids an Internet Explorer dependency on Server Core. |
| 219–222 | Healthy only if no probe added a failure. |
| 234–238 | Optional JSON output includes the commit, so a liveness result is traceable to a specific build. |
| 239–246 | Writes the summary and `RUN END` records, then exits 0 or 3. |

---

## 8. `Start-DriftRunner.ps1` — the scheduled re-check

**In one sentence:** validates the server inventory, then runs a full files-plus-config verification for every target, writing one timestamped log per target and a heartbeat file.

**Why it matters:** this is how an unauthorized change gets noticed *after* deployment. Its exit code is the worst outcome across all targets — one drifted target means the run reports drift.

| Lines | What happens |
|---|---|
| 16–22 | Parameters: the targets file, region, log directory, heartbeat path, and log retention (365 days by default for audit evidence). |
| 28–34 | Log directory resolution: explicit `-LogDir`, else `VES_AUDIT_LOG_DIR`, else a local default. |
| 42–51 | Run identity and the counters that will populate the heartbeat and the summary. |
| 46 | **`$worst` starts at exit 2**, not 0. If the run dies before validating anything, it reports ERROR, not clean. |
| 53–82 | `Write-Heartbeat` — builds the heartbeat document (run ID, start/finish, duration, outcome, exit code, target count, drift/trust-fail/error counts, host) and writes it **atomically**: to a temporary file, then a move-with-overwrite (75–78). A watchdog can never read a half-written heartbeat. |
| 88–97 | **Inventory gate.** Loads and validates the inventory. If it is invalid, every specific problem is logged and the run **throws** — "no drift target was reported clean." An incomplete inventory cannot produce a false all-clear. |
| 99–101 | Only after the inventory validates does `$worst` drop to 0. |
| 103–107 | Per target: its own timestamped JSONL log, plus a record of which processor on which server is being checked. |
| 108–124 | Calls `Invoke-Verification.ps1 -Mode All` with that target's release root, manifest, trust parameter, config contract, and config path. |
| 118 | The inventory has no per-target commit, so the **release tag** is what gets stamped into the log entries as the release identifier. |
| 135–137 | Exit 0 ⇒ logged `Clean`. |
| 138–148 | Exit 1 ⇒ recorded as drift; `DRIFT DETECTED <processor>: deployed files/config diverged from baseline`. |
| 149–159 | Exit 2 ⇒ recorded as a trust failure: baseline missing, unreadable, or untrusted. |
| 160–170 | Any other exit code ⇒ recorded as an error and explicitly `treating as unverified` — an unexpected result is never a pass. |
| 183–200 | Log pruning, deliberately narrow: only this runner's own per-target logs match the pattern (188). Deploy audit logs, run summaries, heartbeat files, and stray files are never touched. |
| 202–211 | Any run-level error forces the outcome to exit 2. |
| 212–229 | The `finally` block always writes the `RUN END` record **and** the heartbeat, even after a failure — that is what makes the watchdog trustworthy. If the heartbeat itself cannot be written, the outcome is downgraded to exit 2 (226–227). |

---

## 9. `Test-DriftHeartbeat.ps1` — the watchdog

**In one sentence:** an independently scheduled task that detects when the drift check itself stopped running.

**Why it matters:** a scheduled job that dies silently is indistinguishable from "no drift found." This closes the missed-run gap. Exit 2 on any problem.

| Lines | What happens |
|---|---|
| 15–19 | Parameters: heartbeat path, maximum acceptable age (75 minutes by default, i.e. wider than a 30-minute cadence), environment, log file. |
| 25–27 | `RUN START` record naming the heartbeat file being watched. |
| 29–33 | A non-positive `-MaxAgeMinutes` is a usage error (exit 10) rather than a threshold that can never trip. |
| 40–42 | **Failure 1: missing.** No heartbeat file at all. |
| 43 | Reads and parses the heartbeat. |
| 44–46 | **Failure 2: wrong schema.** Guards against pointing at an unrelated or outdated file. |
| 47–49 | **Failure 3: no completion time** recorded. |
| 50–54 | Parses the completion timestamp with invariant culture and round-trip handling, so a server's locale cannot change the result, then computes its age in minutes. |
| 55–57 | **Failure 4: future-dated** by more than 5 minutes — clock skew or a forged heartbeat. |
| 58–60 | **Failure 5: stale** — older than the threshold. This is the actual "missed run" detection. |
| 61–62 | Fresh: records the age plus the last run's outcome and exit code. |
| 64–66 | Every failure mode funnels into one detail message, so all five report identically. |
| 76–85 | Fresh ⇒ log PASS, optional JSON, exit 0. |
| 87–88 | Not fresh ⇒ `MISSED DRIFT RUN: <reason>` with structured evidence. |
| 89–93 | The alert push is commented out — **today the exit code and the JSONL log are the only signal.** There is no automatic path to on-call until telemetry is re-enabled or log shipping is wired up. |
| 98–100 | `RUN END` record, exit 2. |

---

## 10. `Install-DriftTask.ps1` — scheduling

**In one sentence:** registers the two scheduled tasks — the drift runner and its independent watchdog — as SYSTEM, and can remove both again.

**Why it matters:** it makes the monitoring cadence a single decision (one interval) and guarantees the watchdog is installed alongside the runner rather than being an optional extra.

| Lines | What happens |
|---|---|
| 19–27 | Parameters: targets file, interval (30 minutes default), the two task names, log directory, heartbeat threshold, environment, and an `-Uninstall` switch. |
| 32–40 | `-Uninstall` removes both tasks and returns. |
| 41 | A non-positive interval is rejected outright. |
| 42–44 | If no heartbeat threshold was given, it derives one: three intervals, minimum 15 minutes. A single late run therefore doesn't page anyone; two consecutive misses do. |
| 45–47 | Rejects a threshold at or below the interval — that would alert on every normal run. |
| 50–53 | Locates the runner and the watchdog next to this script and **throws** if either is missing. |
| 54–56 | A missing targets file is a warning, not an error: the task can be registered before the inventory is finalized. |
| 57–59 | Creates the log directory and derives the heartbeat and watchdog log paths from it, so all three agree by construction. |
| 62–63 | The runner action: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Start-DriftRunner.ps1` with the targets file and log directory. |
| 64–66 | The watchdog action, pointed at the same heartbeat path with the derived threshold. |
| 71–73 | The trigger is `-Once` plus a repetition interval rather than a daily schedule, so cadence stays one knob. Duration is a fixed 3650 days rather than `TimeSpan.MaxValue`, which serializes badly on the 2012R2-era hosts these legacy systems may still run. |
| 74–76 | The watchdog is offset to start one interval plus five minutes later, so it doesn't fire before the runner has ever written a heartbeat. |
| 79 | Both tasks run as **SYSTEM** at the highest run level — needed to read production folders and manage services and tasks. |
| 80–81 | Settings: skip overlapping runs (`IgnoreNew`), catch up if a run was missed (`-StartWhenAvailable`), and a one-hour execution limit so a hung run cannot block the next. |
| 84–87 | Registers (or overwrites) both tasks. |
| 89–92 | Prints what was registered and the reminder to point monitoring and log shipping at the log directory. |

Because the runner's exit code lands in Task Scheduler's "Last Run Result," a monitor can read pass/drift/trust-failure directly from Windows without parsing logs.

---

## 11. `Invoke-Tests.ps1` — the test runner

**In one sentence:** runs the automated Pester suite and exits with the number of failing tests (0 = green), ready to wire into CI.

**Why it matters:** the suite proves the core UAT-baseline-versus-production flow behaves correctly, including its failure paths. Run it on a workstation or build host, not on a production server.

| Lines | What happens |
|---|---|
| 4–9 | Header: needs Pester 5.x, and should run under Windows PowerShell 5.1 so tests exercise the same engine as production. |
| 15 | Optional `-Path` for running a narrower subset. |
| 18–21 | Defaults to the `tests\` folder next to this script, with a fallback for hosts where `$PSScriptRoot` isn't populated. |
| 23–25 | Finds the newest installed Pester 5.x. |
| 27–31 | If only the in-box Pester 3.4 is present, prints the exact install command and exits 2 rather than failing with a confusing parse error. |
| 33–34 | Imports that specific Pester version and prints it, so test output records which engine ran. |
| 36–39 | Configures the run: path, pass-through results, detailed output. |
| 41–44 | Redirects audit logs to a temporary per-process directory during the run, so tests never write into the real audit log location. |
| 45–49 | Runs the suite and restores the original log directory in a `finally`, even if the run throws. |
| 50 | Exits with the failed-test count. |

**What the suite covers:** creating a baseline manifest, a matching-tree pass (exit 0), changed-file drift detection (exit 1), tampered-baseline rejection (exit 2), and missing-required-input rejection (exit 10) — that is, the failure paths are tested, not just the happy path.

---

## 12. `processors/Deploy-*.ps1` — the per-system wrappers

**In one sentence:** one thin script per system that pins everything fixed about that system, so an operator supplies only what changes per release.

**Why it matters:** it removes the chance of a wrong path or wrong SSM parameter being typed at deploy time. The operator provides two things: the staged tree and its commit.

`Deploy-SYSTEM_NAME.ps1` is the template; `Deploy-OutboundDBQ-uat.ps1` is the first filled-in instance (UAT DBQ processor on VESMSEGRESSUAT).

Walking the UAT instance:

| Lines | What happens |
|---|---|
| 12–17 | Header flags the values still marked `# CONFIRM` — the scheduled-task name and log directory are not documented in `SERVERS.md` and must come from the Outbound Deployment Steps runbook. |
| 23–35 | Parameters: staged root and commit are mandatory; release tag, baseline repository, audit log directory, and region are optional. |
| 38 | Locates the shared `Deploy-Processor.ps1` one folder up. |
| 39–41 | **Refuses to run** until the operator passes `-ConfirmedRunbookValues`, confirming the two unverified values were checked. An unconfirmed path cannot be deployed against by accident. |
| 43–45 | Resolves the audit log directory and creates a timestamped JSONL log for this deployment. |
| 47–66 | The `$fixed` block — everything constant for this system: processor name, target folder, baseline manifest path, the two SSM parameters, config contract and config path, backup root. |
| 56–57 | The two values still tagged `# CONFIRM`. |
| 59–61 | `KillProcesses` and `StartTasksAfter` are on, and the mode argument pattern `\bRTPDP\b` identifies *this* instance among the several copies of the same executable on the box. |
| 62 | The executable is listed under `RequiredAssemblies` so the health check load-tests it. |
| 64–65 | `ServiceName` and `HealthUrl` are deliberately empty — DBQ is a console EXE with no actuator endpoint. |
| 68–72 | Passes the fixed values plus the per-release ones to `Deploy-Processor.ps1`, with environment hard-set to `uat`. |
| 73 | Propagates the deployment's exit code, so the wrapper is transparent to any caller or scheduler. |

The template (`Deploy-SYSTEM_NAME.ps1:21-38`) documents the two shapes to fill in — outbound `.exe` processor versus Java/Spring Boot service — and the server-awareness rule: PROD splits the outbound processors across VESEMSEGRESS01/02/03 while UAT runs all three on one box, so each wrapper lists only the scheduled tasks that live on *its* server.

---

## What to say about the honest gaps

If leadership asks "so is this done?", these are the accurate answers, all of which are already documented in the repository README:

1. **Enforcement is built; some data is still pending.** The server inventory (`targets.json`) is deliberately marked `inventoryComplete: false`, and the drift runner refuses to report any target clean until it is confirmed. The Citrix server names are not yet documented and must be added before that flag can be set. The code fails closed rather than overstating coverage.
2. **There is no automatic alert path today.** The Datadog integration is commented out across the module and every script. Exit codes and JSONL logs are the only signal, which means a durable central log location (`VES_AUDIT_LOG_DIR`) and log shipping must be configured before production, or a failure is only visible to whoever looks.
3. **Preflight's targets-file mode does not yet use the validating inventory loader** that the drift runner uses, so in that one mode it currently checks nothing per target. Per-processor preflight is unaffected. Small, self-contained fix.
4. **Per-server config is overwritten by the copy.** `robocopy /MIR` replaces a config file living under the target folder with the staged one. On a server whose config legitimately differs, the deployment flattens it. The decision needed before PROD: exclude configs from the mirror, or stage the correct per-server config alongside the artifact.
5. **The console-EXE stop/restart mechanism is implemented but not yet piloted.** Pilot on the UAT egress box before any PROD use.
6. **Break-glass is a policy decision, not a code gap.** The gate supports an audited override with a mandatory reason; `Deploy-Processor.ps1` deliberately does not pass it. Hard-block versus audited override needs a decision.

---

## Source files covered

| File | Lines | Section |
|---|---|---|
| [module/VesVerify.psm1](../module/VesVerify.psm1) | 730 | 1 |
| [Invoke-Preflight.ps1](../Invoke-Preflight.ps1) | 279 | 2 |
| [Invoke-Verification.ps1](../Invoke-Verification.ps1) | 303 | 3 |
| [Verify-Config.ps1](../Verify-Config.ps1) | 230 | 4 |
| [Invoke-PreDeployGate.ps1](../Invoke-PreDeployGate.ps1) | 242 | 5 |
| [Deploy-Processor.ps1](../Deploy-Processor.ps1) | 386 | 6 |
| [Invoke-HealthCheck.ps1](../Invoke-HealthCheck.ps1) | 247 | 7 |
| [Start-DriftRunner.ps1](../Start-DriftRunner.ps1) | 232 | 8 |
| [Test-DriftHeartbeat.ps1](../Test-DriftHeartbeat.ps1) | 101 | 9 |
| [Install-DriftTask.ps1](../Install-DriftTask.ps1) | 93 | 10 |
| [Invoke-Tests.ps1](../Invoke-Tests.ps1) | 51 | 11 |
| [processors/Deploy-OutboundDBQ-uat.ps1](../processors/Deploy-OutboundDBQ-uat.ps1) | 74 | 12 |
| [processors/Deploy-SYSTEM_NAME.ps1](../processors/Deploy-SYSTEM_NAME.ps1) | 103 | 12 |

Related reading: [README.md](../README.md) (overview, exit codes, trust model, open items), [SERVERS.md](../SERVERS.md) (server and path map), [RUNBOOK.md](RUNBOOK.md) (technical tester runbook), [RUNBOOK-NON-TECHNICAL.md](RUNBOOK-NON-TECHNICAL.md) (plain-language guide).
