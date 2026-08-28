# Карта репозитория Sudrf

Эта карта нужна для быстрого выбора исходных файлов перед изменением кода. Она
не заменяет `README.md`, `AGENTS.md` или чтение реализации. Для локальной правки
сначала откройте строку нужной задачи в таблице ниже; сквозные потоки и
инварианты читайте только тогда, когда изменение затрагивает несколько слоёв.

Рядом лежит `ksoyu-listing-grammar.md` — грамматика сплошного перечня дел КСОЮ
(`name_op=r` без поискового запроса) с провенансом и статусом проверки каждого
параметра. Она нужна для массового сбора судебных актов, а не для поиска по
конкретному делу, поэтому в таблицу маршрутов ниже не входит.

## Границы продуктов

| Продукт | Роль | Направление зависимостей |
| --- | --- | --- |
| `SudrfKit` | Сеть, HTML-парсинг, справочники судов, цели обжалования, модели и сбор движения дела | Зависит только от `SwiftSoup` и системных framework |
| `CaptchaSolver` | Локальное распознавание CAPTCHA через Vision/CoreML | Не зависит от `SudrfKit` |
| `SudrfApp` | SwiftUI, SwiftData, фоновые обновления, CAPTCHA-адаптер, AI и системные интеграции | Зависит от `SudrfKit` и `CaptchaSolver` |
| `fssp-captcha-lab` | Отдельная developer-лаборатория для подтверждения CAPTCHA ФССП и обучения локальной bootstrap-модели; в обычный `.app` не входит | Зависит от `SudrfKit` и `CaptchaSolver` |
| `sudrf-cli` | Командный интерфейс к поиску, карточкам и справочникам | Зависит от `SudrfKit` и `ArgumentParser` |

Источник графа таргетов — `Package.swift`. Прямого ребра между таргетами
`SudrfKit` и `CaptchaSolver` нет: их связывают адаптер и точки вызова в
`SudrfApp`, прежде всего `AutoCaptchaSolver.swift`.

## Куда идти по задаче

