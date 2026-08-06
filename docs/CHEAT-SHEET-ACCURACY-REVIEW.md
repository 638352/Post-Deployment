# Accuracy review: "Post-Deployment Verification Cheat Sheet" (non-technical, 3 pages)

Reviewed 2026-08-06 against the scripts on `claude/document-accuracy-review-d7idsj`.
Source document: `VesVerify_Cheat_Sheet_NonTechnical.pdf`, dated August 5, 2026.

Every claim in the cheat sheet was checked against the actual source. Findings are
ordered by how much they mislead a leadership reader. Simplification for a general
audience is not treated as an error — only statements that are stale, factually
wrong, or that would leave a reader with an incorrect mental model.

---

## Critical — describes technology that is not in the scripts

### C1. The trust anchor is not AWS Parameter Store (§2, §3 stage 1, §4 Preflight row)

Three separate places still describe AWS:

| Where | Current text |
|-------|--------------|
| §2 | "The baseline has a fingerprint of its own, and that one is **stored in AWS Parameter Store in encrypted form**." |
| §3, stage 1 | "Capture. Fingerprint the UAT-approved files and **store the result in Parameter Store**." |
| §4, Invoke-Preflight | "Checks the server, **the AWS access**, and the baselines are all usable…" |

AWS/SSM was removed. The approved manifest is now committed under
`baselines/<processor>/` in a **Git release archive** and tagged
`<system>/vMAJOR.MINOR.PATCH`; verification and the gate read the manifest back out
of that tag.

Evidence: `module/VesVerify.psm1:524-537`, `README.md:114-118`,
`docs/RUNBOOK-NON-TECHNICAL.md:8`, `Invoke-Preflight.ps1:18-19`,
`Invoke-PreDeployGate.ps1:11-14`. The parameters `-TrustParam`,
`-ApprovedCommitParam` and `-Region` no longer exist; the scripts take
`-ArchiveRepo`/`-BaselineRepo` and `-ReleaseTag`.

Preflight actually checks: PowerShell version, release-tag readability, manifest
integrity and anchoring, config-contract parse, and target inventory
(`Invoke-Preflight.ps1:83-250`). It performs no AWS check — the Datadog probe that
once lived there is commented out (`Invoke-Preflight.ps1:190-203`).

**Suggested replacement (§2):**
> The baseline has a fingerprint of its own, and the approved copy is filed in a
> separate release archive — a Git repository where each approved release is
> recorded under its own release tag. Anyone who edits the baseline file sitting on
> the server is caught, because the archived copy no longer agrees with it.

**Suggested replacement (§3, stage 1):**
> Capture. Fingerprint the UAT-approved files and file the result in the release
> archive under that release's tag.

**Suggested replacement (§4, Preflight row):**
> Checks the server, the release archive, and the baselines are all usable before
> anything else runs. It reads only and changes nothing.

### C2. The strength of the guarantee in §2 has changed and the document does not say so

> "Anyone who edits the baseline file sitting on the server is caught, because the
> stored copy no longer agrees with it."

Still true in shape, but materially weaker than when it was written, and this is the
one sentence in the document that a control owner will lean on.

Under the old design the trusted hash was write-gated by IAM. Under the tag anchor,
the source says plainly: *"SSM read/write was gated by IAM, whereas the tag is only
as immutable as the archive remote makes it. Whoever can move a tag can author an
approval"* (`module/VesVerify.psm1:533-537`; same warning at
`Invoke-PreDeployGate.ps1:16-20` and `README.md:105-108`).

Worse for the document's framing: enforcing who may move tags is still an **open
item**, not a control in force (`README.md:607-611`;
`docs/UAT-PILOT-CHECKLIST.md:12`).

There is also a second-order point the document may want to make, since it opens by
justifying the tool's existence: the AWS anchor it describes was never actually
operating. *"There is no AWS in this environment and there never was, so that anchor
was always vacant — Set-VesTrustedHash never once succeeded, and every verify ran
unanchored"* (`module/VesVerify.psm1:528-530`). The tag anchor is the first working
version of this control, not a downgrade from one that was running.

