## Imported Claude Cowork project instructions

## Captcha auto-solver

- SwiftPM product `CaptchaSolver` (Sources/CaptchaSolver/) — Vision-based,
  on-device, no network. Default = ON; toggle in system menu "Captcha" (⌃⌘A).
- `SudrfKit` is **not** a dependency of `CaptchaSolver`; only `SudrfApp`
  imports it. The solver is opt-in: `RefreshCenter` tries it first when
  it catches `SudrfError.captchaRequired`, falls through to manual
  `CaptchaPendingQueue` on low confidence or exhaustion.
- Two captcha kinds: `.sudrfToken` (digits, *.sudrf.ru) and
  `.kcaptcha` (mixed letters+digits, *.msudrf.ru). Selection is
  host-based in `RefreshCenter.kindFromURL(_:)`.
- See `changelog-v0.38.0.md` for the implementation notes.
