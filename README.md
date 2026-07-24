# ves-verify

Interim verification for legacy Windows systems still deployed by manual file
copy. Confirms production matches the UAT-approved release and detects drift
afterward. Bridge until these systems get a real pipeline.

Target runtime: Windows PowerShell 5.1. AWS GovCloud (SSM Parameter Store).
Results are exit codes plus structured JSONL logs; wire those into whatever
monitoring you already run.

## Layout

```
module/VesVerify.psm1        shared functions
Invoke-Preflight.ps1         read-only self-check: SSM + baseline reachable/intact
Invoke-Verification.ps1      Capture / VerifyFiles / VerifyConfig / All
Verify-Config.ps1            config contract check (called by the above)
Invoke-PreDeployGate.ps1     blocks deploys that don't match the approved release
Invoke-HealthCheck.ps1       assembly load, service, scheduled-task, log, endpoint
Start-DriftRunner.ps1        scheduled re-verify, writes per-target JSONL logs
Test-DriftHeartbeat.ps1      independent missed-run watchdog
Install-DriftTask.ps1        registers the runner + watchdog scheduled tasks
Deploy-Processor.ps1         gate -> stop -> backup -> copy -> restart -> verify -> health
processors/                  one thin deploy script per system (template inside)
targets.json                 fail-closed server/Citrix inventory starter
sample.config.json           example config contract
SERVERS.md                   authoritative server + processor path map
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
- AWS GovCloud access (us-gov-east-1) for the SSM leg of config-verify. The
  on-prem<->AWS VPN already exists; the runner needs a GovCloud read-only role
  to read the pinned hashes / expected values.

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

0 pass, 1 file/config drift, 2 trust/inventory/runtime error, 3 health failure,
10 usage or unsafe configuration. These map to the brief's three outcomes:
`PASS` (0), `FAIL` (1 or 3), and `ERROR` (2 or 10). A missing baseline,
incomplete inventory, dead check, or unconfigured health probe is never a pass.

## Trust model

The manifest sits next to the artifacts, so by itself it proves nothing. At
capture time its content hash is pinned to SSM Parameter Store (SecureString).
Verification reads the pinned hash from SSM and rejects a manifest that doesn't
match, which covers the case where someone edits prod files and the manifest
together.

Heads up: uat and sandbox share a GovCloud account, so scope ssm:PutParameter
by parameter path per environment. The account boundary won't protect you there.

## Usage

Capture at UAT sign-off:

```powershell
.\Invoke-Verification.ps1 -Mode Capture -ReleaseRoot D:\uat\<system> `
  -ManifestPath D:\baselines\<system>.json `
  -TrustParam /ves/<system>/baseline-hash `
  -ArchiveRepo D:\ves-verify -ReleaseTag <system>/v1.4.0 `
  -Processor <system> -CommitSha (git rev-parse HEAD)

aws ssm put-parameter --name /ves/<system>/approved-commit --value <sha> `
  --type SecureString --overwrite --region us-gov-west-1
```

-ArchiveRepo/-ReleaseTag are the audit layer: the manifest (and contract, when
passed) are committed under `baselines/<processor>/` in that checkout and the
commit is tagged, so every approved release leaves a Git-tagged rollback/audit
point. Capture also generates `release-record.json` with the release tag,
source commit, manifest hash, file count, trust parameter, and approval
provenance. `-TrustParam`, `-ArchiveRepo`, and `-ReleaseTag` are required;
capture fails closed if any is missing. The
`-AllowUntrustedCapture`/`-AllowUnarchivedCapture` switches exist only for
isolated local tests and must not be used for an approved release.

Preflight before a deploy (read-only; touches no prod or staged files). Confirms
the AWS CLI is present, the SSM parameters actually read back (auth + KMS decrypt
+ correct path/region), and the baseline manifest is intact and trust-anchored.
Exit 0 = ready, 2 = not ready:

```powershell
.\Invoke-Preflight.ps1 -Processor <system> `
  -ApprovedCommitParam /ves/<system>/approved-commit `
  -TrustParam /ves/<system>/baseline-hash `
  -ManifestPath D:\baselines\<system>.json

