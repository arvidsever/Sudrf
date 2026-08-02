# Изменения — Alpha 0.38.6

## Исправлено

Диагностический дамп в `SearchDiagnostics` записывал HTML в файл
через `String.data(using: .utf8)` — то есть всегда в UTF-8, даже если
сервер прислал `windows-1251`. Файл получал байты в одной кодировке,
а `<meta charset=windows-1251>` в нём указывал на другую → браузер
декодировал «правильно по meta-тегу» и получал mojibake
(`РЈРЅРёРєР°Р»СЊРЅС‹Р№ РёРґРµРЅС‚РёС„РёРєР°С‚РѕСЂ РґРµР»Р°`
вместо «Уникальный идентификатор дела»).

Решение: `SearchDiagnostics.save` теперь принимает `Data` и пишет
байты в файл **verbatim**, без перекодирования. Файл в браузере
открывается корректно — `<meta charset=...>` уже в самом HTML
указывает правильную кодировку, и байты ей соответствуют.

## Изменено

- **`Sources/SudrfKit/SudrfClient.swift`**: добавлен приватный
  `fetchHTMLData(_:allowHTTPFallback:) -> (Data, String)`. Публичный
  `fetchHTML(_:)` теперь — тонкая обёртка над ним
  (`return .1` от кортежа). Внутренние вызовы в `searchOnce`
  (form pre-check) и `runVariants` (variant loop) используют
  `fetchHTMLData` напрямую и передают `Data` в дамп вместо
  декодированной строки.

- **`runVariants`**: `lastHTML: String` заменён на `lastData: Data?`.
  В блоке `if let lastData { SearchDiagnostics.dumpVariant(data: ...) }`
  перед `throw SudrfError.searchModuleUnavailable(...)`.

- **`searchOnce`**: form pre-check теперь вызывает
  `SearchDiagnostics.dumpFormCheck(data: formData, host: ...)` —
  передаёт сырые байты формы.

- **`Sources/SudrfKit/SearchDiagnostics.swift`**: `dumpVariant` и
  `dumpFormCheck` получили `data:`-перегрузки (рекомендуемые для
  продакшена) и сохранили `html:`-перегрузки (для тестов и обратной
  совместимости — конвертируют `String` через `Data(html.utf8)`).
  `dumpSolverMismatch` тоже перешёл на `responseData: Data`.

## Тесты

`Tests/SudrfKitTests/SearchDiagnosticsTests.swift` дополнен:

- **`testDumpVariantPreservesRawBytes`** — главный регресс-тест
  v0.38.6. Берём байты `D0 CF E0 E2 E5 F0` («Россия» в
  windows-1251), вызываем `dumpVariant(data:host:)`, читаем
  файл — проверяем, что байты записаны **побайтово**. До фикса
  код писал `String.data(using: .utf8)`, что давало совершенно
  другую последовательность байт.

- **`testDumpFormCheckPreservesRawBytes`** — то же для
  `dumpFormCheck`. Байты «Форма поиска» в cp1251 сохраняются
  как есть.

Существующие тесты обновлены: `testDumpSolverMismatchWritesBothFiles`
и `testToggleDisables` используют `data:`-перегрузки.

Таргетный прогон: 270 тестов, 0 падений.

## Как диагностировать текущую проблему

1. `swift run SudrfApp`
2. Выбрать captcha-включённый суд (любой, кроме magistrate).
3. Ввести № дела, нажать «Искать».
4. Дождаться ошибки «Поисковый модуль суда … не отвечает в
   известных форматах».
5. `open ~/Library/Application Support/Sudrf/diagnostics/`
6. Открыть самый свежий `variant_<host>_*.html` в браузере.
   Браузер прочитает `<meta charset=...>` и покажет корректный
   русский текст — а не mojibake. Если `РЈРЅРёРєР°Р»СЊРЅС‹Р№`
   в `cat`-выводе заменяется на `Уникальный` в браузере, фикс
   работает.
7. Поделиться содержимым — для следующей диагностики (что суд
   реально прислал в ответ на наш запрос).

## Что остаётся без фикса

- **mo возвращает домашнюю страницу** вместо результатов поиска —
  `searchModuleUnavailable` срабатывает корректно (домашняя
  страница не имеет маркеров выдачи), но сам запрос возвращает
  не то, что нужно. Это отдельный баг — не encoding, а
  `delo_id` / `new` / сессия / anti-bot. Диагностический файл
  после v0.38.6 покажет, что прислал сервер.
- **spb и mo не решаются preprocessor-ом** — у них rotated/struck-
  through captcha, conf=0.00 на сырых данных. `defaults write
  ru.sudrf.app captcha.preprocessorHosts -array oblsud--mo.sudrf.ru`
  для per-host включения (v0.38.4).
- **spb cached token fragility** — после 30 мин токен протухает и
  captcha-зона требует ручного ввода.
