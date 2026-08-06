# ves-verify

Interim verification for legacy Windows systems still deployed by manual file
copy. Confirms production matches the UAT-approved release and detects drift
afterward. Bridge until these systems get a real pipeline.

Target runtime: Windows PowerShell 5.1. Trust anchor: a Git baseline archive
repo whose release tags name each approved baseline. Results are exit codes
plus structured JSONL logs; wire those into whatever monitoring you already run.

## Layout

```
module/VesVerify.psm1        shared functions
Invoke-Preflight.ps1         read-only self-check: baseline intact + tag anchor readable
Invoke-Verification.ps1      Capture / VerifyFiles / VerifyConfig / All
Verify-Config.ps1            config contract check (called by the above)
Invoke-PreDeployGate.ps1     blocks deploys that don't match the approved release
Invoke-HealthCheck.ps1       assembly load, service, scheduled-task, log, endpoint
Start-DriftRunner.ps1        scheduled re-verify, writes per-target JSONL logs
Test-DriftHeartbeat.ps1      independent missed-run watchdog
Install-DriftTask.ps1        registers the runner + watchdog scheduled tasks
Deploy-Processor.ps1         gate -> stop -> backup -> copy -> restart -> verify -> health
Invoke-Rollback.ps1          restore a backup, prove it, emit a restore attestation
processors/                  one thin deploy script per system (template inside)
targets.json                 fail-closed server/Citrix inventory starter
sample.config.json           example config contract
SERVERS.md                   authoritative server + processor path map
docs/                        operator runbooks (start at docs/README.md)
Invoke-Tests.ps1             dev-time Pester runner (see Testing)
tests/                       Pester test suite + fixtures
```

## Where this runs (OMS)

**Scope (per the leadership brief):** OMS .NET executables, PowerBuilder
binaries, and their configurations — everything still deployed by manual file
copy, including every Citrix server that receives a deployment copy. Gateway
cloud services and MERA are **excluded** because they already have standard
deployment processes; tying them to this Git release discipline is planned as
later work. Database objects (stored procedures, triggers, views) fit the same
SHA-256 capture-and-verify pattern and are planned as a fast follow, kept out
of the current scope to protect the two-week timeline.

This suite does NOT target the Salesforce (Copado) or CDK-managed AWS paths,
which already have pipelines. Two execution contexts:

- On-prem Windows servers, where files/services/tasks/logs physically live.
  Outbound egress: UAT VESMSEGRESSUAT (all three processors on one box), PROD
  split across VESEMSEGRESS01/02/03 (VEMS-5346). Inbound: UAT VESEMSINGRESUAT,
  PROD VESEMSINGRESS01 (real-time) / VESEMSINGRESS02 (Handler). Java hosts
  VESOMSVEMS01/02. SQL VESSQLOMS101 (OMS2) in PROD. Citrix server list is
  pending (see Open items). See SERVERS.md for the full per-server/per-processor
  path map. MERA (VESMERA01) is out of scope for this effort — defer to the
  MERA team's existing deployment process. Run locally on each box or from a
  central runner over WinRM.
- The baseline archive: a Git checkout holding the tag-archived release
  records, reachable from wherever capture, the gate, verification, preflight,
  and the drift runner execute. Capture commits into it; every other script
  only reads a manifest back out of a release tag. Keep a clone on (or
  reachable from) each runner and push capture records off-host with
  `-PushRemote` so the record survives the workstation that wrote it.

Two target shapes drive the -ServiceName vs -ScheduledTasks split. The Java
services run as Windows services with a Spring Boot actuator endpoint. The
outbound processors are console EXEs with no health endpoint: a single
VES.OutboundDBQProcessor.exe is deployed per processor folder and launched by a
.bat (mode by arg: Ack/XML = RTP, DBQ = RTPDP), typically triggered by Task
Scheduler. Prove those alive via task last-run + a fresh log line. Note the same
exe name runs 2-3 times per box, so an instance is identified by its working
dir / arg, not by process name (see SERVERS.md).

Capture, file verify, and config verify are modes of one script rather than
three tools. Replaces the older Verify-Deployment.ps1.

## Exit codes

0 pass, 1 file/config drift, 2 no baseline / anchor unreadable or untrusted
(also inventory/runtime errors), 3 health failure, 10 usage or unsafe
configuration. These map to the brief's three outcomes:
`PASS` (0), `FAIL` (1 or 3), and `ERROR` (2 or 10). A missing baseline,
incomplete inventory, dead check, or unconfigured health probe is never a pass.

