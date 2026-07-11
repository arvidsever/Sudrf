# Captcha auto-solver — v0.39.15

## Контекст

FIXPLAN.md задача A3 [P1]: «Для msudrf распознанный токен не отправляется».
Премисса плана: `MagistrateURLBuilder.searchURL` не принимает токен;
query не содержит `captcha`/`captchaid`; клиент мировых судей не
читает `CaptchaTokenStore`; авто-солвер сохраняет пару и повторяет
тот же URL без неё → снова капча. Закрытие задачи требует проверки
этой премиссы по фактической механике msudrf-капчи.

## Эмпирика (по `Петрозаводский1.webarchive`)

Капча на `petrozavodskoj.komi.msudrf.ru` имеет принципиально иную
структуру, чем sudrf:

- POST-форма `id="kcaptchaForm"`, action не указан → POST идёт на
  текущий URL страницы.
- Один input `name="captcha-response"` (НЕ `captcha`, НЕ `captchaid`).
- Img `<img src="/captcha.php">` (НЕ data-URI, НЕ inline base64).
- `captchaid` отсутствует. Сессия привязана к cookies.

Извлечённый фрагмент:

```html
<form style="..." method="post" id="kcaptchaForm">
  <div style="text-align: center">
    <div style="width: 252px; margin: 0 auto;">
      <img src="/captcha.php" style="border: 1px solid #a5a5a5; border-radius: 2px;">
    </div>
    <div style="margin: 10px auto; width: 162px;">
      <input type="text" class="text-input" name="captcha-response" style="width: 150px;">
    </div>
    <div style="margin: 0 auto; width: 162px;">
      <button type="submit" class="button-normal" style="width: 162px;">Продолжить</button>
    </div>
  </div>
</form>
```

## Почему план A3 в текущей формулировке не реализуем

1. Имя параметра у msudrf — `captcha-response`, не `captcha` — суд
   проигнорирует GET-параметр `captcha=…`.
2. `captchaid` у msudrf нет — параметр `captchaid=…` мусорный.
3. Капча отправляется POST'ом в body, не GET'ом в query —
   `MagistrateClient.search` (через `SudrfClient.fetchHTML` →
   `URLSession.dataTask` GET) не может отправить body без
   переписывания клиента.
4. `AutoCaptchaSolver.solve` (AutoCaptchaSolver.swift:73-77) для
   msudrf даже не доходит до Vision: `CaptchaImageExtractor.extract`
   требует `input[name=captchaid]` И `img[src^=data]` (CaptchaImage-
   Extractor.swift:38, 48) — обоих нет на msudrf → возвращает
   `nil` → токен не сохраняется. FIXPLAN ошибочно говорит, что
   «авто-солвер сохраняет пару» — на msudrf этого не происходит.

## Что уже работает (без правок кода)

Manual flow для msudrf полностью покрыт. Цепочка:

1. `MagistrateClient.search:340` бросает
   `.captchaRequired(formURL: try builder.formURL())` при
   обнаружении `kcaptchaForm` через `CaptchaDetector`.
2. `SearchModel.beginCaptcha` (SearchModel.swift:694-702) открывает
   `CaptchaAssistSheet` с `kind = .kcaptcha`,
   `formURL = /modules.php?name=sud_delo&op=hl`.
3. `CaptchaWebView.Coordinator.applyAssist` (CaptchaWebView.swift:
   562-718) находит kcaptchaForm, рисует PNG, пользователь вводит
   код, JS сабмитит POST.
4. `CaptchaWebView.Coordinator.inspectSubmittedResult` (CaptchaWeb-
   View.swift:382-442) видит отсутствие captcha-input на новой
   странице → `case .accept` → `captureSession` (стр. 464-475) — НЕ
   `captureCaptchaPair`, потому что `contextKindRequiresToken` =
   `kind == .sudrfToken` = false для `.kcaptcha` (стр. 296).
5. `Self.copyCookies(from: WKHTTPCookieStore, host:)` (стр. 477-491)
   копирует cookies (включая msudrf session) в
   `HTTPCookieStorage.shared`.
6. `onSessionUnlocked(host)` → `AppModel.captchaSessionUnlocked:
   822-828` → `refreshCenter.retryPendingCaptcha(host:)` →
   `refresh(key:)` для всех отслеживаемых дел этого хоста.
7. `MagistrateClient.search` (повторный вызов) → `client.fetchHTML`
   → `URLSession` с `httpCookieStorage = HTTPCookieStorage.shared`
   (SudrfClient.swift:27) подхватывает cookies → captcha-проверка
   пройдена → выдача получена.

**Live-поиск:** manual sheet открывается автоматически по
`captchaRequired`, пользователь вводит код → результат.

**Background refresh:** дело ставится в `CaptchaPendingQueue`,
пользователь видит captcha-pending счётчик/бейдж (через
`captchaPendingCount`/`captchaPendingCaseNumbers` в RefreshCenter,
UI-сигналы в `CaptchaMenu`/`OverviewView`), разблокировка — ручная
через `retryPendingCaptcha(host:)`. UI-сигнализация уже на месте.

## Корректная формулировка статуса

- **Премисса A3 неверна** → описанного бага нет.
- **msudrf корректно деградирует** на рабочий manual+cookies flow.
- **msudrf auto-solver — отдельная фича** (вынесена в бэклог),
  **реализуемая**, но **не P1** и **не в текущем контракте**
  `AutoCaptraSolver`/`CaptchaImageExtractor`.

## Follow-up (backlog, не P1): msudrf auto-solve

Реализация потребует:

1. Расширить `CaptchaImageExtractor.extract` — распознавать
   `kcaptchaForm`: img src `/captcha.php` (без data:, без captchaid
   в URL). Captchaid синтезировать из host
   (`CaptchaToken(value: code, id: <host>)`).
2. Добавить fetch PNG для msudrf: GET `/captcha.php` с
   `HTTPCookieStorage.shared` cookies → байты → `CaptchaKind.
   kcaptcha` → `CaptchaSolver` (Vision уже умеет `.kcaptcha`).
3. `AutoCaptraSolver` — добавить путь для `.kcaptcha` msudrf: submit
   через скрытый WKWebView (программно заполнить `kcaptchaForm` и
   кликнуть «Продолжить»), затем обновить `HTTPCookieStorage.shared`
   по аналогии с `CaptchaWebView.captureSession`.
4. `MagistrateClient.search` — после submit перечитать страницу;
   cookies автоматически подхватываются (SudrfClient.init:27 уже
   настроен на `HTTPCookieStorage.shared`).
5. Тесты на msudrf-фикстуры: HTML `kcaptchaForm` + PNG + Vision +
   мок submit через WKWebView.

Оценка: 2-4 дня работы + QA. Backlog, не блокирует P1 FIXPLAN.
`.kcaptcha` поддержан как `CaptchaKind`, Vision-стратегия
(VisionOCRStrategy.swift:133-185) уже решает; decoder
`CoreMLCaptchaStrategy` для текстовых — отдельная ветка, в
backlog A4 уже зафиксированы ограничения 5-значной модели.

## Что остаётся

- A4, A5, A14, A15, A16 (FIXPLAN Track A P1).
- A6-A12 (Track A P2), A13 (Track A P3 — откат version-полей в
  `project.yml` / `Scripts/make-app.sh` перед merge).
- Backlog: msudrf auto-solver (см. раздел Follow-up выше).
- Track B — отдельные PR от main.
