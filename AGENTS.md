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
- See `changelog-v0.38.{0,1,2,3,4,5,6,7}.md` for the implementation notes.
- При полном исчерпании попыток солвер сохраняет последний PNG в
  `~/Library/Application Support/Sudrf/captcha-failures/` (≤ 50 файлов,
  FIFO). Лог `captcha-solve.log` рядом содержит путь к сохранённой
  картинке — открывайте её, чтобы понять, почему Vision выдаёт conf=0.00.
- **SearchDiagnostics** (v0.38.5, raw-bytes fix in v0.38.6) — при
  «Поисковый модуль суда … не отвечает в известных форматах»
  (captcha-включённый суд, не magistrate) последний HTML-ответ
  суда сбрасывается в `~/Library/Application Support/Sudrf/diagnostics/variant_<host>_*.html`
  (≤ 50 файлов, FIFO). С v0.38.6 файл сохраняется **в исходных
  байтах** (без перекодирования в UTF-8) — браузер прочитает
  `<meta charset=...>` из самого HTML и применит его, mojibake
  больше нет. Отключается: `defaults write ru.sudrf.app
  captcha.diagnosticsEnabled -bool NO`.
- **Preprocessor** (v0.38.4 + v0.38.7) — глобальный тоггл
  preprocess в меню «Captcha» (`CaptchaSettings.preprocessorEnabled`).
  Под капотом — `VisionOCRStrategy.preprocessingProvider: (() -> Bool)?`,
  читается при каждом вызове солвера, тоггл в меню действует
  сразу. **Default = OFF** (регрессирует на простых captcha:
  «667» → «49»). Per-host set `preprocessorHosts` сохранён для
  обратной совместимости, в UI не управляется. Power-user
  по-прежнему может выставить
  `defaults write ru.sudrf.app captcha.preprocessorEnabled -bool YES &&
   defaults write ru.sudrf.app captcha.preprocessorHosts -array sankt-peterburgsky--spb.sudrf.ru`,
  тогда preprocess ограничен per-host. В UI-режиме preprocess
  применяется ко всем.
- **Top-3 candidates diagnostic** (v0.38.7) — на каждой попытке
  `AutoCaptchaSolver` пишет в
  `~/Library/Application Support/Sudrf/diagnostics/<host>_<ts>_<kind>_candidates.txt`
  с полями host, kind, preprocessed, submitted, confidence, alternatives
  (топ-3 после регулярки). Помогает офлайн разобрать, почему
  солвер выбрал именно этот текст (или почему conf=0.00).
