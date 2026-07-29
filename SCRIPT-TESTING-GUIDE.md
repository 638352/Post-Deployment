# Post-Deployment File Match Guide (UAT to Production)

This guide is for one job only: proving the files in production match the
approved UAT release.

It removes all unrelated testing paths. No scheduler tests, no deployment
engine tests, no health checks, no config-rule tests.

## What scripts are in scope

| Script | Why it is used now | Where to run it |
|---|---|---|
| `Invoke-Tests.ps1` | Runs the reduced automated tests for file matching only. | Workstation (Windows PowerShell 5.1) |
| `Invoke-Verification.ps1 -Mode Capture` | Creates the approved UAT file baseline (manifest). | UAT approval host (release owner present) |
| `Invoke-Verification.ps1 -Mode VerifyFiles` | Compares production files to the approved UAT baseline. | Production target server (read-only check) |

## Before you start

1. Open **Windows PowerShell** (not PowerShell 7).
2. Go to the repository:

```powershell
Set-Location 'C:\Users\howardr01\Post-Deployment'
```

3. Confirm PowerShell 5.1:

```powershell
$PSVersionTable.PSVersion
```

4. Record the commit you are testing:

```powershell
git rev-parse --short HEAD
```

5. Keep the same PowerShell window open for the full session.

## Step-by-step run order

## Step 1 - Run the reduced automated test suite (workstation)

This confirms the local file-match checks are working.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Invoke-Tests.ps1
$LASTEXITCODE
```

Expected result: `0`.

If not `0`, stop. Do not continue.

## Step 2 - Capture the approved UAT baseline (UAT)

Run this only when UAT sign-off is complete and the release owner is present.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode Capture `
 -ReleaseRoot REPLACE_WITH_UAT_APPROVED_RELEASE_FOLDER `
 -ManifestPath REPLACE_WITH_BASELINE_MANIFEST_PATH `
 -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
 -ArchiveRepo REPLACE_WITH_BASELINE_GIT_CHECKOUT `
 -ReleaseTag REPLACE_WITH_RELEASE_TAG `
 -Processor REPLACE_WITH_PROCESSOR_NAME `
 -CommitSha REPLACE_WITH_APPROVED_COMMIT `
 -Environment uat `
 -Region REPLACE_WITH_CONFIRMED_REGION `
 -Json
$LASTEXITCODE
```

Expected result: `0`.

If not `0`, stop.

## Step 3 - Compare production files to UAT baseline (production)

This is the main check. It verifies file content only.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
 -File .\Invoke-Verification.ps1 `
 -Mode VerifyFiles `
 -ReleaseRoot REPLACE_WITH_PRODUCTION_TARGET_FOLDER `
 -ManifestPath REPLACE_WITH_BASELINE_MANIFEST_PATH `
 -TrustParam REPLACE_WITH_SSM_TRUST_PARAM `
 -Processor REPLACE_WITH_PROCESSOR_NAME `
 -Environment prod `
 -Region REPLACE_WITH_CONFIRMED_REGION `
 -Json
$LASTEXITCODE
```

Expected result: `0`.

If result is:

- `1`: files do not match (drift found).
- `2`: trusted baseline could not be confirmed.
- `10`: command values were incomplete or invalid.

For any non-zero code, stop and escalate.

## What to record each time

For every run, record:

1. Script name and date/time.
2. `git rev-parse --short HEAD` value.
3. `$LASTEXITCODE`.
4. Any `MISSING`, `CHANGED`, or `EXTRA` lines.
5. JSONL log path (if printed).

Do not copy passwords, tokens, connection strings, or raw SSM secret values into
the record.

## Quick summary for non-technical operators

1. Run Step 1 on a workstation.
2. Run Step 2 on UAT (with release owner).
3. Run Step 3 on production.
4. A pass is only `0`.
5. Any other number means stop and hand over results.
