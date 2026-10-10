# Issue #455: unsupported complaint note

## Scope — 10 October 2026

The mapper no longer creates "жалоба отклонена" from complaint kind, absent UID
and absent case request. Those fields do not prove a disposition. The published
court result and event timeline remain unchanged, including an explicitly
published rejection in the result. Supported refusal/return notes remain.

The branch starts at actual main
`8a7f0e8245d7275dcd879692b998560c33ef9d9f` (0.64.8, build 260).
No release version, database migration, live request or application launch was
performed. Working data, localization and deadline rules were not changed.

## Consumer audit

The unsupported literal had one producer: MovementService.mapProduction.
CaseMovementView displays notes as a TinyChip, separately from the published
result and sessions. Membership/order rules elsewhere compare only the distinct
"Предыдущая регистрация" note. MovementCachePolicy uses its specific temporary
unavailable notes for partial refresh. AppModel and TrackedCaseRepair use their
own previous-registration notes; no status or act rule depends on the removed
unsupported literal. Generic cache/repair merging can retain old note strings;
the sole header consumer now suppresses the exact unsupported note for VSRF
instances, so previously saved caches also stop displaying that bubble. Raw
cached notes and all result/timeline data remain intact; no cache normalization
or migration is performed. Other notes and sources retain their presentation.

## Offline profile

VSRFMovementTests: 15 tests passed, zero failures/skips. Three added regressions
cover complaint without UID/case request with absent or published result, real
refusal/return, and an independent case production. Own result, sessions, dates,
source URL, judge, instance level and act links are asserted unchanged.
The selected Kit suite has no UserDefaults access or production shared clients;
its transport fixture uses an ephemeral URLProtocol session. No full local suite
or UI/working database was opened.

Log: `/private/tmp/sudrf-455-vsrf-movement-profile.log`, SHA-256:
`e9efa75972756c1e486dc7ce2805010c95654c2ca7e5633437a7155559f5f223`.
Independent review and current-head hosted CI remain separate gates.

## Build and display verification — 10 October 2026

Read-only source verification confirmed the sole TinyChip consumer excludes
only `(moduleHost == "vsrf.ru" && note == "жалоба отклонена")`. The published
result, sessions and act links remain separate consumers. This same guard covers
legacy decoded/cached notes without altering the saved value. No duplicate
implementation test or additional UI component was introduced.

Independent Astra review passed for all five changed files. `swift build
--target SudrfApp` passed without launch; log SHA-256:
`02f1f43512ba1236299f9579159522613b1c44e5c3456f0529898b76be4d4e04`.
Own Xcode Debug build passed in `/private/tmp/sudrf-455-derived`, without launch
or signing; log SHA-256:
`7000b1246262f3c2d2e86c94aba56087c5f91a8bf5282daeb4b67fdd1a6097ec`.
The registry generator check passed. All three CoreML models matched the
checked-in manifests and are present in the built app resources. Models were
copied from the previously verified #241 checkout; no court portal was queried.
Current-head hosted full CI remains the final execution gate.
