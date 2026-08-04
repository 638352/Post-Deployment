# Backup & Rollback — Line-by-Line Walkthrough

**Audience:** reviewers and leadership who need to point at the exact code that protects production before a deploy and restores it after a bad one.
**Date:** 2026-08-04
**Line numbers are pinned to commit `d1f58d74`.** The working tree has seen several same-day commits; re-check anchors against `git blame` if you are reading this against a later commit.
**Scope:** `Deploy-Processor.ps1` (the deploy/rollback entry point), `module/VesVerify.psm1` (shared backup/rollback library), and the per-system wrappers in `processors/` that say **which production instances get backed up and to where**.

---

## The 60-second version

| Capability | Where it lives | What it does |
| --- | --- | --- |
| **Backup of prod before overwrite** | `Deploy-Processor.ps1:360-373` (Stage 2) | Copies the live tree to a dated folder before the new release is mirrored in |
| **Backup retention (prune)** | `Deploy-Processor.ps1:541-557` | After a fully green deploy only, keeps the newest N backups per processor |
| **Rollback (restore a backup)** | `Deploy-Processor.ps1:128-238` (`-Rollback` switch) | Quiesces the processor, mirrors the chosen backup over the live tree, restarts |
| **Backup picker** | `Deploy-Processor.ps1:107-126` (`Get-RollbackSourcePath`) | Chooses the newest backup for the processor, or an explicitly named one |
| **Shared library support** | `module/VesVerify.psm1:607-921` | `Get-VesBackupSet`, `Stop-VesProcessorTarget`, `Start-VesProcessorTarget` |
| **Which prod instances, which paths** | `processors/Deploy-*.ps1` | Per-system wrapper pins `TargetRoot` (what is backed up) and `BackupRoot` (where it goes) |

**Backup folder naming convention** (runbook convention, built at `Deploy-Processor.ps1:362`):

```
<BackupRoot>\<yyyyMMdd>_<Initials>_<Processor>
e.g.  C:\VLER_Test\Processors\BackUp\20260804_RH_SYSTEM_NAME
```

The design rule throughout: **a backup failure aborts the deploy before production is touched, and a failed deploy never deletes its own restore point.**

---

## 1. Where prod instances are backed up — `Deploy-Processor.ps1` Stage 2

**In one sentence:** immediately after the pre-deploy gate passes and before anything stops or overwrites production, the entire live tree (`TargetRoot`) is copied to a dated backup folder.

**Why it matters:** this backup *is* the rollback point. If it cannot be taken, the deploy stops with production still untouched and still running.

| Lines | What happens |
| --- | --- |
| 67–69 | `-BackupRoot` parameter: dated backup of the current target before overwrite. **Skipped entirely if not set** — the wrapper configs are what guarantee it is always set for real systems. |
| 70–72 | `-KeepBackups` (default **5**): how many backups to retain per processor. `0` keeps everything. |
| 357–358 | `-WhatIf` guard: the real work (including backup) only runs inside `ShouldProcess`. |
| 360–361 | Stage 2 begins; only runs when `-BackupRoot` was supplied. |
| 362 | Builds the dated folder name: `<BackupRoot>\<yyyyMMdd>_<Initials>_<Processor>`. `<Initials>` defaults to `$env:USERNAME` (line 75), so every backup names who took it. |
| 363 | Only backs up if `TargetRoot` actually exists (first-ever deploy has nothing to save). |
| 364–366 | Logs `Backup <TargetRoot> -> <backupDir>`, creates the folder, then `robocopy /E` — a full recursive copy including empty dirs. **Not** `/MIR`: the backup only ever adds, never deletes. |
| 367 | **Fail-closed:** robocopy exit code ≥ 8 means the copy failed → log ERROR, abort the whole deploy with exit `1` (DRIFT) **before the live tree is stopped or overwritten**. |
| 368 | Clears robocopy's 1–7 "success variant" codes so later stage checks don't trip on them. |
| 370–372 | If `TargetRoot` doesn't exist yet: WARN "nothing to back up" and continue (fresh install path). |
| 490–494 | `-WhatIf` path: logs `WhatIf: skipping stop/backup/copy, gate only` and exits 0. A rehearsal never writes a backup. |

