# Sudrf roadmap

> Единственный актуальный план работ. Подробная история вынесена в
> [`Docs/roadmap-history.md`](roadmap-history.md); она не задаёт текущие приоритеты.

## Сделано

Текущий baseline: **main 0.46.6**, build 133, 839 тестов (5 пропущены). Следующее
исправление — 0.46.7; следующая пользовательская функция или новый источник — 0.47.0.

| Версия | Результат |
| --- | --- |
| 0.41.0 | Swift 6, versioned data layer, Spotlight, App Intents, typed AI pipeline и сводка одного акта; APPLE-6 оставлен на ручной приёмке |
| 0.42.1 | Groq structured output: компактный payload, ограниченный output budget и bounded retry |
| 0.42.13–0.42.34 | Серия UI-, lifecycle-, packaging- и Spotlight-исправлений |
| 0.43.0 | Казначейство: все исполнительные документы, строгая RSS-привязка и история исполнения |
| 0.44.0 | ФССП: точный поиск всех ИД, независимый refresh и ручная CAPTCHA |
| 0.44.1 | Developer-only лаборатория CAPTCHA ФССП |
| 0.45.0 | Production-модель CAPTCHA ФССП и ансамбль двух числовых моделей СОЮ |
| 0.45.1–0.45.5 | Строгий allowlist заседаний, TestFlight из main, сортировка мировых участков, локализация и судьи в календаре |
| 0.46.0 | Безопасное удаление пользовательских подборок без удаления дел |
| 0.46.1 | Лицензия CC BY-NC-ND 4.0 и границы сторонних материалов |
| 0.46.2 | Типизированный source-state contract: full, honest zero, partial, CAPTCHA и errors |
| 0.46.3 | Постоянное внутреннее досье, история карточек, номеров и УИДов |
| 0.46.4 | Idempotent startup: identity и проекции не сохраняются без реальных изменений |
| 0.46.5 | #77: диагностика startup store, fail-closed regression и доказанный исторический in-memory fallback |
| 0.46.6 | #195: same-day lifecycle cache и scoped reload устранили блокировку UI при массовом обновлении дел |

Завершённый AI-фундамент: `S6-0A/B`, `DATA-1`, `SPOT-2`, `INTENT-3`, `AI-4` и
`SUMMARY-5`. Реализация и критерии сохранены в
[истории roadmap](roadmap-history.md) и [AI benchmark](AI-BENCHMARK.md).

## Очередь

Порядок читается сверху вниз. Знак `→` означает техническую зависимость; задачи,
перечисленные через `+`, можно вести независимо или объединять одним PR, если scope
совпадает. Все 55 открытых issues перечислены в этом разделе.
Дополнительно упомянуты три закрытых reference/acceptance case: #80, #85 и #102.

### 1. Сохранность данных

- **#144** — добавить retry и только явный обратимый quarantine всех
  `store`/`-wal`/`-shm`; автоматический quarantine запрещён.
- **#44 → #64:** убрать ложный успех после rollback, затем сделать durability-critical
  commits явно fallible во всех mutation paths.

### 2. Correctness и source reliability до event journal

- **#187** — вернуть прошедшие заседания в календарь, сохранив строгий allowlist и
  future-only поведение ближайшего заседания/App Intent.
- Source gate: **#79 + #78 + #82 + #88 + #164 + #89**. Рекомендуемый порядок —
  unknown/honest zero, CAPTCHA continuation/session, затем пригодное движение КСОЮ;
  между задачами нет искусственной жёсткой зависимости.
- **#181** проходит двумя уровнями: raw response → normalized snapshot/outcome входит
  в соответствующие source-fix PR и issue не закрывает; old/new snapshot → expected
  `CaseEvent[]` добавляется после стабилизации event vocabulary и закрывает contract.

### 3. Единый контур изменений

- **#155 → #179:** сначала shadow `CaseSnapshot → CaseEvent` со стабильными event IDs и
  сравнением с текущим поведением; после фактической сверки journal становится источником
  ленты, локальных уведомлений и badges.
- Второй уровень fixture contract завершается после стабилизации vocabulary этой фазы.

### 4. Юридическая семантика

- **#56 → #70 → (#129 + #125 + #111) → #128.** Сначала устраняется ложный срок при
  живой кассации. Затем rules engine получает формулу, evidence и provenance; в том же
  контуре реализуются календарные месяцы, рабочие дни и перенос окончания срока с учётом
  процессуального кодекса.
- Ранее закрытый **#80** остаётся negative fixture; его live-проверка входит в acceptance
  rules engine. Развязка стадии и срока обязательна до исправления последнего ложного срока.

### 5. Пользовательские проекции