# or validate every drift target's SSM + baseline at once:
.\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json
```

`targets.json` uses the `ves.targets.v1` root schema. Set
`inventoryComplete=true` only after `requiredServers` lists every server that
receives a manual deployment copy (including all Citrix targets) and every
server/processor entry is marked `inventoryStatus: "confirmed"`. Preflight and
the drift runner reject a legacy array, placeholders, incomplete coverage,
duplicate server/processor entries, or missing release/file/config/trust fields. The
checked-in file is intentionally incomplete because the Citrix inventory and
several production paths are not available in this repository; it cannot
produce a false claim of full coverage.

Deploy (pilot in dev/qa first). Each system gets its own thin script in
processors/ that pins the fixed values and calls Deploy-Processor.ps1; copy
processors/Deploy-SYSTEM_NAME.ps1 to onboard a system. -WhatIf runs the gate
only, no copy:

```powershell
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha> -WhatIf
.\processors\Deploy-<system>.ps1 -StagedRoot D:\stage\<system> -StagedCommit <sha>
```

Deploy-Processor.ps1 can still be called directly with the full parameter set
when scripting something one-off.

Scheduled drift check, every 30 min or whatever cadence fits. Register it once
(elevated) and it runs as SYSTEM from Task Scheduler. The installer creates
both the drift task and an independent heartbeat watchdog; the watchdog exits 2
and emits an alert if the runner does not complete on time:

```powershell
.\Install-DriftTask.ps1 -TargetsFile D:\ves-verify\targets.json `
  -IntervalMinutes 30 -LogDir \\audit-share\ves-verify\logs
```

Or run the runner by hand:

```powershell
.\Start-DriftRunner.ps1 -TargetsFile D:\ves-verify\targets.json
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
.\Invoke-HealthCheck.ps1 -Processor pagecount `
  -ServiceName oms-vems-pagecount-prod `
  -HealthUrl http://localhost:9191/actuator/health
```

The console-EXE check matches `ExecutablePath` under the processor folder and
optionally the mode argument; process name alone is not enough when the same EXE
runs several times. A health invocation with no assembly, service, exact
process, task, fresh-log, or endpoint probe exits 10 instead of returning a
false green result.

Config contracts support ssmExpectedValues (config key -> SSM parameter name)
for values whose expected value should live in Parameter Store rather than the
contract file; see Verify-Config.ps1 header and sample.config.json. Contract
`format` is appconfig (App.config/web.config), json, or keyvalue (a Java
application.properties file is keyvalue). Keys listed under `sensitiveKeys`
(and every ssmExpectedValues key) are compared on their real values but
reported as `(masked)` on mismatch, so a secret never lands in a log or
report — list any secret-bearing key there rather than relying on convention.
A sensitive key under `expectedValues` is rejected because that would store the
secret in Git; use `requiredKeys` for non-empty presence or
`ssmExpectedValues` for a secure comparison.

The contract is exhaustive by default. Every live key must appear under
`requiredKeys`, `expectedValues`, `ssmExpectedValues`, `machineKeys`, or the
explicit `ignoredKeys` allowlist. Undeclared keys are reported as drift.
`machineKeys` may differ by environment but must still be present and non-empty.

Config files (*.config) are excluded from the file-hash compare on purpose: the
legacy App.config carries server-specific log4net paths that differ every
UAT->PROD, so config is checked by contract (Verify-Config), not by hash. The
runtime dirs `logs\`, `temp\`, `cache\` and `.git\` are excluded too, at the root
and at any depth. All of this lives in one place — `$Global:VES_DEFAULT_EXCLUDE`
in module/VesVerify.psm1 — because capture and compare must use identical rules;
if they disagree, excluded files resurface as "Extra" and every check reports drift.

## Upgrading: re-pin baselines captured under the old exclude pattern

The exclude pattern previously matched `logs\`/`temp\`/`cache\`/`.git\` only when
nested, so a **top-level** one leaked into the baseline. Fixing that changes which
files a manifest contains, which changes its hash, which breaks the SSM pin — the
next check would report exit 2 (trust failure).

Only baselines whose release root actually has a top-level `logs\`, `temp\`,
`cache\` or `.git\` are affected. To find them without touching prod files:

```powershell
.\Invoke-Preflight.ps1 -TargetsFile D:\ves-verify\targets.json
```

Any target reporting a `manifest-pattern` **WARN** needs re-capture. WARN does not
block readiness, so a clean run here means nothing to do. For each flagged target,
re-capture and re-pin:

```powershell
.\Invoke-Verification.ps1 -Mode Capture -ReleaseRoot <releaseRoot> `
  -ManifestPath <manifestPath> -TrustParam <trustParam> -Processor <name> `
  -ArchiveRepo <git-checkout> -ReleaseTag <name>/vX.Y.Z
