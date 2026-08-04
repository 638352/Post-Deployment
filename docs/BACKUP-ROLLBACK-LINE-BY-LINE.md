# Backup & Rollback — Line-by-Line Walkthrough

**Audience:** reviewers and leadership who need to point at the exact code that protects production before a deploy and restores it after a bad one.
**Date:** 2026-08-04
**Line numbers are pinned to commit `7cd3a7a3`.** This tree sees frequent same-day commits; re-check anchors against `git blame` when reading against a later commit.
**Scope:** `Deploy-Processor.ps1` (deploy-time backup, auto-rollback), `Invoke-Rollback.ps1` (the restore engine), `module/VesVerify.psm1` (shared backup/rollback library), and the per-system wrappers in `processors/` that say **which production instances get backed up and to where**.

---

## The 60-second version

| Capability | Where it lives | What it does |
| --- | --- | --- |
| **Backup of prod before overwrite** | `Deploy-Processor.ps1:312-452` (Stage 2) | Snapshots the live tree to a timestamped folder before the new release is mirrored in |
| **Restore-point evidence (sidecars)** | `Deploy-Processor.ps1:334-447` | `backup-manifest.json` (hash of what was replaced), `_ves-config` stash, prior SSM values, `rollback-record.json` |
| **Auto-rollback on a failed deploy** | `Deploy-Processor.ps1:459-520` (`-AutoRollback`) | Restores the backup automatically when the copy, verify, or health stage fails |
| **Operator rollback (the restore engine)** | `Invoke-Rollback.ps1` (entire script) | Picks a backup, safety-gates it, quiesces, mirrors it back, restores config, **proves** the restore, optionally re-pins trust |
| **`-Rollback` alias** | `Deploy-Processor.ps1:143-166` | Thin delegation to `Invoke-Rollback.ps1` so an operator holding the deploy command line can reverse it |
| **Backup retention (prune)** | `Deploy-Processor.ps1:622-636` | After a fully green deploy only, keeps the newest N backups per processor |
| **Shared library** | `module/VesVerify.psm1:607-921` | `Get-VesBackupSet`, `Stop-VesProcessorTarget`, `Start-VesProcessorTarget` — one definition of "what counts as a backup" and one quiesce/restart implementation |
| **Which prod instances, which paths** | `processors/Deploy-*.ps1` | Per-system wrapper pins `TargetRoot` (what is backed up) and `BackupRoot` (where it goes) |

**Backup folder naming convention** (built at `Deploy-Processor.ps1:322`):

```
<BackupRoot>\<yyyyMMddTHHmmss>_<Initials>_<Processor>
e.g.  C:\VLER_TEST_OUTBOUND\Processors\BackUp\20260804T143255_RH_OutboundDBQ
```

Timestamped, not date-only, on purpose (lines 317–321): with date-only names, a second deploy on the same day by the same operator robocopied the *already-overwritten* tree into the same folder, destroying the true pre-deploy state. Older `yyyyMMdd_...` folders remain restorable (`Get-VesBackupSet` accepts both shapes).

The design rules throughout: **a backup failure aborts the deploy before production is touched; a failed deploy never deletes its own restore point; and a rollback is never reported as a success of the deploy — it is remediation.**

---

## 1. Where prod instances are backed up — `Deploy-Processor.ps1` Stage 2

**In one sentence:** immediately after the pre-deploy gate passes and before anything stops or overwrites production, the live tree (`TargetRoot`) is copied into a timestamped backup folder along with everything a future rollback will need to prove itself.

**Why it matters:** this backup *is* the restore point. The copy itself is load-bearing and aborts the deploy on failure; everything after it is best-effort evidence that degrades gracefully but never blocks a deploy (line 312–315 states this rule).

### The parameters (lines 75–94)

| Lines | Parameter | What it does |
| --- | --- | --- |
| 75–79 | `-BackupRoot` | Where the dated backup goes. **Skipped if not set — and then there is nothing to roll back to**, so the wrappers set it on every real deploy. |
| 80–82 | `-KeepBackups` (default **5**) | Newest N backups kept per processor; pruned after a *successful* deploy only. `0` keeps everything. |
| 83–87 | `-AutoRollback` | Opt-in: restore the backup automatically when post-deploy verify or health fails. Requires `-BackupRoot`. Never re-pins the SSM trust anchor. |
| 88–90 | `-Rollback` | Run a restore instead of a deploy (delegates to `Invoke-Rollback.ps1`). |
| 91–94 | `-RollbackBackup`, `-RollbackReason` | Rollback-only: a specific backup folder to restore, and the audited reason. |