| Задача | Начать с | Затем проверить | Основные тесты |
| --- | --- | --- | --- |
| Запуск приложения, корневые экраны и навигация | `Sources/SudrfApp/SudrfApp.swift`, `RootView.swift`, `AppModel.swift` (`AppRouter`) | `MonitoringModels.swift`, `ContentView.swift`, `OverviewView.swift`, `MyCasesView.swift`, `CalendarScreen.swift` | `CurrentEntityActivityTests`, `OverviewModelTests`, `MyCasesModelTests`, `CalendarWeekLayoutTests` |
| Интерактивный поиск и выбор суда | `Sources/SudrfApp/SearchModel.swift` | `MovementContext.swift`, `Sources/SudrfKit/MovementTargetBuilder.swift`, `CourtDirectory.swift`, `DistrictCourtResolver.swift`, `MagistrateDirectory.swift` | `SearchResultSelectionTests`, `MoscowCourtOptionTests`, `CourtDirectoryTests`, `DistrictResolverTests`, `MagistrateTests` |
| URL, запросы и HTML обычных судов `*.sudrf.ru` | `Sources/SudrfKit/SudrfClient.swift`, `SudrfURLBuilder.swift` | `ResultsParser.swift`, `CaseCardParser.swift`, `HTMLTextExtractor.swift`, `SearchPageClassifier.swift`, `SearchPatternDirectory.swift`, `WorkingVariantStore.swift` | `URLBuilderTests`, `ResultsParserTests`, `CaseCardParserTests`, `SearchPageClassifierTests`, `SearchPatternTests`, `WorkingVariantStoreTests` |
| Мировые судьи, ВС РФ или Мосгорсуд | `Sources/SudrfKit/MagistrateClient.swift`, `VSRFClient.swift`, `MosGorSudClient.swift` | Соответственно `MagistrateDirectory.swift`, `VSRFCard.swift`, `MosGorSud.swift`, `MosGorSudMovement.swift`, `MosGorSudParsers.swift`, `MosGorSudCourtDirectory.swift`; общий транспорт ВС РФ и Мосгорсуда — `HTMLCourtTransport.swift` | `MagistrateTests`, `VSRFCardParserTests`, `VSRFMovementTests`, `MosGorSudTests`, `HTMLCourtTransportTests` |
| Движение дела по инстанциям | `Sources/SudrfKit/Movement.swift` (`MovementService`) | `CaseMovementCaptcha.swift`, `MovementTargetBuilder.swift`, `Sources/SudrfApp/MovementContext.swift`, `MovementDerivation.swift`, `CaseMovementView.swift` | `MovementServiceTests`, `MovementDedupTests`, `VSRFMovementTests`, `MovementContextTests`, `MovementDerivationTests`, `KoAPMovementTargetTests` |
| Отслеживание и постоянное хранение | `Sources/SudrfApp/TrackedStore.swift`, `DataCatalog.swift` | `AppModel.swift` (`track`, `untrack`, `reload`), `MovementContext.swift` | `DataCatalogTests`, `MovementContextTests`, `MyCasesModelTests` |
| Фоновое обновление и сохранение кэша | `Sources/SudrfApp/RefreshCenter.swift`, `Sources/SudrfKit/SourceOutcome.swift` | `Sources/SudrfKit/MovementCachePolicy.swift`, `Sources/SudrfApp/MovementCache.swift`, `MovementDerivation.swift`, `TrackedStore.swift` | `RefreshCenterTests`, `MovementCachePolicyTests`, `MovementDerivationTests`, `SourceOutcomeTests` |
| Исполнительные листы и Казначейство | `Sources/SudrfKit/Enforcement.swift`, `CaseCardParser.swift` | `Movement.swift`, `Sources/SudrfApp/RefreshCenter.swift`, `TrackedStore.swift`, `CaseMovementView.swift`, `AppModel.swift` | `TreasuryClientTests`, `CaseCardParserTests`, `RefreshCenterTests`, `DataCatalogTests`, `OverviewModelTests` |
| Импорт, объединение дублей и восстановление цепочки | `Sources/SudrfApp/CaseImport.swift`, `TrackedCaseRepair.swift` | `CaseOriginResolver.swift`, `MovementContext.swift`, `TrackedStore.swift`, `Sources/SudrfKit/Cartoteka.swift` (`CartotekaRegistry.resolve`) | `CaseImportTests`, `TrackedCaseRepairTests`, `CaseOriginResolverTests`, `CorrectivePassTests`, `CartotekaRegistryTests` |
| Автоматическая или ручная CAPTCHA | `Sources/SudrfApp/AutoCaptchaSolver.swift`, `CaptchaWebViewCoordinator.swift`, `RefreshCenter.swift` | `CaptchaWebView.swift`, `CaptchaAssistSheet.swift`, `CaptchaFlowDecisions.swift`, `CaptchaSolverFactory.swift`, `CaptchaSettings.swift`, `CaptchaMenu.swift`, `Sources/SudrfKit/CaptchaImageExtractor.swift`, `CaptchaTokenStore.swift`, `Sources/CaptchaSolver/HighestConfidenceStrategy.swift`, `Sources/CaptchaSolver/` | `AutoCaptchaSolverTests`, `CaptchaAssistTests`, `CaptchaPendingQueueTests`, `CaptchaSheetStateTests`, `CaptchaImageExtractorTests`, `CaptchaTokenStoreTests`, `CaptchaSolverTests`, `VisionOCRStrategyTests` |
| Лаборатория CAPTCHA ФССП | `Sources/FSSPCaptchaLab/FSSPCaptchaLabModel.swift`, `FSSPCaptchaLabRuntime.swift` | `Sources/CaptchaSolver/FSSPPreprocessor.swift`, `CoreMLModelDiscovery.swift`, `CorpusStore.swift`, `Sources/SudrfKit/FSSPClient.swift`, `Scripts/train-fssp-bootstrap.py` | `FSSPCaptchaLabModelTests`, `CoreMLCaptchaStrategyTests`, `test_prepare_fssp_corpus.py` |
| Проверка корпуса и обучение числовой CAPTCHA СОЮ | `Scripts/sudrf-captcha-curator.py`, `Scripts/train-sudrf-numeric-v2.py` | `Sources/CaptchaSolver/CorpusStore.swift`, `CoreMLCaptchaStrategy.swift`, `Scripts/prepare-fssp-corpus.py` | `test_sudrf_captcha_curator.py`, `test_train_sudrf_numeric_v2.py`, `CorpusStoreTests`, `SearchResultSelectionTests` |
| Текст судебного акта и AI-резюме | `Sources/SudrfApp/AppModel.swift` (`loadSelectedActSummary`, `generateSelectedActSummary`) | `SummaryOperationState.swift`, `AISummaryCoordinator.swift`, `AIProviders.swift`, `AISettings.swift`, `AppleAISummarizers.swift`, `Sources/SudrfKit/ActDocument.swift`, `ActSummary.swift` | `ActDocumentTests`, `ActSummaryTests`, `AISummaryPipelineTests`, `CorrectivePassTests` |
| Spotlight, deep links, App Intents | `Sources/SudrfApp/SpotlightIntegration.swift`, `AppIntentsIntegration.swift` | `DataCatalog.swift`, `CurrentEntityActivityFactory.swift`, `AppModel.swift` (`handleDeepLink`) | `SpotlightIntegrationTests`, `CurrentEntityActivityTests` |
| CLI или справочники судов | `Sources/sudrf-cli/SudrfCLI.swift` | `Sources/SudrfKit/CourtDirectory.swift`, `DistrictCourtResolver.swift`, `Cartoteka.swift`, `CaseIndexClassifier.swift` | `CourtDirectoryTests`, `DistrictResolverTests`, `CartotekaRegistryTests`, `CaseIndexClassifierTests` |

