# Изменения — Alpha 0.38.7

## Контекст

В v0.38.6 диагностический дамп `SearchDiagnostics` стал писать
«сырые» байты HTML — это позволило точно увидеть, что отвечает
сервер на запросы `1kas`, `oblsud--mo.sudrf.ru` и
`sankt-peterburgsky--spb.sudrf.ru`. Во всех трёх случаях сервер
возвращает страницу с сообщением **«Неверно указан проверочный код
с картинки»** — то есть наш URL правильный, и сервер действительно
обрабатывает запрос, но отвергает его из-за неверно распознанной
капчи. Это **OCR-проблема**, а не URL/cookie/headers.

В v0.38.4 уже был введён `Preprocessor` (grayscale + 2x scale) для
rotated/struck-through captcha, но его можно было включить только
через `defaults write ... captcha.preprocessorHosts -array ...` —
лишний шаг для пользователя, который не знает имени хоста.
v0.38.7 закрывает эту брешь: preprocess становится **глобальным
тогглом** в меню, плюс солвер начинает писать диагностические
файлы с топ-3 кандидатами Vision, чтобы офлайн-разбор стал
дешевле.

## Добавлено

### 1. Глобальный тоггл preprocess в меню «Captcha»

`CaptchaSettings.preprocessorEnabled` теперь управляется
**напрямую** из SwiftUI-меню (`CaptchaMenuContent`). Раньше
флаг был в `UserDefaults`, но солвер читал его **один раз** при
инициализации — тоггл в меню не действовал до перезапуска.

Решение: `VisionOCRStrategy` получил опциональный
`preprocessingProvider: (() -> Bool)?` — замыкание, которое
вызывается при каждом `solve`/`topCandidates`. Production-wiring:

- `AppModel.init` — `strategy.preprocessingProvider = { [weak settings] in settings?.preprocessorEnabled ?? false }`
- `SearchModel.init` — то же, локально для интерактивного поиска.

Меню «Captcha» дополнено `Toggle(isOn: $settings.preprocessorEnabled)`
с `.help(...)` — пояснением, что preprocess может РЕГРЕССИРОВАТЬ
на простых captcha (Vision читает «667» как «49»). По умолчанию
выключен (см. v0.38.4). Включил — следующий вызов солвера
сразу видит новое значение, перезапуск не нужен.

Per-host set `preprocessorHosts` сохранён в `CaptchaSettings` и
в `CaptchaConfiguration` для обратной совместимости, но в
v0.38.7 меню им не управляет. Power-user по-прежнему может
выставить `defaults write ... captcha.preprocessorHosts -array ...`
— фиксированный флаг в `CaptchaSolver` тогда ограничивает
preprocess до этих хостов. В UI-режиме (через тоггл) preprocess
применяется ко всем.

### 2. Диагностический файл «топ-3 кандидатов Vision»

`AutoCaptchaSolver` теперь на каждой попытке (а не только при
исчерпании) пишет в
`~/Library/Application Support/Sudrf/diagnostics/<host>_<ts>_sudrfToken_candidates.txt`:

```
host=oblsud--mo.sudrf.ru
kind=sudrfToken
preprocessed=yes
submitted=667
confidence=0.4123
alternatives:
  1. "667" conf=0.4123
  2. "GG7" conf=0.3811
  3. "8G7" conf=0.2944
```

Это `CaptchaSolverLog.logCandidates(host:kind:submitted:confidence:alternatives:preprocessed:)`.
Поле `preprocessed` показывает, был ли применён `Preprocessor.process`
для этой конкретной попытки — теперь видно, **помог ли preprocess**
на конкретном хосте. `submitted` — текст, который солвер выбрал;
`alternatives` — топ-3 после регулярки `kind.regex`, отсортированы
по (длина ↓, уверенность ↓).

Метод `CaptchaSolverLog.init` расширен: добавлен `diagnosticsDir: URL?`
(рядом с `failuresDir`). Приватный `private init()` создаёт
директорию автоматически.

### 3. Real-PNG тесты на основе `captcha-failures/`

Новый хелпер `RealCaptchaFixture` (`Tests/CaptchaSolverTests/RealCaptchaFixture.swift`)
читает реальные captcha-PNG из
`~/Library/Application Support/Sudrf/captcha-failures/`. Окружение
`SUDRF_FIXTURE_DIR` позволяет переопределить путь (CI/бэкап).
Если папка пуста, тесты делают `XCTSkip` — чистый клон
остаётся зелёным.

Новые тесты (5 шт.):

- **`CaptchaSolverTests.testPreprocessLiveProviderToggle`** —
  синтетика, проверяет, что live-флаг preprocess виден солверу
  без пересоздания, тоггл туда-обратно корректно отражается в
  `preprocessed` кортеже из `topCandidates`.
