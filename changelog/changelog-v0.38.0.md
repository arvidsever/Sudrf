# Изменения — Alpha 0.38.0

## Добавлено

Авто-распознавание капчи (sudrf / msudrf) на устройстве через Vision
framework. Новый SwiftPM-продукт `CaptchaSolver` (`Sources/CaptchaSolver/`):

- `CaptchaKind` (`.sudrfToken` / `.kcaptcha`) — два формата капчи,
  различаются по домену (`*.sudrf.ru` → цифры, `*.msudrf.ru` →
  буквы+цифры).
- `VisionOCRStrategy` — стратегия распознавания: `VNRecognizeTextRequest`
  с по-видовой настройкой языков и пост-фильтром по регулярному
  выражению (3–6 символов).
- `actor CaptchaSolver` — точка входа: rate-limit (50 мс между
  вызовами), логирование попыток в `~/Library/Application Support/Sudrf/captcha-solve.log`,
  внутренние ошибки Vision превращаются в «не уверен» (а не throw).
- `CaptchaImageExtractor` в SudrfKit — публичная функция извлечения
  PNG + captchaid из HTML формы (использует SwiftSoup). Раньше жила
  как `CaptchaImagePayload` в `CaptchaWebView` — теперь общий код-путь
  для UI и фона.

В `RefreshCenter.performRefresh(key:)` на `SudrfError.captchaRequired`:

1. Если авто-солвер включён (`CaptchaSettings.shared.isEffectivelyEnabled`)
   и есть `CaptchaSolver` — пробуем распознать до `maxAttempts = 3` раз
   с разными `captchaid` (каждая попытка — новый GET формы).
2. При уверенности `≥ minConfidence` (по умолчанию 0.55) токен
   `captcha/captchaid` сохраняется в `CaptchaTokenStore`, и
   `refresh(key:)` запускается заново — уже с токеном.
3. При исчерпании попыток / низкой уверенности — поведение прежнее:
   `CaptchaPendingQueue` + ручной ввод через `CaptchaAssistSheet`.

Новый блок «Captcha» в системном меню macOS (`SudrfApp.commands` →
`CommandMenu("Captcha")`):

- `[✓] Автоматически решать капчу   ⌃⌘A`
- `Решено сегодня: N`
- `Порог уверенности: M%`
- `Сбросить настройки`

Настройки — в UserDefaults: `captcha.autoSolve` (default `true`),
`captcha.minConfidence` (default `0.55`).

`SudrfClient.fetchForm(_:)` — тонкий алиас `fetchHTML(_:)` с
семантическим именем «форма поиска» для `RefreshCenter.tryAutoSolve`.
Вся троттлинговая логика и TLS-обход судов (включая `msudrf.ru` и
HTTP-fallback) унаследованы.

## Изменено

- `RefreshCenter.init` принимает `captchaSolver:` и `captchaSettings:`
  (оба опциональны, default = `nil` → поведение без солвера, как в v0.37).
- `AppModel.init` создаёт `CaptchaSolver()` и `CaptchaSettings.shared`
  и передаёт в `RefreshCenter`.
- `CaptchaWebView.CaptchaImagePayload.data(fromDataURL:)` — шim к
  `CaptchaImageExtractor.data(fromDataURL:)`. Поведение не изменилось.

## Тесты

- `CaptchaSolverTests` (новый таргет): скелет солвера, дефолты
  конфигурации, kind label, stub-возврат пустой попытки.
- `ImagePreprocessorTests`: на синтетической 100×40 капче — пайплайн
  даёт 200×64 на выходе; Otsu в [0,1]; битый PNG отбрасывается.
- `VisionOCRStrategyTests`: на 5 размеченных фикстурах от spb и nsk —
  spb читается верно, nsk (другой стиль) — UNREADABLE (честный ноль,
  ручной фолбэк).
- `CaptchaImageExtractorTests` (SudrfKit): base64-парсинг, экстракция
  inline-капчи из HTML, отсутствие `captchaid` → nil.

Таргетный прогон: 252 теста, 0 падений.

## Скрипты

- `Scripts/dump-captcha-fixtures.sh` — снимает капчи с живых судов
  (spb, nsk) для пополнения тестового набора. Не запускается в CI.
- `Scripts/swift-ocr-preview.swift` — печатает Vision-предположения
  по фикстурам для ручной разметки `labels.csv`.

## Известные ограничения

- **msudrf.ru фикстуры:** в этом окружении `msudrf.ru` недоступен по
  HTTPS (требует HTTP-fallback с TLS-обходом, который работает
  только в `SudrfClient`). Метки `.kcaptcha` стратегии есть,
  реальная точность не проверена.
- **nsk-капчи:** Vision их не читает (сильный шум, возможно поворот).
  Авто-солвер на них возвращает низкую уверенность, дело уходит
  в ручную очередь — это ожидаемое поведение.
- **Статус в меню «Captcha»** обновляется при открытии меню; SwiftUI
  `CommandMenu` не перерисовывает элементы динамически. Для live-счётчика
  нужен `NSMenu` напрямую — отложено.
