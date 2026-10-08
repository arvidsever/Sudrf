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
- Полный тестовый прогон: [лог](</private/tmp/sudrf-186-full-swift-test.log>).
  `swift test -Xswiftc -strict-concurrency=complete` завершился с кодом 1:
  1954 XCTest, 20 пропусков, один сбой; 28 Swift Testing прошли. По target:
  SudrfKit 714/0, SudrfApp 1155/1 (15 пропусков), FSSPCaptchaLab 10/0,
  CaptchaSolver 75/0 (5 пропусков). Единственный сбой — известная независимая
  #426 `TrackedCaseRepairTests.testAliasMergeKeepsActiveExactPrivateDeadlineAheadOfClosedMonthlyHistory`:
  `XCTUnwrap` не нашёл `StoredDeadline` в `Tests/SudrfAppTests/TrackedCaseRepairTests.swift:402`.
  Сбой не исправлялся и проверка не ослаблялась в рамках #186.

## Приёмка остаётся открытой

Финальное доказательство требует signed Debug-сборки на отдельной macOS-
учётной записи или VM: проверить запуск и независимость sandbox, defaults,
Keychain, URL-схемы и фактического Spotlight-индекса, включая отсутствие
автоматического переноса данных. Эта системная проверка отложена; #186 остаётся
открытым до её выполнения. Успех unsigned build или мок-тестов не подтверждает
подписанное поведение macOS.
