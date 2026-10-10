# #322 — восстановление московских цепочек

## Источник доказательств

Офлайн-тесты используют сохранённые санитизированные HTML-фрагменты из
[provenance фикстур](../../../Tests/SudrfKitTests/Fixtures/issue322_provenance.md).
Исходные сведения проверены 25 сентября 2026 года. Это необходимые поля
парсеров, а не побайтовые копии полных ответов суда; SHA-256 относятся к
опубликованным фрагментам.

## Повторная офлайн-проверка — 10 октября 2026 года

Ветка обновлена через rebase на `origin/main`
`bd06f4ef19922f311ece19df3167296a80d26756`; проверенный код ветки —
`459fb2b3eb6bc42eee71fc72738c836255067579`. В тестовом `makeCenter`
явно передан `fsspAutoModelEnabled: false`: создание `RefreshCenter`
не проверяет eligibility установленной FSSP-модели. Остальные границы
изоляции описаны ниже.

В отдельном процессе выполнена только команда:

```sh
swift test --disable-sandbox -Xswiftc -strict-concurrency=complete --filter Issue322AcceptanceTests
```

Выполнены ровно `testKSOYURefreshRestoresBothMoscowCardsWithoutJoiningPositiveControl`
и `testTwoAppealsRepairThroughRefreshAndRetainHistoryAcrossPartialFailureAndReopen`:
2 XCTest, 0 ошибок, 0 пропусков; время тестов 0,713 секунды,
сборки SwiftPM — 18,43 секунды. Другие test bundles получили тот же фильтр
и выполнили 0 тестов. Лог проверки —
`/private/tmp/sudrf-322-rebased-isolated-profile.log`, SHA-256:
`1853bd44580491509821e6552ed513f5830ffe1e0065a9fbccd34c01c9519f72`.

Также выполнены `xcodegen generate` и Debug-сборка Xcode без запуска:

