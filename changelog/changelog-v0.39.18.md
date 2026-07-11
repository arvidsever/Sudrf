# Captcha auto-solver — v0.39.18

## Контекст

FIXPLAN A15 [P1] (H4 из ревью №2): «дедлок листа капчи после
неудачного submit». `CaptchaWebView.Coordinator.submitIfNeeded`
записывал `lastSubmitRequestID = parent.submitRequestID` **до**
проверки `state == .ready` — retry из `.failed`/`.rejected`/
`.loadingForm`/`.submitting` «съедал» requestID и завершался без
submit. Следующий пользовательский submit проходил тот же цикл →
лист не отправлял форму после любой ошибки.

### Что было сломано (A15)

1. **`submitIfNeeded` deadlock (L350-356):** `lastSubmitRequestID`
   записывался до `guard state == .ready`. Retry из `.failed`
   безвозвратно съедал requestID.

2. **Нет `didFail/didFailProvisionalNavigation`:** навигационный
   fail (offline, таймаут сети) не разблокировал лист. `state`
   оставался `.submitting` бесконечно.

3. **Нет таймаута для `.submitting`:** если суд не отвечал, `didFinish`
   не приходил, лист зависал.

4. **Гонка completion от старой попытки с новым retry:** `evaluateJavaScript`
   completion от submit #1 мог прилететь после `submitIfNeeded` для
   submit #2 и перезаписать состояние.

5. **Дублирование `sendSubmissionState(.submitting)`:** и в
   `submitIfNeeded`, и в `submitCaptcha` — SwiftUI получал сигнал дважды.

## Что в v0.39.18 (код)

### Bug fix: state-machine submit + 60-сек watchdog + best-effort request tracking

- **`Sources/SudrfApp/CaptchaWebView.swift`** — 4 точки правок +
  новые internal helper'ы:

  1. **`submitIfNeeded` (L350-area):** переставлен guard. Сначала
     `CaptchaWebViewSubmitDecisionFactory.decide(state:currentRequestID:lastRequestID:)` —
     если state не allow, requestID **не трогаем** (раньше съедался).
     При `.submit` — `attemptGenerator.start()` → монотонный ID (1, 2, 3, …),
     `state = .submitting`, `sendSubmissionState(.submitting)` (единственная точка),
     `scheduleSubmitTimeout(for: attempt)`, `submitCaptcha(...attempt:in:)`.

  2. **`decidePolicyFor` (новый метод):** best-effort request tracking.
     `defer { decisionHandler(.allow) }` гарантирует callback на любом
     пути. Фильтр `navigationType == .formSubmitted && targetFrame?.isMainFrame`
     — main-frame form submit. Записывает `expectedSubmitMarker` =
     `(attempt, expectedURL, setAt)` + `DispatchQueue.main.asyncAfter(5s)`
     self-clear.

  3. **`didStartProvisionalNavigation` (новый):** URL+window matcher
     (`CaptchaWebViewSubmitMarkerFactory.decide`) — если URL совпал и
     timestamp не протух, `submittedNavigation = navigation`. Иначе
     очистка маркера.

  4. **`didFinish` (L358-area):** guard `submittedNavigation === navigation`
     в дополнение к `state == .submitting && attempt match` — поздний
     `didFinish` от чужой навигации не пройдёт.

  5. **`didFail` + `didFailProvisionalNavigation` (новые):** →
     `handleNavigationFailure(navigation:error:)`. `NSURLErrorCancelled`
     ignore. `.ready`/`.accepted`/`.failed` — ignore. `.submitting` —
     fail если `isOurs` (state + attempt + navigation ===). `.loadingForm`
     — fail.

  6. **`scheduleSubmitTimeout(for:)` (60 сек):** `DispatchQueue.main.asyncAfter`.
     Guard `activeID == attempt && state == .submitting` — старый
     watchdog от submit #1 не ломает submit #2.

  7. **`fail(_:)`:** раздваивается. С attempt (через `activeID`) →
     `completeSubmit(attempt:nextState:.failed)` → `state = .failed` +
     `sendSubmissionState(.failed)`. Без attempt (loading fail) →
     просто `.failed`. **Инвалидация** attempt + `submittedNavigation` +
     `expectedSubmitMarker` в `completeSubmit` — все completion от
     старой попытки игнорируют гонку.

  8. **`inspectSubmittedResult(attempt:in:)` (L382-area):** добавлен
     `attempt` параметр. JS-completion guard `activeID == attempt` →
     гонка с retry не пройдёт. Reject-ветка → `completeSubmit(attempt:,.loadingForm)`
     + `applyAssist(rejected: true)`. failMissingToken →
     `completeSubmit(attempt:,.failed)` + `fail(...)`.

  9. **`captureCaptchaPair(attempt:from:)` / `captureSession(attempt:from:)`**
     (L444-area): добавлен `attempt` параметр. Guard `activeID == attempt`.
     `completeSubmit(attempt:,.accepted)` инвалидирует attempt ДО
     `sendSubmissionState(.accepted)`.

  10. **`submitCaptcha(_:attempt:in:)` (L506-area):** добавлен `attempt`
      параметр. **Убран** `sendSubmissionState(.submitting)` —
      единственная точка теперь в `submitIfNeeded`. JS-completion
      guard `activeID == attempt`.