**Sequencing guarantee:** backup (Stage 2, lines 360–373) completes *before* the stop/copy phase (Stage 3, lines 375+) begins. The processor is still running and its files are still intact while the backup is taken.

### Backup retention — prune after green deploys only

| Lines | What happens |
| --- | --- |
| 541–544 | Runs **last, and only after all five stages passed** (gate → backup → copy → verify → health). The comment states the rule: "a failed deploy must never eat its own restore point." |
| 545 | Three conditions: `-BackupRoot` set, `-KeepBackups > 0`, and the backup root exists. |
| 546 | Regex `^\d{8}_.+_<Processor>$` — matches only **this processor's** dated folders; the processor name is regex-escaped so it can't accidentally match other systems' backups. |
| 547–549 | Sorts folder names descending (names start `yyyyMMdd`, so name order *is* date order) and skips the newest `KeepBackups` — what's left is the deletion list. |
| 550–556 | Deletes each old backup with a log line per folder. A prune failure is only a **WARN** — retention housekeeping must never fail an otherwise green deploy. |

---

## 2. Which prod instances are backed up, and to where — `processors/` wrappers

**In one sentence:** `Deploy-Processor.ps1` is generic; the per-system wrapper scripts pin the real paths, so the wrapper is the authoritative answer to "where is *this* instance backed up."

| Wrapper | Instance (what is backed up) | Backup destination | Lines |
| --- | --- | --- | --- |
| `processors/Deploy-SYSTEM_NAME.ps1` | `TargetRoot = C:\VLER_Test\Processors\SYSTEM_NAME` | `BackupRoot = C:\VLER_Test\Processors\BackUp` | 66, 73 |
| `processors/Deploy-OutboundDBQ-uat.ps1` | `TargetRoot = C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` | `BackupRoot = C:\VLER_TEST_OUTBOUND\Processors\BackUp` | 49, 55 |

Two caveats, both stated in `Deploy-Processor.ps1`'s own header:

- **These are QA/UAT paths, not confirmed PROD paths.** Lines 33–34: "The actual in-scope system list is unconfirmed as of 2026-07; do not assume VLER or vemsoutbound naming." The template (`SYSTEM_NAME`) is the placeholder to be cloned per real system.
- **PROD is server-split.** Lines 28–31: PROD runs the outbound processors across `VESEMSEGRESS01/02/03` (VEMS-5346), whereas UAT runs all three on one box — so in PROD each server gets its own wrapper with only *its* tasks and paths. Backups land on the **local disk of the server being deployed to**; there is no central/offbox backup share configured in the current scripts.

---

## 3. Rollback — `Deploy-Processor.ps1 -Rollback`

**In one sentence:** `-Rollback` reuses the deploy's own stop/restart machinery, but instead of copying a staged release in, it mirrors a chosen backup folder back over the live tree.

**Why it matters:** the restore path exercises the exact same quiesce logic as a deploy, so a rollback can't corrupt the tree in a way a deploy couldn't — and it never leaves production stopped, even when the restore fails.

### 3a. Choosing the restore source — `Get-RollbackSourcePath` (lines 107–126)

| Lines | What happens |
| --- | --- |
| 109–113 | If `-RollbackBackup <path>` was given explicitly, that exact folder is used — after proving it exists. Missing path → throw. |
| 115–117 | Otherwise `-BackupRoot` is required; neither present → throw ("Rollback requires -BackupRoot or -RollbackBackup"). |
| 118–121 | Auto-pick: matches only `^\d{8}_.+_<Processor>$` folders (same convention Stage 2 writes, processor name regex-escaped), sorts by name descending, takes the first — **the newest backup for this processor**. |
| 122–125 | No matching folder → throw ("No rollback backup found"). You can never silently "restore" from nothing. |

### 3b. The rollback execution block (lines 128–238)