```

Baselines with no such directory hash identically before and after the change and
need nothing.

Monitoring: every entry script creates a structured JSONL audit log even when
`-LogFile` is omitted. Set `VES_AUDIT_LOG_DIR` to a durable central share; the
fallback is `%ProgramData%\ves-verify\logs` (the scheduled runner keeps its
explicit `-LogDir`). Run boundaries carry a run ID, processor/release context,
PASS/FAIL/ERROR outcome, and exit code. The drift runner writes one timestamped
log per target plus a run summary and atomically updates
`ves-verify-drift.heartbeat.json`.

Datadog hooks in the gate/deploy/health paths are best-effort and never block
deploy/verify outcomes. Two independent transports with different prerequisites:
- **Events** (deploy/gate markers) POST to the ddog-gov Events API and need
  `DD_API_KEY` set; without it they are skipped with a warning. Drift, trust
  failure, runner error, and missed-heartbeat events are included. Production
  uses Datadog `error` severity; dev/qa/UAT use `warning`.
- **Metrics** (verify/health gauges) are DogStatsD packets to a *local* Datadog
  Agent on `127.0.0.1:8125`. On any box without a running agent they are silently
  dropped — the primary check still runs, but nothing reaches the dashboard.
  `Invoke-Preflight -CheckDatadog` reports whether the `datadogagent` service and
  `DD_API_KEY` are in place.

Target inventory `environment` controls drift severity/tags. `DD_ENV` remains
the fallback for direct invocations.

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
- **Console-EXE stop mechanism** (closed, pilot pending): `Deploy-Processor
  -KillProcesses` stops the running instance whose exe lives under TargetRoot
  (audited by PID + command line), and `-StartTasksAfter` relaunches it via
  its scheduled task after a clean copy. Pilot on the UAT egress box before
  any PROD use.
- **Release record under a Git tag** (closed): `Invoke-Verification -Mode
  Capture -ArchiveRepo <checkout> -ReleaseTag <system>/vX.Y.Z` commits the
  manifest + sanitized contract + generated release record under
  `baselines/<processor>/` and tags the commit. Trust pinning and Git archival
  are required unless an explicit local-only exception is used.
- **Settings are exhaustive and sanitized** (closed): missing, mismatched, and
  undeclared settings are named; machine/ignored differences require an
  explicit allowlist; sensitive values cannot be embedded in the contract.
- **Run evidence and outcomes** (closed): scripts create JSONL evidence by
  default, record run boundaries, and use distinct PASS/FAIL/ERROR exit codes.
- **Server/Citrix inventory** (enforcement closed, data pending): the runner
  refuses to claim success until a `ves.targets.v1` inventory explicitly covers
  every required server — including every Citrix server that receives a
  deployment copy — with confirmed release/file/config/trust fields. The
  checked-in inventory remains `inventoryComplete=false` until operations
  supplies the missing Citrix and production path details.
- **Missed runs and environment-aware alerting** (closed in code): the installer
  registers an independent heartbeat watchdog. Drift/trust/missed-run events use
  production error severity and lower-environment warning severity. Delivery to
  on-call still depends on the host's Datadog API key and the organization's
  Datadog event monitor/routing.
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
  manifest hash pinned to SSM at sign-off is the approval record, and the
  capture-time Git archive (-ArchiveRepo/-ReleaseTag) is the audit trail. What
  still needs sign-off is that position itself, plus what value to pin as
  /ves/<system>/approved-commit for TFS-sourced systems (a TFS label string
  works: the gate compares strings, it does not require a real Git SHA).
- In-scope system list is unconfirmed. The scripts now fail closed until the
  inventory is confirmed. Documented outbound processors:
  VES.OutboundDBQProcessor.exe / VES.OutboundProcessor.exe, Task Scheduler jobs
  VLER_EM_Outbound_Request_Handler / _Processor (and _2 / _12 variants) and
  VLER_EM_Real_Time_Outbound_Processor. **Citrix server names are not yet
  documented** and must be added to `requiredServers` and `targets` before
  `inventoryComplete` can be set to true. processors/ holds only the template;
  copy it per confirmed system and server (3-5 person-days each incl. pilot).
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
- SSM region. Examples default to us-gov-west-1, but the OMS SSM convention
  (/DbqFormService/<ENV>/<region>/...) points at us-gov-east-1. Set -Region per
  the confirmed parameter path before running config-verify/preflight for real.
- Monitoring sink. Primary signal is still exit codes + JSONL logs. A best-effort
  Datadog push (metrics via the local agent, events via the ddog-gov API) covers
  gate/deploy/health/drift/watchdog paths, but it never changes the primary
  verification outcome. Configure `DD_API_KEY`, the local agent, on-call routing,
  and a durable central `VES_AUDIT_LOG_DIR` before production.
- Break-glass: the gate supports -AllowOverride with a mandatory reason and an
  audit line, but Deploy-Processor doesn't pass it. Decide hard-block vs
  audited override before prod.

## Testing

There is a Pester test suite under `tests/`. It is **dev-time only** — run it on
the workstation/CI where this suite is maintained, NOT on the legacy PS 5.1
production boxes. It needs Pester 5.x (the in-box Pester 3.4 will not parse the
tests); install it once:

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck
```