```sh
xcodebuild -project Sudrf.xcodeproj -scheme Sudrf -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/sudrf-322-rebased-xcode \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Результат — `BUILD SUCCEEDED`, без предупреждений и ошибок в логе.
Derived Data изолированы во временном каталоге; автоматическая регистрация
сборки средствами Xcode не означает запуска приложения. Отдельные команды
LaunchServices не выполнялись. Лог —
`/private/tmp/sudrf-322-rebased-xcodebuild.log`, SHA-256:
`503ebf2d428e47bd6a43bc92bc23e7e83e821ca7c62de2bbc90ab090cbe6ce16`.

`python3 Scripts/generate-legal-deadline-registry.py --check` подтверждает,
что реестр сроков актуален. Полный набор тестов текущего исходного кода
не запускался. Живая проверка, полный ответ порталов, приложение и UI,
рабочая база, production bootstrap и TestFlight не использовались.
Офлайн-профиль остаётся доказательством поведения на сохранённых фрагментах
и синтетических данных; живая приёмка #322 остаётся незавершённой.

## Изоляция CAPTCHA recovery — 10 октября 2026 года

По согласованному контракту `TrackedCaseRepairCoordinator` принимает
`captchaStore: CaptchaTokenStore = .shared`. При автоматическом решении токен
записывается в переданное хранилище; обычные production-вызовы используют
прежнее общее хранилище. В изолированном запуске клиент и координатор должны
получить один и тот же отдельный экземпляр, чтобы повторный запрос прочитал
решённый токен. Офлайн-профиль явно передаёт координатору отдельное хранилище;
солвер и настройки CAPTCHA в этом профиле отсутствуют.

Также согласована инъекция `CaptchaSettings(defaults: UserDefaults = .standard)`:
чтение, регистрация defaults и сохранение свойств идут в переданный suite.
Обычные вызовы и `CaptchaSettings.shared` сохраняют `.standard`. Для живого
изолированного запуска настройки должны создаваться с отдельным suite.

До исправления конструктора логгера в профильном тесте выполнена команда:

```sh
swift test --disable-sandbox -Xswiftc -strict-concurrency=complete --filter 'Issue322AcceptanceTests|TrackedCaseRepairTests.testRegularSudrfCaptchaIsAutoSolvedOnceBeforeReporting|TrackedCaseRepairTests.testCaptchaSettingsPersistOnlyInInjectedDefaults'
```

Результат: 4 XCTest, 0 ошибок, 0 пропусков, 0,773 секунды. Два теста
`Issue322AcceptanceTests` проверяют прежний офлайн-профиль. Тест автоматического
решения использует отдельные settings suite, CAPTCHA store и WorkingVariantStore
без дискового кеша; проверяет запись решённого токена именно в переданный store.
Вызовы solver, fetcher и origin resolver подменены. Однако конструктор
`CaptchaSolver()` в этом запуске использовал `CaptchaSolverLog.shared`,
который мог создать общие каталоги Application Support. Поэтому этот запуск
не подтверждает полную изоляцию от общей файловой системы. Содержимое общих
каталогов не проверялось и не удалялось. После review тест изменён на явный
логгер с `fileURL`, `failuresDir`, `diagnosticsDir`, равными nil. Исправленная
редакция проверена той же командой: 4 XCTest, 0 ошибок и пропусков. Лог —
`/private/tmp/sudrf-322-captcha-final-isolated-profile.log`, SHA-256:
`b47e95593e8dcdaf3d2e4b88b656c13bbd8262fa1e42a62830e1dbf8d22265db`. Тест настроек проверяет
сохранение всех пяти свойств, нормализацию числа попыток, повторное открытие
и отсутствие этих значений в другом suite. Лог —
`/private/tmp/sudrf-322-captcha-isolated-profile.log`, SHA-256:
`022e20d1e8b0a91a257bccc609f8fa1f5e6e2dad576206f3227aab136b57cc52`.

Эти проверки подтверждают изоляцию CAPTCHA на подменённых вызовах.
Живые запросы, UI, установленное приложение, рабочая база и TestFlight не
использовались. До живой приёмки требуется собрать и проверить полностью
изолированный клиент/координатор/refresh-профиль (включая cookies, кеши,
диагностику OCR и provider/resolver dependencies). Само наличие двух DI-параметров
не подтверждает изоляцию произвольного живого запуска.

## Устранение оставшихся общих клиентов — 10 октября 2026 года

Последующий аудит выявил ещё одну границу прежних профильных запусков:
даже при custom `serviceBuilder` конструктор `RefreshCenter` создавал
неиспользуемые Moscow, VSRF, Treasury и FSSP clients. В частности, production
конфигурации Moscow/VSRF обращались к общему cookie storage. Поэтому прежние
логи не подтверждают полную изоляцию от общего cookie storage.

Переиспользована проверенная для #241 минимальная правка: при переданных
service/enforcement closures неиспользуемые production clients не создаются.
Обычные production defaults сохранены. Профиль #322 передаёт private CAPTCHA
store, VSRF provider и enforcement closures, которые завершают неожиданный вызов
ошибкой теста. Прежние providers, transfer-directory, ephemeral client, disk
store и private UserDefaults остаются отдельными.

Проверка финальной редакции выполнена той же командой четырёх тестов выше:
4 XCTest, 0 ошибок и пропусков, 0,793 секунды; strict-concurrency compilation
прошла. Основание — локальный `HEAD` `0e236f0` плюс незакоммиченные constructor
и профильные изменения. Лог —
`/private/tmp/sudrf-322-constructor-final-profile.log`, SHA-256:
`081aeaf90717a49b4f8d4cc90fe96c443c019ae1bd00eada6c9d2de88a11508f`.

Полный suite не запускался: его визуальные тесты прямо изменяют
`UserDefaults.standard`, включая Spotlight preferences; диагностические тесты
изменяют общий `SearchDiagnostics.enabled`. Такой запуск не соответствует
ограничению на общие settings и системные публикации. Для полного локального
suite требуется отдельная подтверждённая изоляция этих тестов.

Живых попыток этой редакции нет. Pending criteria #322: актуальные полные
ответы московских порталов и Тверского суда; штатный repair/refresh обеих
апелляций и кассации с точными ссылками; повторное обновление, частичный отказ
и холодное открытие с сохранностью пользовательских данных. Офлайн-фикстуры
эти критерии не закрывают. GUI и основное приложение не запускались.

## Офлайн-профиль — 9 октября 2026 года

Проверено на ветке `codex/moscow-chain-acceptance-322-post434`, основание —
слитый `origin/main` `8403266e7ec76cba69abc2b74cf8b0621cf15496`
(`#434`, версия 0.64.1, сборка 253). Команда:

```sh
swift test --disable-sandbox -Xswiftc -strict-concurrency=complete --filter Issue322AcceptanceTests
```