Severity is not numeric order: `2` (ERROR) outranks `3` (FAIL), so a script
combining several stage results ranks them `10 > 2 > 3 > 1 > 0`
(`Get-VesWorstExitCode`).

Rollback uses the same contract, read as: `2` means **production state is not
proven** — no usable backup, a partial one, a failed restore copy, or no
baseline to verify the restored release against. A deploy that auto-rolls-back
exits with the code of the stage that failed (`1` or `3`), never `0`: rolling
back is remediation, not success.

## Trust model

The manifest sits next to the artifacts, so by itself it proves nothing:
whoever can edit prod files can re-capture the manifest beside them and the two
will agree. The anchor is therefore the Git baseline archive. Capture commits
the manifest under `baselines/<Processor>/` in that repo and tags the commit
`<system>/vMAJOR.MINOR.PATCH` — the tag IS the approval record. Verification
and the gate read the manifest back out of the tag, a separate Git object the
deployer cannot rewrite without moving the tag, which covers the case where
someone edits prod files and the local manifest together.

Be honest about what that rests on: the tag's integrity is the whole control.
Who can move (force-push, delete, re-create) release tags in the archive remote
is the entire trust boundary — a deployer who can move a tag can author their
own approval. Restrict tag pushes on the archive remote to the release
authority and treat any moved tag as an incident. A verify run without the tag
anchor (`-AllowUnanchoredVerify`) is an explicit, loudly-logged opt-in: a pass
there proves only that two local files agree, never that production matches an
approved release. Use it as a local drift-scan tool, not release evidence.

> Changed 2026-08-05: the trust anchor moved from AWS SSM Parameter Store to
> the Git baseline archive. `-TrustParam`, `-ApprovedCommitParam`, `-Region`,
> `-AllowCommitOnly`, `-AllowUntrustedCapture`, and `-RepinTrust` no longer
> exist; the approved commit now lives inside the tag-archived manifest, and
> archival at capture time is the activation step (there is no separate pin).

## Usage

One-time setup per environment: create (or clone) the baseline archive repo,
then decide and enforce who may move release tags in it — that permission is
the trust boundary (see Trust model). After that, the first Capture below is
all the activation there is.

Capture at UAT sign-off:

```powershell
.\Invoke-Verification.ps1 -Mode Capture -ReleaseRoot D:\uat\<system> `
  -ManifestPath D:\baselines\<system>.json `
  -ArchiveRepo D:\ves-verify -ReleaseTag <system>/v1.4.0 `
  -Processor <system> -CommitSha (git rev-parse HEAD) -PushRemote
```

-ArchiveRepo/-ReleaseTag are the anchor: the manifest (and contract, when
passed) are committed under `baselines/<processor>/` in that checkout and the
commit is tagged, so every approved release leaves a Git-tagged rollback/audit
point. Archival IS activation — committing and tagging the record is what makes
this release the approved one; there is no separate pin step. Tagged rollback
points begin with the first verified release; anything shipped before that
still needs a safe baseline determined manually (the generated release record
carries the same note). `-ReleaseTag` must match `<system>/vMAJOR.MINOR.PATCH`;
anything else is rejected (exit 10). `-CommitSha` must be a real value — the
recorded commit is what the pre-deploy gate later accepts as approved, so an
empty or `'unknown'` value is refused (exit 10). Add `-PushRemote` (with
optional `-Remote`, default `origin`) to push the commit and tag off-host
immediately — a failed push fails the capture, because a release record that
exists only on one workstation is not an audit trail. Capture also generates
`release-record.json` with the release tag, source commit, manifest hash, file
count, and approval provenance. It also records `previousManifestHash` — the
manifest hash of the release record already in the archive, read before this
capture overwrites it — so the tagged records chain and a rollback target can
be identified from the archive alone. A first capture (or an unreadable prior
record) leaves it null with a warning rather than failing. When a prior
baseline is being superseded, capture logs a WARN naming both hashes, because
that supersession is what a rollback would have to undo.
`-ArchiveRepo` and `-ReleaseTag` are required; capture fails closed if either
is missing. The `-AllowUnarchivedCapture` switch exists only for isolated local
tests and must not be used for an approved release.

The archived record is not write-only: the gate and verification read the
baseline manifest back out of the release tag instead of a local file, which is
the brief's "inspect the artifact against the manifest in the Git release tag":

```powershell
# post-deploy / drift check anchored to the tagged record
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot C:\Procs\<system> `
  -BaselineRepo D:\ves-verify -ReleaseTag <system>/v1.4.0 -Processor <system>

# pre-deploy gate against the tagged record
.\Invoke-PreDeployGate.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> `
  -BaselineRepo D:\ves-verify -ReleaseTag <system>/v1.4.0 -Processor <system>
