# v0.41.1 — onscreen activity crash hotfix

Ветка `codex/fix-onscreen-activity-crash` (PR #47).

> Отдельным билдом 0.41.1 не выходил: фикс влит 20.07.2026 и уехал в составе
> релиза 0.42.0 от 25.07.2026. Заметки опубликованы задним числом, чтобы
> исправление не потерялось между 0.41.0 и 0.42.0.

## Исправлено

- Открытие отслеживаемого дела или судебного акта больше не передаёт custom URL
  `sudrf://` в `NSUserActivity.webpageURL`. На macOS 27 это вызывало
  `NSInvalidArgumentException` и останавливало приложение.
- Onscreen awareness продолжает связывать открытый экран с `CaseEntity` или
  `CourtActEntity` через `appEntityIdentifier` и стабильный
  `persistentIdentifier`.
- Deep links `sudrf://` остаются в Core Spotlight и обработчике `.onOpenURL`;
  исправление не меняет Spotlight-навигацию.

## Проверка

- Добавлены регрессионные тесты для activity дела и акта: AppEntity identifiers
  присутствуют, а `webpageURL` остаётся `nil`.
- `swift test -Xswiftc -strict-concurrency=complete`: 515 тестов, 0 ошибок под
  Xcode 26.6 и Xcode 27.0 beta.
- SwiftPM-продукты SudrfApp/CLI и Xcode-схема Sudrf собраны под Xcode 26.6 и
  Xcode 27.0 beta (SDK 27.0, deployment target macOS 26.0).
- Ручная приёмка после установки сборки: открыть дело, переключать акты и дела,
  закрыть карточку — без `NSUserActivity.webpageURL scheme "sudrf" is not allowed`.

## Процесс

- PR получает AI self-review автора до независимого adversarial review.
- Merge разрешён только после устранения принятых замечаний и зелёных checks.