**Suggested addition after the §2 sentence:**
> That protection rests entirely on the release archive: only the release authority
> may move a release tag. Setting and enforcing that permission is an open item and
> must be closed before the first production deployment.

---

## Major — accurate-sounding but leaves the reader with the wrong picture

### M1. §4's script table omits Invoke-Rollback.ps1, and the Deploy-Processor row is incomplete as a result

`Invoke-Rollback.ps1` is a first-class script (~30 KB, its own 20 KB test file,
listed in the README layout at `README.md:30`). It restores a processor from a
deploy backup and then proves the restore by re-running verification and the health
check.

Because it is missing, the Deploy-Processor row is also incomplete:

> "Any failed step stops the rest."

True as far as it goes, but with `-AutoRollback` a failed post-deploy verify or
health check triggers a restore of the previous release before the deploy reports
failure (`Deploy-Processor.ps1:32`, `:116`, `:495-551`). A reader told only that
failures "stop the rest" will not expect production to have been changed back.

**Suggested new row:**
> `Invoke-Rollback.ps1` — Puts the previous release back from the backup taken at
> deploy time, then re-checks and re-tests it to prove the restore worked.

**Suggested amendment to the Deploy-Processor row:**
> …Any failed step stops the rest, and the deploy can optionally put the previous
> release back automatically if the checks fail after the copy.

### M2. §7 — Datadog is not "switched off by default"; it is commented out of the code

> "Datadog reporting is switched off by default, and the infrastructure it needs has
> not been confirmed."

"Switched off by default" reads as a setting someone can flip. It is not. The
integration is commented out in source across the module and every entry script, and
`-CheckDatadog` no longer binds — restoring it takes a code change and a re-test,
not a configuration change (`README.md:450-454`; `DATADOG DISABLED` blocks in
`Deploy-Processor.ps1:128`, `:302`, `:678`; `Start-DriftRunner.ps1:148`, `:165`,
`:176`, `:189`; `Test-DriftHeartbeat.ps1:70`, `:91`; `Invoke-Preflight.ps1:190-203`).

The consequence is sharper than the current wording admits: *"Exit codes + JSONL
logs are the **only** signal… nothing reaches a dashboard today"* (`README.md:612`),
and for the missed-run watchdog specifically, *"there is **no** push path to
on-call"* (`README.md:553-556`).

**Suggested replacement:**
> There is no automatic alerting. Reporting to Datadog has been removed from the
> code rather than switched off, so nothing reaches a dashboard or an on-call
> person today. Results are exit codes and log files, and someone has to be
> assigned to read them. Restoring the alerting is a code change, and the
> infrastructure it would need has not been confirmed.

### M3. §5 — most runs legitimately produce no log file

> "A log file records the run, and a run with no log is treated as a failed run."

