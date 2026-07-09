# Изменения — Alpha 0.38.2

## Исправлено

Авто-солвер капчи теперь срабатывает и в **третьем** месте — на
per-instance заглушках в `CaseMovementView` («Форма суда защищена
кодом с картинки — автопоиск невозможен. Ввести код»). Раньше
`AppRouter.beginCaptcha(for:)` сразу открывал ручной `CaptchaAssistSheet`,
минуя солвер.

- `Sources/SudrfApp/AppModel.swift`: в `AppRouter` добавлены
  `captchaSolver: CaptchaSolver` и `captchaSettings: CaptchaSettings`
  (те же, что и в `RefreshCenter` — общий `CaptchaSettings.shared`,
  свой `CaptchaSolver`). `beginCaptcha(for:)` сначала запускает
  `AutoCaptchaSolver.solve(...)`; на успех — токен в
  `CaptchaTokenStore`, `refreshCenter.retryPendingCaptcha(host:)`,
  `refreshOpenCase()` (тихий ретрай, ручной лист НЕ открывается);
  на провал — fallback на ручной лист (как раньше). Сигнатура
  остаётся sync — async-работа внутри `Task`, чтобы не трогать
  места вызова в `CaseMovementView` (Button).
- `Sources/SudrfApp/FeedNotifier.swift`: `setBadge(_:)` защищён
  `guard available else { return }` — `NSApp` равен nil в
  SwiftPM-тестах (нет бандла приложения), иначе force-unwrap
  падал. В обычной работе бейдж всегда доступен.

Все три места, где живёт капча в приложении, теперь проходят через
одну логику `AutoCaptchaSolver.solve(...)`:

| Место вызова | Файл | Кто вызывает |
|---|---|---|
| Интерактивный поиск | `SearchModel.runSearch` (v0.38.1) | `executeSearch(allowAutoSolve:)` |
| Фоновое обновление дела | `RefreshCenter.performRefresh` (v0.38.0) | `AutoCaptchaSolver.solve(...)` напрямую |
| Per-instance заглушка в движении | `AppRouter.beginCaptcha(for:)` (v0.38.2) | `AutoCaptchaSolver.solve(...)` внутри Task |

## Тесты

Таргетный прогон: 255 тестов, 0 падений.

Тесты для `AppRouter.beginCaptcha` отложены: требуют URLProtocol stub
для `SudrfClient.fetchForm`, которого в проекте пока нет. Helper
`AutoCaptchaSolver.solve(...)` покрыт юнит-тестами (default settings,
`kindFromURL` маппинг, nil при недоступной сети).
