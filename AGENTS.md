# Sudrf project instructions

## License

- Except for third-party components and materials, original repository content
  is © 2026 Воробьёв Виктор Викторович and licensed under CC BY-NC-ND 4.0;
  see `LICENSE.md` and `THIRD_PARTY_NOTICES.md`.
- Preserve copyright, attribution, SPDX, license, and third-party notices.
- An automated agent acting on an in-repository task authorized by the
  rightsholder may modify the repository within that task. Do not infer
  permission to relicense or distribute modified material outside the
  authorized repository workflow.

## Roadmap

- Живой план работ — `Docs/roadmap.md`: очередь задач, принятые решения и находки, которых нет в issues. Читайте его перед тем, как брать задачу, и обновляйте в той же ветке сразу после мёрджа.
- Не заводите план в `~/.claude/plans/`: файл там привязан к сессии и в интерфейсе показывает прежнюю редакцию, даже когда правки легли на диск.

## Repository map

- Для широких и сквозных изменений сначала используйте `Docs/architecture/repo-map.md`; для локальной правки открывайте только релевантную строку таблицы маршрутов.

## Changelog convention

- **Branch drafts:** новые изменения пишутся в `Docs/branch-changelogs/<branch-slug>/vX.Y.Z.md` (папка = имя ветки, файл = прогнозируемая версия). Прогноз может не совпасть с финалом — это нормально.
- **Не трогаем** `changelog/changelog-v*.md`, `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION` в `project.yml` / `Scripts/make-app.sh` пока идёт работа в feature-ветке. Версия присваивается при merge/release.
- **Перед merge/release:** выбираем финальный номер по фактическому порядку выхода, копируем содержимое черновика в `changelog/changelog-vX.YY.ZZ.md`, обновляем `project.yml` и `Scripts/make-app.sh` с новой версией и следующим номером билда.
- **Классификация SemVer:** новая пользовательская функция или новый источник данных повышают второй сегмент и сбрасывают третий в ноль. Исправления, косметика, переобучение без новой продуктовой возможности и developer-only инструменты повышают третий сегмент. Каждая влитая ветка получает собственный номер по этой классификации: отсутствие отдельной сборки — повод бампнуть версию, а не повод склеить заметки.
- **Имена файлов в `changelog/`:** второй и третий сегменты дополняются нулём до двух знаков (`changelog-v0.04.00.md`, `changelog-v0.42.06.md`), чтобы алфавитная сортировка папки совпадала с порядком версий. Заголовок внутри файла и `MARKETING_VERSION` остаются обычным semver без ведущих нулей (`# v0.42.6`, `"0.42.6"`).
- **После merge:** черновик из `Docs/branch-changelogs/` удаляем (или оставляем, если он полезен как handoff-документ).
- Применяется ко всем feature-веткам с этого момента. v0.38.0–v0.38.7 (на ветке `captcha-auto-solver` до rebase) были закоммичены по старому правилу — при следующем merge их release-ноты будут retro-fitted в `changelog/changelog-v0.38.{0..7}.md` из draft в `Docs/branch-changelogs/captcha-auto-solver/v0.38.8.md` (preamble).

## Captcha auto-solver

- SwiftPM product `CaptchaSolver` (Sources/CaptchaSolver/) — Vision-based,
  on-device, no network. Default = ON; toggle in system menu "Captcha" (⌃⌘A).
- `SudrfKit` is **not** a dependency of `CaptchaSolver`; only `SudrfApp`
  imports it. The solver is opt-in at the call site: each consumer
  calls `AutoCaptchaSolver.solve(...)` and falls through to manual
  flow on nil.
- Two automatic entry points:
  - `SearchModel.executeSearch` — interactive search (v0.38.1).
  - `RefreshCenter.performRefresh` — background tracked-case refresh
    (v0.38.0), including higher-court CAPTCHA stubs before they are
    published. `AppRouter.beginCaptcha(for:)` is the explicit manual
    fallback behind the «Ввести код» button.
- `RefreshCenter` coalesces concurrent automatic solves by canonical court
  module host: a batch of cases reaching the same KSOYU CAPTCHA shares one
  solve and token instead of launching duplicate OCR tasks.
- Two captcha kinds: `.sudrfToken` (digits, *.sudrf.ru) and
  `.kcaptcha` (mixed letters+digits, *.msudrf.ru). Selection is
  host-based via `AutoCaptchaSolver.kindFromURL(_:)`.
- История изменений captcha-солвера: `Docs/branch-changelogs/captcha-auto-solver/`
  (черновик) → `changelog/changelog-v*.md` (после merge).
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
