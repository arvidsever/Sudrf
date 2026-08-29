# v0.46.9 — обязательная обработка ошибок сохранения

## Исправлено

- Все изменения отслеживаемых дел теперь завершаются явным fallible commit:
  отказ синхронизации проекции и отказ SwiftData save различаются и полностью
  откатывают транзакцию.
- Refresh, enforcement, repair, CAPTCHA, сроки, подборки, импорт и Shortcuts
  больше не выполняют успешные callbacks, reload/Spotlight или закрытие
  редактора до подтверждённого сохранения.
- CSV-импорт сохраняет весь подготовленный batch и проекцию актов одной
  транзакцией; при отказе ни одна новая запись не остаётся в базе.
- Интерактивные операции показывают единый dismissible alert, а фоновые
  обновления, импорт и App Intents сохраняют специализированные сообщения.

## Совместимость

- SwiftData V6, migration plan, публичные API и формат хранилища не изменились.

## Проверено

- `swift test`: 865 тестов, 10 пропущено, ошибок нет.
- Focused-регрессии projection/context rollback, refresh, enforcement, repair,
  import, сроков, track/untrack, подборок, App Intent и startup fail-closed.
- Независимый adversarial review, SwiftPM, Xcode Debug и CI-пакетирование
  macOS-приложения.