| Lines | What happens |
| --- | --- |
| 128–135 | Resolves the restore source via `Get-RollbackSourcePath`; any of the throws above becomes a logged ERROR and exit `10` (USAGE). |
| 137–138 | Trackers: which tasks we disabled (so `finally` can re-enable exactly those), and a `stopFailed` flag. |
| 140–151 | **Quiesce step 1:** disable each `-ScheduledTasks` entry. First failure sets `stopFailed` and stops trying. |
| 152–164 | **Quiesce step 2:** stop the Windows service (`-ServiceName`), for Java-service targets. |
| 165–198 | **Quiesce step 3:** find running console-EXE instances whose `ExecutablePath` is under `TargetRoot` (that path prefix is the instance identity — the same exe name runs from several folders per box). Without `-KillProcesses` a found instance **blocks** the rollback; with it, each PID is force-stopped with an audit line (PID + full command line), then a 30-second wait (lines 185–196) confirms the handles were actually released. |
| 199–205 | **The restore:** only if fully quiesced — `robocopy <backup> <TargetRoot> /MIR`. `/MIR` makes the live tree *exactly* match the backup, deleting files the bad deploy added. Robocopy exit ≥ 8 → ERROR, exit `1`. |
| 207–234 | **`finally` — production always comes back up:** restart the service (208–217), re-enable every task we disabled (218–224), and with `-StartTasksAfter` trigger them now rather than waiting for the next schedule (225–233). Runs even when the quiesce or copy failed. |
| 235 | If the processor could not be quiesced, exit `1` — the tree was never touched. |
| 236–237 | Success: logs `Rollback complete: <Processor> restored from <source>` and exits `0`. |

### 3c. Rollback/deploy parameter validation (lines 248–293)

| Lines | What happens |
| --- | --- |
| 249 | `$rollbackOnlyProvided` = `-BackupRoot` or `-RollbackBackup` was supplied. |
| 250–263 | Rollback mode must not carry deploy-only params (`StagedRoot`, `StagedCommit`, `ManifestPath`, `TrustParam`, `ApprovedCommitParam`, `ReleaseTag`, `BaselineRepo`), and requires `-TargetRoot` plus a backup source. Violations exit `10`. |
| 264–293 | Deploy mode: rejects rollback-only params without `-Rollback` (265–268), then requires the six deploy essentials. |

> ⚠️ See **Known issues** below — at commit `d1f58d74` this validation block sits *after* the rollback execution block, and line 249 misclassifies `-BackupRoot`.

---

## 4. Shared library support — `module/VesVerify.psm1` (lines 607–921)

**In one sentence:** the module carries one canonical definition of "what counts as a backup" plus the quiesce/restart pair, so deploy, rollback, and any future tooling can never disagree.

| Lines | What happens |
| --- | --- |
| 607–611 | The section contract: Deploy-Processor backs up to `<BackupRoot>\<stamp>_<Initials>_<Processor>`; both the restore picker and the deploy's prune are meant to enumerate through `Get-VesBackupSet` "so they can never disagree about what counts as a backup." |
| 633–652 | **`Get-VesBackupSet`** — enumerate a processor's backups, newest first. Accepts **both** folder shapes: current `yyyyMMddTHHmmss_<Initials>_<Processor>` and older date-only `yyyyMMdd_...`. Date-only sorts at midnight, so a same-day timestamped backup correctly outranks it. |
| 654 | Missing backup root → empty array (not an error): "no backups yet" is a valid state. |
| 656–660 | One regex with named groups covers both shapes; the processor name is regex-escaped so metacharacters can't widen the match to other systems. |
| 662–683 | Parses each folder's stamp (timestamp → date → fall back to the folder's own `LastWriteTime` for unparseable names, so nothing silently drops out of the set). |
| 685–699 | Reads the `rollback-record.json` sidecar. It is written **last** by the deploy, so `HasRecord = $false` also means "this backup may be incomplete" — callers warn on it rather than trusting the folder blindly. A malformed sidecar is reported as "no record", never a crash. |
| 701–702 | Detects the `backup-manifest.json` sidecar (per-backup integrity manifest). |
| 704–718 | Counts/sizes the **payload only** — the two sidecars and the `_ves-config` stash are excluded so they never inflate the numbers. `FileCount = -1` means "could not enumerate", distinct from a genuinely empty backup. |
| 720–738 | Emits `{Name, FullName, Stamp, StampKind, Initials, HasRecord, Record, HasManifest, ManifestPath, FileCount, SizeBytes}` sorted newest-first; the leading comma keeps a single backup from unrolling to a scalar. |
| 741–859 | **`Stop-VesProcessorTarget`** — the deploy's quiesce phase lifted verbatim into the module so deploy and rollback stop production identically: disable tasks (782–791), stop service (793–806), detect/kill exe instances under `TargetRoot` with audit lines and a handle-release wait (808–849). **Never throws**; returns `{Stopped, DisabledTasks, ServiceStopped, KilledPids, BlockingPids, Errors}` — `Stopped = $false` means "do not touch the tree." |
| 861–921 | **`Start-VesProcessorTarget`** — the mirror image, meant to run in a `finally`: service first (884–896), then re-enable exactly the tasks that were disabled (897–906), optionally trigger them now (907–919). Never throws — a restart failure is logged and collected because there is nothing left to unwind. |

