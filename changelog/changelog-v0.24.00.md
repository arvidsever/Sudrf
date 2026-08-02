# Изменения — Alpha 0.24.0

## Решённая капча переиспользуется: одно окно вместо окна на каждый запрос

Форма поиска sud_delo отправляется GET-ом, поэтому введённый пользователем
код уходит параметрами `&captcha=<код>&captchaid=<id>` — и суд принимает ту же
пару в последующих запросах, пока не отклонит (приём подтверждён боевой
практикой tochno-st/sudrfscraper). Раньше пара выбрасывалась, и на суде с
капчей каждый поиск заканчивался окном «введите код». Теперь код вводится один
раз: пара перехватывается из окна капчи, сохраняется и подставляется в
поисковые URL этого суда.

Принцип не изменился: капчу решает ЧЕЛОВЕК, приложение лишь не заставляет его
решать одно и то же многократно.

### Хранилище пар — `Sources/SudrfKit/CaptchaTokenStore.swift`

- `CaptchaToken` (value/id/obtainedAt) и actor-синглтон `CaptchaTokenStore`:
  `token(forDomain:)` (TTL 30 минут), `store`, `invalidate`. Ключ — дефисная
  форма хоста (обе формы и оба клиента SudrfClient попадают в одну запись).
  Только в памяти: валидность пары привязана к серверной сессии.

### Подстановка и инвалидация — SudrfKit

- `SudrfURLBuilder.searchURLVariants(…, captcha:)` — пара добавляется к
  каждому варианту URL (`&captcha=…&captchaid=…`).
- `SudrfClient.searchOnce`: при наличии токена предпроверка формы пропускается
  (минус запрос) — сразу выдача с парой. Если классификатор ответил «капча»
  (в т.ч. «Неверно указан проверочный код») — пара инвалидируется и поток
  возвращается к обычному сценарию с окном. Неудачное переиспользование стоит
  один лишний запрос.

### Перехват пары — `Sources/SudrfApp/CaptchaWebView.swift`

- В `Coordinator.didFinish` до ветки карточки: URL выдачи (`name_op=r`) с
  непустыми `captcha`/`captchaid` → cookies сессии WebView копируются в
  `HTTPCookieStorage.shared` (суд может проверять пару только в связке с
  сессией; клиенты используют общее хранилище cookies) → колбэк
  `onCaptchaPair(host, token)`. Пара с неверным кодом отсеется при первом
  переиспользовании (инвалидация в клиенте) — в WebView проверок нет.
- `CaptchaSheet`/`CaptchaWebView` получили опциональный `onCaptchaPair`.

### Wire-up — SudrfApp

- `SearchModel.storeCaptchaPair` / `AppModel.storeCaptchaPair` →
  `CaptchaTokenStore.shared` (оба листа капчи: ContentView.swift, RootView.swift).
- `AppModel`: после подхвата карточки из окна капчи движение перезапрашивается
  (`refreshOpenCase`) — оставшиеся заглушки-инстанции того же суда дозагружаются
  уже с парой в URL, без новых окон.

### Проверка вживую (из песочницы сеть до судов закрыта)

Сценарий: суд с капчей → окно, ввести код, открыть дело → карточка
подхватилась → повторить поиск по тому же суду — окно появляться не должно;
у отслеживаемого дела после решения капчи должны дозагрузиться остальные
инстанции без окон. Если суд отклоняет пару несмотря на копию cookies —
запасной вариант: копировать `JSESSIONID` явно (см. риск в плане).

### Тесты (176, все зелёные; было 171)

- `CaptchaTokenStoreTests`: нормализация форм хоста, инвалидация, TTL,
  раздельные суды.
- `SearchPatternTests.testCaptchaPairAppendedToEveryVariant`: пара в каждом
  варианте URL; без токена суффикса нет.

### Файлы

- Новые: `Sources/SudrfKit/CaptchaTokenStore.swift`,
  `Tests/SudrfKitTests/CaptchaTokenStoreTests.swift`.
- Изменены: `Sources/SudrfKit/SudrfURLBuilder.swift`,
  `Sources/SudrfKit/SudrfClient.swift`,
  `Sources/SudrfApp/CaptchaWebView.swift`, `Sources/SudrfApp/SearchModel.swift`,
  `Sources/SudrfApp/AppModel.swift`, `Sources/SudrfApp/ContentView.swift`,
  `Sources/SudrfApp/RootView.swift`, `project.yml` (версия 24).
