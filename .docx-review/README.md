# STALE — not canonical operator guidance

This folder holds an older Word export (`source.docx`) and rendered page images/PDF
used for a one-time review. **It still describes AWS Parameter Store / `-TrustParam`
as the trust model.** That is wrong.

## Use these instead

- [docs/RUNBOOK-NON-TECHNICAL.md](../docs/RUNBOOK-NON-TECHNICAL.md)
- [docs/RUNBOOK.md](../docs/RUNBOOK.md)
- [docs/UAT-PILOT-CHECKLIST.md](../docs/UAT-PILOT-CHECKLIST.md)
- [docs/STATUS-RAID-SOLUTIONS-2026-08-06.md](../docs/STATUS-RAID-SOLUTIONS-2026-08-06.md)

Approved releases are recorded in the **Git baseline archive** (`-ArchiveRepo` /
`-BaselineRepo` + `-ReleaseTag`). Do not circulate `source.docx` or the baseline
PDF/PNGs to leadership or testers as current guidance.

If a Word handout is required again, regenerate it from the markdown guides above
and replace this tree — do not edit the stale export in place.