Результат: 2 XCTest, 0 ошибок. Это только профиль двух тестов #322, не полный
набор. Ветка содержит тесты и документацию #322; производственные изменения
#434 пришли из `origin/main`, их повторно не переносили.

Профиль покрывает две отдельные апелляционные карточки 1 АСОЮ и кассационную
карточку 2 КСОЮ. Он проверяет восстановление первой инстанции Мосгорсуда для
пары 1 АСОЮ и обеих нижестоящих карточек для Лукьяновой (Хамовнический районный
суд и апелляция Мосгорсуда), не объединяя положительный контроль с отдельной
карточкой Мосгорсуда. Проверяются точные ссылки и исходные события, частичный
отказ, повторное обновление, холодное открытие дискового тестового хранилища и
сохранение ранее записанного текста актов, связанного с собственной карточкой.
Текст актов синтетический: исходные HTML-фрагменты его не содержат.

На каждом этапе сравниваются полные наборы инстанций в виде
`(уровень, номер, домен, URL)` и их количество: ожидаются ровно три звена,
без лишних и повторных карточек. Во втором сценарии такие же точные проверки
делаются отдельно для целевого дела и отдельного положительного контроля.
Для обеих записей сохраняется снимок значений `addedAt`, `seenAt`, подборок,
полного журнала событий, карточек и связанных текстов актов.

Настоящее холодное открытие разделено на две фазы. Первая создаёт дисковое
хранилище, выполняет repair/refresh и частичный отказ, затем возвращает только
путь и plain-value `Sendable`-снимки. Её `ModelContainer`, `TrackedStore`,
записи, `RefreshCenter` и провайдеры выходят из области видимости. Вторая фаза
создаёт новый `ModelContainer` по сохранённому пути, сравнивает каждую запись
до повторного обновления, выполняет повтор и сравнивает снимки ещё раз.

`TrackedCaseRepairCoordinator` и `RefreshCenter` используют подменённые
московский и SUDRF-провайдеры. `MovementService` собирается тестовым helper по
тем же целям из `MovementContext`, но с локальным transfer-directory, который
возвращает синтетический пустой результат и считает обращения; профиль проверяет,
что обращений не было. Это исключает production directory resolver,
используемый `MovementContext.makeService` по умолчанию. Инъецированный
`SudrfClient` использует ephemeral URLSession с `Issue322OfflineURLProtocol`,
который завершает тест ошибкой при неожиданном HTTP-запросе; дисковые кеши
источников отключены. `WorkingVariantStore` и CAPTCHA store тестовые,
`UserDefaults` изолирован, хранилище создаётся во временной папке.

Источники для целевого дела перед первым частичным отказом получают явную
синтетическую дату `seenAt`: восстановление новой карточки может законно
обозначить цепочку непрочитанной. Профиль фиксирует состояние после этого
перехода и проверяет, что ненулевые `addedAt`/`seenAt`, подборки и журналы не
меняются при частичной ошибке, холодном открытии и повторном refresh. Он не
делает отдельного вывода о политике непрочитанности при первоначальном repair.

Путь `AppRouter` и `openNSActivity` не запускается: тест не открывает
приложение и не проверяет пользовательский интерфейс. Рабочая база, системные
настройки, TestFlight и живые сайты не использовались.

## Остаётся проверить на живых данных

Фикстуры санитизированы и отражают опубликованные поля, а не полные ответы.
Они не подтверждают доступность источников сейчас или воспроизведение свежего
сообщения автора от 4 октября 2026 года. Fixture-refresh заканчивается
`.partial`; новых живых запросов не было, поэтому текущую доступность порталов
не утверждаем.

Issue #322 остаётся открытой до отдельной проверки:

- Начать с уже сохранённых `66а-4311/2020` и `66а-2013/2020` в ситуации из
  сообщения автора от 4 октября; штатный repair/refresh должен подтвердить
  первую инстанцию Мосгорсуда `3а-3696/2020` для обеих карточек, без ручного
  повторного импорта. Сверить контроль Хамовников `3а-1318/2021 → 66а-4009/2021`.
- Отдельно проверить кассацию Лукьяновой `8а-7078/2022 [88а-8501/2022]`:
  цепочка должна включать и Хамовнический районный суд, и апелляцию Мосгорсуда.
  Не присоединять `13-1388/2023` только по совпадению сторон.
- Повторить обновление, частичный отказ источника и перезапуск, сверив точные
  суды, номера, ссылки, отдельные события и сохранность пользовательских данных.
  Получить полные актуальные ответы источников и проверить штатный путь
  обновления; офлайн-профиль этого не доказывает.