```

The gate requires `-BaselineRepo` and `-ReleaseTag` (exit 10 without them, and
a malformed tag is also exit 10): the tag-archived manifest supplies BOTH the
approved commit (the `commitSha` recorded inside it) and the baseline content
hash, so there is no separate approved-commit store and no commit-only mode —
passing on a commit string alone would prove nothing was inspected. Gate exits:
0 pass, 1 blocked, 2 anchor unreadable/untrustworthy, 10 usage. Verification
likewise refuses to pass unanchored: without `-BaselineRepo`/`-ReleaseTag` it
exits 2 unless `-AllowUnanchoredVerify` is passed explicitly (loudly logged; a
pass then proves only file-match against a local manifest, not approval — a
drift-scan tool, never release evidence). Deploy-Processor accepts
`-ReleaseTag`/`-BaselineRepo` (both required for a deploy) and threads them
through the gate, verification, and health stages, so every stage's run log
records which release tag it checked.

Preflight before a deploy (read-only; touches no prod or staged files). Checks
the PowerShell version (5.1, not 7.x), that the baseline manifest is intact and
self-consistent and — when `-BaselineRepo`/`-ReleaseTag` are supplied — matches
the manifest archived under the tag, and that the config contract parses. An
unanchored manifest is a WARN ("NOT anchored"; readiness unaffected), but a
CONFIGURED anchor that cannot be read is a hard FAIL — indistinguishable from a
tag deleted to hide a change. Exit 0 = ready (WARNs allowed), 2 = not ready:

```powershell
.\Invoke-Preflight.ps1 -Processor <system> `
  -ManifestPath D:\baselines\<system>.json `
  -BaselineRepo D:\ves-verify -ReleaseTag <system>/v1.4.0

# or validate every drift target's baseline at once (each target anchors
# against its own releaseTag from the inventory):
.\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json -BaselineRepo D:\ves-verify
```

`targets.json` uses the `ves.targets.v1` root schema. Set
`inventoryComplete=true` only after `requiredServers` lists every server that
receives a manual deployment copy (including all Citrix targets) and every
server/processor entry is marked `inventoryStatus: "confirmed"`. Preflight and
the drift runner reject a legacy array, placeholders, incomplete coverage,
duplicate server/processor entries, or missing release/file/config fields
(`releaseTag` is required per target — it is the field each target is anchored
against). The
checked-in file is intentionally incomplete because the Citrix inventory and
several production paths are not available in this repository; it cannot
produce a false claim of full coverage.

Deploy (pilot in dev/qa first). Each system gets its own thin script in
processors/ that pins the fixed values and calls Deploy-Processor.ps1; copy
processors/Deploy-SYSTEM_NAME.ps1 to onboard a system. -WhatIf runs the gate
only, no copy:

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> `
  -ReleaseTag <system>/v1.4.0 -BaselineRepo D:\ves-verify -WhatIf
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> `
  -ReleaseTag <system>/v1.4.0 -BaselineRepo D:\ves-verify
```

`-ReleaseTag` and `-BaselineRepo` are mandatory on the wrappers because
Deploy-Processor refuses an unanchored deploy — there is no way to ship without
naming the approved release being shipped.

Deploy-Processor.ps1 can still be called directly with the full parameter set
when scripting something one-off.

## Rollback

Every deploy that is given `-BackupRoot` writes its restore point first:

```
<BackupRoot>\<yyyyMMddTHHmmss>_<Initials>_<Processor>\
    <the whole pre-deploy tree>
    backup-manifest.json     SHA-256 of the tree that was replaced
    rollback-record.json     what replaced it (incoming release tag, commit,
                             and incomingManifestHash), the config stashed, and
                             the baselineRepo in force at the time (written
                             LAST, so its absence means the backup may be
                             incomplete)
    _ves-config\             a config living outside TargetRoot, which the
                             mirror would otherwise leave unrecoverable
```

The folder name carries a **time**, not just a date: with date-only names a
second deploy on the same day by the same operator backed up the
already-overwritten tree into the same folder and destroyed the true pre-deploy
state. Older date-only folders are still restorable.

Look before you leap — this is read-only and touches nothing:

```powershell
.\Invoke-Rollback.ps1 -Processor <system> -BackupRoot <BackupRoot> -ListBackups
```