Logging is opt-in for the read-only scripts. Verification, config, health, preflight
and the gate write a JSONL record only when `-LogFile` is passed; otherwise they
report to the console and exit code alone (`README.md:441-444`;
`Verify-Config.ps1:49`; `Invoke-HealthCheck.ps1:60`;
`docs/RUNBOOK-NON-TECHNICAL.md:271` — *"verification scripts write one only when
`-LogFile` is used"*). Only Deploy-Processor, the drift runner and the heartbeat
watchdog log by default.

As written, the rule would condemn the majority of normal passing runs. It is also
the rule a tester would apply during the phase C sign-off described in §6.

**Suggested replacement:**
> A log file records the run when one is asked for. Deployments and the scheduled
> checks always write one — those files are the audit record, and a deployment or
> scheduled check with no log is treated as a failed run. The other scripts write a
> log only when told to, so ask for one on anything being kept as evidence.

### M4. §2/§3 — configuration files are deliberately excluded from the fingerprint

> "the tool takes a fingerprint of **every approved file**" … "Anything missing,
> extra, or altered is reported by name."

The default exclusion drops `logs\`, `temp\`, `cache\`, `.git\` and any `.log`,
`.tmp`, or **`.config`** file (`module/VesVerify.psm1:29-45`). `.config` is excluded
by design, because config legitimately differs from server to server; it is checked
structurally by `Verify-Config.ps1` instead, which is why that script exists.

The document describes both mechanisms but never connects them, so a reader is
likely to assume a changed config setting is caught by the fingerprint check. It is
not — and if config verification is not wired up for a given system, nothing catches
it. (Within its scope, "missing, extra, or altered … reported by name" is exactly
right: `Invoke-Verification.ps1:324-326` emits `MISSING`, `CHANGED`, `EXTRA`.)

**Suggested addition to §2:**
> Two things are deliberately left out of the fingerprint: throwaway files like logs
> and temporary data, and the configuration files themselves. Configuration is
> expected to differ from one server to the next, so fingerprinting it would report
> a false alarm every time. It is checked separately, against an agreed list of
> settings — that is what Verify-Config does.

### M5. §7 omits that the scheduled Watch stage cannot report success today

§3 presents stage 5 as running ("Every 30 minutes by default"), and §7 softens the
gap to "the per-system paths are still being confirmed."

The actual behaviour is stronger and is a deliberate control: the inventory is
marked `inventoryComplete: false` (`targets.json:3`) and the drift runner **fails
closed** — an incomplete or unconfirmed inventory throws with *"Target inventory is
incomplete or invalid; no drift target was reported clean"*
(`Start-DriftRunner.ps1:103-108`; `module/VesVerify.psm1:194-199`). Citrix server
names in particular are not yet documented (`README.md:585-587`).

This is worth stating positively — the tool refuses to claim coverage it does not
have — but as written, a reader would believe the 30-minute check is already
watching production.

**Suggested replacement for the §7 bullet:**
> The server and folder inventory is not complete — Citrix server names in
> particular are still missing. Until it is signed off, the scheduled check refuses
> to report success at all, rather than claim it is covering servers nobody has
> confirmed.

---

## Minor — correct enough, but worth tightening

### m1. §4 — Install-DriftTask registers two scheduled tasks, not one
> "Sets up the Windows scheduled task that calls the runner on a fixed interval."

It registers `ves-verify-drift` **and** `ves-verify-drift-watchdog`
(`Install-DriftTask.ps1:23-24`, `:118-120`). Since §4 separately describes
Test-DriftHeartbeat as "a separate watchdog," naming its installer closes the loop:
> Sets up the two Windows scheduled tasks — the one that calls the runner on a fixed
> interval, and the watchdog that checks the runner is still firing.

### m2. §5 — a non-zero result from Invoke-Tests is not always a failing-test count
> "Invoke-Tests reports the number of failing tests, so zero means everything passed."

Zero does mean everything passed. But if Pester 5.x is not installed, the script
exits **2** without running a single test — its own header flags this: *"Missing
Pester exits 2 — that is a runner signal, not the suite's usage (10) / trust (2)
contract"* (`Invoke-Tests.ps1:10-11`, `:34-38`). Suggest: "…so zero means everything
passed. A `2` can also mean the test tool itself is not installed, in which case
nothing ran — the screen output says which."

### m3. §5 — Preflight has a third state, and it matters
> "Invoke-Preflight reports ready or not ready."

There is a WARN state that still reports READY. A manifest that is internally
consistent but **not anchored** to a release tag warns and passes
(`Invoke-Preflight.ps1:179`, `:277-289`; `docs/RUNBOOK-NON-TECHNICAL.md:110`). So
"ready" does not by itself mean "checked against the approved release." Suggest:
"…reports ready or not ready, and can report ready with warnings — read them, because
one of them means the baseline has not been matched to an approved release yet."

### m4. §5 — the Verify-Config note is correct; the cause is a one-line omission
> "The one exception is Verify-Config, which currently reports on screen and in its
> log without leaving a number behind. That is on the fix list."

Accurate as observed. For whoever picks up the fix: `Verify-Config.ps1:226` has an
`if ($ExitWithCode) { exit $VES_EXIT_NOBASE }` branch, but `-ExitWithCode` is not
declared in the param block (`Verify-Config.ps1:41-46`), so the variable is always
empty and the branch is unreachable. Run through `Invoke-Verification -Mode
VerifyConfig` the exit code is correct (`Invoke-Verification.ps1:345-351`) — only
the direct run is silent. Worth adding to §5: "…when it is run on its own. Run as
part of the main verification it does leave a number behind."

### m5. §4 — Invoke-Verification has four modes, not two
> "Captures a baseline from approved files, or compares a folder against one."

The modes are Capture, VerifyFiles, VerifyConfig, and All
(`Invoke-Verification.ps1:38`). The description omits config verification, which the
cheat sheet treats as a distinct capability elsewhere. Suggest: "…or compares a
folder against one — files, configuration settings, or both."

### m6. §5 — code 1 is also the gate's "blocked" result
The table defines `1` as "Drift — Something differs from the baseline. The output
names it." The pre-deploy gate also exits `1` when it blocks a deploy
(`Invoke-PreDeployGate.ps1:112`, header line 36). The reader's action differs: for a
gate block the answer is "this is not the approved release, stop," not "look at the
named files." Suggest adding to the row: "From the gate, this means the release
being deployed is not the approved one."

---

## Confirmed accurate

Checked and correct as written — recorded so they are not re-opened:

- **The five stages and their order.** Deploy-Processor really runs gate → backup →
  stop → copy → restart → verify → health (`Deploy-Processor.ps1:326`, `:344-370`,
  `:557-583`, `:619`, `:642`).
- **"Every 30 minutes by default"** — `Install-DriftTask.ps1:22`.
- **Exit codes 0/1/2/3/10** and their meanings — `module/VesVerify.psm1:23-27`.
- **"This is never fixed by capturing a fresh baseline in production"** (code 2) —
  matches the trust model exactly.
- **Health check probes**: services, scheduled tasks, recent log activity, and
  whether required program files load — all four are real
  (`Invoke-HealthCheck.ps1:91-231`).
- **Start-DriftRunner "reports the worst result it found"** —
  `Start-DriftRunner.ps1:257`, ranked by severity rather than numeric value
  (`module/VesVerify.psm1:620-632`).
- **Missing / extra / altered files reported by name** —
  `Invoke-Verification.ps1:324-326`.
- **§7's remaining bullets** — does not deploy on its own, does not replace the build
  pipeline, not running in production yet, known defects logged
  (`README.md:572-620`).
- **The three "attack" tests named in §6** all have counterparts in the suite:
  `tests/Invoke-Verification.Tests.ps1`, `tests/Invoke-PreDeployGate.Tests.ps1`,
  `tests/Start-DriftRunner.Tests.ps1`.

### One observation on §6

The three testing phases (A/B/C), with their stated timings and risk levels, are not
documented anywhere in this repository — the closest artefact is
`docs/UAT-PILOT-CHECKLIST.md`, which is structured differently. If the test plan
lives outside the repo, nothing here contradicts it. One claim does undersell,
though: phase A is described as proving "the comparison logic itself is correct,"
but the automated suite covers considerably more — the gate, the deploy stage
machine, rollback, the drift runner, preflight, config contracts and backup
handling (ten test files under `tests/`). Suggest: "The suite's own logic is
correct — the comparison, the gate, the deployment steps, and the rollback."

---

## Separate finding: an error in README.md, not the cheat sheet

`README.md:30` states the deploy order as `gate -> stop -> backup -> copy -> restart
-> verify -> health`. The backup is taken **before** the stop
(`Deploy-Processor.ps1:344-370` precedes `:557-566`). The cheat sheet has this
right and the README has it wrong; the README line should read
`gate -> backup -> stop -> copy -> restart -> verify -> health`.