## Интеграция актуального main — 10 октября 2026 года

В своей feature-ветке выполнен merge `origin/main`
`8a7f0e8245d7275dcd879692b998560c33ef9d9f` без переписывания истории PR #438.
Единственный конфликт — roadmap: сохранены актуальные #222/#450 и release facts,
а строка #322 сохраняет офлайн-доказательства и незавершённую живую приёмку.
Независимый review разрешения конфликта — PASS. Source changes приняли без
конфликтов; production DI и source #262 сохранены.

Безопасный профиль четырёх тестов с теми же concurrency flags прошёл:
4 XCTest, 0 ошибок и пропусков, 0,749 секунды. Лог —
`/private/tmp/sudrf-322-main-integration-profile.log`, SHA-256:
`6429734146bf446618844cbf567c6528a0f5d3a782be4fdb07420cf2314698d9`.
XcodeGen пересоздал проект; unsigned Debug build `Sudrf` завершился
`BUILD SUCCEEDED`, без warnings/errors, с отдельным derived-data каталогом
`/private/tmp/sudrf-322-main-integration-xcode`. Лог —
`/private/tmp/sudrf-322-main-integration-build.log`, SHA-256:
`53e4bd74b1b8cbbcd762b1522979fc2be2b8d2b6e9af038c36ae9a58101020f9`.
Приложение не запускалось; встроенный build step RegisterWithLaunchServices
не означает запуск. Полный suite, новые живые попытки и GUI не выполнялись.
Hosted CI должен подтвердить новый head после push; старые проверки его не
заменяют. Issue #322 остаётся открытой.

## Private prerequisite gate — 10 October 2026

Source base `2c4360f2382618dd92f6ad5ec92d4a4b90ad52ee` plus the uncommitted
`SearchDiagnostics.swift` and `Issue322PrivateHarnessTests.swift` changes.
The diagnostic directory initialization is reused from #339; the private
`enabled` override is reused from #241. Production defaults remain unchanged.
The process-global diagnostic overrides must be tested serially/exclusively.

Actual sequential local checks (no live requests or AppRouter):

| Check | Actual result | Private log SHA-256 |
|---|---|---|
| `swift build --build-tests` | PASS, 2.53 s | `efbdbf29ece7c9367754d872edeb360c28b8bf05e61c48e0e480be7ff2ab889a` |
| `swift test --skip-build --filter Issue322PrivateHarnessTests` | 2 PASS, 0 failures/skips, 0.018 s | `d06b5094f32929492e8fd94b6af2bf10f79affa34f4af4c5f74c788b7ed0c90b` |
| `swift test --skip-build --filter Issue322AcceptanceTests` | 2 PASS, 0 failures/skips, 0.667 s | `05a8b63b9fd3dec91b307b6e94ea5e76f0b9aeea4d932cac68513fe1f83796dd` |
| `swift test --skip-build --filter Issue322SourceFixtureTests` | 3 PASS, 0 failures/skips, 0.025 s | `270aa8750a4bbbafd7e1c68223e7190a615e6444a84bcde2049e20dec5182ba7` |

Logs are `/private/tmp/sudrf-322-private-gate-compile.log`,
`/private/tmp/sudrf-322-private-gate-tests.log`,
`/private/tmp/sudrf-322-offline-acceptance-current.log`, and
`/private/tmp/sudrf-322-source-fixtures-current.log` respectively.
An initial compile found an actor-isolation annotation missing on the test's
configuration factory; marking that pure factory `nonisolated` fixed it before
any test execution.

The new gate proves private diagnostic writing and construction of clients,
resolver, repair coordinator and refresh center with private settings/tokens,
nil caches/cookies, rejecting transport and unused providers. It does not prove
live chain acceptance, OCR model eligibility, request scope, or cold AppRouter/UI.
The actual opt-in live profile still needs its final private pipeline audit,
explicit model paths verified against the tracked artifact manifest, and source
locators from `Tests/SudrfKitTests/Fixtures/issue322_provenance.md`. No installed
application model discovery is permitted. No full local suite was run.

### Complete opt-in pipeline preparation (no live execution)

