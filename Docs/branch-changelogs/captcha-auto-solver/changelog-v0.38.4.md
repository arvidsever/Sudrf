# Изменения — Alpha 0.38.4

## Добавлено

Per-host preprocessor для `VisionOCRStrategy`. На captcha sudrf с
rotated digits и strikethrough-линиями (spb, nsk, некоторые другие
регионы) Vision возвращал `conf=0.00` — Vision просто не видел
символов, потому что они слишком мелкие (≈20% высоты 100×30 PNG) и
низкоконтрастные (blue-on-grey с цветными линиями).

Новый `Preprocessor` (Sources/CaptchaSolver/Preprocessor.swift,
~40 строк) делает три вещи:

1. **Grayscale** через `CIColorControls` (saturation=0, contrast=1.4).
2. **2x scale** через `CGAffineTransform`.
3. **Render → PNG** через `CIContext.createCGImage → NSBitmapImageRep`.

Критический момент: рендер через `createCGImage` + `NSBitmapImageRep`
избегает Y-flip-бага из v0.38.0 (когда CIImage-координаты
bottom-up ломали ориентацию для Vision).

Per-host gating — `preprocessingEnabled` и `preprocessorHosts` в
`CaptchaConfiguration` / `CaptchaSettings`:

- `preprocessingEnabled = false` (default) — preprocess выключен
  глобально. **Это критично:** практика показала, что preprocess
  регрессирует на простых captcha — Vision с прямым PNG читает
  «667» с conf=1.00, а после preprocess видит «49» (тот же
  conf=1.00, но wrong). Поэтому default = off, а не opt-out.
- `preprocessingEnabled = true` + `preprocessorHosts = []` —
  preprocess для всех хостов (опасно, может регрессировать).
- `preprocessingEnabled = true` + `preprocessorHosts = {host1, host2}` —
  preprocess только для указанных хостов (рекомендуемый режим).

`CaptchaSettings` хранит оба поля в UserDefaults
(`captcha.preprocessorEnabled`, `captcha.preprocessorHosts`),
`RefreshCenter` и `SearchModel` создают общий экземпляр
`CaptchaSolver` с этой конфигурацией.

`CaptchaSolvingProvider.solve(pngData:kind:host:)` — добавлен
опциональный `host` параметр. Старый 2-аргументный `solve` теперь
default-реализация в extension (передаёт `host = nil`). StubProvider
в тестах обновлён под новую сигнатуру.

`VisionOCRStrategy.minimumTextHeight` понижен с 0.3 до 0.2 — на
100×30 captcha текст может быть ниже 30% высоты, и 0.3 не давал
Vision даже пытаться. На простых captcha это не регрессирует
(`testSudrfFixturesAccuracy` по-прежнему 3+ correct из 5).

## Изменено

- `CaptchaSolverLog.shared` теперь `var` (было `let`), чтобы
  `CaptchaSolverLogTests` мог подменить его на temp-dir instance
  и не загрязнять реальный `~/Library/Application Support/Sudrf/`
  при `swift test`.

## Тесты

`Tests/CaptchaSolverTests/PreprocessorTests.swift` (новый, 4 теста):
- `testPreprocessUpscales` — 100×30 → 200×60.
- `testPreprocessPreservesAspectRatio` — 80×40 → 160×80.
- `testPreprocessHandlesNonImageData` — bogus input → nil, без крэша.
- `testVisionDoesNotCrashOnSyntheticCaptcha` — pipeline не падает
  ни с preprocess, ни без. Конкретное value не проверяем
  (synthetic-блобы не похожи на настоящие цифры).

`CaptchaSolverLogTests` (v0.38.3) дополнен — `setUp` сохраняет
`originalShared` и подменяет на test instance, `tearDown` восстанавливает.
Тесты больше не пишут `example.test` строки в production log.

`AutoCaptchaSolverTests.StubProvider` обновлён под новую сигнатуру
`solve(pngData:kind:host:)`.

Таргетный прогон: 263 теста, 0 падений.

## Как включить preprocess для spb

`CaptchaSettings.shared` (или defaults):

```bash
defaults write ru.sudrf.app captcha.preprocessorEnabled -bool YES
defaults write ru.sudrf.app captcha.preprocessorHosts -array sankt-peterburgsky--spb.sudrf.ru
```

Или через системное меню «Captcha → Настройки preprocess» (TODO —
UI ещё не добавлен). После включения запустите поиск на spb —
лог `captcha-solve.log` покажет, прошёл ли preprocess путь и какая
conf у Vision на препроцесснутых капчах.
