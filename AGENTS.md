# Agent Guidance

This repository targets Windows PowerShell 5.1 only. Avoid PowerShell 7 syntax and keep changes compatible with the engine used in production and tests.

Start with [README.md](README.md) for behavior and workflows, then use [SERVERS.md](SERVERS.md) for server and processor mappings. Keep the root module in [module/VesVerify.psm1](module/VesVerify.psm1) as the shared implementation surface and the scripts in the repository root as thin entry points.

## Working Rules

- Preserve the exit-code contract defined in [module/VesVerify.psm1](module/VesVerify.psm1); callers depend on the existing `0`, `1`, `2`, `3`, and `10` meanings.
- Keep capture and compare exclude rules in sync. If the default manifest exclusion changes, update the single source of truth in [module/VesVerify.psm1](module/VesVerify.psm1) and the affected tests together.
- When changing deploy behavior, update the per-system wrapper under [processors/](processors/) and the shared orchestration path together so processor names, manifest paths, and SSM parameters stay aligned.
- Treat config verification as structural, not byte-hash based. Config contract changes usually belong in [Verify-Config.ps1](Verify-Config.ps1) and the fixtures under [tests/fixtures/](tests/fixtures/).

## Validation

- Use [Invoke-Tests.ps1](Invoke-Tests.ps1) for the full test suite.
- Run tests with Windows PowerShell 5.1, for example: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1`.
- The test runner exits with the failed-test count, so a zero exit code is the success signal.

## Good Starting Points

- [tests/\_helpers.ps1](tests/_helpers.ps1) shows how the suite launches child PowerShell processes and captures exit codes.
- [tests/](tests/) contains the Pester patterns and fixtures to mirror when adding coverage.
- [sample.config.json](sample.config.json) is the canonical example for config-contract shape.
