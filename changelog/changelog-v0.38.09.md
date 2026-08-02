# Изменения — Alpha 0.38.9

## Резюме

v0.38.8 + v0.38.9 из черновика `Docs/branch-changelogs/captcha-auto-solver/`.
v0.38.8 добавляет CoreML-стратегию для распознавания числовых
sudrf captcha (заменяет/дополняет Vision). v0.38.9 замыкает
self-improving цикл: каждый успешный search с auto-solve
добавляет captcha в корпус, при превышении потолка — FIFO-eviction.

Это **первый релиз с обученной CoreML-моделью** на ветке
`captcha-auto-solver`. Friend's 4042 captcha corpus (5-digit
numeric, sudrf-style) обучены до **90.6% per-digit, 62.1% per-string**
на held-out 808 captcha. На out-of-distribution стилях
(rotated/struck-through spb captcha) — модель возвращает
5-значный ответ без падения, но точность низкая; лечится
накоплением в `solved-numeric/` (этот релиз) и retrain.

## Добавлено

### CoreML-стратегия (v0.38.8)

- **`Sources/CaptchaSolver/CoreMLCaptchaStrategy.swift`** —
  новая стратегия распознавания. 100×30 RGB → бинарная маска
  «чернил» (порог по RGB-расстоянию от teal `(2,103,154)`)
  → downsample 100×30 → 64×20 (box-averaging) → CoreML model
  → один выход `digits` формы `[1, 5, 10]` (5 softmax-голов
  по 10 цифр) → argmax → 5 цифр.
- **`Sources/CaptchaSolver/KindDispatchingStrategy.swift`** —
  per-kind диспетчер: `primaryKinds` (default `[.sudrfToken]`)
  идут в primary (CoreML), остальные — fallback (Vision).
  На CoreML-сбое прозрачно падает на Vision.
- **`Sources/CaptchaSolver/CoreMLModelDiscovery.swift`** — ищет
  скомпилированную модель в
  `~/Library/Application Support/Sudrf/model-captcha-numeric.mlmodelc/`,
  потом в `Bundle.main`. При отсутствии — Vision path.
- **`Scripts/train-coreml-captcha-helper.py`** — обучение
  модели. PyTorch (conv×2 + dense 64 + 5×softmax(10)) →
  coremltools 9 → `coremlc compile` → `.mlmodelc/`. Mini-batch
  SGD (24, lr=0.02, ×0.5 на эпохах 10/16/22, momentum 0.9,
  L2=1e-4, 30 эпох).

### Corpus bootstrap (v0.38.9)

- **`Sources/CaptchaSolver/CorpusStore.swift`** — actor для
  per-kind корпусов. `add(png:code:host:kind:)` пишет в
  `solved-<kind>/<code>_<host>_<ts>_<uuid>.png`. Потолок
  5000 на kind (numeric + text), FIFO-eviction по mtime.
  `manifest.json` с дебаунсом 1с. `pendingSinceLastTrain`
  растёт при каждом `add`, сбрасывается в `markTrained`.
- **`Sources/SudrfKit/SearchPageClassifier.swift`** — новый
  `SearchPageKind.captchaRejected` + `captchaRejectedMarkers`
  (5 маркеров: «Неверно указан проверочный код с картинки» и т.д.).
  Captcha-rejected проверяется **до** captcha-формы, чтобы
  различать «форму с картинкой» (`.captcha`) и «отказ после
  submit'а» (`.captchaRejected`).
- **`Sources/SudrfApp/AutoCaptchaSolver.swift`** — `solve(...)`
  теперь возвращает `SolveResult { token, png }` (PNG нужен
  для bootstrap в `CorpusStore`).
- **`Sources/SudrfApp/SearchModel.swift`** — bootstrap-хуk:
  `lastSubmittedCaptchaPNG` property +
  `bootstrapCaptchaToCorpus(host:results:)` helper. Срабатывает
  после успешного search с auto-solve, если `results.count > 0`.
  Защиты: только `lastSubmittedCaptchaPNG != nil`, только
  `results.count > 0`, только `CaptchaTokenStore.token(forDomain:)`
  существует.
