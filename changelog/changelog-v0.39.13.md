# Captcha auto-solver — v0.39.13

## Контекст

После v0.39.12 (wrong-token feedback loop) идём по FIXPLAN.md (PR #6
«captcha-auto-solver»). v0.39.13 закрывает задачу **A1 — retry
авто-солвера не запускается**.

### Что было сломано (A1)

`RefreshCenter.performRefresh(key:)` в ветке `catch SudrfError.captchaRequired`
после успешного `AutoCaptchaSolver.solve` и `CaptchaTokenStore.shared.store(...)`
звонил приватный `retryAfterCaptcha(key:host:)`, который в свою очередь
звонил `refresh(key:)`. Но `refresh(key:)` дедуплицирует по
`tasks[key]` (RefreshCenter.swift:228 `if let existing = tasks[key] { return existing }`),
а `tasks[key]` чистится **после** возврата `performRefresh` (RefreshCenter.swift:235).
То есть в момент retryAfterCaptcha текущая задача ещё в `tasks[key]`,
`refresh` возвращает её же — повтор `performRefresh` не стартует.
Токен лежит в сторе никем не потреблённый, пользователь видит ошибку
«форма ждёт код» даже после успешного авто-солва.

## Что в v0.39.13 (код)

### Bug fix: inline retry after auto-solve

- **`Sources/SudrfApp/RefreshCenter.swift`**:
  - В `performRefresh(key:)` в ветке `catch SudrfError.captchaRequired(let url)`
    после `await CaptchaTokenStore.shared.store(token, domain: ...)` повтор
    `service.movement(...)` теперь идёт **inline** в текущей `Task` (вложенный
    `do/try/catch`). Токен уже в `CaptchaTokenStore`, `SudrfClient.search`
    подхватит его автоматически — никакого `refresh(key:)` не нужно, и
    `tasks[key]` не мешает.
  - На повторной `.captchaRequired` (токен отклонён) или другой `SudrfError` —
    `queueCaptcha + fail` (ручной ввод, как раньше). Рекурсии нет:
    `refresh(key:)` не вызывается, новый `Task` не стартует.
  - Success-путь (merge / snapshot / persist / `captchaPending.remove` /
    `lastErrors = nil` / `onRefreshed`) вынесен в приватный `applyMovement(key:ctx:mv:)`
    и вызывается из обоих точек (обычный happy path + retry-after-solve).
  - Приватный `retryAfterCaptcha(key:host:)` удалён (единственный вызов
    ушёл). `retryPendingCaptcha(host:)` остаётся — он зовётся из UI
    («Captcha» menu) для ручного retry, и к тому моменту task уже
    завершён, так что `refresh(key:)` стартует новый проход нормально.
  - `RefreshCenter.init` теперь принимает два новых опциональных параметра:
    - `autoSolve: ((URL, SudrfClient, CaptchaSolver, AutoCaptchaSolver.Settings) async -> AutoCaptchaSolver.SolveResult)?`
      — дефолт зовёт реальный `AutoCaptchaSolver.solve`. Нужен для
      герметичных тестов (см. ниже).
    - `serviceBuilder: ((MovementContext) -> any MovementProviding)?` —
      дефолт строит `MovementService` через `ctx.makeService(...)`.
      Нужен для подмены `service.movement(...)` в тестах без сети.
    В обоих default-замыканиях `vsrfClient` / `mosGorSudClient`
    снимаются в **локальные `let`**, чтобы не ловить self-capture
    до завершения `self.init`.

- **`Sources/SudrfApp/TrackedStore.swift`**:
  - Добавлен `init(inMemory: Bool)` — для тестов, чтобы не трогать
    пользовательское `~/Library/Application Support` и держать записи
    изолированно. Существующий `init()` оформлен как convenience и
    делегирует `init(inMemory: false)` — поведение прод-кода
    идентично. Существующая fallback-ветка на in-memory при сбое
    persistent store сохранена.

### Tests

- **`Tests/SudrfAppTests/RefreshCenterTests.swift`** (новый, 2 теста):
  - `testBackgroundAutoSolveRetryConsumesToken` — главный тест
    фикса. `ScriptedMovement` (actor-мок `MovementProviding`)
    бросает `.captchaRequired` на первом `movement(...)` и
    возвращает реальный `CaseMovement` на втором. `autoSolve`-
    замыкание возвращает `SolveResult(token: CaptchaToken(value: "12345", id: "abc"), png: ...)`.
    Ассерты:
    - `scripted.calls.count == 2` (inline retry реально сработал);
    - `rec.movementFetchedAt != nil` (запись обновлена);
    - `center.lastErrors[key] == nil` (ошибка сброшена);
    - `center.captchaPendingGroups.isEmpty` (ключ не висит в очереди);
    - `onRefreshed` вызван ровно один раз;
    - `CaptchaTokenStore.shared.token(forDomain:)?.value == "12345"`
      (токен действительно сохранён).
  - `testBackgroundAutoSolveNilTokenFallsBackToManual` — sanity.
    `autoSolve` возвращает `nil`-токен. Ассерты:
    - `scripted.calls.count == 1` (повторного вызова не было);
    - `center.captchaPendingGroups.count == 1` (ключ попал в очередь);
    - `center.lastErrors[key] != nil`;
    - `CaptchaTokenStore.shared.token(forDomain:) == nil` (стор не загрязнён).

### Тестовая инфраструктура

- В `setUp` / `tearDown` сохраняются и восстанавливаются
  `autoSolveEnabled` / `forceDisabled` / `minConfidence`
  из `CaptchaSettings.shared` — тест не должен оставлять побочных
  эффектов в UserDefaults пользователя.
- `CaptchaTokenStore.shared.invalidate(domain:)` чистится в
  setUp/tearDown для изоляции между прогонами.
- `TrackedStore(inMemory: true)` изолирует тестовое хранилище
  от продового.

## Тесты (v0.39.13)

Всего 312 тестов (было 310, +2):
- 2 в `RefreshCenterTests` — inline retry после успешного solve,
  fallback на manual при nil-токене.

## Release notes (lift to `changelog/changelog-v0.39.13.md` at merge)

- **Bug fix:** `RefreshCenter` теперь делает повторный `service.movement`
  inline после успешного авто-солва капчи, а не через `refresh(key:)`.
  Раньше `refresh(key:)` дедуплицировал по `tasks[key]`, который ещё
  не был очищен → retry не стартовал → токен лежал в
  `CaptchaTokenStore` не потреблённый. Теперь задача потребляет
  токен сама, без обращения к дедупликации.
- **Refactor:** success-путь `performRefresh` вынесен в приватный
  `applyMovement(key:ctx:mv:)`. Используется из обоих happy-path'ов.
- **Refactor:** приватный `retryAfterCaptcha` удалён — больше не нужен.
  Ручной retry из UI (captcha menu) идёт через `retryPendingCaptcha` →
  `refresh(key:)` напрямую и работает корректно (task к моменту вызова
  уже завершён).
- **Testability:** `RefreshCenter.init` принимает опциональные
  `autoSolve` и `serviceBuilder` для герметичных тестов без сети.
  Поведение прод-кода не меняется (defaults зовут те же функции).
- **Testability:** `TrackedStore.init(inMemory:)` для in-memory
  хранилища в тестах. Продовый init сохраняет семантику.
- +2 теста в `RefreshCenterTests`. Всего 312.

## Что остаётся

- A2, A3, A4, A5, A14, A15, A16 (FIXPLAN Track A P1).
- A6…A12 (Track A P2), A13 (Track A P3).
- Track B — отдельные PR от main.