Then dry-run, then restore. `-Reason` is required and goes in the audit log:

```powershell
.\Invoke-Rollback.ps1 -Processor <system> -TargetRoot <live tree> `
  -BackupRoot <BackupRoot> -Reason 'VEMS-1234 bad release' `
  -BaselineRepo D:\ves-verify -ReleaseTag <system>/v1.3.0 `
  -FreshLogDir <logs> -WhatIf
```

Note `-ReleaseTag` here names the release being RESTORED (the prior one, e.g.
v1.3.0 when rolling back v1.4.0), not the release being removed.

`Deploy-Processor.ps1 -Rollback -RollbackReason '...'` is an alias for the same
thing, for an operator already holding the deploy command line.

A rollback proves itself. After the restore it re-runs verification and the
health check, choosing the baseline for the **restored** release, strongest
source first:

1. `-BaselineRepo` + the prior release tag (the tag-archived manifest).
   Configure `-BaselineRepo` on production boxes so this rung is available — it
   is the only one that proves the restored release was approved.
2. an explicit `-ManifestPath` for the prior release.
3. the backup's own `backup-manifest.json`. This proves the restore matches
   pre-deploy production; it does **not** prove that state was approved, and the
   run says so.
4. nothing → exit 2. A restore whose result cannot be checked is not a pass;
   `-AllowUnverifiedRollback` downgrades that to a warning when no manifest for
   the prior release exists.

Verifying a restored old tree against the *new* release's manifest is the
likeliest way to make a good rollback look like a bad one, which is what that
ladder prevents. Note `-ManifestPath` on the box normally holds the new release.

**Re-pointing the trust anchor is a separate, deliberate, human step.** Nothing
automated ever moves a release tag. On a proven restore the run emits an
ATTESTATION naming the restored release — and warns that the archive still
marks the rolled-back release as approved. The operator must re-point the
approved release tag by hand before the next deploy, or the gate will compare
against the release that was just removed. A restore that did not pass its own
verification is loudly NOT attested and makes no claim about what is now
running in production.

Automatic rollback is opt-in per deploy:

```powershell
.\Deploy-Processor.ps1 ... -BackupRoot <BackupRoot> -AutoRollback
```

It restores when the post-deploy verify or the health check fails, and the
deploy still exits with that stage's code. `-AutoRollback` without `-BackupRoot`
is refused before the gate runs. Three outcomes are distinguished in the log and
the exit code: `AUTO-ROLLBACK COMPLETE` (restored and proven; exit = the failing
stage), `AUTO-ROLLBACK RESTORED BUT UNPROVEN` (the tree is back but did not pass
its own verify/health; exit 2), and `AUTO-ROLLBACK FAILED` / `UNAVAILABLE`
(exit 2, production indeterminate). A machine-readable `ROLLBACK OUTCOME` record
carries the stage, both exit codes, and the backup folder.

Refusals, all before anything is touched: an empty backup (mirroring it would
wipe production), a backup with fewer files than its own manifest claims, a
`BackupRoot` that overlaps `TargetRoot` (the mirror would delete the restore
source — the deploy refuses this too), and a missing `-Reason`. A live
instance under `TargetRoot` blocks the
restore unless `-KillProcesses` is passed, exactly as it blocks a deploy.

Scheduled drift check, every 30 min or whatever cadence fits. Register it once
(elevated) and it runs as SYSTEM from Task Scheduler. The installer creates
both the drift task and an independent heartbeat watchdog; the watchdog exits 2
and emits an alert if the runner does not complete on time:

```powershell
.\Install-DriftTask.ps1 -TargetsFile D:\ves-verify\targets.json `
  -BaselineRepo D:\ves-verify `
  -IntervalMinutes 30 -LogDir \\audit-share\ves-verify\logs
```

`-BaselineRepo` is baked into the registered task; each target then anchors
against its own `releaseTag` from targets.json. Without it the scheduled check
runs UNANCHORED — it catches accidental drift but not a deliberate edit that
rewrote prod and the local manifest together — and every unanchored target gets
a loud WARN in the run log rather than a quiet pass.

Or run the runner by hand:

```powershell
.\Start-DriftRunner.ps1 -TargetsFile D:\ves-verify\targets.json -BaselineRepo D:\ves-verify
```

Health check by target type (any failure exits 3):

```powershell
# outbound .exe processor (no endpoint): task last-run + fresh log line
.\Invoke-HealthCheck.ps1 -Processor OutboundDBQ `
  -ScheduledTasks VLER_EM_Real_Time_Outbound_Processor `
  -ProcessPathRoot C:\VLER_Test\Processors\VES.OutboundProcessor `
  -ProcessArgumentPattern '\bRTPDP\b' `
  -FreshLogDir C:\VLER_Test\Logs\VES.OutboundProcessor -FreshLogMaxAgeMinutes 60