### Validation before anything runs (lines 177–229)

| Lines | What happens |
| --- | --- |
| 178–186 | `-RollbackBackup`/`-RollbackReason` without `-Rollback` → exit `10`. The comment at 178–180 records the rule explicitly: **`-BackupRoot` is NOT rollback-only** — a deploy needs it to create the restore point. |
| 187–192 | `-AutoRollback` without `-BackupRoot` → exit `10` **now**, not at stage 4: "finding out there is nothing to restore from only once the deploy has already overwritten prod is the worst moment." |
| 217–229 | **Overlap gate:** a `BackupRoot` inside `TargetRoot` (or vice versa) → exit `10`. The `/E` backup would recurse into its own destination and the `/MIR` that follows would delete the restore point it just made — "measured, not theoretical." |

### The backup itself (lines 312–452)

| Lines | What happens |
| --- | --- |
| 316–322 | Only with `-BackupRoot`. Builds `<BackupRoot>\<yyyyMMddTHHmmss>_<Initials>_<Processor>` — local time for operator readability; `createdUtc` in the sidecar is the unambiguous value. |
| 323 | Only backs up if `TargetRoot` exists (first-ever deploy has nothing to save; WARN at 449–451). |
| 325–328 | If the destination folder already exists and is non-empty, WARNs that `/E` will merge two releases into it. |
| 329–332 | **The load-bearing copy:** `robocopy /E` (recursive, add-only — never deletes). Exit ≥ 8 → ERROR, abort the whole deploy with exit `1` **before production is stopped or overwritten**. |
| 334–354 | **(a) `backup-manifest.json`:** hashes the tree being replaced (hashes `$TargetRoot`, not the backup copy, so the sidecars stay out of the manifest) via `Get-VesManifest`/`Export-VesManifest`. A hashing failure (e.g. >260-char paths under PS 5.1) degrades the evidence with a WARN — never the deploy. |
| 356–382 | **(b) out-of-tree config stash:** config living outside `TargetRoot` is not in the `/E` copy and would be unrecoverable, so it is copied into `<backup>\_ves-config\`. |
| 384–404 | **(c) prior SSM values:** reads the trust hash and approved commit *currently* pinned in Parameter Store, recording read-success explicitly (a `$null` can't distinguish ParameterNotFound from AccessDenied). Without this, a rollback has no way to say what the trust anchor used to point at. |
| 406–415 | **Free drift signal:** compares the pre-deploy tree's hash against the pinned baseline. `OK` = the backup is a *trusted* restore point; `DRIFT` = "the backup restores production as it actually was, not as approved." |
| 417–447 | **(d) `rollback-record.json` — written LAST, on purpose:** its presence is how a rollback knows the backup finished rather than dying part-way. Schema `ves.rollback-record.v1`: who/when, what tree, what release replaced it, the manifest hash and file count, config location, SSM parameter names and prior values, and any evidence-gathering errors. Ends with `Restore point ready: <dir>`. |

### Backup retention — prune after green deploys only (lines 622–636)

| Lines | What happens |
| --- | --- |
| 622–627 | Runs **last, only after all five stages passed** — "unreachable on a failed deploy, so a failure can never eat its own restore point." Conditions: `-BackupRoot` set, `-KeepBackups > 0`, root exists. |
| 628 | Enumerates through **`Get-VesBackupSet`** — the same function the restore picker uses, so the two can never disagree about what counts as a backup (both name shapes included). Skips the newest N. |
| 629–635 | Deletes the rest, one log line each. A prune failure is a **WARN** — housekeeping never fails a green deploy. |

---

## 2. Which prod instances are backed up, and to where — `processors/` wrappers

**In one sentence:** `Deploy-Processor.ps1` is generic; the per-system wrapper pins the real paths, so the wrapper is the authoritative answer to "where is *this* instance backed up." Each wrapper's config block now says so in its own comments ("TargetRoot is the live processor tree that will be backed up before deploy / BackupRoot is the folder where dated restore points are stored for rollback").

| Wrapper | Instance (what is backed up) | Backup destination | Lines |
| --- | --- | --- | --- |
| `processors/Deploy-SYSTEM_NAME.ps1` | `TargetRoot = C:\VLER_Test\Processors\SYSTEM_NAME` | `BackupRoot = C:\VLER_Test\Processors\BackUp` | 69, 76 |
| `processors/Deploy-OutboundDBQ-uat.ps1` | `TargetRoot = C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` | `BackupRoot = C:\VLER_TEST_OUTBOUND\Processors\BackUp` | 52, 58 |

Two caveats, both from `Deploy-Processor.ps1`'s own header:

- **These are QA/UAT paths, not confirmed PROD paths.** Lines 41–42: the actual in-scope system list is unconfirmed as of 2026-07; `SYSTEM_NAME` is the placeholder template to be cloned per real system.
- **PROD is server-split.** Lines 36–39: PROD runs the outbound processors across `VESEMSEGRESS01/02/03` (VEMS-5346); UAT runs all three on one box. In PROD each server gets its own wrapper with only *its* tasks and paths. Backups land on the **local disk of the server being deployed to** — there is no central/offbox backup share in the current scripts.

---

## 3. Auto-rollback — `Deploy-Processor.ps1 -AutoRollback`

**In one sentence:** when a stage *after* the copy fails — production is already carrying the new bits — the deploy restores its own Stage-2 backup by shelling `Invoke-Rollback.ps1`, then still exits with the failing stage's code, because rolling back is remediation, not success.

| Lines | What happens |
| --- | --- |
| 125–128 | `$script:rolledBack` / `$script:rollbackExitCode` — every terminal `RUN END` record states whether a rollback was attempted and how it went. "A rollback must never be silent." |
| 261–289 | `Step` gained an optional `$onFail` handler: on a stage failure it gets a chance to remediate and to substitute the final exit code (read back via a script-scoped variable so the child process's stdout can't corrupt it). |
| 454–458 | The handler's ground rules: shells `Invoke-Rollback.ps1` with this run's own `-LogFile` (both runs interleave in one JSONL stream) and **deliberately never passes `-RepinTrust`** — "an automated write to the trust anchor, triggered by a failing deploy, is the most dangerous thing this suite could do." |
| 462–467 | No backup was taken (fresh target)? `AUTO-ROLLBACK UNAVAILABLE`, exit `2` — manual recovery, never a silent no-op. |
| 468–497 | Builds the full `Invoke-Rollback` argument set — the same target/tasks/service/probes as the deploy, plus `-Reason "auto-rollback: deploy stage '<name>' failed with exit <code>"` — and runs it. |
| 504–507 | Rollback exited `0` → `AUTO-ROLLBACK COMPLETE: prior release restored, re-verified, healthy. The deploy still FAILED.` Final exit = the failing stage's code. |
| 508–514 | Rollback exited `1`/`3` → `RESTORED BUT UNPROVEN`: the bits are back on disk but didn't pass their own verify/health. Exit `2` — a human must confirm production. |
| 515–518 | Anything else → `AUTO-ROLLBACK FAILED… INDETERMINATE state`, exit `2`. |
| 559–568 | A `/MIR` that died part-way through the copy triggers the same handler — "the case rollback exists for." |
| 600, 620 | The handler is wired to the two post-copy stages: `post-deploy verify` and `health check`. |

---

## 4. The restore engine — `Invoke-Rollback.ps1`

**In one sentence:** one script owns every restore (operator-driven, `-Rollback` alias, and auto-rollback): pick the backup, refuse the unsafe ones, quiesce, mirror it back, restore config, restart, then **prove** the restore by re-running verification and the health check.

**Why it matters:** a rollback that cannot prove itself is treated as an ERROR (`2`), not a pass — the same fail-closed rule as everywhere else in the suite. Its exit codes (header, lines 26–32): `0` restored + proven + healthy, `1` restored but drifted, `2` not proven / indeterminate, `3` restored but unhealthy, `10` usage.

### Mode selection and safety gates — everything before the first mutation

| Lines | What happens |
| --- | --- |
| 41–44 | No `ConfirmImpact='High'`: a confirm prompt would hang scheduled and child-process runs. The mandatory `-Reason` and the audit record are the deliberate friction instead. |
| 136–164 | **`-ListBackups`** (read-only): prints every restorable backup for the processor, newest first — file count, size, whether the sidecar exists (`NO (may be incomplete)`), what release replaced it, and whether its hash matched the SSM pin at backup time. |
| 167–177 | Restore mode requires `-TargetRoot`, `-Reason` (validated in-body: a `Mandatory` attribute would prompt on stdin under `powershell.exe -File` and hang), and `-BackupRoot` or `-BackupDir`. |
| 179–190 | **Nesting gate first:** a `/MIR` whose source lives under its own destination deletes the restore source mid-flight → exit `10`. |
| 192–224 | **Backup selection:** `-BackupDir` restores a specific folder (with an escape hatch at 203–210 for a backup moved to another volume); otherwise the newest entry from `Get-VesBackupSet`. No backup at all → exit `2`. |
| 226–228 | No `rollback-record.json` → WARN: the backup predates the sidecar or was left incomplete; config restore and trust re-pin are unavailable. |
| 230–242 | **Empty-backup gate:** counts the payload exactly the way `Get-VesBackupSet` does (sidecars and `_ves-config` excluded). Zero files → "Mirroring it would wipe production", exit `10`. |
| 244–264 | **Partial-backup gate:** compares files on disk against the `fileCount` the deploy's own `backup-manifest.json` recorded. Fewer → "the backup copy died part-way", exit `2`. Read raw from JSON, not through `Import-VesManifest` — a manifest too damaged to load is exactly when this guard matters most. |
| 276–285 | `-RepinTrust` preconditions: refuses without a recorded prior SSM value ("re-pinning to a blank anchor would break every later verify"). |
| 287–316 | Builds the robocopy exclusions: the two sidecars by name, the `_ves-config` stash by full path, any operator `-PreservePaths` (with a WARN if a preserved path is hash-verified and will therefore show as drift), and the live config when `-NoConfigRestore` asked to keep it. |
| 318–325 | `-WhatIf`: block-level `ShouldProcess` (robocopy is native and gets no automatic `-WhatIf`) — reports exactly what would be restored, changes nothing, exits `0`. |

### The restore (lines 327–402)

| Lines | What happens |
| --- | --- |
| 327–338 | **Concurrency lock:** `%ProgramData%\ves-verify\<processor>.rollback.lock` opened `CreateNew` — two concurrent `/MIR` runs into one tree corrupt it; a second rollback refuses with exit `2`. |
| 340–344 | Quiesce via the module's **`Stop-VesProcessorTarget`** — the same disable-tasks / stop-service / detect-and-kill-instances sequence a deploy uses. |
| 345–355 | **The restore copy:** `robocopy <backup> <TargetRoot> /MIR` with the exclusion lists. `/MIR`, not `/E`, deliberately: `/E` would leave the bad release's files behind and every one would surface as EXTRA in the post-rollback verify. Exit ≥ 8 → restore failed. |
| 357–379 | **Out-of-tree config restore:** copies the stashed config back — after first stashing the *current* config to `_ves-config\pre-rollback\`, so the rollback is itself reversible. |
| 382–391 | `finally`: **`Start-VesProcessorTarget`** restarts the service and re-enables exactly the tasks that were disabled, even on failure — production is never left down. Tasks are *started* after a clean restore by default (`-NoStartTasksAfter` opts out) — a rollback that leaves the processor down fails its own health check. The lock is always released. |
| 393–401 | Could not quiesce → exit `2` (tree untouched). Restore copy failed → exit `2`: "a half-mirrored tree is an ERROR (indeterminate), not a clean FAIL." |
| 402 | `Rollback complete: <Processor> restored from <backup>`. |

### Prove it (lines 404–530)

| Lines | What happens |
| --- | --- |
| 404–425 | **Baseline ladder, strongest first:** `-BaselineRepo`+`-ReleaseTag` (the archived tag) → `-ManifestPath` (a manifest for the restored release) → the backup's own `backup-manifest.json` (proves the restore is byte-identical to pre-deploy production, but **not** that that state was approved — WARNed as such). "Verifying a restored old tree against the new release's manifest is the likeliest way to make a good rollback look like a bad one, which is what this ladder prevents." |
| 427–435 | No baseline at all → exit `2`, unless the operator explicitly accepts the risk with `-AllowUnverifiedRollback`. |
| 436–454 | Runs `Invoke-Verification.ps1` against the chosen baseline; a non-zero verify becomes the rollback's own outcome. |
| 456–466 | Informational pin check: `OK` (restored tree matches the SSM-pinned prior baseline) or `DRIFT` (it matches pre-deploy production, which itself had drifted). |
| 468–493 | **Health check runs even when the verify failed** — "an operator looking at a half-restored box needs the whole picture in one run." Skippable with `-SkipHealth`. |
| 495–527 | **Trust re-pin — last, opt-in, and only on a proven restore:** skipped with an ERROR if verify didn't pass ("pinning the anchor to an unproven tree is exactly what the anchor exists to prevent"). The audit line is written *before* the SSM write so intent is on record even if it fails; one switch drives **both** the baseline hash and the approved commit, because re-pinning only one leaves the gate and the verifier disagreeing. |
| 529–530 | Final exit = `Get-VesWorstExitCode` over verify + health — severity order, not numeric (`2` outranks `3`). |

---

## 5. Shared library — `module/VesVerify.psm1` (lines 607–921)

| Lines | What happens |
| --- | --- |
| 607–611 | The section contract: the deploy backs up to `<BackupRoot>\<stamp>_<Initials>_<Processor>`; `Invoke-Rollback` restores from it; both enumerate through the same function "so they can never disagree about what counts as a backup." |
| 633–740 | **`Get-VesBackupSet`** — enumerates a processor's backups, newest first. Accepts both the timestamped and legacy date-only shapes; parses the stamp (falling back to the folder's own `LastWriteTime` rather than dropping it); reads both sidecars defensively; counts/sizes the payload with sidecars and `_ves-config` excluded; `FileCount = -1` means "could not enumerate", distinct from empty. Used by the deploy's prune (`Deploy-Processor.ps1:628`), the restore picker, and `-ListBackups`. |
| 742–860 | **`Stop-VesProcessorTarget`** — the one quiesce implementation: disable tasks, stop service, detect console-EXE instances by ExecutablePath-under-TargetRoot, kill with audit lines only under `-KillProcesses`, wait for handles to release. Never throws; `Stopped=$false` means "do not touch the tree." Called by both the deploy (`Deploy-Processor.ps1:531`) and the rollback (`Invoke-Rollback.ps1:343`). |
| 862–921 | **`Start-VesProcessorTarget`** — the mirror image, designed for a `finally`: service first, re-enable exactly the tasks that were disabled, optionally trigger them now. Never throws. Called from both scripts' `finally` blocks. |

---

## 6. How it fails

| Scenario | Behavior | Exit |
| --- | --- | --- |
| Backup robocopy fails during a deploy | Deploy aborts **before** stop/copy; production untouched and running | `1` |
| Sidecar/evidence gathering fails during a deploy | WARN only; recorded in `recordErrors` — evidence degrades, the deploy proceeds | (stage codes) |
| `BackupRoot` nested in `TargetRoot` (either script) | Refused before any mutation | `10` |
| `-AutoRollback` without `-BackupRoot` | Refused before the gate even runs | `10` |
| Auto-rollback restores + proves the prior release | Deploy still exits with the **failing stage's** code | `1`/`3` |
| Auto-rollback restores but cannot prove/health-check it | `RESTORED BUT UNPROVEN` | `2` |
| Auto-rollback unavailable (no backup taken) or failed | Manual recovery required | `2` |
| Rollback: empty backup folder | Refused — "mirroring it would wipe production" | `10` |
| Rollback: partial backup (fewer files than its manifest recorded) | Refused | `2` |
| Rollback: cannot quiesce / restore copy fails | Tree untouched, or declared INDETERMINATE; processor restarted either way | `2` |
| Rollback restored but verify reports drift / health fails | Restored, not proven / not alive | `1` / `3` |
| Rollback with no baseline for the restored release | ERROR unless `-AllowUnverifiedRollback` | `2` / `0` |
| Concurrent rollback for the same processor | Second run refuses (lock file) | `2` |
| Prune fails after a green deploy | WARN only | `0` |
| `-WhatIf` (either script) | Reports, changes nothing | `0` |

---

## 7. Changelog note — issues from the previous revision of this document

The 2026-08-04 review of commit `d1f58d74` flagged four defects. All four are resolved at `7cd3a7a3`:

1. ~~Rollback validation was dead code (execution ran before validation)~~ — the inline rollback block is gone; `-Rollback` now delegates immediately to `Invoke-Rollback.ps1`, which validates before mutating.
2. ~~`$rollbackOnlyProvided` counted `-BackupRoot` and blocked every deploy that supplied it~~ — now only `-RollbackBackup`/`-RollbackReason` (`Deploy-Processor.ps1:178-181`), with a comment recording why, and a regression test (`tests/Deploy-Processor.Tests.ps1:93-99`).
3. ~~Module comment referenced a non-existent `Invoke-Rollback`~~ — the script now exists and owns the restore path.
4. ~~Deploy wrote neither the sidecars nor the timestamped folder shape the module expected~~ — Stage 2 now writes `backup-manifest.json`, the `_ves-config` stash, and `rollback-record.json` (last), under `yyyyMMddTHHmmss` names; the deploy's quiesce/restart and prune now go through the module functions.

---

## Related files

- Tests: `tests/Deploy-Processor.Tests.ps1` (backup, sidecars, prune across both shapes, `-AutoRollback`, `-Rollback` alias), `tests/VesVerify.Backup.Tests.ps1` (module backup-set functions)
- Runbook: `docs/RUNBOOK.md`
- Full-suite walkthrough: `docs/SCRIPT-GUIDE-LINE-BY-LINE.md`
