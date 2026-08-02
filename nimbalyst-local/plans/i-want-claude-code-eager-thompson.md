# Code Review — VES Post-Deployment Scripts

## Context

You asked for a review of your scripts. This repo is the VES Post-Deployment Verification
toolkit: 13 PowerShell files (~3,193 lines) whose whole job is to prove a production deploy
matches its UAT baseline and to fail loudly when it does not. That makes the tooling's own
correctness the thing under review — **a verification tool that fails open is worse than no tool.**

Two facts found during exploration change what this review needs to be:

1. **`main` (71ed2e19) is missing fixes that exist on unmerged branches.** Confirmed at HEAD:
   `Invoke-Preflight.ps1` never calls `Import-VesTargetInventory`, so `-TargetsFile` preflight
   iterates the root JSON object instead of `.targets` and the fail-closed inventory gate never
   fires. `Invoke-Verification.ps1:135` still uses `$manifest.Count`. `Verify-Config.ps1` has no
   `-ExitWithCode`; `Deploy-Processor.ps1` has no `-PreserveFiles`. Fixes sit on
   `claude/verify-fixes-2026-07-27` (on origin) and `claude/master-tester-guide-accuracy-d7f78d`
   (local only). The review must report *status at HEAD*, not rediscover history.

2. **The test suite has collapsed.** `tests/` holds 2 files / 7 `It` blocks covering 2 of 13
   files and 0 module functions. Nine test files present in the frozen `datadog` worktree —
   including `VesVerify.Module.Tests.ps1` (330 lines) — were deleted from the live tree. Prior
   passes ran 129–149 tests. The coverage regression is itself a finding.

**Outcome:** a dated markdown findings report plus a ranked inline summary. Read-only —
no files under review are modified, nothing is fixed, nothing is committed.

## Scope

**In (13 files, main tree):** `module/VesVerify.psm1` (729); root `Deploy-Processor.ps1` (385),
`Invoke-Verification.ps1` (302), `Invoke-Preflight.ps1` (278), `Invoke-HealthCheck.ps1` (246),
`Invoke-PreDeployGate.ps1` (241), `Start-DriftRunner.ps1` (231), `Verify-Config.ps1` (229),
`Test-DriftHeartbeat.ps1` (100), `Install-DriftTask.ps1` (92), `Invoke-Tests.ps1` (50);
`processors/Deploy-SYSTEM_NAME.ps1` (102), `processors/Deploy-OutboundDBQ-uat.ps1` (73).

**Out:** the frozen worktree `Post-Deployment-datadog-558667ed/` (AGENTS.md: do not edit —
used only as a *reference* for the deleted tests), and the three Python doc-tooling files.