- **Новые internal types** (на уровне файла, доступны тестам через
  `@testable import SudrfApp`):
  - `enum CaptchaWebViewState` — зеркало private `Coordinator.WebState`.
  - `enum CaptchaWebViewSubmitDecision` + `CaptchaWebViewSubmitDecisionFactory.decide(...)`.
  - `struct CaptchaWebViewAttemptGenerator` — монотонный `nextID` +
    optional `activeID`. `start()` инкрементирует `nextID` (всегда
    уникальный), `finish(activeAttempt:)` обнуляет `activeID` при
    совпадении.
  - `struct CaptchaWebViewSubmitMarker` + `CaptchaWebViewSubmitMarkerFactory.decide(...)` —
    URL+window matcher, 5-секундное окно.
  - `enum NavigationFailureDecision` + `CaptchaWebViewNavigationFailureFactory.decide(...)` —
    классификация nav-fail с `NSURLErrorCancelled` ignore.

- **`private static func mapState(_:)`** в Coordinator (fileprivate) —
  маппинг `WebState` → `CaptchaWebViewState` для factory'ев.

### Request tracking — best-effort (честно)

WebKit не предоставляет прямого идентификатора между
`WKNavigationAction` (в `decidePolicyFor`) и `WKNavigation` (в
`didStartProvisionalNavigation` / `didFinish` / `didFail`). Привязка
через URL + 5-секундное временное окно **снижает вероятность ложного
соответствия**, но не устраняет его полностью.

**Edge case:** поздняя навигация submit #1 (>5 сек задержка) при
активном submit #2 может быть ошибочно записана за #2 → `didFail` этой
навигации вызовет `fail()` → `state = .failed` → пользователь увидит
сообщение и повторит submit. **Worst case: 1 лишний fail, исходный
deadlock не возвращается (UI разблокирован через `.failed`).**

Строгая корреляция attempt ↔ WKNavigation в публичном API WebKit
**невозможна** без модификации submit-flow (добавления уникального
маркера в `form.action` через JS). Это инвазивно (может сломать
sudrf-сайт) и не входит в scope A15.

Ссылки: [WKNavigationDelegate](https://developer.apple.com/documentation/webkit/wknavigationdelegate),
[didStartProvisionalNavigation](https://developer.apple.com/documentation/webkit/wknavigationdelegate/webview(_:didstartprovisionalnavigation:)).

### Не трогаем

- `project.yml` / `changelog/changelog-v*.md` (AGENTS.md).
- `didReceive challenge` (TLS) — отдельная логика.
- `applyAssist` (загрузка формы) — fail-ветка уже корректна.
- `AutoCaptchaSolver`, `SearchModel`, `RefreshCenter` — не задействованы.

### Совместимость

- **3kas, magistrate, mos-gorsud** — не задействованы.
- **A1 (RefreshCenter)** — не задействован.
- **A2 (`.captchaRequired`)** — не задействован.
- **A14 (moduleHost dedup)** — не задействован.
- **60-сек watchdog на DispatchQueue** — стандартный механизм, не
  ломает UI.

## Тесты (v0.39.18)

Всего 335 тестов (было 317, +18):
- 7 в `CaptchaSheetStateTests` — submit decision factory (7 кейсов)
- 7 в `CaptchaSheetStateTests` — navigation failure factory (7 кейсов)
- 1 в `CaptchaSheetStateTests` — attempt generator (реальный сценарий retry)
- 3 в `CaptchaSheetStateTests` — URL+window marker matcher (match/mismatch/expired)

## Release notes (lift to `changelog/changelog-v0.39.18.md` at merge)

- **Bug fix:** `submitIfNeeded` больше не «съедает» requestID при
  неподходящем state — retry из `.failed` работает, deadlock снят.
  Guard `state == .ready || state == .failed` (через
  `CaptchaWebViewSubmitDecisionFactory.decide`).
- **Bug fix:** `didFail` / `didFailProvisionalNavigation` теперь
  реализованы — навигационный fail (offline, таймаут) разблокирует
  лист. `NSURLErrorCancelled` игнорируется (программная отмена
  навигации, не наш кейс).
- **Bug fix:** 60-сек watchdog для `.submitting` без ответа — если
  суд не отвечает, лист переходит в `.failed` с сообщением «Суд не
  ответил. Попробуйте ещё раз.».
- **Bug fix:** `sendSubmissionState(.submitting)` отправляется
  единожды (в `submitIfNeeded`), а не дважды (раньше и в
  `submitIfNeeded`, и в `submitCaptcha`).
- **Гонка защита:** монотонный `CaptchaWebViewAttemptGenerator`
  гарантирует уникальный attempt ID для каждой submit-попытки. Все
  completion-handlers (JS submit, inspectSubmittedResult, capturePair,
  captureSession) проверяют `activeID == attempt` перед записью
  состояния. 60-сек watchdog видит `activeID != attempt` после retry
  и не роняет новую попытку.
- **Best-effort request tracking:** `decidePolicyFor` +
  `didStartProvisionalNavigation` через URL+window matcher
  (5 секунд) снижают вероятность ложного соответствия
  attempt ↔ WKNavigation. Worst case: 1 лишний fail, deadlock не
  возвращается.
- **Testability:** новые internal types (`CaptchaWebViewState`,
  `CaptchaWebViewSubmitDecisionFactory`, `CaptchaWebViewAttemptGenerator`,
  `CaptchaWebViewSubmitMarkerFactory`, `CaptchaWebViewNavigationFailureFactory`)
  тестируются через `@testable import SudrfApp`.
- +18 unit-тестов в `CaptchaSheetStateTests`. Всего 335.

## Что остаётся

- **Track A P1:** A5, A16.
- **Track A P2:** A6, A7, A8, A9, A10, A11, A12.
- **Track A P3:** A13.
- **Track B:** отдельные PR от main.
- **Backlog (A15):** рефакторинг `submitCaptcha` для инъекции
  `CaptchaSubmitting`-протокола (мок `WKWebView`); инъекция
  `Clock`-протокола для тестирования watchdog; мок `WKNavigation` для
  end-to-end тестирования request tracking.