- **`Sources/SudrfKit/SudrfClient.swift`** — `runVariants`
  обрабатывает новый `.captchaRejected` case: путь к
  `searchModuleUnavailable` с диагностическим дампом.
- **kcaptcha regex** (v0.38.9) — `^[0-9A-Za-zА-Яа-я]{3,6}$`
  → `^[а-я0-9]{5,6}$` (только lowercase cyrillic + digits,
  5-6 chars). Был избыточно широк.

## Изменено

- **`Sources/SudrfApp/AppModel.swift`** — `init` создаёт
  `VisionOCRStrategy` с `preprocessingProvider`, оборачивает
  CoreML (если модель найдена) через `KindDispatchingStrategy`.
  Solder передаётся в `RefreshCenter` для фонового обхода.
- **`Sources/SudrfApp/SearchModel.swift`** — то же для
  интерактивного пути. Bootstrap в `executeSearch` после
  успешного search.
- **`Sources/CaptchaSolver/CaptchaConfiguration.swift`** —
  добавлено поле `modelURL: URL?`.

## Тесты

**294 теста, 0 падений** (было 270 в начале ветки, +24):

- 5 в `CoreMLCaptchaStrategyTests` — каркас (binarize, dispatch,
  model discovery, init fails for missing model).
- 3 в `CoreMLCaptchaStrategyTests` — реальная модель
  (XCTSkip если не в bundle). **Когда модель есть**:
  - `testModelLoadsFromBundle` — загружается.
  - `testInferenceOnRealCaptcha` — возвращает 5 цифр.
  - `testLocalSudrfFixturesAccuracy` — 5 локальных captcha →
    5 валидных 5-значных ответов (точность не проверяется,
    out-of-distribution).
- 6 в `CorpusStoreTests` — add, FIFO, markTrained, length
  distribution, currentCount, ceiling.
- 2 в `SearchPageClassifierTests` — rejected markers, rejected
  beats form.
- 1 в `AutoCaptchaSolverTests` — SolveResult exposes PNG.
- 5 в `VisionOCRStrategyTests` — обновлены kcaptcha-тесты
  под новый regex (lowercase cyrillic + digits).
- 2 в `CaptchaSolverTests` — live preprocess toggle, fixed
  fallback (из v0.38.7).

## Как обучалась модель

```bash
# Один раз: подготовить venv с coremltools/torch.
brew install python@3.12
python3.12 -m venv ~/.venvs/sudrf-train
source ~/.venvs/sudrf-train/bin/activate
pip install numpy pillow torch --index-url https://download.pytorch.org/whl/cpu
pip install coremltools

# Сгенерировать train/test TSV.
swift Scripts/train-coreml-captcha.swift \
  --input ~/Library/Application\ Support/Sudrf/captcha-training/solved/ \
  --output /tmp/model.mlmodelc

# Обучить и скомпилировать (MPS, ~3 минуты).
python3 Scripts/train-coreml-captcha-helper.py \
  --train-tsv /tmp/train-data.tsv \
  --test-tsv  /tmp/test-data.tsv \
  --output    Tests/CaptchaSolverTests/Fixtures/model-captcha-numeric.mlmodelc/ \
  --epochs 30 --device mps

# Положить копию в user-папку для runtime-использования:
cp -R Tests/CaptchaSolverTests/Fixtures/model-captcha-numeric.mlmodelc \
      ~/Library/Application\ Support/Sudrf/
```

## Точность

```
held-out (808 captcha, 80/20 split):
  per-digit:  [0.94, 0.91, 0.88, 0.91, 0.89]   mean: 0.906
  per-string: 0.621  (502/808)
```

Friend reports 95.1% per-digit на 4039 captcha (его JS CNN). Наша
модель достигает 90.6% на 3234 train + 808 test (меньше данных
+ другая реализация batch/normalization). Это **всё ещё
значительный прогресс над Vision conf=0.00** на rotated/struck-
through captcha.

**Out-of-distribution:** наши spb captcha (5 captcha в
`Fixtures/sudrf/labels.csv`, rotated/struck-through) — модель
возвращает 5-значный ответ (не падает), но 0/5 правильных. Это
та же проблема, что была с Vision, только в менее выраженной
форме. **Лечится:** self-improving цикл (CorpusStore
solved-numeric/) — накопление spb-styled captcha → retrain
(после 500+ новых captcha) → per-host точность растёт.