**Standards, in descending authority:** `module/VesVerify.psm1:1-50` (the executable contract) →
`.claude/agents/code-reviewer.md` (the repo's six-priority rubric and reporting format) →
`README.md` (exit semantics, SSM trust model, secret masking, contract exhaustiveness) →
`AGENTS.md`. `README.md` §Limits/§Open items and `docs/SCRIPT-GUIDE-LINE-BY-LINE.md`
"honest gaps" list **known-accepted** gaps — confirm status, do not re-litigate.

## Approach

Use the repo's own `code-reviewer` subagent (`.claude/agents/code-reviewer.md`) — it already
encodes the rubric, the read-only constraint, and the reporting format. Six passes:

| Pass | Files | Review question |
|---|---|---|
| **P1 Module** | `module/VesVerify.psm1` | Everything downstream inherits this. Produce a contract table of the 16 exported functions (param types, return shape, throw-vs-return-vs-`$null`) that later passes check call sites against. |
| **P2 Trust chain** | `Invoke-Verification`, `Invoke-Preflight`, `Invoke-PreDeployGate` | Can failure to *retrieve* the SSM anchor become a pass? All three consume it — diff their handling against each other. |
| **P3 Deploy + prove** | `Deploy-Processor`, `Invoke-HealthCheck`, `Verify-Config` | Mutates production, then proves itself. Can it destroy state and still report PASS? Deploy-Processor invokes the other two. |
| **P4 Unattended drift** | `Start-DriftRunner`, `Test-DriftHeartbeat`, `Install-DriftTask` | Nobody is watching. Does silent failure look identical to a clean run? |
| **P5 Wrappers + harness** | both `processors/*`, `Invoke-Tests.ps1` | The process boundary. **None imports the module**, so the exit constants aren't in scope and the contract can drift silently. |
| **P6 Cross-cutting sweep** | all 13 | Axis sweeps, deduplicated: exit-code map (18 AST sites), `.Count`-on-possibly-scalar (30 sites), `SilentlyContinue` (17 sites / 6 files), `$LASTEXITCODE` vs `$?` after robocopy/git/aws, any second copy of the exclude regex, and every `-File` boundary that passes a list. |

Review the module **first and alone** — eight entry scripts import it, so reviewing callers
first yields N duplicate findings for one module defect.

## Machine verification (read-only)

Run through Windows PowerShell 5.1 (`$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`),
not pwsh 7 — 5.1 is the target runtime. Pass the 5.1 script as a single-quoted pwsh here-string
to `-Command`; inlining it on the command line does not survive quoting.

1. **Parse-check all 13** via `[System.Management.Automation.Language.Parser]::ParseFile`
   (does not execute). `FileCount=13` proves scope completeness; `TOTAL-PARSE-FAILURES=0` is
   positive proof that no PS7-only *syntax* (`??`, `?.`, ternary, `&&`/`||`) exists, since those
   are hard parse errors in 5.1.
2. **Grep for PS7-only *runtime* constructs** (not parse errors): `AsHashtable`, `-Parallel`,
   `LeafBase`, `Get-Error`, `Test-Json`, `$PSStyle`. Must exclude the datadog worktree path.
3. **PSScriptAnalyzer** — verified **absent from both 5.1 and 7.6.4**. Record "not installed,
   not run" and mark the rules it would have machine-checked as not machine-verified. Do not
   install it; that is a state change.
4. **Pester** — gate first: grep `tests/` for production paths (`D:\`, `VESEMS`, `us-gov`,
   `/ves/`); currently clean. Then run `Invoke-Tests.ps1` under 5.1 as an operator would.
   Post-run, check cleanliness with a *filesystem* listing as well as `git status` — `.gitignore`
   hides `*.jsonl`, `logs/`, `baselines/`, `*.manifest.json`.
5. **AST censuses** for anything the report states as a count — grep over-counts
   (`grep -c "exit "` says 37; the AST says 18 real `ExitStatementAst` nodes).

## Report

**Location: `.claude/reviews/2026-08-01-ves-code-review-71ed2e19.md`.** `.claude/` is the only
in-repo path verified gitignored (`.gitignore:2`), so a concurrent actor's `git add -A` cannot
sweep the report into their branch — the exact failure this repo has hit before. Caveat to state
in the report: gitignored means git is not backing it up, and `git clean -xdf` would delete it.

Per finding: ID, title, severity, status tier, `file:line` **plus the quoted source line**,
trigger condition, contract violated (with its own file:line), operator impact, corrected 5.1
code, fix status (`NEW` / `FIX-ON-BRANCH <name>`), and the command whose output is the evidence.

**Severity in this repo's terms:** Critical = fails open (a check that should fail passes, or
production state destroyed while still reporting PASS). High = wrong exit code reaches the
caller, or a configured check never runs. Medium = degraded evidence. Low = style/portability.

**Three status tiers**, exactly one per finding: `VERIFIED-BY-EXECUTION` (a command was run and
its output is in the report) / `VERIFIED-BY-STATIC-PROOF` (AST + quoted line + documented 5.1
semantics; nothing run) / `INFERRED` (runtime behavior not exercised — say so plainly).

**Sections:** anchor block (SHA, `git status` at start *and* end, runtime versions, Pester
version, PSSA absent) → executive summary (≤10 lines, doubles as the inline summary) → scope &
method → machine results → **new findings only** → **prior findings: status at HEAD** (separate
table with a verdict + evidence command per row, kept out of the findings count) →
known-accepted gaps (one line each: still accurate, or wording now diverges) → test-coverage
regression → not-reviewable-read-only → reproduction appendix with every command and its output.

## Verification — how to confirm the review is thorough, not just plausible

- **Coverage ledger**: all 13 files with line count, pass number, what was examined, and findings
  count *including zero*. Line column must sum to 3,193. A zero-findings file states what was
  checked — "no findings" without evidence is indistinguishable from "not read."
- **Every line number is checkable at the anchor SHA**, since other actors edit this tree:
  `git show 71ed2e19:Invoke-Verification.ps1` and compare the report's quoted line character
  for character.
- **The machine steps reproduce**: re-running gives `FileCount=13`, `TOTAL-PARSE-FAILURES=0`,
  18 exit sites, and the same Pester counts.
- **Negative controls reported** (parse errors 0, PS7 runtime-isms 0, production paths in tests 0)
  — a report containing only positives suggests the reviewer went looking for confirmation.
- **Spot-check**: pick 3 findings at random, verify location/quoted text/trigger; then read 50
  lines of a file the report calls clean.
- **Status-tier mix**: nothing marked `INFERRED` means overclaiming; all-Critical-and-`INFERRED`
  means the severity ranking is not earned.

## Risks and gotchas specific to this repo

- **StrictMode is narrower than the rubric implies.** `Set-StrictMode -Version 2.0` appears at
  exactly one site (`module/VesVerify.psm1:13`). A module has its own session state, so it governs
  code *inside* the module — none of the 12 entry scripts sets it. Every "throws under StrictMode"
  finding must state which side of that line the code is on. Getting it backwards manufactures
  false findings, which the rubric explicitly forbids.
- **The nested worktree silently doubles scope.** `Post-Deployment-datadog-558667ed/` sits inside
  the main tree; any `-Recurse` enumeration picks up its ~12 scripts and 9 test files. Use the
  explicit 13-path list or filter the path on every enumeration.
- **`Invoke-Tests.ps1` will run Pester 6.0.1, not 5.x** — `:23-25` takes the highest version
  `>= 5.0.0` with no upper bound, and 6.0.1/6.0.0/5.9.0/3.4.0 are all installed. Do not report a
  red suite as a code defect without re-running pinned to 5.9.0. The unbounded pin is itself a
  finding, as is `:30`'s `exit 2` colliding with both "two tests failed" and `VES_EXIT_NOBASE`.
- **Running Pester executes the scripts under review** — `tests/_helpers.ps1` spawns them as child
  `powershell.exe` to read real exit codes. You authorized this; the rubric forbids it. Reconcile
  explicitly in the method section, gated on the clean production-path grep.
- **`-File` cannot pass arrays**, and this repo crosses that boundary four times
  (`Deploy-Processor.ps1:173,336,356`; `Install-DriftTask.ps1:62-65`). Repeated named params are
  `ParameterAlreadyBound`; `-X a,b` binds as one string. Each such finding must name the
  invocation path — `-File` (no arrays) vs `-Command`/`&` (arrays fine).
- **Deduplicate before counting**: one module defect surfacing at four call sites is one finding
  listing four instances, not four IDs.
- **Concurrency**: capture `git rev-parse HEAD` and `git status --porcelain` at start *and* end.
  If HEAD moves mid-review, say which findings predate the change and re-verify via `git show`.
- **This plan file's own location is not gitignored.** `nimbalyst-local/` is untracked and
  unignored, so a concurrent `git add -A` would commit it. The review report goes to
  `.claude/reviews/` for that reason; consider ignoring `nimbalyst-local/` separately.

## Out of scope

No fixes applied, no branches merged, no commits. Not assessed: real SSM/AWS behavior, robocopy
against a live tree, Task Scheduler registration, PSScriptAnalyzer rule results (not installed),
and real 5.1 parameter binding across the `-File` boundary. Whether to merge
`claude/verify-fixes-2026-07-27` is a recommendation in the report, not an action.
