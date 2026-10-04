# Sudrf roadmap

> Единственный актуальный план работ. Исторические результаты, прежняя очередь и
> полевые наблюдения — в [истории roadmap](roadmap-history.md); актуальные критерии
> приёмки каждой задачи — в GitHub issue.

Текущий выпуск: **0.61.9 (235)**: Журнал сохраняет подтверждённые базы каждого суда отдельно от кэша карточки; неполное обновление не поглощает ожидающие изменения. Перезапуск и объединение записей сохраняют базы без дублей и восстановления старых событий.
([PR #407](https://github.com/arvidsever/Sudrf/pull/407)).
Переключение ленты, уведомлений и значков на журнал остаётся в #179.
Сроки обращения в ВС РФ по подтверждённому маршруту ГПК/КАС подключены в
[выполненной части #222](https://github.com/arvidsever/Sudrf/pull/394).
Актуальные предупреждения и исторические режимы кассации исправлены в #372.
Незавершённая живая приёмка [#339](https://github.com/arvidsever/Sudrf/issues/339)
остаётся в очереди. Результаты и ограничения прошлых выпусков сохранены в
[истории](roadmap-history.md) и [changelog](../changelog/).

**[Последние выпуски — краткая таблица](roadmap-history.md#последние-выпуски).**
Обновляем её в том же PR, что код и changelog.

## Очередь

Сверено с [открытыми GitHub Issues](https://github.com/arvidsever/Sudrf/issues?q=is%3Aissue%20is%3Aopen) **4 октября 2026 года**: 55 задач после закрытия #262; выполненная часть #222 не закрывает всю задачу. Каждая открытая issue имеет одну строку ниже; критерии приёмки и доказательства остаются в issue. Порядок строк внутри группы — порядок работы; после закрытия задачи сверяем список заново. P0 — ближайшие исправления достоверности данных и сроков, P1 — следующие исправления и их необходимые основания, P2 — продуктовые и системные работы, P3 — новые источники. Отложенные решения автора перечислены отдельно и не входят в ближайшую очередь.

### P0 · Достоверность сроков, данных и текущие регрессии

| Issue | Следующий результат |
| --- | --- |
| [#339](https://github.com/arvidsever/Sudrf/issues/339) | Завершить живую приёмку последовательных CAPTCHA при добавлении дела; код уже в 0.59.1. |
| [#406](https://github.com/arvidsever/Sudrf/issues/406) | Проверить присоединённые к другому делу производства: завершённые не должны оставаться в первой инстанции. |
| [#343](https://github.com/arvidsever/Sudrf/issues/343) | По проверенным карточкам восстановить два круга апелляции и кассации `2-4739/2024`. |
| [#241](https://github.com/arvidsever/Sudrf/issues/241) | Принять живое обновление 3 КСОЮ при флапающем сайте и сохранение последнего успешного снимка. |

### P1 · Завершить пути источников и расчёт сроков

| Issue | Следующий результат |
| --- | --- |
| [#222](https://github.com/arvidsever/Sudrf/issues/222) | Подключены сроки обращения в ВС РФ по ГПК/КАС и отдельные сроки материалов. Далее: надзор и прочие неподключённые правила; выполненная часть и её ограничения — в истории. Календарная арифметика принята в #129, решения/определения — в #125. |
| [#76](https://github.com/arvidsever/Sudrf/issues/76) | Доделать кассационный маршрут дел суда субъекта; апелляционная часть уже выпущена. |
| [#322](https://github.com/arvidsever/Sudrf/issues/322) | Подтвердить и восстановить нижестоящие московские карточки из 1 АСОЮ и 2 КСОЮ через существующие правила связи. |
| [#156](https://github.com/arvidsever/Sudrf/issues/156) | Использовать `r_juid` как проверяемое доказательство передачи дела, без auto-merge по одному ответу реестра. |
| [#104](https://github.com/arvidsever/Sudrf/issues/104) | Обнаруживать и точно связывать новые производства ВС РФ; отделять их от регрессий уже найденных #340/#345. |
| [#344](https://github.com/arvidsever/Sudrf/issues/344) | Сразу показывать известную карточку и фоново дополнять цепочку; явно различать загрузку, пустоту и отказ. |
| [#250](https://github.com/arvidsever/Sudrf/issues/250) | Проверять связи CSV-импорта в фоне с прогрессом и приоритетом интерактивных запросов. |
| [#248](https://github.com/arvidsever/Sudrf/issues/248) | Завершить импорт старых URL, Мосгорсуда, мировых и ВС РФ; доступные семейства принять отдельно от будущих источников. |
| [#350](https://github.com/arvidsever/Sudrf/issues/350) | Довести картотеки окружных и флотских военных судов до паритета с живым сайтом. |
| [#68](https://github.com/arvidsever/Sudrf/issues/68) | Добавить пользовательский экран Source Health поверх уже сохраняемой обезличенной диагностики. |
| [#65](https://github.com/arvidsever/Sudrf/issues/65) | Запустить независимый live canary контрактов судебных порталов. |
| [#224](https://github.com/arvidsever/Sudrf/issues/224) | Завершить исторический календарь за пределами федерального покрытия 2013–2026 годов. |
| [#111](https://github.com/arvidsever/Sudrf/issues/111) | Принять федеральные переносы нерабочих дней и проверить оставшиеся региональные исключения. |
| [#223](https://github.com/arvidsever/Sudrf/issues/223) | Отдельно рассчитывать и показывать нормативные сроки рассмотрения на том же календаре. |
| [#179](https://github.com/arvidsever/Sudrf/issues/179) | После shadow-сверки подтверждённых баз #262 перевести ленту, уведомления и badges на CaseEvent journal. |
| [#308](https://github.com/arvidsever/Sudrf/issues/308) | В «Обзоре» показывать все сроки на ближайшую дату одной группой, не теряя просроченные. |
| [#221](https://github.com/arvidsever/Sudrf/issues/221) | Закончить visual QA файловых актов Мосгорсуда: несколько вложений, ошибка чтения и исходный файл. |

### P2 · Интерфейс, системная приёмка и следующая функциональность

| Issue | Следующий результат |
| --- | --- |
| [#403](https://github.com/arvidsever/Sudrf/issues/403) | Расширить локальный фильтр «Моих дел»: судьи, номера производств, участники и реквизиты уже сохранённых дел. |
| [#405](https://github.com/arvidsever/Sudrf/issues/405) | Самостоятельный материал 3/12-129/2022 показывать в правильном месте движения. |
| [#341](https://github.com/arvidsever/Sudrf/issues/341) | Не допускать наезда прокрученной выдачи поиска на шапку и навигацию. |
| [#354](https://github.com/arvidsever/Sudrf/issues/354) | Развести капсулу навигации и правую панель в узком окне, показать полный номер. |
| [#363](https://github.com/arvidsever/Sudrf/issues/363) | Удержать движение под закреплённой шапкой с системным scroll edge. |
| [#337](https://github.com/arvidsever/Sudrf/issues/337) | Размещать накладки недели по фактической высоте карточек. |
| [#368](https://github.com/arvidsever/Sudrf/issues/368) | Закрепить координаты навигационных кнопок месяца и недели при смене периода. |
| [#388](https://github.com/arvidsever/Sudrf/issues/388) | Сдвигать месячную сетку по одной неделе колесом и трекпадом; сохранять события и независимую прокрутку панели дня после #368. |
| [#352](https://github.com/arvidsever/Sudrf/issues/352) | Короткие имена суда и картотеки в пикерах; полные — в списке, tooltip и VoiceOver. |
| [#353](https://github.com/arvidsever/Sudrf/issues/353) | Скрыть пустой пикер «Суд» в поиске ВС РФ. |
| [#357](https://github.com/arvidsever/Sudrf/issues/357) | Убрать внутренние ID правил из колонки «Дальше» и перенос посреди слов. |
| [#364](https://github.com/arvidsever/Sudrf/issues/364) | Выровнять карточки «Моих дел», показать вид производства и однозначную метку стадии. |
| [#366](https://github.com/arvidsever/Sudrf/issues/366) | Исправить обрезание «Экспериментальных» и верхний отступ настроек. |
| [#324](https://github.com/arvidsever/Sudrf/issues/324) | Мультивыбор фильтров «Моих дел», включая «всё, кроме завершённых». |
| [#264](https://github.com/arvidsever/Sudrf/issues/264) | Проверить upgrade реальных V1/V2 баз до любой новой миграции схемы; gate для #333. |
| [#333](https://github.com/arvidsever/Sudrf/issues/333) | После gate #264 добавить необязательное короткое название дела для календаря. |
| [#46](https://github.com/arvidsever/Sudrf/issues/46) | Проверить cold-start App Intents и background resolution. |
| [#186](https://github.com/arvidsever/Sudrf/issues/186) | Проверить Spotlight identity Debug/Developer ID при общем bundle ID. |
| [#66](https://github.com/arvidsever/Sudrf/issues/66) | Завершить APPLE-6 системной матрицей после #46/#186; AI-зависимая часть ждёт отдельного решения. |
| [#69](https://github.com/arvidsever/Sudrf/issues/69) | Собрать production Developer ID/notarization pipeline. |
| [#93](https://github.com/arvidsever/Sudrf/issues/93) | После #179 добавить движение жалоб в общий event/feed contract. |
| [#101](https://github.com/arvidsever/Sudrf/issues/101) | После #179 показывать стороны и суд в локальных уведомлениях. |
| [#148](https://github.com/arvidsever/Sudrf/issues/148) | После event identity и сроков создать одностороннюю проекцию в Apple Calendar. |
| [#149](https://github.com/arvidsever/Sudrf/issues/149) | После надёжности источников и журнала добавить backend/APNs с тем же event contract. |
| [#164](https://github.com/arvidsever/Sudrf/issues/164) | Продолжить обучение KCAPTCHA после 500 уникальных проверенных картинок с трёх host. |
| [#106](https://github.com/arvidsever/Sudrf/issues/106) | Подключить поиск мировых судей Москвы по проверенному reference. |
| [#108](https://github.com/arvidsever/Sudrf/issues/108) | После #106 вынести общий routing источников мировых судей. |
| [#107](https://github.com/arvidsever/Sudrf/issues/107) | После #108 подключить мировых судей Санкт-Петербурга. |
| [#165](https://github.com/arvidsever/Sudrf/issues/165) | Прямой уголовный поиск ВС РФ после точного номера и HTML fixture; #76 не блокирует. |

### P3 · Новые источники после стабилизации текущих

| Issue | Первый проверяемый этап |
| --- | --- |
| [#346](https://github.com/arvidsever/Sudrf/issues/346) | КС РФ: отдельно проверить поиск обращения, статус, опубликованный акт и уведомление. |
| [#347](https://github.com/arvidsever/Sudrf/issues/347) | КАД: проверить живые поиск, пагинацию, PDF и повторное обновление до подключения к хранилищу. |

### Отложено решением автора

| Issue | Условие возврата |
| --- | --- |
| [#260](https://github.com/arvidsever/Sudrf/issues/260) | Риск TLS имеет P1, но автор исключил задачу из ближайшей очереди; вернуться только по его решению. |
| [#43](https://github.com/arvidsever/Sudrf/issues/43) | Отмена устаревшей генерации сводки — после выбора и проверки способа AI-генерации. |
| [#67](https://github.com/arvidsever/Sudrf/issues/67) | Выделение live-case session — вместе с #43, чтобы не перенести прежнюю гонку. |

Решение автора от 8 сентября 2026 года: AI-сводки и CASEAI-7 отложены; CAPTCHA/OCR, просмотр актов, Spotlight и App Intents продолжаются независимо. AI-зависимая часть PUBLIC-8 требует проверенных CASEAI-7/APPLE-6, production release и backend/APNs. Подробные прежние формулировки и выполненные этапы сохранены в [истории roadmap](roadmap-history.md).

## Правила ведения

### Источник правды

- Текущие приоритеты, статусы и решения живут только в этом файле.
- [`Docs/roadmap-history.md`](roadmap-history.md) — указатель последних выпусков и архива, а не второй план.
  Подробный результат записывается один раз в файл месяца; полный реестр и короткая
  таблица ведут к этой записи. Порядок пополнения — в [истории](roadmap-history.md#как-пополнять-историю).
- Детали реализации и acceptance принадлежат GitHub Issues; roadmap фиксирует порядок,
  зависимости и решения, но не дублирует issue body.
- Перед каждым обновлением перечитывается весь список открытых issues.
- Roadmap обновляется в той же ветке, что и задача, до merge результата.

### Рабочий цикл

Одна задача → ветка → реализация и roadmap → PR → self-review → независимый review →
CI → требуемая ручная/визуальная проверка → merge → закрытие issue → локальный `main`.

- Одна самостоятельная влитая ветка получает собственную версию.
- Changelog draft живёт в `Docs/branch-changelogs/<branch>/vX.Y.Z.md`.
- Release changelog, `MARKETING_VERSION` и build number меняются только перед merge/release.
- TestFlight собирается из актуального `main`; отдельной постоянной ветки нет.
- Для автозакрытия issue используется английское `Closes #N` / `Fixes #N`.
- Новые архитектурные epics и границы deliverables сначала согласуются с автором.
- Промоушен release changelog и версии — последний коммит перед merge.
- Fallout собственной правки исправляется в том же PR; соседний самостоятельный дефект
  получает отдельную issue.
- Зафиксированное решение автора не откатывается молча; визуальная развилка показывается
  вариантами и требует выбора автора.

### Статусы и merge-gate

Статусы этапов: `planned`, `in_progress`, `completed`, `blocked`. `Completed` означает
merge и зафиксированный результат проверки, а не наличие кода в незавершённой ветке.

Для каждого значимого этапа обязательны:

1. реализация и автоматические проверки критерия готовности;
2. self-review: scope, инварианты, data-loss/privacy/concurrency risks, негативные сценарии;
3. независимый adversarial review;
4. исправление замечаний либо записанное обоснование отклонения;
5. повторный прогон затронутых проверок;
6. merge, после которого обновляются статус и roadmap.

### SemVer

- Новая пользовательская функция или источник повышает minor и сбрасывает patch.
- Исправление, косметика, переобучение без новой возможности и developer-only tool
  повышают patch.
- Отсутствие отдельной публичной сборки не позволяет склеивать несколько merged branches
  в одну версию.

### Проверки

Базовый набор:

```bash
swift build && swift test
xcodegen generate && bash Scripts/make-app.sh
```

`Scripts/make-app.sh` запускается через `bash`. Визуальные изменения требуют ручной
проверки: сборка и тесты не подтверждают композицию, альфа-канал, системную индексацию,
Shortcuts, Translation или Apple Intelligence.

## Зафиксированные архитектурные решения

### Целевая цепочка

`transport → source adapter → normalized snapshot → identity/reconciliation →
semantic diff → append-only CaseEvent journal → projections`

Стек остаётся native: Swift, SwiftUI и SwiftData. Репозиторий маршрутизируется по
[`Docs/architecture/repo-map.md`](architecture/repo-map.md); основания open-source review
лежат в [`Docs/architecture/open-source-reference.md`](architecture/open-source-reference.md).

### Данные и источники

- Миграция схемы versioned. До destructive migration сохраняется согласованный комплект
  `store`/`-wal`/`-shm`; тихий persistent/in-memory fallback запрещён, failure показывает
  blocking recovery UI.
- Persistent bootstrap завершает backup, migration и подготовку проекций до создания
  `AppRouter`. Основная запись и её проекции сохраняются одной транзакцией.
- Если непустой `movementData` не декодируется, последняя проекция актов и сводки
  сохраняются до успешного обновления; повреждение не трактуется как удаление.
- Paragraph snapshot, paragraphizer version и document identity стабильны между
  запусками; новая ревизия создаётся только при изменении source hash.
- Последний хороший snapshot не стирается CAPTCHA, maintenance, partial/unknown HTML,
  parse error или временной пустой выдачей.
- `HTTP 200` не означает usable snapshot. Full, honest zero, partial, CAPTCHA,
  maintenance, transport и parser failure — разные outcomes; `lastAttempt` и
  `lastSuccess` не смешиваются.
- Существующая база никогда автоматически не уходит в quarantine. Это только явное
  обратимое действие пользователя после неудачного retry.
- Transport отвечает за HTTP, charset, TLS, cookies, throttle/retry и CAPTCHA continuity,
  но не знает процессуальной семантики. Обычные страницы — HTTP-first; browser automation
  допустима только как доказанный fallback.
- Token CAPTCHA и session CAPTCHA — разные протоколы. Для `msudrf` session continuity
  сохраняется через challenge → image → POST → unlocked listing.
- Source adapter нормализует source-native identity и не знает UI. Новые семейства
  выражаются capabilities/registry, а не новыми presentation-specific ветками.

### Identity и события

- Номер дела — атрибут, не primary key. Logical case связывает source-native cards,
  официальные court IDs, УИДы и доказанную историю перерегистраций.
- `r_juid` — evidence source, а не самостоятельное правило auto-merge. Пустой, partial
  или ошибочный registry response ничего не объединяет и не удаляет.
- Raw JSON/positional diff не является пользовательской семантикой. Перестановка строк,
  whitespace и publish timestamp не создают новое событие.
- Один event contract обслуживает feed, notifications, badges, Spotlight, Calendar и
  будущий APNs; presentation strings не участвуют в event identity.
- Fixture contract имеет два независимых уровня: raw response → normalized outcome и
  old/new snapshot → `CaseEvent[]`. Нужны positive и negative cases; ложное юридически
  значимое событие опаснее пропущенного cosmetic change.

### Правила, проекции и фоновые задачи

- Rules engine владеет юридической формулой, trigger/evidence и provenance; event journal
  владеет identity, dedup и доставкой downstream.
- Apple Calendar — только проекция Sudrf → Calendar. Пользовательское изменение или
  удаление события не переписывает судебное состояние.
- Adaptive scheduling допускается только после измерений простого TTL. Backoff/jitter и
  host circuit breaker вводятся при подтверждённой внешней проблеме, не «на будущее».
- Always-on backend и APNs обязательны, но позже. Сервер воспроизводит тот же normalized
  snapshot и event semantics, а не заводит вторую доменную модель или diff-engine.
- PostgreSQL, Redis, queues и search infrastructure появляются только при измеренной
  server workload; в desktop-приложении их нет.

### AI, privacy и системные интеграции

- Deployment target — macOS 26; macOS 27 API закрываются availability checks.
- Личный режим — BYOK; ключи хранятся в Keychain. Model IDs фиксированы, случайные
  free routers и провайдеры без проверенной privacy/retention политики запрещены.
- Cloud включается явным отзываемым согласием и получает только выбранный акт; фоновой
  отправки базы нет. Согласие предупреждает о персональных данных третьих лиц.
- Provider error body, prompt и `failed_generation` не сохраняются и не показываются;
  наружу допускается только allowlisted machine code.
- Новый AI-провайдер допускается после official-docs и benchmark gate: фиксированный
  model ID, structured schema, контекст, региональная доступность, privacy/retention и
  условия использования.
- AI не входит в critical path статуса, identity или срока. Typed summary обязана иметь
  существующие paragraph citations и локальную проверку критических реквизитов.
- Ранее реализована интеграция Groq `openai/gpt-oss-120b`; её текущая пригодность
  не подтверждена. По решению от 8 сентября 2026 года AI-генерация отложена
  до выбора и проверки подходящего способа; существующая интеграция не означает готовность.
- Apple direct и Apple через английский — изолированные Experimental routes. Двойной
  перевод выключен по умолчанию; Intel/недоступная модель дают BYOK fallback.
- Translation сохраняет paragraph/literal IDs; суммы, даты, номера, валюты и нормы права
  через свободный перевод не пропускаются.
- Spotlight включён по умолчанию, но до одноразового disclosure не получает writes.
  Disclosure прямо сообщает, что индекс содержит стороны, реквизиты и полный текст
  опубликованных актов: продолжение с ON запускает rebuild, OFF — полный purge и
  сохраняет отказ. Тот же toggle остаётся в Settings.
- Benchmark 50–100 опубликованных актов хранится вне Git и запускается вручную:
  100% существующих citations, ≥95% критических реквизитов, ≥90% полноты разделов.

### Явно не делать

- не replatform-ить native client на Python/Node/Java;
- не отключать TLS verification и не делать browser automation штатным транспортом;
- не считать CAPTCHA/error/unknown HTML за нулевой результат;
- не использовать номер дела или URL как identity;
- не строить независимые diff-алгоритмы для feed, Calendar и server notifications;
- не переписывать SwiftData и не добавлять server-scale infrastructure без измерений;
- не ослаблять structured output и не маскировать provider limits бесконечными retries.
