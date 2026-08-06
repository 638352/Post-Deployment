# RAID solutions — Howard weekly status (7/30/2026 – 8/6/2026)

Source status report: `5_15 Howard_08-06-2026.docx`.  
Canonical operator guides: [RUNBOOK-NON-TECHNICAL.md](RUNBOOK-NON-TECHNICAL.md), [UAT-PILOT-CHECKLIST.md](UAT-PILOT-CHECKLIST.md), [RUNBOOK.md](RUNBOOK.md).

This note maps each Assumptions / Issues / Decisions / Roadblock & Help / Risks item to a concrete solution, owner, and next action.

---

## Status vs repo (summary)

| Item | Still open? | Notes |
| --- | --- | --- |
| Issue: non-tech guide still cites AWS Parameter Store | Partially | Live markdown is corrected; stale Word/PDF under `.docx-review/` is not |
| Risk: UAT task name / log folder unconfirmed | Yes | Wrapper defaults marked `# CONFIRM`; need live runbook check |
| Risk: first end-to-end under change control | Yes | Use [UAT-PILOT-CHECKLIST.md](UAT-PILOT-CHECKLIST.md) |
| Assumption: PROD / Citrix / DB after UAT pilot | Keep | Correct scope cut; collect Citrix names in parallel |
| Roadblock: inventory signed off (incl. Citrix) | Yes | `targets.json` has `inventoryComplete: false` |
| Decisions (Git archive trust, staged config, docs, checkout, logs) | Closed | Live design; follow through on pilot only |

---

## Risks

### R1 — UAT OutboundDBQ scheduled-task name and fresh-log folder still need confirming

**Solution**

1. On `VESMSEGRESSUAT`, open Task Scheduler and the Outbound Deployment Steps runbook.
2. Compare against the current wrapper defaults in [`processors/Deploy-OutboundDBQ-uat.ps1`](../processors/Deploy-OutboundDBQ-uat.ps1):
   - Task: `VLER_EM_Realtime_DBQ_Processor`
   - Fresh log dir: `C:\VLER_TEST_OUTBOUND\Logs\VES.OutboundProcessor`
3. If the runbook differs, update the wrapper and [SERVERS.md](../SERVERS.md), then re-check.
4. Only then run with `-ConfirmedRunbookValues` (the script also verifies the task exists via `Get-ScheduledTask` and the log directory via `Test-Path`).

| | |
| --- | --- |
| **Owner** | Release owner + server owner (UAT egress) |
| **Next action** | Fill confirmation row in the pilot checklist before any real UAT deploy |

### R2 — Pilot is the first full chain on a real server under change control

**Solution**

Follow [UAT-PILOT-CHECKLIST.md](UAT-PILOT-CHECKLIST.md) in order: baseline archive remote + tag ACL → standalone `Verify-Config` → Capture → Preflight → `-WhatIf` deploy → real UAT deploy → health + evidence. Keep `inventoryComplete=false` so an incomplete fleet inventory cannot look like a green drift sweep. Name a person who reviews deploy/drift JSONL until alerting is wired (see [AUTOMATION-POSTURE.md](AUTOMATION-POSTURE.md)).

| | |
| --- | --- |
| **Owner** | Release owner (pilot); ops (log review cadence) |
| **Next action** | Schedule the change window and run the checklist end to end |

---

## Assumptions

### A1 — Production wrappers, Citrix inventory, and database objects stay out of scope until the UAT OutboundDBQ pilot has run once

**Solution**

Keep this assumption. Treat PROD wrappers and DB objects as blocked until checklist §5 exits `0` and evidence is filed. Do **not** set `inventoryComplete=true` from the UAT pilot alone.

**Safe parallel work:** collect Citrix server names and paths now (see Roadblock worksheet below) without expanding the pilot scope.

| | |
| --- | --- |
| **Owner** | Project / release lead |
| **Next action** | Reaffirm in the next status report; start the inventory ask in parallel |

---

## Issues

### I1 — Non-technical guide still describes AWS Parameter Store as the approved-release source

**Reality check**

[RUNBOOK-NON-TECHNICAL.md](RUNBOOK-NON-TECHNICAL.md) already states (2026-08-05) that the Git release archive is the trust anchor and that `-TrustParam` / `-ApprovedCommitParam` / `-Region` are gone. The stale AWS wording lives in `.docx-review/source.docx` and the rendered PNG/PDF under `.docx-review/baseline/`.