Run the suite under Windows PowerShell 5.1 (the target runtime), so the tests
exercise the same engine as production:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
```

`Invoke-Tests.ps1` exits with the failed-test count (0 = green), ready to wire into
CI later. What's covered:

- **Unit** (`tests/VesVerify.Module.Tests.ps1`): the module's pure functions —
  manifest hashing (stable, order-independent, change-sensitive), the
  export/import round-trip and tamper detection, `Compare-VesFiles` drift
  detection, fail-closed target inventory validation, environment alert tags,
  and the `Write-VesLog` JSONL format. No AWS/host needed.
- **End-to-end**: each entry script is driven as a real `powershell.exe` child
  process and asserted against the documented exit-code contract
  (`0/1/2/3/10`) plus its `-Json` output — `Invoke-Verification` (capture / verify
  / drift / usage, and capture's `-ArchiveRepo` commit+tag against a throwaway
  git repo), `Verify-Config` (all three contract formats, undeclared-setting
  drift, secret-contract rejection, and explicit ignores),
  `Invoke-HealthCheck` (fresh-log liveness, assembly load, exact-process failure,
  and no-probe rejection),
  `Invoke-Preflight` (usage + manifest/contract self-check),
  `Invoke-PreDeployGate` (pass / block-naming-the-file / commit block / SSM
  error — SSM is stubbed by a fake `aws.cmd` prepended to PATH, so no real AWS
  is touched), and `Deploy-Processor` (clean deploy, `-WhatIf`, and the
  running-instance abort/kill paths using a real locked process under the
  target dir). `Start-DriftRunner` covers inventory enforcement, drift exits,
  heartbeat writing, and safe pruning; `Test-DriftHeartbeat` covers fresh,
  stale, and missing heartbeats.

Deliberately out of scope this round (would need more mocking): the real
SSM read/write paths (`Get-/Set-VesTrustedHash` against actual AWS, and
verify-with-`-TrustParam`), and the health check's service / scheduled-task / HTTP
branches. No test requires AWS, a running service, a scheduled task, or the
network.

## Host prerequisites

AWS CLI with an instance profile allowing ssm:GetParameter (and PutParameter
for capture hosts) plus kms:Decrypt. The service accounts on the boxes are
svc_omsvems (VEMS) and svc_mera (MERA); the runner needs rights to manage those
services / scheduled tasks. TLS 1.2 is forced in the module.
