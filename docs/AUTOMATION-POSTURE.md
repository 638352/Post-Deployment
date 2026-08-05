# Automation Posture: What Is Automated and What Is Still Manual

**Audience:** leadership and release management
**Subject:** the Post-Deployment Verification script suite (ves-verify)
**Status as of:** 2026-08-05

---

## The one-paragraph answer

The **verification controls are automated; the decision to run them is not.** Once an
operator launches a deployment on a server, the suite performs the entire sequence
itself — it blocks unapproved releases, backs up the current release, copies the new
one, restarts the processor, re-verifies every file against the approved baseline,
and runs a health check — stopping the moment any step fails. What remains human is
everything around that: deciding to deploy, logging onto each server, launching the
run, reading the result, and acting on it. One background job runs on its own: a drift
check that re-verifies production every 30 minutes. Nothing else fires without a person.

---

## What is automated

| Capability | What it does without human involvement |
| --- | --- |
| **Pre-deploy gate** | Refuses to deploy anything that does not match the approved release. Compares the staged code against the approved commit and against the baseline manifest archived under the Git release tag. Cannot be talked out of it — with no trusted source available it errors rather than assuming the artifact was checked. |
| **Deployment sequence** | Gate → stop the processor → dated backup → copy → restart → verify → health check, as a single unattended chain. Any failing step aborts the rest and reports which one failed. |
| **Backup before overwrite** | Every deploy writes a timestamped restore point plus a record of what it replaced, before touching production. |
| **File verification** | Re-hashes the deployed tree against the approved baseline and reports any file that is missing, changed, or unexpected — by name. |
| **Configuration verification** | Structural check of the live configuration against an approved contract. |
| **Health check** | Confirms the processor actually came back up after the restart. |
| **Automatic rollback (opt-in)** | When enabled, restores the backup if the post-deploy verification or health check fails. |
| **Continuous drift detection** | A scheduled task re-verifies production every 30 minutes and logs the result. A second watchdog task detects the first one going silent — so "no drift reported" cannot be confused with "the check stopped running." |
| **Evidence capture** | Every run writes a structured audit log — who ran it, when, against which release, and the outcome. This happens automatically on every script; it is not something an operator can forget to do. |

---

## What is still manual

### Setup — once per processor, per server

Someone fills in a configuration wrapper for each processor on each server: file paths,
scheduled-task names, backup location, log directory. Production splits the outbound
processors across three servers while UAT runs all three on one, so these differ per
box and cannot be derived automatically. The template refuses to run until it has been
properly filled in and an operator has confirmed the values against the current
deployment runbook.

Also one-time: setting up the baseline archive repository that holds the approved
release records (and restricting who can move release tags in it), completing the
server inventory, registering the drift tasks on each box, and pointing monitoring at
the logs.

### Per release

- **Building and staging the release.** The suite verifies artifacts; it does not produce them.
- **Capturing the approved UAT baseline.** An operator runs the capture step against the
  UAT-approved build. This is the moment "approved" becomes a machine-checkable fact —
  a deliberate human checkpoint, not a gap.
- **Assigning the release version/tag** and recording the approved commit.
- **Authoring the configuration contract** that defines a valid production config.
- **Running preflight** on each target server to confirm readiness.

### Per deployment

- **Deciding to deploy**, and doing it inside an approved change window.
- **Logging onto each target server and launching the run.** There is no central
  orchestrator: a three-server production deployment is three separate launches.
- **Following the pilot sequence** — dry run, then UAT, then production.
- **Judging the running-instance situation.** If the processor is holding files open,
  the deploy stops rather than forcing it; overriding that is an explicit operator choice.
- **Reading and acting on the outcome.** The suite reports pass / fail / error / unhealthy
  as distinct results, but a person interprets them and decides what happens next.

### Rollback

Automatic rollback is opt-in and narrow — it triggers only on a failed post-deploy
verification or health check. Everything else is a human decision: choosing to roll back
at all, selecting which restore point, supplying the reason for the audit record, and
re-establishing the trust anchor afterward (deliberately operator-only, so that no
automated action can quietly redefine what "approved" means).

### Ongoing

- Running the regression test suite (CI runs it on pull requests; operators can
  still run `Invoke-Tests.ps1` locally).
- Triaging drift findings: the system detects and records drift, but does not judge it.
- **Watching for alerts.** See the gap below.

---

## The one gap leadership should know about

**Detection is automated; notification is not.**

The drift runner and its watchdog run on schedule and record their findings. But there
is currently no paging or alerting wired up — the alerting integration was deferred to
a future release by decision. Today a drift finding, or the drift check dying entirely,
sits in a log file and in the Windows Task Scheduler result until a person looks at it.

The plumbing for this exists — every run emits a machine-readable result and a distinct
exit code specifically so a monitor can consume it. What is missing is the monitoring
configuration on the other end. Until that is in place, the drift control depends on
someone reviewing the logs on a regular cadence, and that review should be treated as a
named, owned responsibility rather than an assumption.

---

## How to read this posture

The manual steps are not automation debt. They fall into two groups:

1. **Deliberate human checkpoints** — approving a baseline, deciding to deploy, choosing
   to roll back, overriding a safety stop. These are the points where accountability
   attaches to a person, and automating them would remove the control rather than
   strengthen it. Each one is recorded in the audit trail with the operator's identity.

2. **Genuine remaining work** — filling the remaining per-server deploy wrappers
   and confirming runbook values (task names, log dirs), completing the server
   inventory, and above all connecting alerting. The rule for per-server config
   files is already decided and enforced: stage the server-correct config with
   the artifact; the gate blocks a package that shipped without it. Remaining
   items are tracked in the README.

> **Trust model (2026-08-05).** The approved baseline is the release tag in the
> baseline archive repository plus the manifest committed under it. There is no
> separate pin and no AWS/SSM dependency. Preflight and gate readiness are driven by
> that tag anchor and the inventory — not by an AWS CLI. Tag integrity is only as
> strong as the controls on who can create, move, or delete release tags on the
> archive remote.

The distinction that matters for risk: **an unapproved or corrupted release cannot reach
production undetected** — that check is automated and fails closed. What still depends on
people is that the process is *initiated* correctly and that *findings are noticed*.
