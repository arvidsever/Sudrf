# #434 — сохранение акта при обновлении карточки

Дата: 9 октября 2026 года. Первичный полный прогон был на `8eb91de`, до rebase
на [#248](https://github.com/arvidsever/Sudrf/pull/435). Текущая база после
rebase: `39f253c9256ed31f0889afb8e6c87776286e3543` (0.64.0 / build 252);
кандидат выпуска — 0.64.1 / build 253 в PR #437.

## Проверяемый сценарий

Санитизированная карточка КСОЮ из тестового набора #322 разбирается штатным
парсером и проходит через `MovementService` и `RefreshCenter`. Фикстура не
содержит текста акта, поэтому ранее сохранённый текст в регрессии синтетический
и прямо так обозначен. Обновление получает ту же карточку без связанного акта.

Положительное сопоставление требует одинакового канонического хоста, уровня,
валидной совпадающей карточки и отсутствия конфликта `cartotekaID`. Другая
карточка, уровень, конфликт картотеки или отсутствие проверенного URL не должны
переносить акт. Проверяется также, что свежие реквизиты и текст побеждают кэш.

Сквозной XCTest использует временный дисковый store и штатный `RefreshCenter`:
полное обновление, частичное обновление, холодное закрытие и повторное открытие
store, повторное обновление. Проверяются связь акта с карточкой, тело, точный
набор ID журнала, `movementFetchedAt`, коллекции, `addedAt` и `seenAt`.

Прямые тесты отдельно проверяют совпадение карточки, номера дела, уровня и
`cartotekaID`, свежие реквизиты и текст, а также запрет переноса в другой круг.
Проверка семантического сравнения подтверждает, что один scalar act ID/URL и
эквивалентный одиночный массив не меняют источник, но дополнительные акты,
файлы и изменённые scalar-поля остаются значимыми.

Тесты работают только с санитизированной фикстурой и локальными подменёнными
источниками. Пользовательская база, настройки установленного приложения,
TestFlight и живые судебные сайты не используются.

## Проверки

- `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete` — полный
  прогон до rebase на #248, на коде `8eb91de`, завершился с кодом 0:
  `SudrfKitTests` — 726 XCTest; `SudrfAppTests` — 1 160 (15 пропусков);
  `FSSPCaptchaLabTests` — 10 (0 пропусков); `CaptchaSolverTests` — 75
  (5 пропусков); `CaseEventDeriverTests` — 28 Swift Testing. Итого 1 971 XCTest,
  20 пропусков, 0 ошибок и 28 успешных Swift Testing. #434, #370, #76 и
  публикационные conflict-регрессии прошли.
- На исходном production-файле `MovementCachePolicy.swift` из `861906f` тесты
  #370 и #76 проходили. В изменённой версии диагностировался сброс `seenAt`:
  при восстановлении кеша scalar act-ссылки превращались в эквивалентные
  singleton-массивы и ошибочно выглядели изменением источника. После
  нормализации только эффективных linked-массивов оба сценария проходят в
  финальном полном прогоне; scalar-поля и порядок ссылок остаются значимыми.
- `python3 Scripts/generate-legal-deadline-registry.py --check` — реестр
  актуален.
- `xcodegen generate` — проект создан, отслеживаемых изменений генерации нет.
- После rebase выполнен строгий профильный прогон:
  `swift test --disable-sandbox -Xswiftc -strict-concurrency=complete --filter 'MovementCachePolicyTests|MovementDerivationTests|Issue434CachedActRetentionTests'` — 131 XCTest, 0 ошибок. Лог:
  `/private/tmp/sudrf-434-final/affected-tests.log`.
- После rebase `python3 Scripts/generate-legal-deadline-registry.py --check`
  подтвердил актуальность реестра; лог:
  `/private/tmp/sudrf-434-final/registry-check.log`.
- Выпуск `0.64.1 (253)` собран без подписи на Xcode 27.0 (build 27A266a),
  macOS SDK 27.0, командой
  `xcodebuild -project Sudrf.xcodeproj -scheme Sudrf -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`.
  Сборка успешна. Логи:
  `/private/tmp/sudrf-434-final/xcode-version.log` и
  `/private/tmp/sudrf-434-final/xcodebuild.log`.
- Исходные и скопированные в собранный `.app` модели numeric,
  numeric-specialist и FSSP совпали с manifest; файл eligibility в `.app`
  совпал с fixture.
- `git diff --check` — без ошибок.
