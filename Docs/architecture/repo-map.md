# Карта репозитория Sudrf

Эта карта нужна для быстрого выбора исходных файлов перед изменением кода. Она
не заменяет `README.md`, `AGENTS.md` или чтение реализации. Для локальной правки
сначала откройте строку нужной задачи в таблице ниже; сквозные потоки и
инварианты читайте только тогда, когда изменение затрагивает несколько слоёв.

## Границы продуктов

| Продукт | Роль | Направление зависимостей |
| --- | --- | --- |
| `SudrfKit` | Сеть, HTML-парсинг, справочники судов, модели и сбор движения дела | Зависит только от `SwiftSoup` и системных framework |
| `CaptchaSolver` | Локальное распознавание CAPTCHA через Vision/CoreML | Не зависит от `SudrfKit` |
| `SudrfApp` | SwiftUI, SwiftData, фоновые обновления, CAPTCHA-адаптер, AI и системные интеграции | Зависит от `SudrfKit` и `CaptchaSolver` |
| `sudrf-cli` | Командный интерфейс к поиску, карточкам и справочникам | Зависит от `SudrfKit` и `ArgumentParser` |

Источник графа таргетов — `Package.swift`. Прямого ребра между таргетами
`SudrfKit` и `CaptchaSolver` нет: их связывают адаптер и точки вызова в
`SudrfApp`, прежде всего `AutoCaptchaSolver.swift`.

## Куда идти по задаче

| Задача | Начать с | Затем проверить | Основные тесты |
| --- | --- | --- | --- |
| Запуск приложения, корневые экраны и навигация | `Sources/SudrfApp/SudrfApp.swift`, `RootView.swift`, `AppModel.swift` (`AppRouter`) | `ContentView.swift`, `OverviewView.swift`, `MyCasesView.swift`, `CalendarScreen.swift` | `CurrentEntityActivityTests`, `OverviewModelTests`, `MyCasesModelTests`, `CalendarWeekLayoutTests` |
| Интерактивный поиск и выбор суда | `Sources/SudrfApp/SearchModel.swift` | `MovementContext.swift`, `MovementTargetBuilder.swift`, `Sources/SudrfKit/CourtDirectory.swift`, `DistrictCourtResolver.swift`, `MagistrateDirectory.swift` | `SearchResultSelectionTests`, `MoscowCourtOptionTests`, `CourtDirectoryTests`, `DistrictResolverTests`, `MagistrateTests` |
| URL, запросы и HTML обычных судов `*.sudrf.ru` | `Sources/SudrfKit/SudrfClient.swift`, `SudrfURLBuilder.swift` | `ResultsParser.swift`, `CaseCardParser.swift`, `SearchPageClassifier.swift`, `SearchPatternDirectory.swift`, `WorkingVariantStore.swift` | `URLBuilderTests`, `ResultsParserTests`, `CaseCardParserTests`, `SearchPageClassifierTests`, `SearchPatternTests`, `WorkingVariantStoreTests` |
| Мировые судьи, ВС РФ или Мосгорсуд | `Sources/SudrfKit/MagistrateClient.swift`, `VSRFClient.swift`, `MosGorSudClient.swift` | Соответственно `MagistrateDirectory.swift`, `VSRFCard.swift`, `MosGorSud.swift`, `MosGorSudMovement.swift`, `MosGorSudParsers.swift`, `MosGorSudCourtDirectory.swift` | `MagistrateTests`, `VSRFCardParserTests`, `VSRFMovementTests`, `MosGorSudTests` |
| Движение дела по инстанциям | `Sources/SudrfKit/Movement.swift` (`MovementService`) | `CaseMovementCaptcha.swift`, `Sources/SudrfApp/MovementContext.swift`, `MovementTargetBuilder.swift`, `MovementDerivation.swift`, `CaseMovementView.swift` | `MovementServiceTests`, `MovementDedupTests`, `VSRFMovementTests`, `MovementContextTests`, `MovementDerivationTests`, `KoAPMovementTargetTests` |
| Отслеживание и постоянное хранение | `Sources/SudrfApp/TrackedStore.swift`, `DataCatalog.swift` | `AppModel.swift` (`track`, `untrack`, `reload`), `MovementContext.swift` | `DataCatalogTests`, `MovementContextTests`, `MyCasesModelTests` |
| Фоновое обновление и сохранение кэша | `Sources/SudrfApp/RefreshCenter.swift` | `Sources/SudrfKit/MovementCachePolicy.swift`, `Sources/SudrfApp/MovementCache.swift`, `MovementDerivation.swift`, `TrackedStore.swift` | `RefreshCenterTests`, `MovementCachePolicyTests`, `MovementDerivationTests` |
| Импорт, объединение дублей и восстановление цепочки | `Sources/SudrfApp/CaseImport.swift`, `TrackedCaseRepair.swift` | `CaseOriginResolver.swift`, `MovementContext.swift`, `TrackedStore.swift` | `CaseImportTests`, `TrackedCaseRepairTests`, `CaseOriginResolverTests`, `CorrectivePassTests` |
| Автоматическая или ручная CAPTCHA | `Sources/SudrfApp/AutoCaptchaSolver.swift`, `CaptchaWebView.swift`, `RefreshCenter.swift` | `CaptchaSettings.swift`, `CaptchaMenu.swift`, `Sources/SudrfKit/CaptchaImageExtractor.swift`, `CaptchaTokenStore.swift`, `Sources/CaptchaSolver/` | `AutoCaptchaSolverTests`, `CaptchaAssistTests`, `CaptchaPendingQueueTests`, `CaptchaSheetStateTests`, `CaptchaImageExtractorTests`, `CaptchaTokenStoreTests`, `CaptchaSolverTests`, `VisionOCRStrategyTests` |
| Текст судебного акта и AI-резюме | `Sources/SudrfApp/AppModel.swift` (`loadSelectedActSummary`, `generateSelectedActSummary`) | `AISummaryCoordinator.swift`, `AIProviders.swift`, `AISettings.swift`, `AppleAISummarizers.swift`, `Sources/SudrfKit/ActDocument.swift`, `ActSummary.swift` | `ActDocumentTests`, `ActSummaryTests`, `AISummaryPipelineTests`, `CorrectivePassTests` |
| Spotlight, deep links, App Intents | `Sources/SudrfApp/SpotlightIntegration.swift`, `AppIntentsIntegration.swift` | `DataCatalog.swift`, `AppModel.swift` (`handleDeepLink`) | `SpotlightIntegrationTests`, `CurrentEntityActivityTests` |
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