`Issue322LiveAcceptanceTests` now prepares the real `SudrfClient` /
`MosGorSudClient` → `CaseOriginResolver` → repair coordinator → `RefreshCenter`
→ private disk store → reopen → repeat path. Its live method remains disabled
unless `SUDRF_322_LIVE=1`. It requires `SUDRF_322_MANIFEST` and the exact
`SUDRF_322_MANIFEST_SHA256`. The JSON manifest contains `outputRoot`, `sourceURLs`
(the exact six URLs, in source-table order), `numericModel`, and `specialistModel`.
The models must be in this checkout's `Tests/CaptchaSolverTests/Fixtures`, pass
its tracked `MODEL_MANIFEST.sha256` / `MODEL_NUMERIC_SPECIALIST_MANIFEST.sha256`
through `Scripts/verify-model.sh`, and are loaded explicitly. There is no installed
application model discovery, model fetch, normal app launch or background timer.

The forwarding transport permits only HTTPS on `1ap.sudrf.ru`, `2kas.sudrf.ru`
and `mos-gorsud.ru`; it rejects other hosts/HTTP/credentials/ports, redirects
outside that set, responses over 5 MiB and resource lifetimes over 30 seconds.
Every consumed body and response record is retained under a fresh private run
in a 0700 root, with files set to 0600. Request/effective URLs are in private
response records only; public reports contain stages/status/timing/count/hash.
Cookies and URL cache are nil. The normal numeric-token contract passes
`captcha`/`captchaid` as search parameters (`SudrfClient` and `SudrfURLBuilder`);
this establishes the client contract, not server acceptance without cookies.
The unchanged solver logger may emit ordinary local macOS diagnostic entries;
nil log directories prevent file output but do not disable that system logger.
This local diagnostic allowance was explicitly retained; no logger API changed.

Actual offline preparation checks, sequential and without any live method:

- Compile: `/private/tmp/sudrf-322-live-harness-compile.log`, PASS,
  SHA-256 `94fdebff8c4461cbc7c445042fe10dd4f344ddbcce95ad7222345b468512cb31`.
- Exact filter `Issue322LiveAcceptanceTests.testOfflineReplayUsesRealClientsRepairRefreshAndReopen|Issue322LiveAcceptanceTests.testPreflightRejectsHTTPWrongSourceAndInvalidManifest`:
  **2 PASS, 0 failures/skips**, 34.338 seconds;
  `/private/tmp/sudrf-322-live-harness-offline-preflight.log`, SHA-256
  `dfea78d2fd4685238f2e5aa2096981cc0663ef054aa9c8073ff3514400ee486d`.

Replay forwards committed HTML through the actual clients/parsers and the same
repair/refresh/store code. Its additional empty higher-search responses are
explicit synthetic controls with source-shaped count metadata, never claims
about the portals. It proves convergence of the two appellate anchors on the
Moscow card, their distinct own native locators, disk reopen and repeat. Its
outcome is explicitly **expected partial**, with affected sources Moscow,
2 KSOYu and VS RF; the VS provider rejects out-of-scope discovery. No provider
was disabled merely to force a complete result. The full live method still
requires `.refreshed` and its full movement/act/original-query assertions.

A first application of those full live assertions to the excerpts failed:
`/private/tmp/sudrf-322-live-harness-replay-full-oracle-failure.log`, SHA-256
`f61bcfa562880bf111afd5655776bf1b8c0e151f40247ef128d9a4bec1d6ea80`.
The excerpts omit both ASOY session tables and linked act bytes, and the current
Moscow movement builder canonicalizes away the `caseNumber` query while retaining
the own native path. Replay explicitly observes these facts; it does not claim
exact legacy query retention or live act success. The raw journal rewrites had
different 1182-byte encodings; **whole decoded journal equality now
passes after repeat**, including imported history and metadata. Reopen still
compares exact saved bytes. This is an existing serialization dependency of the
#179 work, not a newly inferred #322 semantic mutation.

The KSOYu context/expected number is parsed from the published excerpt:
`8а-7078/2022 [88а-8501/2022]`, not an invented `8а-8501/2022` primary number.
Its original URL/native ID remains unchanged. Current live alias/number changes
must be validated from the actual own card, not substituted silently.

