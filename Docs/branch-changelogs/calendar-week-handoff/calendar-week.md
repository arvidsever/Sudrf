# Branch changelog: calendar-week-handoff

Target release: next feature release, assigned at merge/release time.

This is a branch-local draft. Do not use this file as the public release
changelog. When the branch is merged to `main`, move the final user-facing
notes into `changelog/changelog-vX.Y.Z.md`, then update `MARKETING_VERSION`
and `CURRENT_PROJECT_VERSION`.

## Planned

- Add Calendar mode `Week`: a seven-day hourly grid with hearings, deadlines,
  conflict grouping, and a shared `Month | Week | Agenda` segmented control.
- Keep calendar data derived from the existing `router.hearings` and
  `router.deadlines` arrays so Month, Week, Agenda, day panel, and Overview
  stay in sync.
- Remove production-type tinting from rows in `My Cases` list mode while
  keeping production type visible via text/badges.

## Notes

- Version number is intentionally not reserved in this branch.
- If this branch ships before the captcha/opencode line, it may become
  `Alpha 0.38.0`; otherwise use the next available feature release.
- Do not copy HTML/JS from the design handoff into production code; treat it as
  a visual and behavioral reference.