Ошибки при загрузке вышестоящего суда обрабатываются иначе: `MovementService`
может вернуть частичный `CaseMovement` с CAPTCHA/сетевой заглушкой или с
`incompleteHigherCourtDomains`. Такой результат проходит через
`applyMovement`, а `MovementCachePolicy.merge` восстанавливает сохранённые
инстанции соответствующего суда вместо их удаления.

### CAPTCHA

Точки вызова, настройки, диагностика и обязательный ручной fallback описаны в
корневом `AGENTS.md`, раздел «Captcha auto-solver». Для выбора файлов и тестов
используйте строку «Автоматическая или ручная CAPTCHA» в таблице маршрутов.

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
- `SudrfClient`, `MovementService`, `VSRFClient` и резолверы используют actor
  isolation. Не обходите их троттлинг отдельными `URLSession` в UI-слое.
- HTML судов — нестабильный внешний контракт. Новый вариант страницы должен
  сопровождаться классификатором/парсером и фикстурным регрессионным тестом.
- Миграции и резервное копирование SwiftData выполняются до создания рабочего
  `AppRouter`. При ошибке загрузки нельзя переходить на незаметную временную БД.
- AI получает только явно выбранный акт. `ActSummaryValidator` должен проверять
  структуру и ссылки на абзацы перед показом или сохранением результата.
- Проекцию судебных актов, Spotlight и сохранённые AI-резюме обновляйте через
  `TrackedStore`/`CaseCatalog`, а не параллельной записью из SwiftUI view.

## Владение кодом

- `AppModel.swift` — оркестрация и состояние приложения. Новые парсеры,
  алгоритмы и независимые модели следует помещать в профильные файлы, а не
  увеличивать `AppRouter`.
- `Movement.swift` — доменные модели и сетевой агрегатор движения. UI-проекции
  находятся в `Sources/SudrfApp/MovementDerivation.swift`.
- `CaptchaWebView.swift` — мост ручной CAPTCHA и WebKit. Распознавание живёт в
  `CaptchaSolver`, извлечение изображения и токена — в `SudrfKit`.
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
