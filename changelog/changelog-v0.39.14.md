# Captcha auto-solver — v0.39.14

## Контекст

После v0.39.13 (A1, inline retry после авто-солва) FIXPLAN требует A2:
если `SudrfClient.runVariants` распознал `.captchaRejected` (суд детерминированно
отверг наш токен) — UI должен получить `.captchaRequired`, а не
`.searchModuleUnavailable`. До A2 manual sheet не открывался и
captcha-queue не пополнялся; дело «терялось» как «поисковый модуль
недоступен» при живом, решаемом ручным вводом запросе.

### Что было сломано (A2)

`SudrfClient.runVariants` (SudrfClient.swift:196-262) в цикле вариантов
при `case .captchaRejected:` инвалидирует токен в `CaptchaTokenStore`
(фикс v0.39.12), дампит HTML в `rejected_<host>_<ts>.html`, ставит
`lastWasCaptchaRejected = true`, и ВЕДЁТ СЕБЯ как `.unrecognized`:
продолжает перебор. После цикла (все варианты дали либо `.unrecognized`,
либо `.captchaRejected`, без `.results`/`.empty`) — `runVariants` бросал
`SudrfError.searchModuleUnavailable(domain: court.domain)`.

Эту ошибку ловят ТОЛЬКО `searchOnce` cached-token catch (который
смотрит только `.captchaRequired`) и **не** ловят
`SearchModel.handleCaptcha` и `RefreshCenter.performRefresh` — они
тоже ловят только `.captchaRequired`. В итоге manual captcha sheet
не открывался, дело оставалось в «поисковый модуль недоступен»,
а token-store чистый. По сути пользователь получал сообщение
«суд не отвечает» вместо «введите код с картинки», хотя код был
единственной проблемой.

## Что в v0.39.14 (код)

### Bug fix: `.captchaRejected` → `.captchaRequired`

- **`Sources/SudrfKit/SudrfClient.swift`** — `runVariants`, финальная
  ветка (после dump-блока, перед `throw searchModuleUnavailable`):
  ```swift
  if lastWasCaptchaRejected, let formURL = try? builder.formURL(cartoteka) {
      throw SudrfError.captchaRequired(formURL: formURL)
  }
  throw SudrfError.searchModuleUnavailable(domain: court.domain)
  ```
  Условие — тот же `lastWasCaptchaRejected` (уже выбирает префикс
  дампа `rejected_` вместо `variant_`): когерентно с диагностикой.
  `try? builder.formURL(cartoteka)` — fallback на старое поведение
  при несобираемом formURL (битый cartoteka). Цикл перебора вариантов
  не трогаем: `case .captchaRejected:` по-прежнему инвалидирует токен
  и идёт дальше (если в оставшихся вариантах есть шанс на `.results`).

  **Семантическое замечание:** `.captchaRequired` не проходит
  `withHostFallback` (SudrfClient.swift:296 `if case .captchaRequired
  = e { throw e }`). До A2 `searchModuleUnavailable` запускал перебор
  dot/dash-форм. Это улучшение: rejection детерминирован для обеих
  форм одного сервера (один и тот же back-end), дополнительный GET
  бесполезен. Если в редком кейсе dot-форма приняла бы код — мы
  этого больше не увидим; считаем приемлемым, зафиксировано в
  changelog.

### Три обработчика уже на месте

- `SudrfClient.searchOnce` cached-token catch (SudrfClient.swift:163-165)
  — `.captchaRequired` → `await captchaStore.invalidate(...)` →
  continue к предпроверке формы.
- `SearchModel.handleCaptcha` (SearchModel.swift:481-515) — авто-солвер
  / manual captcha (используется живым поиском).
- `RefreshCenter.performRefresh` (RefreshCenter.swift:271-329, после
  A1 v0.39.13) — inline retry / manual captcha / queue.

После A2 все три видят `.captchaRequired` от rejected-пути и ведут
себя корректно: открывают sheet / ставят в captcha-queue / запускают
новую попытку.

### Тесты

- **`Tests/SudrfKitTests/SudrfClientCaptchaTests.swift`** (обновлены
  + 1 новый, всего 4 теста в suite):
  - `testCaptchaRejectedInvalidatesToken` — ассерт на
    `.searchModuleUnavailable` заменён на `.captchaRequired`;
    ассерт инвалидации токена сохранён (главная проверка v0.38.10).
  - `testCaptchaRejectedWithoutTokenDoesNotCrash` — то же обновление.
  - `testCaptchaRejectedDumpsWithRejectedPrefix` — без правок: дамп
    `rejected_` пишется до `throw` (внутри dump-блока), ассерты
    на `_variant`/`_rejected` остаются зелёными.
  - `testCaptchaRejectedThrowsCaptchaRequiredForPrimary` (новый) —
    главный тест A2. Rejection-HTML на все варианты, ожидаем
    `catch SudrfError.captchaRequired(let formURL)`. Ассерты:
    `formURL.host == "spb.sudrf.ru"`; `formURL.query.contains("name_op=sf")`.
    Отдельный `XCTFail` если прилетит `.searchModuleUnavailable`
    (защита от регрессии к старому поведению).

## Тесты (v0.39.14)

Всего 313 тестов (было 312, +1):
- +1 в `SudrfClientCaptchaTests` (`testCaptchaRejectedThrowsCaptchaRequiredForPrimary`).
- 2 существующих обновлены под новый ожидаемый throw.

## Release notes (lift to `changelog/changelog-v0.39.14.md` at merge)

- **Bug fix:** `SudrfClient.runVariants` теперь бросает
  `.captchaRequired` при `.captchaRejected` (суд детерминированно
  отверг токен) вместо `.searchModuleUnavailable`. Без фикса три
  обработчика `.captchaRequired` (searchOnce cached-token catch,
  SearchModel.handleCaptcha, RefreshCenter.performRefresh) не
  срабатывали — manual sheet не открывался, captcha-queue не
  пополнялся, дело «терялось» как «модуль недоступен» при живом,
  решаемом запросе.
- **Поведенческое замечание:** `.captchaRequired` из rejected-пути
  не проходит `withHostFallback` (в отличие от прежнего
  `searchModuleUnavailable`). Rejection детерминирован для обеих
  форм одного сервера, дополнительный GET бесполезен. Считаем
  приемлемым trade-off ради корректного UX.
- +1 новый тест в `SudrfClientCaptchaTests`. 2 существующих
  обновлены под новый ожидаемый throw. Всего 313.
- **Эффект на пользователя:** captcha-включённые суды, которые
  раньше «отваливались» в «модуль недоступен» после отклонения
  токена, теперь корректно предлагают manual captcha sheet или
  повторную попытку авто-солвера.

## Что остаётся

- A3, A4, A5, A14, A15, A16 (FIXPLAN Track A P1).
- A6…A12 (Track A P2), A13 (Track A P3).
- Track B — отдельные PR от main.