# Java/Spring Boot service: Windows service state + actuator probe
# (profile retained for the excluded gateway/MERA services -- later work)
.\Invoke-HealthCheck.ps1 -Processor pagecount `
  -ServiceName oms-vems-pagecount-prod `
  -HealthUrl http://localhost:9191/actuator/health
```

The console-EXE check matches `ExecutablePath` under the processor folder and
optionally the mode argument; process name alone is not enough when the same EXE
runs several times. A health invocation with no assembly, service, exact
process, task, fresh-log, or endpoint probe exits 10 instead of returning a
false green result.

Config contracts declare their checks in the contract file; see
Verify-Config.ps1 header and sample.config.json. A contract that still declares
`ssmExpectedValues` (a legacy key -> Parameter Store mapping) FAILS loudly as
unverifiable — there is no Parameter Store in this environment, so those values
cannot be checked, and a declared-but-unchecked setting must not look covered.
Move those keys to `expectedValues`, or remove them and cover the setting
another way. Contract `format` is appconfig (App.config/web.config), json, or
keyvalue (a Java application.properties file is keyvalue). Keys listed under
`sensitiveKeys` are compared on their real values but reported as `(masked)` on
mismatch, so a secret never lands in a log or report — list any secret-bearing
key there rather than relying on convention. A sensitive key under
`expectedValues` is rejected because that would store the secret in Git; use
`requiredKeys` for non-empty presence. As defense-in-depth, any key whose
name matches the secret-name pattern (password/pwd/secret/token/credential/
api-key/key/connectionstring, case-insensitive) is auto-masked in reports even
when the contract forgot to declare it — the explicit list is still the rule,
the pattern is the safety net for undeclared secrets.

The contract is exhaustive by default. Every live key must appear under
`requiredKeys`, `expectedValues`, `machineKeys`, or the explicit `ignoredKeys`
allowlist. Undeclared keys are reported as drift.
`machineKeys` may differ by environment but must still be present and non-empty.

Config files (\*.config) are excluded from the file-hash compare on purpose: the
legacy App.config carries server-specific log4net paths that differ every
UAT->PROD, so config is checked by contract (Verify-Config), not by hash. The
runtime dirs `logs\`, `temp\`, `cache\` and `.git\` are excluded too, at the root
and at any depth. All of this lives in one place — `$Global:VES_DEFAULT_EXCLUDE`
in module/VesVerify.psm1 — because capture and compare must use identical rules;
if they disagree, excluded files resurface as "Extra" and every check reports drift.

## Upgrading: re-capture baselines captured under the old exclude pattern

The exclude pattern previously matched `logs\`/`temp\`/`cache\`/`.git\` only when
nested, so a **top-level** one leaked into the baseline. Fixing that changes which
files a manifest contains, which changes its hash, so the tree no longer matches
the manifest archived under the release tag — the next anchored check would
report exit 2 (anchor untrusted / baseline unusable).

Only baselines whose release root actually has a top-level `logs\`, `temp\`,
`cache\` or `.git\` are affected. To find them without touching prod files:

```powershell
.\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json
```

Any target reporting a `manifest-pattern` **WARN** needs re-capture. WARN does not
block readiness, so a clean run here means nothing to do. For each flagged target,
re-capture and archive under a fresh release tag (then update the target's
`releaseTag` in targets.json to match):

```powershell
.\Invoke-Verification.ps1 -Mode Capture -ReleaseRoot <releaseRoot> `
  -ManifestPath <manifestPath> -Processor <name> -CommitSha <sha-or-label> `
  -ArchiveRepo <git-checkout> -ReleaseTag <name>/vX.Y.Z -PushRemote