**Solution**

1. Treat `docs/` as canonical; do not hand leadership the Word export.
2. Mark `.docx-review/` non-canonical (see that folder’s README).
3. Scrub leftover SSM-trust comments in scripts and reviewer guidance (done in the same change set as this note).
4. Next status report: mark the markdown fix done; track only “stale Word export retired / regenerated” if anyone still needs a `.docx`.

| | |
| --- | --- |
| **Owner** | Repository maintainer |
| **Next action** | Point testers at `docs/RUNBOOK-NON-TECHNICAL.md`; regenerate Word only if required by a consumer |

---

## Decisions (validate — do not reopen)

| Decision | Follow-through |
| --- | --- |
| Git baseline archive is the trust model (8/5) | Pilot uses `-ArchiveRepo` / `-BaselineRepo` + `-ReleaseTag` only; restrict who can move release tags |
| Per-server `.exe.config` staged with the release; gate blocks a package missing one | Ship the server-correct config in the staged tree; prove with gate `-WhatIf` before a real deploy |
| Single operator set under `docs/` | Do not circulate `.docx-review` exports as current guidance |
| One canonical checkout | Keep tooling pointed at the repo root ([AGENTS.md](../AGENTS.md)) |
| Opt-in logs for read-only checks; always-on for deploy + scheduled drift | Capture deploy/drift JSONL paths in pilot evidence |

| | |
| --- | --- |
| **Owner** | Release owner (pilot execution); repo maintainer (docs/tooling) |
| **Next action** | Execute pilot against these decisions; no design reopen |

---

## Roadblock & Help Needed

### B1 — Need the server inventory signed off (including every Citrix server)

The scheduled drift check and inventory import refuse success until `targets.json` explicitly covers every server that receives the release. That fail-closed exit (`2`) is intentional, not a bug.

**What we need from Operations / server owners**

1. Full list of Citrix servers that receive a manual deployment copy (hostname + processor paths).
2. Confirmation or correction of PROD paths and task names for `VESEMSEGRESS01` / `02` / `03` from the Outbound Deployment Steps runbook.
3. A named `inventoryOwner` for [`targets.json`](../targets.json).

**What we do with that input**

- Add each server to `requiredServers` and one confirmed `targets[]` row per server/processor copy.
- Set `inventoryStatus: "confirmed"`, real `releaseTag` values, then `inventoryComplete: true`.
- Until then leave `inventoryComplete: false`.

---

## Inventory sign-off worksheet (ops fill-in)

Return this completed table to the repository maintainer. Do not invent paths — copy from the current Outbound Deployment Steps runbook / Server Notes.

### Meta

| Field | Value |
| --- | --- |
| Inventory owner (name) | |
| Date confirmed (UTC) | |
| Runbook revision / link used | |
| Approver (server owner / ops lead) | |

### Citrix servers (manual-copy targets)

Add one row per Citrix host that receives a deployment copy. If none, write `NONE — confirmed by <name>` so the gap is closed on the record.

| Server hostname | Processor(s) on this host | Release root path | Config path | Scheduled task name(s) | Fresh log directory | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | |
| | | | | | | |

### PROD egress confirmation (`VESEMSEGRESS01` / `02` / `03`)

| Server | Processors expected ([SERVERS.md](../SERVERS.md)) | Release roots confirmed? (Y/N + path) | Task names confirmed? (Y/N + name) | Log dirs confirmed? (Y/N + path) | Confirmed by |
| --- | --- | --- | --- | --- | --- |
| VESEMSEGRESS01 | XML / Outbound Events | | | | |
| VESEMSEGRESS02 | Ack, DBQ, XML / Outbound Events | | | | |
| VESEMSEGRESS03 | XML / Outbound Events, DBQ | | | | |

### UAT pilot path (not fleet-complete)

| Field | Value |
| --- | --- |
| UAT host | VESMSEGRESSUAT |
| Processor for first pilot | OutboundDBQ |
| Scheduled task name (confirmed) | |
| Fresh log directory (confirmed) | |
| `-ConfirmedRunbookValues` ready? (Y/N) | |

After this worksheet returns, the maintainer updates `targets.json` (`inventoryOwner`, `requiredServers`, confirmed `targets[]`, then `inventoryComplete` only when coverage is complete).
