# UAT pilot checklist (OutboundDBQ on VESMSEGRESSUAT)

Operator checklist for the first controlled UAT pilot. Code/docs in this repo
get you to the gate; the steps below are environment work that must happen on
or for the UAT egress box. Keep `inventoryComplete=false` until Citrix and PROD
paths are confirmed — do not claim fleet coverage from a single-target pilot.

## 1. Baseline archive (trust)

- [ ] Create (or identify) the Git baseline archive remote.
- [ ] Clone it to a path reachable from the UAT capture/verify host (e.g. `D:\ves-baselines`).
- [ ] Restrict who can create, force-push, or delete release tags to the release authority.
- [ ] Confirm `git` is on PATH on every host that will Capture, gate, verify, or run drift.

## 2. Confirm UAT OutboundDBQ runbook values

Against the current Outbound Deployment Steps runbook, confirm and update
[processors/Deploy-OutboundDBQ-uat.ps1](../processors/Deploy-OutboundDBQ-uat.ps1)
and [SERVERS.md](../SERVERS.md) if needed:

- [ ] Scheduled task name (wrapper default: `VLER_EM_Realtime_DBQ_Processor`)
- [ ] Fresh log directory (wrapper default: `C:\VLER_TEST_OUTBOUND\Logs\VES.OutboundProcessor`)
- [ ] TargetRoot / BackupRoot / config path still match the box
- [ ] Only then use `-ConfirmedRunbookValues` on a real run

## 3. Config contract

- [ ] Author a real contract for the live `.exe.config` (do **not** copy
      `sample.config.json` blindly).
- [ ] Do **not** declare `ssmExpectedValues` — that key fails closed.
- [ ] Place the contract where the wrapper expects it (default
      `D:\baselines\OutboundDBQ.config.json`) or update the wrapper path.

Every setting in the live file has to land in exactly one bucket — an undeclared
key is reported as drift, so the contract is only finished when a run comes back
clean. Work down the live `appSettings` and `connectionStrings` and sort each key:

| Bucket | Use it for |
|--------|------------|
| `expectedValues` | must be this exact value on every box (`Tls:MinVersion`, feature flags) |
| `machineKeys` | must exist, value legitimately differs per box (endpoints, thumbprints, connection strings) |
| `requiredKeys` | must exist, value not worth pinning |
| `sensitiveKeys` | real secrets — compared, but reported as `(masked)`. Never also in `expectedValues`; the contract refuses |
| `ignoredKeys` | deliberately out of scope, so it is a decision on the record rather than a silent pass |

`format` is `appconfig` for a `.exe.config`. Connection strings flatten to
`ConnectionStrings:<name>`. Prove the contract before it gates anything:

```powershell
.\Verify-Config.ps1 -ContractPath D:\baselines\OutboundDBQ.config.json `
  -ConfigPath C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe.config
```

- [ ] That standalone run reports PASS against the live file before the contract
      is wired into a deploy

## 4. First Capture (approval record)

On the UAT approval host, with the release owner present:

```powershell
.\Invoke-Verification.ps1 -Mode Capture `
  -ReleaseRoot C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor `
  -ManifestPath D:\baselines\OutboundDBQ.json `
  -Processor OutboundDBQ `
  -CommitSha <tfs-label-or-commit> `
  -ArchiveRepo D:\ves-baselines `
  -ReleaseTag OutboundDBQ/vX.Y.Z `
  -PushRemote
```

- [ ] Capture exits `0` and the tag exists on the archive remote
- [ ] Update the UAT target in [targets.json](../targets.json): set `releaseTag` to
      that tag, set `inventoryStatus` to `confirmed` for this one entry only
- [ ] Leave `inventoryComplete` **false** until the full server/Citrix list is known

## 5. Preflight → dry run → real UAT deploy

```powershell
.\Invoke-Preflight.ps1 -TargetsFile .\targets.json -BaselineRepo D:\ves-baselines
.\processors\Deploy-OutboundDBQ-uat.ps1 `
  -StagedRoot <stage> -StagedCommit <sha> `
  -ReleaseTag OutboundDBQ/vX.Y.Z -BaselineRepo D:\ves-baselines `
  -ConfirmedRunbookValues -WhatIf
```

Then the real deploy (same args without `-WhatIf`), using the wrapper's
`-KillProcesses` / `-StartTasksAfter` defaults after the kill/restart behavior
has been observed once under change control.

- [ ] The staged tree carries `VES.OutboundDBQProcessor.exe.config` with this
      box's values. `/MIR` replaces the config on the server, so whatever ships
      in the package is what production runs; a package without it is blocked at
      the gate before anything is copied.
- [ ] Preflight READY (or WARN only for unanchored items you intentionally skipped)
- [ ] `-WhatIf` gate passes
- [ ] Real deploy exits `0`; health probes populated so health is not empty → `10`
- [ ] JSONL deploy log written under `VES_AUDIT_LOG_DIR` or the wrapper log dir

## 6. Evidence and ownership until monitoring is wired

- [ ] Name an owner who reviews drift/deploy JSONL logs on a cadence
- [ ] Point `VES_AUDIT_LOG_DIR` at the approved central share when available
- [ ] Do **not** set `inventoryComplete=true` or schedule fleet drift success until
      Citrix names and PROD paths are in the inventory

## Out of scope for this first pilot

Citrix inventory, PROD wrappers (`VESEMSEGRESS01/02/03`), database objects,
Datadog re-enable, and break-glass / config-`/MIR` policy decisions (decide those
before PROD; see README Open items).