```

Baselines with no such directory hash identically before and after the change and
need nothing.

Monitoring: JSONL audit logging is opt-in for the read-only verification
scripts (verification, config, health, preflight, gate) — pass `-LogFile` to
persist a record; otherwise they report to the console and exit code only.
Deploy-Processor, the drift runner, and the heartbeat watchdog still log by
default because their files are the deployment audit record and monitoring
signal. Set `VES_AUDIT_LOG_DIR` to a durable central share; the fallback is
`%ProgramData%\ves-verify\logs` (the scheduled runner keeps its explicit
`-LogDir`). Run boundaries carry a run ID, processor/release context,
PASS/FAIL/ERROR outcome, and exit code. The drift runner writes one timestamped
log per target plus a run summary and atomically updates
`ves-verify-drift.heartbeat.json`.

> **Telemetry push is currently disabled.** The Datadog integration is commented
> out in place across the module, all entry scripts, and the preflight probe;
> nothing is emitted and `-CheckDatadog` no longer binds. Exit codes and JSONL
> logs are the only signal. The description below is retained for reference and
> applies once the `DATADOG DISABLED` blocks are uncommented.

<!--
Datadog hooks in the gate/deploy/health paths are best-effort and never block
deploy/verify outcomes. Two independent transports with different prerequisites:

- **Events** (deploy/gate markers) POST to the ddog-gov Events API and need
  `DD_API_KEY` set; without it they are skipped with a warning. Drift, trust
  failure, runner error, and missed-heartbeat events are included. Production
  uses Datadog `error` severity; dev/qa/UAT use `warning`.
- **Metrics** (verify/health gauges) are DogStatsD packets to a _local_ Datadog
  Agent on `127.0.0.1:8125`. On any box without a running agent they are silently
  dropped — the primary check still runs, but nothing reaches the dashboard.
  `Invoke-Preflight -CheckDatadog` reports whether the `datadogagent` service and
  `DD_API_KEY` are in place.

Target inventory `environment` controls drift severity/tags. `DD_ENV` remains
the fallback for direct invocations.
-->

Target inventory `environment` still controls drift severity classification in
the logs.

## Brief conformance

Control mapping to the tracked leadership brief
(`Post-Deployment_Verification_Brief-Master_FINAL_7-7-2026_tracked.docx`):

- **Scope** (confirmed in brief): OMS .NET executables, PowerBuilder binaries,
  and their configurations, including every Citrix server that receives a
  manual deployment copy. Gateway cloud services and MERA are excluded (already
  have standard deployment processes; Git release discipline planned as later
  work). Database objects are planned as a fast follow.
- **Gate names the files** (closed): a content-gate failure now names each
  missing/changed/extra file when `-ManifestPath` is supplied (the deploy
  wrappers pass it automatically), e.g. "Deployment blocked:
  bin/Storage.Net.dll is missing from the artifact". Required configuration
  files/folders are checked separately through `-RequiredArtifactPaths`, so
  hash-excluded environment configuration still blocks when absent.
- **Per-server configuration** (closed): the staged artifact must carry the
  config the target server is meant to run. `Deploy-Processor.ps1` mirrors with
  `robocopy /MIR` and no `/XF`, so a config under TargetRoot is replaced by the
  staged one; rather than protect the on-server file, the deploy derives the
  config's staged relative path from `-ConfigPath` and passes it to the gate as
  a required artifact. A release that shipped without the config is blocked
  before the copy, and Verify-Config then checks the file production is
  actually running. Building the right config into the staged tree is a release
  responsibility, not something the deploy repairs.
- **Console-EXE stop mechanism** (closed, pilot pending): `Deploy-Processor
-KillProcesses` stops the running instance whose exe lives under TargetRoot
  (audited by PID + command line), and `-StartTasksAfter` relaunches it via
  its scheduled task after a clean copy. Pilot on the UAT egress box before
  any PROD use.
- **Release record under a Git tag** (closed): `Invoke-Verification -Mode
Capture -ArchiveRepo <checkout> -ReleaseTag <system>/vX.Y.Z` commits the
  manifest + sanitized contract + generated release record under
  `baselines/<processor>/` and tags the commit. Git archival is required unless
  an explicit local-only exception is used, and archival is the activation —
  the tag IS the trust anchor. The tag format is enforced
  (`<system>/vMAJOR.MINOR.PATCH`), `-PushRemote` makes the record durable
  off-host (a failed push fails the capture), and the record is read back at
  check time: gate and verification take `-BaselineRepo`/`-ReleaseTag` to
  source the baseline manifest from the tag itself ("the manifest in the Git
  release tag").
- **Rollback point caveat** (closed): the generated release record states that
  tagged rollback points begin with the first verified release; anything
  shipped before that still needs a safe baseline determined manually.
  Documented above under Usage and emitted in `release-record.json` at capture
  time.
- **Gate never passes on the commit string alone** (closed): the gate requires
  `-BaselineRepo`/`-ReleaseTag` and exits 10 without them instead of implying
  the artifact was inspected. There is no commit-only mode at all — the
  approved commit and the baseline content both come from the tag-archived
  manifest, so without the anchor there is nothing to compare either check
  against. Deploy-Processor always supplies both.
- **Release tag in run evidence** (closed): `-ReleaseTag` threads through
  deploy -> gate -> verify -> health, and each stage stamps it into its run-start
  and run-end JSONL records, so every piece of execution evidence names the
  release it checked.
- **Settings are exhaustive and sanitized** (closed): missing, mismatched, and
  undeclared settings are named; machine/ignored differences require an
  explicit allowlist; sensitive values cannot be embedded in the contract, and
  secret-named keys are auto-masked in reports even when left undeclared.
- **Run evidence and outcomes** (closed): deploys and scheduled drift runs
  create JSONL evidence by default; read-only verification scripts persist
  evidence when `-LogFile` is passed. All scripts record run boundaries and
  use distinct PASS/FAIL/ERROR exit codes.
- **Server/Citrix inventory** (enforcement closed, data pending): the runner
  refuses to claim success until a `ves.targets.v1` inventory explicitly covers
  every required server — including every Citrix server that receives a
  deployment copy — with confirmed release/file/config fields (a `releaseTag`
  per target is what each drift check anchors against). The
  checked-in inventory remains `inventoryComplete=false` until operations
  supplies the missing Citrix and production path details.
- **Missed runs** (closed in code): the installer registers an independent
  heartbeat watchdog that exits 2 on a missing or stale heartbeat.
  <!-- Environment-aware alerting: drift/trust/missed-run events use production
  error severity and lower-environment warning severity. Delivery to on-call
  still depends on the host's Datadog API key and the organization's Datadog
  event monitor/routing. --> Event emit is currently disabled in code, so there
  is **no** push path to on-call — the watchdog's exit code and JSONL log are
  the only signal.
- **Log retention/centrality** (closed in code, destination pending): drift logs
  default to 365 days and deploy audit logs are not pruned. Set
  `VES_AUDIT_LOG_DIR`/`-LogDir` to the approved central share or shipped
  directory before production.

## Limits

File verify proves prod has the same bytes UAT approved. It does not prove
those bytes were correct. The health check is the only layer that catches a
defect UAT missed, so keep RequiredAssemblies and the endpoint probe populated.

The assembly-load probe is .NET-only. PowerBuilder/native targets are covered
by SHA-256 byte verification plus exact executable-path/mode, scheduled-task,
and fresh-log health probes; do not pass their binaries to
`-RequiredAssemblies`.

## Open items

- Baseline system of record. The gate assumes a Git commit SHA, but the legacy
  processors live in TFS/PVCS (no SHA) and are deployed as compiled .exes. The
  working position: the UAT-approved compiled artifact IS the baseline — its
  manifest archived and tagged at sign-off (-ArchiveRepo/-ReleaseTag) is the
  approval record and the audit trail in one. What still needs sign-off is that
  position itself, plus what value to record as `-CommitSha` for TFS-sourced
  systems (a TFS label string works: the gate compares strings against the
  `commitSha` in the tag-archived manifest, it does not require a real Git SHA
  — but capture refuses an empty or 'unknown' value).
- In-scope system list is unconfirmed. The scripts now fail closed until the
  inventory is confirmed. Documented outbound processors:
  VES.OutboundDBQProcessor.exe / VES.OutboundProcessor.exe, Task Scheduler jobs
  VLER_EM_Outbound_Request_Handler / \_Processor (and \_2 / \_12 variants) and
  VLER_EM_Real_Time_Outbound_Processor. **Citrix server names are not yet
  documented** and must be added to `requiredServers` and `targets` before
  `inventoryComplete` can be set to true. `processors/` has the template plus
  filled wrappers (e.g. `Deploy-OutboundDBQ-uat.ps1`); copy the template per
  confirmed system and server (3-5 person-days each incl. pilot).
- Database objects (stored procedures, triggers, views) are **out of scope** for
  the current two-week window. They fit the same SHA-256 capture-and-verify
  pattern and are planned as a fast follow; no script changes are needed to
  support them — the same manifest/compare approach applies to SQL files.
- Server split (VEMS-5346): PROD spreads the outbound processors across
  VESEMSEGRESS01/02/03 while UAT runs all three on one box, so deploy is
  server-aware (set the processor list per server). See SERVERS.md.
- Stop mechanism for the outbound processors: implemented, pilot pending. The
  running instance is matched by ExecutablePath under TargetRoot (the same exe
  name runs 2-3 times per box from different folders, so the folder IS the
  instance identity), killed only with an explicit -KillProcesses (audited by
  PID + command line, mode arg visible), and relaunched via its scheduled task
  with -StartTasksAfter after a clean copy. Without -KillProcesses a detected
  instance aborts the deploy before robocopy can fight a file lock. Pilot on
  the UAT egress box (vesemsegressuat) before any PROD use.
- Tag protection on the archive remote. The release tag is the trust anchor,
  so who may push/move tags in the baseline archive is the control that
  everything else rests on. Decide and enforce that permission set (and where
  the canonical archive remote lives) before PROD use.
- Monitoring sink. Exit codes + JSONL logs are the **only** signal: the telemetry
  push is commented out in code, so nothing reaches a dashboard today. Configure a
  durable central `VES_AUDIT_LOG_DIR` and log shipping before production, and
  decide whether to restore the push.
  <!-- A best-effort Datadog push (metrics via the local agent, events via the
  ddog-gov API) covers gate/deploy/health/drift/watchdog paths, but it never
  changes the primary verification outcome. Configure `DD_API_KEY`, the local
  agent, and on-call routing. -->
- Break-glass: the gate supports -AllowOverride with a mandatory reason and an
  audit line, but Deploy-Processor doesn't pass it. Decide hard-block vs
  audited override before prod.

## Testing

For a plain-language overview of the whole testing process — the script self-test
versus the release verification flow, and what each script does — see
[docs/CHEAT-SHEET.md](docs/CHEAT-SHEET.md).

The automated Pester suite covers verification, config contracts, the pre-deploy
gate (`tests/Invoke-PreDeployGate.Tests.ps1`), preflight, deploy, rollback,
backup helpers, the drift runner, module unit tests, and health-check scripts.
Run it on a workstation/CI host, not on production servers. GitHub Actions runs
the same entry point on every push and pull request (`.github/workflows/tests.yml`).

It needs Pester **5.x** (not 6+; the in-box Pester 3.4 will not parse the tests).
`Invoke-Tests.ps1` selects the highest installed 5.x even if Pester 6 is also
present. Install once:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 `
  -Scope CurrentUser -Force -SkipPublisherCheck