Remaining gates before live: independent review of the final full private
pipeline; verify the explicit model artifacts; root review of any scope fork
(including required directory hosts outside the allowlist); retain honest partial
outcomes for VS RF (outside #322 source scope). Before closure, still required:
all three original anchors and the independent `3а-1318/2021 → 66а-4009/2021`
positive control (no published control locator is in these six supplied URLs),
actual own movement/acts/user data and no historical notification, repeat after
partial response, reopen, and the separately isolated cold AppRouter/UI gate.
No full local suite, live request or native launch was performed here.

### Review corrections and final offline gate

The initial forwarding transport privately followed an allowed redirect inside
its inner URLSession. Independent review rejected that path because it bypassed
the ordinary `SudrfClient` redirect capture, origin-session rotation and rate
admission. The private transport now stops its inner redirect with
`completionHandler(nil)` and passes it to `URLProtocolClient.wasRedirectedTo`,
then completes the original 302 in the same way as the existing
`SudrfClientTransportPolicyTests` fixture. The outer client handles the new hop.
Private hop JSON retains request/effective/redirect URLs. A synthetic cross-origin
test verifies both admitted requests and exactly `create → invalidate → create`.

The chain oracle now requires exact registration sets, verifies own levels and
source court/native locators, and rejects an extra `13-1388/2023` material rather
than accepting any superset. The original full-live oracles, missing positive
control and published-query limits remain unchanged.

Final actual sequential offline filter: the cross-origin redirect test, extra
registration test, real-client replay/reopen/repeat test, and negative preflight.
**4 PASS, 0 failures/skips**, 34.558 seconds. Log:
`/private/tmp/sudrf-322-final-offline-harness.log`, SHA-256
`f0704fe2f96429dcdedf44c8d6bd7ad5e64b6873c343d8e029d53fa8a66389e5`.
Compile-only build PASS (2.46 seconds):
`/private/tmp/sudrf-322-redirect-compile.log`, SHA-256
`2652ab31035019b0c856cafab8e568fe1ac09e663f203ce0df0627413398fca9`.
One intermediate synthetic redirect test lacked the original-response callback
and exited with signal 5; it was corrected using the existing transport fixture
before this final passing profile. No portal request or application launch was
made. Final full-source review is still required before any live execution.

### Additional ordinary stages authorized (pending execution)

The user explicitly approved ordinary Supreme Court and published court-directory
stages. The live profile now uses `VSRFClient(session:)` with the same bounded
private ephemeral transport and admits only `vsrf.ru`, `www.vsrf.ru`, `sudrf.ru`,
and `www.sudrf.ru` in addition to the original three exact hosts. No wildcard
subdomains are admitted; an unexpected necessary published host remains a denied
partial result. Offline excerpt replay retains RejectVS and its expected partial
boundary. Model manifests and verification are unchanged. No live execution has
been performed; final provider/model/source review remains required.

Current additional-stage offline profile: **5 PASS, 0 failures**, 34.443 seconds
(provider construction/private configuration/exact host denial, redirect policy,
foreign registration rejection, actual replay pipeline and manifest preflight).
Log `/private/tmp/sudrf-322-vs-directory-offline.log`, SHA-256
`caec6b1be82523112eb562833729347cc3bd206561903f8a014b4dbdf5821c02`.
Compile-only PASS, 3.42 seconds; log
`/private/tmp/sudrf-322-vs-directory-compile.log`, SHA-256
`fbac751cc3e314360b8642d415dfa09615c4f00a6ec55fb4e91febe3cb732e5d`.
Both private logs have mode0600. No live or model execution occurred.

Private-root preflight correction: Foundation resolves existing `/private/tmp`
to `/tmp`. The original supplied parent must still be exactly `/private/tmp`,
and canonical parent/name must match the canonical temporary parent and original
`sudrf-322-` name. Outside symlinks and nested/traversal paths are rejected;
existing root0700 validation remains. Two exact root/preflight tests PASS,
0 failures,0.007 seconds. `/private/tmp/sudrf-322-root-tests.log` SHA-256
`bff6fb6cd875959349df28370532391148116f29aeab629d22bfab5e7df39510`.
Compile-only PASS2.91 seconds. This correction made no network request.

### Actual bounded live run: partial (10 October 2026)

Root executed one authorized run. It stopped at first ordinal0 partial after
70,891ms (test duration71.866s), not a PASS. Private root:
`/private/tmp/sudrf-322-live-e53c4438-07ec-4531-88e2-8bf482e07e08`.
Network log0600 SHA-256
`0f48bf725684fea3c54bca50c8a005b6e1a1ed40ac00722f28076501d1853a55`.
The persisted partial snapshot is the cassation-anchor chain, not the first
source-array appeal: three own registrations (02а-0419/2021,33а-6088/2021,
8а-7078/2022 [88а-8501/2022]), session counts2/1/4, five acts and five bodies.
Other anchors, reopen/repeat and full assertions were not reached.

Saved responses: Moscow ten200,2KSOYU four200, VS two302 redirect hops and two
www-host200. No1ASOY response in this stopped run does not prove its failure.
Actual offline parsers on the captured bytes returned two Moscow searches with
one row each; the third search has explicit empty content, no thead/number header
and no detail rows, and MosGorSudResultsParser throws at its required header guard.
This is a demonstrated parser-contract rejection of an empty published response,
not a transport/CAPTCHA failure. Merely including CAPTCHA resources is not proof
of an active challenge. Both captured VS responses parse as zero rows; therefore
VS in affectedSources is not evidence of a failed HTTP/search parse. RefreshCenter
promotes verified VS-empty only when there are no incomplete higher sources;
the Moscow incomplete source prevents that promotion in this result.

Offline captured-parser diagnostic tool executed successfully in3.087s (not a
regression test: it printed parser counts/caught error types without assertions); log0600
`/private/tmp/sudrf-322-captured-parsers.log`, SHA-256
`a4c535940697eece46376c411df779781e7e1ccb48380d6b4143a1127958c0bc`.
No new request, GUI or product change during diagnosis. Raw bodies remain private.
The working source checkpoint is base2c4360f plus the uncommitted four-file
harness/diagnostics/evidence allowlist; no publication or acceptance implied.

Root independently verified the empty marker is visible standalone
`h1.noty__headline` (17 characters: «Ничего не найдено»), under `section.noty`
in `div.search-form__results`/`vue-form`; it is not script/style or a library
literal. The temporary diagnostic method was removed from the versioned harness
after execution; its exact source is retained privately mode0600 beside the
capture as `captured-parser-diagnostic.swift`. No extra skipped XCTest gate
remains. No new diagnostic or network run was performed for this cleanup.

Private diagnostic snippet SHA-256:
`20b3e550d708a4d80990ae2ef5d17a4fdb8c59d982043733e93b088fc1530d49`.

Source provenance clarification: the one actual live attempt used version0.64.8
(build260), base `2c4360f` plus the source delta later committed as `d0bd57d`;
root verified exact equality of all three source-file hashes to that checkpoint.
Subsequent integration `4821163` with main7062c54/version0.65.3 is a separate
offline checkpoint, not a live rerun. Its first offline profile exposed the
absent-root canonicalization difference; the harness now resolves the existing
canonical temporary parent before appending the exact validated child name.
Existing and absent private roots are covered in the same focused test; external
symlinks and literal `/tmp` input remain rejected. Independent review: Ship
for draft/push/CI, not full acceptance. Final sequential offline profile after
main integration: **8 PASS, 0 failures/skips**, 26.056 seconds; build2.87 seconds.
Private log `/private/tmp/sudrf-322-main-integration-final.log`, SHA-256
`f3415fb1b56e7016e8920f23844b3c1c060058dce871c7a52e45ef61fe9332d3`.
No live rerun, GUI launch or product-parser fix was performed for this gate.

### Hosted CI and own Xcode build of the integrated checkpoint

On 10 October 2026, hosted [run 38073558741](https://github.com/arvidsever/Sudrf/actions/runs/38073558741)
completed successfully on exact head `ecf7672875646a984e231304cd6e8c54004f5fb7`:
2143 XCTest, 22 skipped, zero failures; 28 Swift Testing; 27 Python checks,
six skipped, zero failures. Registry verification, Xcode app target, app/CLI
build and packaging passed. The opt-in live test was skipped; hosted CI does
not add a successful live attempt. The conditional Xcode 27 build/test steps
were skipped because that SDK was absent. Private full CI-log SHA-256:
`193fa4de0eab89956fa17c9becf3b7b9ce1db477261ebd6952908d0d44060c0d`.

The integrated project was regenerated separately on the development Mac.
Own unsigned Xcode Debug build completed successfully, without launching the
application; the built product reports 0.65.3 (264). Private build log
`/private/tmp/sudrf-322-ecf7672-xcode.log`, SHA-256
`c2bf52cc3e1361383f81e510bb7ca1a12c5b10130eac09b2757db6a714372a85`.
These gates validate the integrated harness. The original live partial remains
partial; the separate empty-Moscow-response fix still awaits the author's
decision. PR #438 and issue #322 remain open, without a release assignment.
