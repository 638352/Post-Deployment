# Post-Deployment agent instructions

## Canonical workspace

Work from the repository root in `c:\Users\howardr01\Post-Deployment`.
That root folder is the source of truth for scripts, tests, and docs because it contains the live Git history.

Treat the snapshot/reference copy folder in the repository root as read-only context. Do not make changes there unless you are explicitly comparing against the snapshot.

## What to read first

- [README.md](README.md) for the project overview, runtime assumptions, exit codes, and top-level workflow.
- [SERVERS.md](SERVERS.md) for the authoritative server and processor path map.
- [sample.config.json](sample.config.json) for config-contract shape and examples.
- [tests/](tests/) for Pester patterns, fixtures, and expected behaviors.

## Working conventions

- Target Windows PowerShell 5.1 scripts only; avoid PS7-only syntax.
- Keep the exit code contract intact: `0` pass, `1` drift, `2` no baseline or trust failure, `3` health failure, `10` usage or unsafe configuration.
- Preserve the JSONL logging behavior and the trust model around SSM-pinned manifest hashes.
- Prefer small, focused edits in the root scripts such as `Invoke-Verification.ps1`, `Invoke-Preflight.ps1`, `Invoke-HealthCheck.ps1`, `Deploy-Processor.ps1`, and `Start-DriftRunner.ps1`.

## Validation

- Use `./Invoke-Tests.ps1` for the main test pass.
- If you touch a specific script, prefer the matching test file under `tests/` for a narrower check.
- Keep behavior aligned with the module in [module/VesVerify.psm1](module/VesVerify.psm1); most shared rules live there.

## Editing guidance

- Update `README.md` and `SERVERS.md` when behavior or paths change in a way users need to know.
- Do not duplicate documentation from the README into this file; link to the source instead.
- If a change would affect both the root tree and the snapshot copy, verify whether the snapshot should stay frozen before editing it.