```

Run the suite under Windows PowerShell 5.1 (the target runtime), so the tests
exercise the same engine as production:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
```

`Invoke-Tests.ps1` exits with the failed-test count (0 = green). Coverage
centers on the exit-code contract end to end: baseline capture and archive,
matching-tree pass (`exit 0`), drift detection (`exit 1`), tampered or
unanchored baseline rejection (`exit 2`), gate block/anchor behavior, backup
and rollback safety gates, config contract checks, drift-runner pruning, and
missing required input rejection (`exit 10`).

For the first UAT egress pilot, follow [docs/UAT-PILOT-CHECKLIST.md](docs/UAT-PILOT-CHECKLIST.md)
after the suite is green.

Run the scripts directly from the repo root:

```powershell
.\Invoke-Preflight.ps1 -TargetsFile .\targets.json
.\Invoke-Verification.ps1 -Mode VerifyFiles -ReleaseRoot <path> `
  -BaselineRepo <archive-checkout> -ReleaseTag <system>/vX.Y.Z
.\Invoke-HealthCheck.ps1 -ProcessPathRoot <processor-root> -FreshLogDir <log-dir>
.\Start-DriftRunner.ps1 -TargetsFile .\targets.json -BaselineRepo <archive-checkout>
.\Deploy-Processor.ps1 -Processor <system> -StagedRoot <stage> -StagedCommit <sha> `
  -BaselineRepo <archive-checkout> -ReleaseTag <system>/vX.Y.Z -WhatIf
.\Invoke-Rollback.ps1 -Processor <system> -BackupRoot <BackupRoot> -ListBackups
.\Invoke-Tests.ps1
```

If `Invoke-Tests.ps1` passes, the checked-in scripts are loading cleanly enough
for the repository's current coverage.

## Host prerequisites

Git on the PATH wherever capture or an anchored check runs: capture commits and
tags the release record, and the gate/verification/preflight/drift scripts
shell out to git to read the manifest back out of the release tag. Capture
hosts additionally need push access to the archive remote for `-PushRemote`;
check-only hosts need read access to a clone. The runner needs rights to manage
the target services / scheduled tasks. (The Java-host service accounts
svc_omsvems (VEMS) and svc_mera (MERA) only become relevant if the excluded
gateway/MERA services join this discipline as later work.) TLS 1.2 is forced in
the module.
