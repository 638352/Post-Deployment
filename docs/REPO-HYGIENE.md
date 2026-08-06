# Repository Hygiene: Open Follow-Ups

**Audience:** whoever maintains this repository
**Subject:** tracked content that is not part of the deliverable, and one broken index entry
**Status as of:** 2026-08-06 (`b74c991e`)

---

## Why this file exists

`b74c991e` untracked 24 scratch page renders under `tmp/` that `c7c41885` had swept in,
and added a `tmp/` entry to `.gitignore` so the same accident cannot recur. That fixed one
directory. The audit that found it also found more of the same class, plus a broken index
entry, and those were deliberately left out of that commit to keep it to one reviewable
change. They are recorded here rather than in a chat log, because a finding that lives only
in someone's memory is the failure mode this whole project exists to remove.

Numbers below are from `git ls-tree -r -l HEAD` at `b74c991e`. None of these are urgent and
none affect how the suite runs; the deliverable itself is clean.

---

## What is tracked at `b74c991e`

| Bucket | Files | Size | Notes |
| --- | ---: | ---: | --- |
| Deliverable (root scripts, `module/`, `processors/`, `tests/`, `docs/`, CI) | 50 | 0.52 MB | What a consumer of this repo actually needs |
| Scratch and editor state (below) | 62 | 14.91 MB | 97% of the repository by size |
| `Post-Deployment-datadog-558667ed` gitlink | — | — | Broken index entry, see below |
| **Total** | **112** | **15.43 MB** | |

---

## 1. Document-review scratch is still tracked

| Path | Files | Size |
| --- | ---: | ---: |
| `.docx-review/` | 53 | 14.88 MB |
| `extract_docx_fixed.py` | 1 | 0.005 MB |
| `.codex-doc-work/extract_docx.py` | 1 | 0.008 MB |

`.docx-review/` is 50 PNG page renders plus a `.docx`, a `.pdf`, and a `.py` — the working
output of a document review, the same class of artifact as the `tmp/` renders and roughly ten
times the size. Nothing in any script, test, or document reads any of it.

**To resolve:** the same treatment `tmp/` got — add the paths to `.gitignore`, then
`git rm -r --cached` them, which leaves every file on disk. Confirm first that nobody is
relying on GitHub as the only copy of those renders, since the point of the review may have
been to share them.

## 2. Editor and tool state is tracked

`.idea/` (5 files), `.codex/agents/code-reviewer.toml`, and
`nimbalyst-local/plans/i-want-claude-code-eager-thompson.md` — 8 files, 0.03 MB. Harmless in
size, but they put one contributor's tooling choices in everyone's checkout, and `.gitignore`
already excludes `.claude/` on exactly that reasoning.

**To resolve:** decide per directory whether it is shared team configuration or personal
state. `.vscode/settings.json` and `.github/` are deliberate and should stay.

## 3. `Post-Deployment-datadog-558667ed` is a broken gitlink

The index records it as mode `160000` (a submodule) pointing at commit `ff799cc7`, but there
is no `.gitmodules` file, so git has no URL to fetch it from. This is not theoretical — it
already fails on every CI run, in `actions/checkout`'s cleanup step:

```
fatal: No url found for submodule path 'Post-Deployment-datadog-558667ed' in .gitmodules
##[warning]The process 'C:\Program Files\Git\bin\git.exe' failed with exit code 128
```

It surfaces as a warning today, so the build still passes, but the same entry makes
`git clone --recurse-submodules` fail and leaves an empty directory in `git archive` output.
`AGENTS.md` describes this path as a snapshot to compare against, which is a worktree or a
sibling clone, not a submodule.

**To resolve:** if the snapshot is not meant to be a submodule, `git rm --cached` the entry
and ignore the directory. If it is, commit a `.gitmodules` with its URL. Either way the CI
warning goes away.

---

## Related

- [../README.md](../README.md) — project overview and the workflow these scripts implement
- `.gitignore` — the `tmp/`, `logs/`, `baselines/` and `.claude/` exclusions referenced above