- **#101 + #133** — стороны, суд и номер в уведомлениях и центральных панелях «Обзора»;
  делать после перехода пользовательских изменений на единое событие.
- **#148** — односторонняя проекция Sudrf → Apple Calendar после event identity и
  deadline semantics. Изменение `EKEvent` не меняет судебное состояние.

### Параллельная системная приёмка

- **#43 + #46 + #186 → #66 (APPLE-6):** stale summary при refresh, App Intents на
  cold start и Debug/Developer ID Spotlight identity проверяются до ручного go/no-go
  macOS 26/27, Apple Silicon/Intel, clean install/upgrade, recovery, consent и fallback.
- **#45** — отдельная rendering reliability-задача; case-level AI не блокирует.
- **#182** — остаточная визуальная приёмка: карточки #85/#102, экран поиска, узкое окно
  1180 pt и настройки 720 pt. Выполняется независимо от архитектурной очереди.

### Следующие продуктовые линии

- **#87 + #68 + #65 → #180:** discovery вышестоящей инстанции, минимальная host-health
  instrumentation и live canary дают baseline. Adaptive scheduler реализуется только при
  измеренном starvation/лишней нагрузке; иначе issue закрывается отчётом.
- **#69** — Developer ID/notarization: остаются notary credentials, submission, stapling
  и release workflow. TestFlight эту задачу не закрывает.
- **#149** — обязательный backend/APNs после event contract, базовой source reliability
  и результатов refresh-health измерений; технически Apple Calendar не блокирует.
- **CASEAI-7** — после APPLE-6, event journal, rules engine и устранения stale-summary:
  «Что изменилось», история инстанций, retrieval по делу, digest и command bar.
- **PUBLIC-8** — только после CASEAI-7, завершённого APPLE-6, готового production
  Developer ID/notarization pipeline и backend/APNs foundation. BYOK сохраняется; cloud
  требует proxy, квот, privacy/legal review и отсутствия хранения текстов судебных актов.

### Остальной backlog

- Дешёвое и заметное: **#91, #117, #92, #110, #151**.
- Доверие к данным: **#86, #76, #94, #93, #74, #90 + #130, #132**.
- Полнота цепочки: **#156, #104, #165**. Для ВС РФ нужны сохранённые автором HTML-фикстуры:
  поиск `2-8236/2025`, карточка `3-КФ26-187-К3` и уголовный кейс.
- Надёжность и локальная архитектура: **#81, #67**.
- Новые source families — последними: **#106 → #107 → #108**.

## Правила ведения

### Источник правды

- Текущие приоритеты, статусы и решения живут только в этом файле.
- [`Docs/roadmap-history.md`](roadmap-history.md) — versioned audit trail, а не второй план.
- Детали реализации и acceptance принадлежат GitHub Issues; roadmap фиксирует порядок,
  зависимости и решения, но не дублирует issue body.
- Перед каждым обновлением перечитывается весь список открытых issues.
- Roadmap обновляется в той же ветке, что и задача, сразу после merge результата.

### Рабочий цикл

Одна задача → ветка → PR → self-review → независимый review → CI → merge → локальный
`main` → обновление roadmap → закрытие issue → требуемая ручная/визуальная проверка.

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
- Рабочий внешний маршрут — Groq `openai/gpt-oss-120b` до нового benchmark.
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

## Ценные наблюдения

- **Сначала воспроизведение.** Формулировка причины в issue и собственная гипотеза
  неоднократно расходились с фактом; код меняется только после подтверждения real path.
- **Проверять артефакт, а не описание.** Зелёный CI не обнаружил отсутствующий alpha
  channel и не гарантирует, что resource bundle/CoreML model попали внутрь `.app`.
- **Visual/system acceptance не выводится из кода.** Liquid Glass, Spotlight ranking,
  Shortcuts cold start, Translation и Apple Intelligence проверяются реальным runtime.
- **Последний успех ценнее свежей ошибки.** Неудачный refresh не стирает карточку,
  движение, сводку или независимый результат другого источника.
- **Строгая семантика безопаснее удобной эвристики.** Время не делает строку заседанием,
  HTTP 200 не делает ответ валидным, а непустой result не доказывает итоговый акт.
- **Юридические сроки не сводятся к числу дней.** Календарные месяцы, рабочие дни,
  перенос окончания и правила разных кодексов требуют evidence и provenance.
- **Структурированный AI нельзя «чинить» ослаблением схемы.** Token budget, bounded retry,
  chunk boundaries и честная ошибка безопаснее правдоподобного невалидированного текста.
- **History — reference, не очередь.** Подробные метрики CAPTCHA, полевые кейсы,
  промежуточные диагнозы и принятые макеты сохранены в
  [`Docs/roadmap-history.md`](roadmap-history.md), чтобы основной план оставался рабочим.
