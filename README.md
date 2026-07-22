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
Install-DriftTask.ps1        registers the Task Scheduler job for the runner
Deploy-Processor.ps1         gate -> stop -> backup -> copy -> restart -> verify -> health
processors/                  one thin deploy script per system (template inside)
targets.json                 drift-runner target list (example values)
sample.config.json           example config contract
SERVERS.md                   authoritative server + processor path map
Invoke-Tests.ps1             dev-time Pester runner (see Testing)
tests/                       Pester test suite + fixtures
```

## Where this runs (OMS)

This suite targets the OMS Legacy on-prem Windows tier, which deploys by
"RDP + Copy" and has no CI/CD. It does NOT target the Salesforce (Copado) or
CDK-managed AWS paths, which already have pipelines. Two execution contexts:

- On-prem Windows servers, where files/services/tasks/logs physically live.
  Outbound egress: UAT VESMSEGRESSUAT (all three processors on one box), PROD
  split across VESEMSEGRESS01/02/03 (VEMS-5346). Inbound: UAT VESEMSINGRESUAT,
  PROD VESEMSINGRESS01 (real-time) / VESEMSINGRESS02 (Handler). Java hosts
  VESOMSVEMS01/02 and VESMERA01. SQL VESSQLOMS101 (OMS2) in PROD. See SERVERS.md
  for the full per-server/per-processor path map. Run locally on each box or
  from a central runner over WinRM.
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

0 ok, 1 drift, 2 no baseline or trust failure, 3 health failure, 10 usage.
A missing baseline is exit 2, never a pass.

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
point. An archive failure fails the capture — re-run it.

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
(elevated) and it runs as SYSTEM from Task Scheduler:

```powershell
.\Install-DriftTask.ps1 -TargetsFile D:\ves-verify\targets.json -IntervalMinutes 30
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
  -FreshLogDir C:\VLER_Test\Logs\VES.OutboundProcessor -FreshLogMaxAgeMinutes 60

# Java/Spring Boot service: Windows service state + actuator probe
.\Invoke-HealthCheck.ps1 -Processor pagecount `
  -ServiceName oms-vems-pagecount-prod `
  -HealthUrl http://localhost:9191/actuator/health
```

Config contracts support ssmExpectedValues (config key -> SSM parameter name)
for values whose expected value should live in Parameter Store rather than the
contract file; see Verify-Config.ps1 header and sample.config.json. Contract
`format` is appconfig (App.config/web.config), json, or keyvalue (a Java
application.properties file is keyvalue). Keys listed under `sensitiveKeys`
(and every ssmExpectedValues key) are compared on their real values but
reported as `(masked)` on mismatch, so a secret never lands in a log or
report — list any secret-bearing key there rather than relying on convention.

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
  -ManifestPath <manifestPath> -TrustParam <trustParam> -Processor <name>
```

Baselines with no such directory hash identically before and after the change and
need nothing.

Monitoring: every script writes structured JSONL via -LogFile and returns a
meaningful exit code (see above). The drift runner writes one timestamped log
per target per run under its -LogDir. Point whatever monitoring you run at those
logs (a `"level":"DRIFT"` or `"ERROR"` line = drift/trust failure) and at the
scheduled task's Last Run Result; a missing/stale run log means the task died.

Datadog hooks in the gate/deploy/health paths are best-effort and never block
deploy/verify outcomes. Two independent transports with different prerequisites:
- **Events** (deploy/gate markers) POST to the ddog-gov Events API and need
  `DD_API_KEY` set; without it they are skipped with a warning.
- **Metrics** (verify/health gauges) are DogStatsD packets to a *local* Datadog
  Agent on `127.0.0.1:8125`. On any box without a running agent they are silently
  dropped — the primary check still runs, but nothing reaches the dashboard.
  `Invoke-Preflight -CheckDatadog` reports whether the `datadogagent` service and
  `DD_API_KEY` are in place.

`DD_ENV` (defaults to `prod`) controls the `env:` tag on both metrics and events.

## Brief conformance

Deltas between this suite and the leadership brief (Post-Deployment
Verification Brief, Master FINAL 7-6-2026), so nobody reads the brief as a
statement of what is already running:

