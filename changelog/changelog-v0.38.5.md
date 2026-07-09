# Изменения — Alpha 0.38.5

## Добавлено

`SearchDiagnostics` (Sources/SudrfKit/SearchDiagnostics.swift, новый,
~110 строк) — сбрасывает HTML-ответы судов на диск при нештатных
путях поиска, для отладки изменений в HTML судов, которые ломают
`CaptchaDetector` / `SearchPageClassifier` / `ResultsParser`.

Папка: `~/Library/Application Support/Sudrf/diagnostics/`, до
50 файлов, FIFO-эвикция. Включается по умолчанию. Отключается:
`defaults write ru.sudrf.app captcha.diagnosticsEnabled -bool NO`.

Три триггера:

1. **`dumpFormCheck(...)` — `SudrfClient.searchOnce`**: форма
   captcha-включённого суда (`.primary` pattern), на которой
   `CaptchaDetector` сказал «нет капчи». Означает, что детектор
   не узнал новый формат маркера. Сохраняется
   `form_<host>_<timestamp>.html`.
2. **`dumpVariant(...)` — `SudrfClient.runVariants`**: все варианты
   выдачи вернули `.unrecognized` от `SearchPageClassifier`.
   **Это путь, который приводит к `SudrfError.searchModuleUnavailable`**
   («Поисковый модуль суда … не отвечает в известных форматах»).
   Сохраняется `variant_<host>_<timestamp>.html` — последний
   из ответов, чтобы можно было посмотреть, что суд реально
   прислал и почему наш классификатор не узнал ни одного маркера.
3. **`dumpSolverMismatch(...)` — заготовлен, но пока не вызывается**:
   для случая «авто-солвер вернул high-conf, но сервер отклонил
   токен на retry». Запись PNG + HTML ответа. Будет привязан
   в v0.38.6+ если такие случаи проявятся.

В `SudrfClient.runVariants` добавлена переменная `lastHTML: String`,
которая обновляется на каждой `.unrecognized` итерации и
сбрасывается через `SearchDiagnostics.dumpVariant(...)` перед
`throw SudrfError.searchModuleUnavailable(...)`.

## Тесты

`Tests/SudrfKitTests/SearchDiagnosticsTests.swift` (новый, 5 тестов):
- `testDumpVariantWritesFile` — файл создаётся с правильным
  префиксом имени и сохранённым содержимым.
- `testDumpFormCheckWritesFile` — аналогично для `dumpFormCheck`.
- `testDumpSolverMismatchWritesBothFiles` — `.html` + `.png`
  создаются в одном вызове.
- `testToggleDisables` — при `enabled = false` ничего не пишется.
- `testFifoEvictionAt50Files` — после 51-й записи самый старый
  файл удаляется, остаётся ровно 50.

Тесты используют `setDirForTesting(_:)` — тестовый каталог в
`NSTemporaryDirectory()`, реальный `~/Library/Application Support/`
не загрязняется.

Таргетный прогон: 268 тестов, 0 падений.

## Как диагностировать текущую проблему

1. `swift run SudrfApp`
2. Выбрать captcha-включённый суд (любой, кроме magistrate).
3. Ввести № дела, нажать «Искать».
4. Дождаться ошибки «Поисковый модуль суда … не отвечает в
   известных форматах».
5. `open ~/Library/Application Support/Sudrf/diagnostics/`
6. Открыть самый свежий `variant_<host>_*.html`.
7. Поделиться:
   - домен (видно в имени файла);
   - 3-5 строк из HTML, которые выглядят как: search input,
     captcha image, ошибка/maintenance текст, page title;
   - или «вижу Cloudflare JS challenge» / «вижу обычную sudrf форму» /
     «вижу что-то другое».

После этого — точечная правка `SearchPageClassifier` или
`CaptchaDetector` (или большая задача с CF clearance) в v0.38.6.