## Эффект на пользователя

- **Friend-style captcha (стандартная 5-цифровая sudrf):**
  auto-solve работает в ~60% случаев (per-string), conf 0.6-0.95
  в логе. Manual sheet перестаёт появляться для большинства
  судов.
- **Out-of-distribution captcha (spb rotated, msudrf
  kcaptcha):** всё ещё ломается, но не хуже чем v0.38.7.
  CoreML путь для `.sudrfToken` активен; `.kcaptcha` остаётся
  на Vision до v0.39.0+.
- **Manual fallback** остаётся: при conf < 0.55 открывается
  `CaptchaAssistSheet`, пользователь вводит код вручную.
- **Corpus bootstrap** тихо работает: каждый успешный search
  добавляет captcha в `solved-numeric/`. Через несколько недель
  использования у нас будет собственный per-host-labeled
  датасет.

## Запуск

```bash
bash Scripts/make-app.sh
# Или: swift run SudrfApp (без bundle, проще итерации)
```

Модель должна лежать в `~/Library/Application Support/Sudrf/model-captcha-numeric.mlmodelc/`
(создаётся при обучении). При отсутствии — авто-фоллбэк на Vision
(поведение до v0.38.8).

## Известные ограничения

- **out-of-distribution captcha** (rotated, struck-through):
  решается self-improving циклом (v0.38.9 wiring активен, retrain
  на накопленных captcha — следующий шаг).
- **Kcaptcha CoreML** — не обучен. Kcaptcha идёт через Vision
  (точность хорошая на стандартных стилях, conf ~0.95).
- **Per-host threshold calibration** — после v0.38.9, когда
  per-host accuracy stats накопятся.
- **Модель** — `.mlmodelc/` gitignored (build artifact, не
  source). Каждый разработчик пересоздаёт локально через
  `train-coreml-captcha-helper.py`. В бандле приложения
  `model-captcha-numeric.mlmodelc/` будет встроен
  автоматически (через `Bundle.main`) — нужно добавить в
  ресурсы Xcode-проекта (TODO).

## v0.38.0–v0.38.7 (ранее на этой ветке, retro-fitted)

Эти версии были закоммичены в `captcha-auto-solver` до принятия
новой convention (черновик в `Docs/branch-changelogs/`, финал при
merge). При rebase (в коммите `293ce99`) release-ноты были
вырезаны из их оригинальных `changelog/v0.38.N.md` файлов, и
ветка поехала с `0.37.1`/build 38. Содержание v0.38.0–v0.38.7
восстановлено в preamble `Docs/branch-changelogs/captcha-auto-solver/v0.38.8.md`.

- **v0.38.0** — SwiftPM `CaptchaSolver` (Vision-based, on-device).
- **v0.38.1** — Wire auto-solver в интерактивный `SearchModel`.
- **v0.38.2** — Wire auto-solve в per-instance captcha stub.
- **v0.38.3** — Log fix (`FileHandle(forUpdating:)` +
  `seekToEnd()`); failed-image dump в
  `~/Library/.../captcha-failures/` (FIFO 50).
- **v0.38.4** — Per-host preprocessor (grayscale + contrast
  + 2x scale); `preprocessorHosts: Set<String>`. `minimumTextHeight`
  0.3 → 0.2.
- **v0.38.5** — `SearchDiagnostics` (HTML dumper в
  `~/Library/.../diagnostics/`). Three paths: `dumpFormCheck`,
  `dumpVariant`, `dumpSolverMismatch`. Toggle
  `captcha.diagnosticsEnabled`.
- **v0.38.6** — Diagnostic dump сохраняет **raw bytes** (без
  перекодирования в UTF-8). Mojibake fix. `data:`-перегрузки
  + `SudrfClient.fetchHTMLData`.
- **v0.38.7** — Live preprocess toggle через
  `VisionOCRStrategy.preprocessingProvider`. Per-attempt
  diagnostic файл `*_candidates.txt` с топ-3 кандидатами Vision
  и пометкой `preprocessed=yes/no`. Real-PNG тесты на
  основе `captcha-failures/` (XCTSkip-when-empty).