- **Gate names the files** (closed): a content-gate failure now names each
  missing/changed/extra file when `-ManifestPath` is supplied (the deploy
  wrappers pass it automatically), e.g. "Deployment blocked:
  bin/Storage.Net.dll is missing from the artifact".
- **Console-EXE stop mechanism** (closed, pilot pending): `Deploy-Processor
  -KillProcesses` stops the running instance whose exe lives under TargetRoot
  (audited by PID + command line), and `-StartTasksAfter` relaunches it via
  its scheduled task after a clean copy. Pilot on the UAT egress box before
  any PROD use.
- **Release record under a Git tag** (closed): `Invoke-Verification -Mode
  Capture -ArchiveRepo <checkout> -ReleaseTag <system>/vX.Y.Z` commits the
  manifest + sanitized contract under `baselines/<processor>/` and tags the
  commit. What still needs a decision is the *upstream* system of record —
  see "Baseline system of record" below.
- **Paging is not built in**: the brief's "prod mismatch pages on call" and
  "missed runs raise their own alert" require monitors on the Datadog metrics
  (or another sink) that are NOT defined in this repo. Until those exist, the
  signal is exit codes + JSONL logs + Task Scheduler Last Run Result only.
- **Log retention**: drift-runner logs are host-local, pruned after
  `-LogRetentionDays` (365 default, sized for the ATO audit-trail claim;
  deploy audit logs are never pruned). Central shipping is still a
  nice-to-have once share/S3 access exists.

## Limits

File verify proves prod has the same bytes UAT approved. It does not prove
those bytes were correct. The health check is the only layer that catches a
defect UAT missed, so keep RequiredAssemblies and the endpoint probe populated.

The assembly-load check is .NET only. If any in-scope system turns out to be
PowerBuilder or native, that check needs a LoadLibrary variant.

## Open items

- Baseline system of record. The gate assumes a Git commit SHA, but the legacy
  processors live in TFS/PVCS (no SHA) and are deployed as compiled .exes. The
  working position: the UAT-approved compiled artifact IS the baseline — its
  manifest hash pinned to SSM at sign-off is the approval record, and the
  capture-time Git archive (-ArchiveRepo/-ReleaseTag) is the audit trail. What
  still needs sign-off is that position itself, plus what value to pin as
  /ves/<system>/approved-commit for TFS-sourced systems (a TFS label string
  works: the gate compares strings, it does not require a real Git SHA).
- In-scope system list is unconfirmed. Documented outbound processors:
  VES.OutboundDBQProcessor.exe / VES.OutboundProcessor.exe, Task Scheduler jobs
  VLER_EM_Outbound_Request_Handler / _Processor (and _2 / _12 variants) and
  VLER_EM_Real_Time_Outbound_Processor. processors/ holds only the template;
  copy it per confirmed system and server (3-5 person-days each incl. pilot).
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
  Datadog push (metrics via the local agent, events via the ddog-gov API) is now
  wired into the gate/deploy/health/drift paths — see the Monitoring section — but
  it never blocks an outcome and is silently dropped on boxes without an agent /
  `DD_API_KEY`. If you need alerting that must not miss, still wire a durable sink
  (log shipper, Windows Event Log, etc.) off the JSONL logs.
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
  detection, and the `Write-VesLog` JSONL format. No AWS/host needed.
- **End-to-end**: each entry script is driven as a real `powershell.exe` child
  process and asserted against the documented exit-code contract
  (`0/1/2/3/10`) plus its `-Json` output — `Invoke-Verification` (capture / verify
  / drift / usage, and capture's `-ArchiveRepo` commit+tag against a throwaway
  git repo), `Verify-Config` (all three contract formats + sensitiveKeys
  masking), `Invoke-HealthCheck` (fresh-log liveness + assembly load),
  `Invoke-Preflight` (usage + manifest/contract self-check),
  `Invoke-PreDeployGate` (pass / block-naming-the-file / commit block / SSM
  error — SSM is stubbed by a fake `aws.cmd` prepended to PATH, so no real AWS
  is touched), and `Deploy-Processor` (clean deploy, `-WhatIf`, and the
  running-instance abort/kill paths using a real locked process under the
  target dir).

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