**Current wiring status:** `Deploy-Processor.ps1` at `d1f58d74` still uses its own inline copies of the quiesce/restart logic and its own backup enumeration regex; it does not yet call `Get-VesBackupSet` / `Stop-VesProcessorTarget` / `Start-VesProcessorTarget`, and it does not yet write the `rollback-record.json` / `backup-manifest.json` sidecars or the timestamped (`yyyyMMddTHHmmss`) folder shape the module already understands. The module side of the refactor landed first (tests: `tests/VesVerify.Backup.Tests.ps1`); the script side is still inline.

---

## 5. How it fails

| Scenario | Behavior | Exit |
| --- | --- | --- |
| Backup robocopy fails (exit ≥ 8) | Deploy aborts **before** stop/copy; production untouched and running | `1` |
| No `-BackupRoot` supplied on deploy | No backup is taken (by design — wrappers are responsible for always supplying it) | n/a |
| Rollback: no backup found / bad path | Nothing is stopped or copied | `10` |
| Rollback: processor won't quiesce (task/service/PID) | Tree untouched; service/tasks restored by `finally` | `1` |
| Rollback: restore robocopy fails | Service/tasks still restarted by `finally` | `1` |
| Prune fails after a green deploy | WARN only — never fails the deploy | `0` |
| `-WhatIf` | Gate only; no backup, no stop, no copy | `0` |

---

## 6. Known issues at commit `d1f58d74` (flagged, not yet fixed)

1. **Rollback validation is dead code.** The rollback *execution* block (lines 128–238) runs and exits before the rollback *validation* block (lines 250–263) is ever reached. Consequence: `-Rollback` combined with deploy-only params (e.g. `-StagedRoot`) is **not** rejected — the rollback just runs; and a missing `-TargetRoot` produces a raw failure instead of the clean usage error at line 256. The validation block needs to move above line 128.
2. **`$rollbackOnlyProvided` blocks legitimate deploys.** Line 249 counts `-BackupRoot` as a rollback-only parameter, but `-BackupRoot` is exactly what a normal deploy needs for its Stage 2 backup — and both wrappers pass it. As written, any deploy that supplies `-BackupRoot` exits `10` at line 267 ("Rollback-only parameters require -Rollback") and never runs. The check should test `-RollbackBackup` only. (Unreachable in rollback mode for the same ordering reason as issue 1, but deploy mode hits it every time.)
3. **Module comment references a script that doesn't exist.** `VesVerify.psm1:609` says "Invoke-Rollback restores from that folder" — there is no `Invoke-Rollback.ps1`; rollback is only reachable via `Deploy-Processor.ps1 -Rollback`.
4. **Sidecar/shape gap.** `Get-VesBackupSet` understands timestamped folders and the two sidecar files, but the deploy currently writes neither — every backup it takes today reports `HasRecord = $false` ("may be incomplete") by the module's own definition.

---

## Related files

- Tests: `tests/Deploy-Processor.Tests.ps1` (rollback CLI behavior), `tests/VesVerify.Backup.Tests.ps1` (module backup-set functions)
- Runbook: `docs/RUNBOOK.md`
- Full-suite walkthrough: `docs/SCRIPT-GUIDE-LINE-BY-LINE.md`
