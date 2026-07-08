## Imported Claude Cowork project instructions

## Captcha auto-solver

- SwiftPM product `CaptchaSolver` (Sources/CaptchaSolver/) — Vision-based,
  on-device, no network. Default = ON; toggle in system menu "Captcha" (⌃⌘A).
- `SudrfKit` is **not** a dependency of `CaptchaSolver`; only `SudrfApp`
  imports it. The solver is opt-in at the call site: each consumer
  calls `AutoCaptchaSolver.solve(...)` and falls through to manual
  flow on nil.
- Three call sites:
  - `SearchModel.executeSearch` — interactive search (v0.38.1).
  - `RefreshCenter.performRefresh` — background tracked-case refresh
    (v0.38.0).
  - `AppRouter.beginCaptcha(for:)` — per-instance captcha stub in
    `CaseMovementView` (v0.38.2). Sync signature, async work in Task.
- Two captcha kinds: `.sudrfToken` (digits, *.sudrf.ru) and
  `.kcaptcha` (mixed letters+digits, *.msudrf.ru). Selection is
  host-based via `AutoCaptchaSolver.kindFromURL(_:)`.
- See `changelog-v0.38.{0,1,2}.md` for the implementation notes.