Имена тестов в таблице совпадают с классами `XCTestCase`; файлы находятся в
`Tests/SudrfKitTests`, `Tests/SudrfAppTests` или `Tests/CaptchaSolverTests`.

## Сквозные потоки

### Интерактивный поиск

`ContentView` → `SearchModel.runSearch` → выбор клиента площадки → URL и сетевой
запрос → классификация страницы → HTML-парсер → `CaseSearchResult`. Открытие
полного движения создаёт `MovementService` через `MovementContext` и собирает
связанные инстанции и акты.

Обычные суды, мировые участки, ВС РФ и Мосгорсуд имеют разные клиенты и
разметку. Не переносите площадко-специфичные селекторы в общий путь без
регрессионной фикстуры.

### Отслеживание и refresh

`AppRouter.track` → `TrackedStore.upsert` → SwiftData. Затем `RefreshCenter`
восстанавливает `MovementContext`, вызывает `MovementService`, объединяет ответ
с последним успешным движением через `MovementCachePolicy`, строит снимок через
`MovementDerivation` и только после этого сохраняет запись.

Ошибка домашнего суда, после которой нельзя собрать пригодный `CaseMovement`,
идёт в failure/pending-путь и не вызывает `applyMovement`. Последний успешный
`movement`, `snapshot` и `movementFetchedAt` при этом остаются доступными.

Перед persistence `SourceOutcome` типизированно различает полный и частичный
snapshot, CAPTCHA, maintenance, transport/parser failure и подтверждённую
пустоту. `sourceRefreshAttempt` обновляется при каждой попытке, а
`movementFetchedAt` — только после полного пригодного движения; partial может
аддитивно обновить данные через `MovementCachePolicy`, но не продлевает TTL.

Ошибки при загрузке вышестоящего суда обрабатываются иначе: `MovementService`
может вернуть частичный `CaseMovement` с CAPTCHA/сетевой заглушкой или с
`incompleteHigherCourtDomains`. Такой результат проходит через
`applyMovement`, а `MovementCachePolicy.merge` восстанавливает сохранённые
инстанции соответствующего суда вместо их удаления.

### CAPTCHA

Точки вызова, настройки, диагностика и обязательный ручной fallback описаны в
корневом `AGENTS.md`, раздел «Captcha auto-solver». Для выбора файлов и тестов
используйте строку «Автоматическая или ручная CAPTCHA» в таблице маршрутов.

### Исполнение

`CaseCardParser` извлекает все строки таблицы исполнительных документов и
передаёт их в `CaseMovement.executionDocuments`. Для отслеживаемого дела
`RefreshCenter` независимо проверяет каждый документ через actor-клиенты
`TreasuryClient` и `FSSPClient`, аддитивно сливает ответы в
`TrackedCaseRecord.enforcementData` и проецирует новые RSS `guid` в ленту.

Суд, Казначейство и ФССП — независимые источники: ошибка или CAPTCHA одного
не стирает последний успех другого. Фоновый запрос ФССП сохраняет pending-
состояние, а ручной ответ проходит через отдельный лист и тот же `FSSPClient`.
Developer-лаборатория использует этот клиент и `CorpusStore`, но её bootstrap-
модель имеет отдельное имя и никогда не участвует в production-discovery.

### Судебный акт и AI

Выбранный акт преобразуется в `ActDocument` с устойчивыми идентификаторами
абзацев и `sourceHash`. Только явное действие
`AppRouter.generateSelectedActSummary` создаёт провайдера через
`ActSummarizerFactory`, запускает резюмирование, валидирует цитаты и сохраняет
результат в `CaseCatalog`. Смена выбранного акта отменяет текущую операцию и
сбрасывает её UI-состояние.

## Инварианты

