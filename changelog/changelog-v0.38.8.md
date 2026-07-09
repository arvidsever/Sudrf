# Изменения — Alpha 0.38.8

## Резюме

Эта версия — **промежуточный релиз** в разработке на ветке
`captcha-auto-solver`. Содержит CoreML-каркас (без обученной
модели). Реальный продукт с обученной моделью — v0.38.9
(следующая версия на той же ветке, в нём же добавлен corpus
bootstrap).

Если вы пришли сюда в поисках «где обученная модель» — это
v0.38.9, а не v0.38.8. v0.38.8 — это **только код-каркас**,
который компилируется и проходит тесты, но без `.mlmodelc` в
`~/Library/Application Support/Sudrf/` поведение солвера
неотличимо от v0.38.7 (Vision path).

## Добавлено

- **`Sources/CaptchaSolver/CoreMLCaptchaStrategy.swift`** —
  реализация `CaptchaSolvingProvider` для CoreML-моделей.
  Preprocessing: 100×30 RGB → бинарная маска чернил (порог
  по RGB-расстоянию от teal `(2, 103, 154)`) → downsample
  100×30 → 64×20 (box-averaging) → `MLMultiArray` `[1, 1, 20, 64]`
  (NCHW) → 5 softmax-голов по 10 цифр → argmax.
- **`Sources/CaptchaSolver/KindDispatchingStrategy.swift`** —
  per-kind диспетчер: `primaryKinds` (default `[.sudrfToken]`)
  идут в primary (CoreML), остальные — fallback (Vision).
  На CoreML-сбое прозрачно падает на Vision.
- **`Sources/CaptchaSolver/CoreMLModelDiscovery.swift`** — ищет
  скомпилированную модель в
  `~/Library/Application Support/Sudrf/...` или в `Bundle.main`.
- **`Sources/CaptchaSolver/CaptchaConfiguration.swift`** —
  добавлено поле `modelURL: URL?`.
- **`Sources/SudrfApp/AppModel.swift`** +
  **`Sources/SudrfApp/SearchModel.swift`** — конструируют
  `KindDispatchingStrategy(primary: coreML, fallback: vision)`
  если модель найдена; иначе работают на Vision.
- **`Scripts/train-coreml-captcha.swift`** — каркас обучения
  (TSV generator). Парсит корпус, делает 80/20 split, пишет
  `train-data.tsv` / `test-data.tsv`. Реальное обучение —
  `Scripts/train-coreml-captcha-helper.py` (v0.38.9).
- **`Scripts/train-coreml-captcha-helper.py`** — Python-скрипт
  обучения (PyTorch + coremltools + coremlc compile). В v0.38.8
  каркас; в v0.38.9 — обученная модель с известной точностью.

## Изменено

- **`Sources/CaptchaSolver/CaptchaConfiguration.swift`** —
  добавлено `modelURL: URL?` (когда nil — fallback на Vision).
- **`Sources/SudrfApp/AppModel.swift`** — `init` создаёт
  `VisionOCRStrategy` с `preprocessingProvider`, оборачивает
  CoreML (если модель найдена) через `KindDispatchingStrategy`.
- **`Sources/SudrfApp/SearchModel.swift`** — то же для
  интерактивного пути.

## Тесты

**280 тестов, 0 падений** (было 275, +5):

- `testBinarizeAndDownsampleDimensions` — синтетика, 1280
  элементов.
- `testBinarizeAndDownsampleOnRealCaptcha` — реальный PNG
  (XCTSkip если папка пустая).
- `testModelDiscoveryReturnsNilWhenAbsent` — без падения.
- `testInitFailsForMissingModel` — error type.
- `testKindDispatchingRoutesByKind` — primary/fallback routing.

## Эффект на пользователя

**Нет наблюдаемого эффекта** без `.mlmodelc`. При наличии модели
(создаётся вручную через `Scripts/train-coreml-captcha-helper.py`)
— модель подхватывается автоматически.

## См. также

- v0.38.9 — следующий релиз на той же ветке, в нём модель
  обучена и добавлен corpus bootstrap.
- v0.38.0–v0.38.7 — предыдущие релизы на ветке
  `captcha-auto-solver`, все описаны в preamble
  `Docs/branch-changelogs/captcha-auto-solver/v0.38.8.md`.
