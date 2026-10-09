# #186 — отдельная Debug identity и Spotlight recovery

## Контракт

- Схема Xcode по-прежнему называется `Sudrf`; её конфигурация `Debug` собирает
  `Sudrf Debug` в `Sudrf-Debug.app` с bundle ID `ru.sudrf.app.debug`.
- Debug регистрирует URL scheme `sudrf-debug` и использует Keychain service
  `ru.sudrf.app.debug.ai-provider-key`. Production сохраняет `sudrf` и
  `ru.sudrf.app.ai-provider-key`.
- Отдельный bundle ID задаёт Debug собственные sandbox и defaults.
  `CSSearchableIndex` по-прежнему называется `Sudrf`; изоляцию системного
  CoreSpotlight-домена по bundle identity подтвердит только отложенная native
  проверка. Автоматического копирования production-данных нет.
- Release и `Scripts/make-app.sh` сохраняют production identity и поведение.
  Текущая проверка Release ограничена build settings; Release build/archive не
  выполнялись.
- При отказе scheduled Spotlight write лог содержит только error domain/code.
  Система хранит актуальный pending scope, делает первоначальную попытку и до
  двух повторов с задержками 5 и 30 секунд. После трёх отказов новые scheduled
  попытки подавляются до успешного явного `setEnabled(true)` с полной
  синхронизацией. Выключение сохраняет явный purge, включение — полную
  синхронизацию.
- Если во время этой полной синхронизации приходит новый scope, его выполняет
  уже существующий scheduled task; после ошибки он объединяется с pending scope
  и повторяется. Регрессия проверяет две карточки и подтверждает, что scope A не
  теряется при ошибке первой записи, а повтор охватывает A и B.

## Автоматические проверки

- `swift test --filter SpotlightIntegrationTests`: 20/20, включая recovery race.
- Xcode Debug собран без подписи после последней правки race guard с настоящими
  CoreML-моделями. Все три модели в bundle прошли `Scripts/verify-model.sh` по
  tracked manifest; FSSP eligibility JSON побайтно совпал с исходным. [Лог
  сборки](</private/tmp/sudrf-debug-spotlight-186-final-build.log>).
- `xcodebuild -showBuildSettings` подтвердил Debug identity выше и production
  Release: `ru.sudrf.app`, `Sudrf`, `sudrf`. Это проверка настроек, не Release
  build.
- `python3 Scripts/generate-legal-deadline-registry.py --check` прошёл.
- Ранее отдельная compile/link-проверка выполнялась с временными пустыми
  каталогами моделей и не проверяла модельные ресурсы; её не следует считать
  доказательством их включения.
- Xcode app не запускался. Production app, база, пользовательские defaults,
  Keychain и системный Spotlight не открывались.
- После обновления на `main` `035599ff3e9faf3e1abd6314c848738882cfb707`
  с отдельным исправлением #426 полный тестовый прогон прошёл: 1954 XCTest,
  20 штатных пропусков, ошибок нет; 28 Swift Testing успешны.
  По target: SudrfKit 714/0, SudrfApp 1155/0 (15 пропусков),
  FSSPCaptchaLab 10/0, CaptchaSolver 75/0 (5 пропусков).
  [Локальный протокол](</private/tmp/sudrf-186-after-426-full.log>).
  Первоначальный независимый сбой ручного срока устранён в PR #428;
  проверка не ослаблялась в рамках #186.
- [Draft PR #430 и CI](https://github.com/arvidsever/Sudrf/pull/430/checks).
  Hosted Xcode 27 job без соответствующего Xcode пропускает сборку;
  локальная настоящая Xcode 27 сборка приведена выше.

### Проверки после переноса на `main` `8403266` (9 октября 2026 года)

- `swift build --scratch-path /private/tmp/sudrf-186-swiftpm-build
  --target SudrfApp` завершился успешно. Это компиляция SwiftPM-продукта; она
  не создаёт macOS app bundle.
- `swift test --scratch-path /private/tmp/sudrf-186-swiftpm-build --filter
  testAppIdentityKeepsDebugLinksAndKeychainSeparate` прошёл: 1 тест, 0 ошибок.
  Проверены только чистые функции выбора bundle ID, URL scheme и Keychain
  service, а также разбор ссылки.
- Xcode 27 (`27A266a`) через `-showBuildSettings` подтвердил Debug-настройки:
  `Sudrf-Debug.app`, `ru.sudrf.app.debug`, `Sudrf Debug`, `sudrf-debug`.
  Для Release подтверждены `Sudrf.app`, `ru.sudrf.app`, `Sudrf` и `sudrf`.
  XcodeGen завершился успешно на текущем `project.yml`; сгенерированный plist
  сохраняет значения identity как build-setting references.
- Генератор существующего QA-host для #324 проверен с текущим `project.yml`:
  XcodeGen и `-showBuildSettings` дали `Sudrf324QA.app`,
  `ru.sudrf.qa.issue324` и `sudrf-qa-324`. В
  `Docs/qa/issue-324/build-ui.sh` заменены прежние частичные подстановки на
  подстановки точных YAML-ключей, чтобы суффикс Debug и схема продукта не
  просачивались в QA identity.
- На момент этой проверки сборка Xcode app после rebase не запускалась. Постобработка Xcode 27
  автоматически регистрирует собираемое macOS-приложение в LaunchServices, что
  затрагивает системное состояние. Поэтому unsigned build log выше относится к
  предыдущей базе и не служит доказательством свежей сборки после rebase.
  [SwiftPM compile log](</private/tmp/sudrf-186-post-rebase-swiftpm-build.log>),
  [isolated identity-test log](</private/tmp/sudrf-186-post-rebase-identity-test.log>).

### Разрешённая сборка Sudrf Debug после возобновления работы

9 октября 2026 года автор разрешил сборку и автоматическую регистрацию
отдельного Sudrf Debug без запуска. XcodeGen и unsigned Xcode 27 Debug build
на текущем checkpoint `035e340` завершились успешно. Собранный plist содержит
`ru.sudrf.app.debug`, `Sudrf Debug` и только URL-схему `sudrf-debug`.
Журнал подтверждает `RegisterWithLaunchServices` именно `Sudrf-Debug.app`.
Три каталога CoreML совпали с tracked manifests; FSSP eligibility JSON
побайтно совпал с исходным. Приложение не запускалось.

Локальный журнал: `/private/tmp/sudrf-186-resume-debug-build.log`.
SHA-256: `45ff7d5caf78d70f9c59f3fed83afc6855ee72050d76b7a2b85d65f5a4c22aa0`.
Эта проверка снимает ограничение предыдущего build checkpoint, но не заменяет
подписанную системную приёмку ниже и не подтверждает работу Spotlight.

## Приёмка остаётся открытой

Финальное доказательство требует signed Debug-сборки на отдельной macOS-
учётной записи или VM: проверить запуск и независимость sandbox, defaults,
Keychain, URL-схемы и фактического Spotlight-индекса, включая отсутствие
автоматического переноса данных. Эта системная проверка отложена; #186 остаётся
открытым до её выполнения. Успех unsigned build или мок-тестов не подтверждает
подписанное поведение macOS.