- Ошибка верхнего уровня до получения пригодного `CaseMovement` не должна изменять
  последний успешный кэш. Частичный результат вышестоящих судов проходит через
  `MovementCachePolicy.merge`, который сохраняет ранее загруженные инстанции для
  незавершённых доменов. Изменение этих веток требует тестов
  `RefreshCenterTests` и `MovementCachePolicyTests`.
- HTTP 200 не является доказательством пригодности ответа. CAPTCHA, maintenance,
  partial и unknown-format сохраняются как разные `SourceOutcomeKind`; provenance
  не содержит URL query, cookies, токены или CAPTCHA-коды.
- `SudrfClient`, `MovementService`, `VSRFClient` и резолверы используют actor
  isolation. Не обходите их троттлинг отдельными `URLSession` в UI-слое.
- Троттлинг и повторы ВС РФ и Мосгорсуда вынесены в `HTMLCourtTransport`, но
  политики у них разные: Мосгорсуд декодирует только UTF-8 и отсчитывает паузу
  от старта предыдущего запроса, ВС РФ допускает cp1251-фолбэк и резервирует
  слот очереди до первого `await`. `SudrfClient` этот транспорт намеренно не
  использует: у него cp1251, CAPTCHA, вариант хоста и отдельный HTTP-фолбэк.
- HTML судов — нестабильный внешний контракт. Новый вариант страницы должен
  сопровождаться классификатором/парсером и фикстурным регрессионным тестом.
- При ошибке или неоднозначном ответе Казначейства нельзя удалять прежнюю историю
  или автоматически выбирать первую запись. RSS-ссылки на старый домен являются
  только источником `documentId`; пользовательские URL строятся на HTTPS
  `app.roskazna.ru`.
- Миграции и резервное копирование SwiftData выполняются до создания рабочего
  `AppRouter`. При ошибке загрузки нельзя переходить на незаметную временную БД.
- AI получает только явно выбранный акт. `ActSummaryValidator` должен проверять
  структуру и ссылки на абзацы перед показом или сохранением результата.
- Проекцию судебных актов, Spotlight и сохранённые AI-резюме обновляйте через
  `TrackedStore`/`CaseCatalog`, а не параллельной записью из SwiftUI view.

## Владение кодом

- `AppModel.swift` — оркестрация и состояние приложения (`AppRouter`). Новые
  парсеры, алгоритмы и независимые модели следует помещать в профильные файлы,
  а не увеличивать `AppRouter`. Уже вынесены: типы представления разделов
  мониторинга — в `MonitoringModels.swift`, состояние операции резюме — в
  `SummaryOperationState.swift`, контекст onscreen awareness — в
  `CurrentEntityActivityFactory.swift`.
- `Movement.swift` — доменные модели и сетевой агрегатор движения. UI-проекции
  находятся в `Sources/SudrfApp/MovementDerivation.swift`, а построение целей
  обжалования — в `Sources/SudrfKit/MovementTargetBuilder.swift`.
- Ручная CAPTCHA разложена по ответственности: `CaptchaWebViewCoordinator.swift`
  — мост к WebKit и state-машина попыток, `CaptchaWebView.swift` — тонкая
  `NSViewRepresentable`-обёртка, `CaptchaAssistSheet.swift` — лист ввода кода,
  `CaptchaFlowDecisions.swift` — чистые решения потока (их и покрывают тесты).
  Распознавание живёт в `CaptchaSolver` и собирается через
  `CaptchaSolverFactory.swift`; извлечение изображения и токена — в `SudrfKit`.
- `TrackedStore.swift` владеет изменениями отслеживаемых записей;
  `DataCatalog.swift` — схемами, миграциями, каталогом актов и AI-резюме.

## Проверка изменений

Минимальная локальная проверка:

```bash
swift test --filter <ИмяКлассаТестов>
swift test
swift build
```

Для изменений приложения дополнительно используйте Xcode 26 и схему `Sudrf`,
если затронуты SwiftUI, SwiftData, App Intents, Spotlight, WebKit, Vision или
сборка `.app`. CoreML-зависимые тесты требуют модели, устанавливаемой через
`Scripts/fetch-model.sh`; без неё соответствующие тесты могут быть пропущены.

Правила веток, changelog и выпуска находятся в корневом `AGENTS.md`. Карта их
не дублирует.

## Когда обновлять карту

Обновите этот файл, если изменились границы таргетов, главный вход в функцию,
сквозной поток, инвариант или тестовая точка входа. Внутренняя правка реализации
и добавление частного helper сами по себе обновления карты не требуют.