- **`CaptchaSolverTests.testPreprocessWithoutProviderFallsBackToFixedFlag`** —
  backward-compat: без `preprocessingProvider` стратегия
  использует фиксированный `preprocessingEnabled` (как до v0.38.7).
- **`CaptchaSolverTests.testCandidatesDiagnosticForRealPNG`** —
  реальный PNG из `captcha-failures/`, проверяет, что
  `logCandidates` пишет ожидаемые поля (host, kind, preprocessed).
- **`PreprocessorTests.testPreprocessOnRealCaptchaPNG`** —
  реальный PNG проходит через `Preprocessor.process` без падения
  и результат отличается от входа.
- **`PreprocessorTests.testVisionDoesNotCrashOnRealCaptchaPNG`** —
  Vision не падает на реальной captcha, ни с preprocess, ни без.

Базовый synthetic-test (`PreprocessorTests.testVisionDoesNotCrashOnSyntheticCaptcha`)
сохранён как fast/offline smoke check.

## Изменено

- **`Sources/CaptchaSolver/VisionOCRStrategy.swift`**:
  - Добавлено свойство `preprocessingProvider: (() -> Bool)?`.
  - Добавлен метод `topCandidates(pngData:kind:host:n:) async throws -> (candidates, preprocessed)`.
  - Метод `solve` рефакторен: `resolveEffectiveData` и `performVision`
    вынесены отдельно и используются обоими `solve` и `topCandidates`.
  - `solve` читает флаг preprocess через `preprocessingProvider?() ?? preprocessingEnabled` —
    live-источник имеет приоритет.
- **`Sources/CaptchaSolver/CaptchaSolver.swift`**:
  - Добавлен `topCandidates(pngData:kind:host:n:) -> (candidates, preprocessed)` —
    делегирует `VisionOCRStrategy`, если провайдер — она; иначе
    возвращает пустой массив.
- **`Sources/CaptchaSolver/CaptchaSolverLog.swift`**:
  - Добавлено свойство `diagnosticsDir: URL?`, инициализируется
    в `private init()`.
  - Добавлен инициализатор `init(fileURL:failuresDir:diagnosticsDir:)`.
  - Добавлен метод `logCandidates(host:kind:submitted:confidence:alternatives:preprocessed:)`.
- **`Sources/SudrfApp/CaptchaMenu.swift`**:
  - Добавлен `Toggle(isOn: $settings.preprocessorEnabled)` с
    `.help(...)` — глобальный preprocess-тоггл.
  - В «Сбросить настройки» добавлен сброс `preprocessorEnabled = false`.
- **`Sources/SudrfApp/AppModel.swift`**:
  - `init` создаёт `VisionOCRStrategy` и пробрасывает
    `preprocessingProvider` к `CaptchaSettings.preprocessorEnabled`.
- **`Sources/SudrfApp/SearchModel.swift`**:
  - То же для интерактивного `SearchModel.runSearch` — иначе
    `SearchModel` имел бы свой собственный `CaptchaSolver` без live-флага.
- **`Sources/SudrfApp/AutoCaptchaSolver.swift`**:
  - На каждой итерации `solve(...)` после `solver.solve` вызывает
    `solver.topCandidates(...)` и пишет диагностический файл
    `logCandidates(...)`.

## Тесты

**275 тестов, 0 падений.** +5 от v0.38.6:

```
CaptchaSolverTests.CaptchaSolverTests
  + testPreprocessLiveProviderToggle
  + testPreprocessWithoutProviderFallsBackToFixedFlag
  + testCandidatesDiagnosticForRealPNG
CaptchaSolverTests.PreprocessorTests
  + testPreprocessOnRealCaptchaPNG
  + testVisionDoesNotCrashOnRealCaptchaPNG
```

Real-PNG-тесты делают `XCTSkip` при пустой
`captcha-failures/` — на CI без пользовательских фикстур остаются
синтетические + live-toggle тесты (3 из 5).

## Версия

- `project.yml`: `MARKETING_VERSION` 0.38.6 → 0.38.7,
  `CURRENT_PROJECT_VERSION` 44 → 45.
- `Scripts/make-app.sh`: те же значения.

## Как пользоваться

1. Запустить `swift run SudrfApp`.
2. Открыть системное меню «Captcha».
3. Включить тоггл «Предобработка капчи (для rotated/struck-through)».
4. Запустить поиск на 1kas / oblsud--mo / sankt-peterburgsky--spb.
5. Если авто-солвер всё ещё возвращает неверный код — открыть
   `~/Library/Application Support/Sudrf/diagnostics/` и
   посмотреть последний `*_candidates.txt` + `captcha-failures/*.png`.
   В файле видно, что именно увидел Vision, и был ли применён
   preprocess. По этому можно судить, стоит ли доверять submitted
   или нужен другой preprocessing-профиль.

Если preprocess РЕГРЕССИРУЕТ на каком-то суде (Vision перестал
читать простую captcha) — выключить тоггл, preprocessor больше
не действует ни на одном хосте.
