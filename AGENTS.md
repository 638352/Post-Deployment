# Post-Deployment agent instructions

## Canonical workspace

Work from the repository root at `c:\Users\howardr01\Post-Deployment`. This is the
single live Git checkout (`origin/main`) and the source of truth for scripts, tests,
and docs. Open Cursor on that path (File → Open Folder); do **not** open the nested
`Post-Deployment\Post-Deployment` folder — it is retired and empty, so Source Control
and commits from that window will look broken.

History note (2026-08-05): there was previously a second, newer checkout nested at
`Post-Deployment\Post-Deployment` while the parent lagged behind. The parent has been
fast-forwarded to that lineage and the nested copy removed. If a nested
`Post-Deployment\` folder ever reappears, it is scratch from another tool, not the
canonical repo — check `git log` before trusting either. Delete the empty retired
nested folder after a reboot if it is still present (directory handles may block
removal until then).

Treat `Post-Deployment-datadog-558667ed/` as a snapshot/reference copy only. Do not make changes there unless you are explicitly comparing against the snapshot.

## What to read first

- [README.md](README.md) for the project overview, runtime assumptions, exit codes, and top-level workflow.
- [SERVERS.md](SERVERS.md) for the authoritative server and processor path map.
- [sample.config.json](sample.config.json) for config-contract shape and examples.
- [tests/](tests/) for Pester patterns, fixtures, and expected behaviors.

## Working conventions

- Target Windows PowerShell 5.1 scripts only; avoid PS7-only syntax.
- Keep the exit code contract intact: `0` pass, `1` drift, `2` no baseline or trust failure, `3` health failure, `10` usage or unsafe configuration.
- Preserve the JSONL logging behavior and the trust model around Git release-tag
  anchors (manifest archived under `<system>/vMAJOR.MINOR.PATCH` in the baseline
  archive repo).
- Prefer small, focused edits in the root scripts such as `Invoke-Verification.ps1`, `Invoke-Preflight.ps1`, `Invoke-HealthCheck.ps1`, `Deploy-Processor.ps1`, and `Start-DriftRunner.ps1`.

## Validation

- Use `./Invoke-Tests.ps1` for the main test pass.
- If you touch a specific script, prefer the matching test file under `tests/` for a narrower check.
- When a rollback test fails on an exit code alone, run
  [tests/Debug-RollbackFailure.ps1](tests/Debug-RollbackFailure.ps1) rather than
  guessing: six paths in `Invoke-Rollback.ps1` return `2`, and it reads the audit
  JSONL to say which one fired. Do not attribute an exit `2` to any single cause
  without that evidence.
- Keep behavior aligned with the module in [module/VesVerify.psm1](module/VesVerify.psm1); most shared rules live there.

## Editing guidance

- Update `README.md` and `SERVERS.md` when behavior or paths change in a way users need to know.
- Do not duplicate documentation from the README into this file; link to the source instead.
- If a change would affect both the root tree and the snapshot copy, verify whether the snapshot should stay frozen before editing it.

## Imported Claude Cowork project instructions

Interim safeguard to confirm production matches what was approved in UAT on manually deployed systems. 

1)	This has already happened. A recent release package shipped without a required DLL, and the gap went undetected for 24 days. That is the exact control gap this effort is built to close.
2)	We cannot prove prod equals UAT. On manually deployed systems, nothing automatically checks that the files and settings in production match the version that passed UAT.
3)	Drift stays invisible until it breaks something. A missing file, a stale config value, or an undocumented server-side edit usually surfaces as a production incident rather than being caught before release.
4)	The impact lands on veterans first. VES is a VA disability-evaluation platform. A faulty release means downtime or bad data on a system veterans depend on.
5)	The audit trail is thin. In a FedRAMP / ATO GovCloud environment, we cannot always show exactly what was deployed, when, and from which approved source  the program’s “Deployment Instructions” page is still marked work-in-progress with no post-deployment section at all.
6)	Correctness depends on memory. It relies on someone remembering to check, not on a process that makes the mistake hard to make. Today those steps live in scattered, partly dated Confluence runbooks (training-environment branding, VES/PNM manual steps, the DevOps checklist), not in the deployment itself.

On the systems we still deploy by manual file copy, we cannot prove that production matches the version approved in UAT  not the files, not the settings. This brief proposes an interim safeguard: keep approved releases in Git under a clear versioning model, then automatically verify deployed files and configuration against the UAT-approved baseline after each release. Deliverable in one to two weeks with tools we already own  Git/GitHub, SHA-256 checksums, and PowerShell/Bash. No new platforms, no new licensing.
