# Sudrf roadmap

> Единственный актуальный план работ. Подробная история вынесена в
> [`Docs/roadmap-history.md`](roadmap-history.md); она не задаёт текущие приоритеты.

## Сделано

Текущий baseline: **main 0.57.7**, build 168, 1192 XCTest (5 пропущены) и 14 Swift Testing. Полный
registry сроков обжалования подключён; оставшиеся typed rules относятся к #222.

| Версия | Результат |
| --- | --- |
| 0.3.0–0.9.0 | Базовый поиск и карточка движения, автоматический проход апелляции/кассации, УИД, картотеки суда субъекта и явное состояние CAPTCHA |
| 0.10.0–0.14.0 | Нативный интерфейс и навигация, полный справочник федеральных и военных судов, категории и участники дела |
| 0.15.0–0.20.0 | Отслеживание, первые процессуальные сроки, persistent-кэш и фоновый refresh, строгий TLS, вторая кассация в ВС РФ и пользовательские подборки |
| 0.21.0–0.26.0 | CSV-import, прямые известные карточки и материалы, классификация производств, VNKOD-суды, повторное использование CAPTCHA и Мосгорсуд |
| 0.27.0–0.34.0 | Интерфейс для больших списков, участники УПК/КоАП, параллельный refresh по хостам, уведомления, badge и календарная повестка |
| 0.35.0–0.37.1 | CAPTCHA Assist с очередью по суду и retry, поиск и движение дел мировых судей, исправления ручного flow |
| 0.38.0–0.38.9 | Недельный календарь, автоматическое решение CAPTCHA, Vision-диагностика/preprocess и первая CoreML-модель с локальным корпусом |
| 0.39.12–0.39.29 | Укрепление CAPTCHA state machine, транспорта, model delivery, настроек, диагностики и атомарного накопления корпуса |
| 0.39.30–0.40.4 | Корректная маршрутизация и identity после импорта, восстановление полных цепочек, единый классификатор производств, maintenance-защита и Swift Concurrency |
| 0.41.0 | Swift 6, versioned data layer, Spotlight, App Intents, typed AI pipeline и сводка одного акта; APPLE-6 оставлен на ручной приёмке |
| 0.41.1 | Hotfix падения onscreen activity при открытии дела или акта |
| 0.42.0 | Поиск, карточки и движение Мосгорсуда выверены по живому порталу |
| 0.42.1 | Groq structured output: компактный payload, ограниченный output budget и bounded retry |
| 0.42.2–0.42.12 | Карта репозитория и упрощение структуры, lifecycle/stage fixes, КСОЮ listing, канонические номера и системная локализация календаря |
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
| 0.46.7 | #144: retry без изменения файлов и только явный обратимый quarantine неоткрываемой базы с README и Finder |
| 0.46.8 | #44: refresh больше не сообщает об успехе после rollback; движение, identity и key-remap сохраняются одной транзакцией |
| 0.46.9 | #64: fallible persistence commits обязательны во всех mutation paths; rollback блокирует success callbacks, UI и проекции |
| 0.46.10 | #187: календарь снова показывает прошедшие заседания; ближайшее заседание, App Intent и lifecycle остаются future-only |
| 0.46.11 | #79: final response URL определяет host карточек, CAPTCHA и diagnostics; пользовательские WebArchive закреплены обезличенными fixtures |
| 0.46.12 | #78: мировые суды больше не выдают неизвестную или положительную разметку за honest zero; реальная выдача закреплена обезличенной fixture |
| 0.46.13 | #82: ручная CAPTCHA надёжно продолжает исходный поиск; ошибки текущей навигации сразу дают retry, а старые callbacks не повреждают новую попытку |
| 0.47.0 | #91: постоянное меню и нативное подтверждение явно снимают дело с отслеживания; поздние refresh/FSSP callbacks не восстанавливают удалённую запись |
| 0.47.1 | #81: latest-wins загрузка picker не позволяет запоздавшим гарнизонным судам заменить выбранное окружное, апелляционное или кассационное звено |
| 0.47.2 | #117: карточка суда больше не подменяет отсутствующий судебный акт; файловые акты Мосгорсуда показываются честными ссылками |
| 0.47.3 | #210: правая карточка поиска резервирует общую верхнюю полосу и больше не пересекается с глобальным поиском |
| 0.48.0 | #151: открытая карточка и каждая известная инстанция получили точную ссылку на соответствующую карточку суда без fallback на главную страницу |
| 0.49.0 | #213: файловые акты Мосгорсуда в DOC, DOCX и PDF проходят безопасное извлечение и входят в общий просмотр, поиск, Spotlight и AI-контур |
| 0.50.0 | #219: военный поиск больше не требует регион и не предлагает юридически невозможные апелляции на мировых судей; поля и картотеки задаются ветвью и звеном |
| 0.51.0 | #211: «Обзор» показывает номер производства конкретной инстанции у заседаний, событий и опубликованных актов |
| 0.52.0 | #220: регион и суд синхронизируются в обе стороны для субъектового, апелляционного и кассационного звена; ВС РФ и военный поиск остаются без региона |
| 0.53.0 | #110: CSV-импорт завершает работу единым прокручиваемым отчётом с provenance строк, scoped repair, CAPTCHA в том же окне и совместимым экспортом только проблемных записей |
| 0.53.1 | #207: CAPTCHA мировых судей использует ту же рабочую сетевую сессию и cookies, что поиск; скрытый WebView остаётся только у федеральных СОЮ |
| 0.53.2 | #164, этап 1: после принятого ручного кода реальная CAPTCHA мирового суда сохраняется только локально в проверенный SHA-256-корпус; Vision не отправляет коды `msudrf.ru` без отдельной допущенной модели |
| 0.53.3 | #88 + #89: автоматическая CAPTCHA КСОЮ проверяется до ручного fallback; карточка КСОЮ переносит опубликованные этапы жалобы; SUDRF-запросы идут через одну FIFO и не держат больше одного origin; при временно недоступной базовой карточке refresh продолжает вышестоящие цели по сохранённому УИД |
| 0.53.4 | #132: после принятия жалобы КСОЮ показывает присвоенный номер производства 88/88а или 77/77У; сырой номер, URL, identity и навигация не меняются |
| 0.54.0 | #90 + #130: реальная активная карточка КСОЮ по делу КоАП получает отдельную стадию «Надзор» и активное звено «Кассационный суд»; в ГПК/КАС/УПК КСОЮ и судебные коллегии ВС РФ остаются «Кассацией», а редкий Президиум ВС РФ — отдельным «Надзором» |
| 0.55.0 | #94: регистрации одного дела в том же суде объединяются по УИД и официальной ссылке на предыдущую регистрацию; история сохраняет точные карточки, акты и обжалования без tracked-дубликата |
| 0.55.1 | #74: связанные материалы показывают собственное опубликованное движение; временная ошибка карточки сохраняет строку материала и последний успешный кэш |
| 0.56.0 | #92: дело, вышестоящую карточку или материал федерального суда можно добавить в «Мои дела» по прямой ссылке после неперсистентной проверки реквизитов; обычные repair и refresh связывают якорь с логическим делом |
| 0.56.1 | #56: кассация текущего процессуального круга больше не создаёт ложный срок апелляции; недатированный пересмотр не завершает дело и не перебивает датированную апелляцию |
| 0.56.2 | #248, частично: исторические КАС-карточки больше не отображаются как гражданские из-за старых технических `delo_id/new`; исходные параметры URL сохраняются для загрузки карточки |
| 0.57.0 | #70: единый generated registry подключает 66 правил из `Docs/legal-deadlines`; первые шесть typed bindings рассчитываются fail-closed с provenance, а подтверждённые, изменённые и исторические occurrences имеют раздельные status/lifecycle |
| 0.57.1 | #181, уровень 1: единый offline fixture contract проверяет реальные ответы SUDRF, КСОЮ, vintage SUDRF, `msudrf`, Мосгорсуда и ВС РФ от исходных байтов до `CaseMovement`/`SourceAttempt`; отсутствующие реальные captures остаются видимыми пробелами матрицы |
| 0.57.2 | #155 + #181, уровень 2: полный успешный refresh пишет доказанные изменения в append-only shadow-журнал `CaseEvent`; реальные SUDRF, КСОЮ и `msudrf` fixtures проверяют semantic diff, а текущая лента остаётся прежней до #179 |
| 0.57.3 | Неработающие ссылки импортированных дел федеральных судов SUDRF восстанавливаются по проверенным параметрам картотеки либо точному поиску в том же суде; временные ошибки не заменяют адрес и не стирают последний успешный кэш |
| 0.57.4 | #239: краткое название дела КоАП выбирает привлекаемое лицо по опубликованной роли, сохраняя защитника и остальных участников в полной карточке; старые снимки исправляются из сохранённого движения без сети |
| 0.57.5 | #265: карточка жалобы КоАП сохраняет опубликованные результат и дату рассмотрения без строки судебного УИД; завершённые производства уходят из активного «Надзора», а неоднозначные реквизиты остаются fail-closed |

| 0.57.6 | #269: точные апелляционные и кассационные карточки, найденные по УИД, объединяют отдельные досье при подготовке хранилища и частичном обновлении; живая приёмка подтвердила обе пары КоАП, 3 строки надзора вместо 5 и сохранность данных |

| 0.57.7 | #271: восстановление узнаёт принятый номер в полном составном заголовке КСОЮ; живая проверка восстановила 17 из 18 карточек со скриншота, включая четыре контрольные; у 2-770/2019 остаётся неполная выдача, общий refresh восстановленных досье частичный из-за других источников |

Завершённый AI-фундамент: `S6-0A/B`, `DATA-1`, `SPOT-2`, `INTENT-3`, `AI-4` и
`SUMMARY-5`. Реализация и критерии сохранены в
[истории roadmap](roadmap-history.md) и [AI benchmark](AI-BENCHMARK.md).

Таблица начинается с первого сохранённого release changelog — 0.3.0. Подробные
заметки каждой версии остаются в [`changelog/`](../changelog/).

## Очередь

После merge #271 остаются
**55 открытых issues**, все распределены
ниже. Ссылки ведут к подробным критериям приёмки. Закрытые issues упоминаются только
как выполненные основания или reference cases, а не как открытые задачи.

Приоритет читается сверху вниз; независимая приёмка может идти параллельно.
`→` обозначает техническую зависимость, `+` — независимые задачи общего направления.
После каждого merge перепроверяются prerequisites: сначала P1 и достоверность данных,
затем короткие заметные исправления и более крупные продуктовые линии.

### Текущая незавершённая работа


- **Восстановление ссылок после импорта / [#248](https://github.com/arvidsever/Sudrf/issues/248)** — реализация выпущена в 0.57.3;
  до закрытия остаётся массовая приёмка последней импортированной подборки с
  окончательным подсчётом восстановленных адресов и отказов. Подробная проверка
  сохранена в [handoff ветки](branch-changelogs/codex/import-card-recovery/v0.57.3.md).
  Это часть #248, а не завершение всего импорта.
  `MDB_MAP_FULL` исключён: причинная связь не подтверждена.

- **Отдельное наблюдение запуска:** до открытия исправленных карточек общий счётчик
  изменился 544 → 481, КАС — 230 → 167. Это не результат #265 и не часть массовой
  приёмки #248; причина требует отдельного сопоставления записей до и после запуска.

### 1. Ближайшие исправления: P1, затем короткие задачи

- **[#260](https://github.com/arvidsever/Sudrf/issues/260) (P1)** — строгая проверка TLS в production, включая CAPTCHA и отсутствие
  скрытого downgrade на HTTP. Bundled roots остаются дополнительными trust anchors.
- **[#261](https://github.com/arvidsever/Sudrf/issues/261) (P1)** — повторяющиеся occurrences событий и полный rollback при ошибке
  журнала до commit. Shadow-журнал уже находится на пути обычного refresh.
- **[#263](https://github.com/arvidsever/Sudrf/issues/263)** — точная связь акта с инстанцией имеет приоритет над совпадением уровня;
  исправить сохранённые реквизиты без потери документа, текста и связанной сводки.
- **[#257](https://github.com/arvidsever/Sudrf/issues/257)** — заседания связанных материалов в «Обзоре» из той же нормализованной
  модели, что и календарь; не ждать [#179](https://github.com/arvidsever/Sudrf/issues/179) и не создавать второй diff-путь.
- **[#233](https://github.com/arvidsever/Sudrf/issues/233)** — устранить публикации во время SwiftUI view update при смене судов,
  сохранив latest-wins; проверить вместе с [#230](https://github.com/arvidsever/Sudrf/issues/230).
- **[#45](https://github.com/arvidsever/Sudrf/issues/45)** — восстановить оформление однострочных актов с сохранением контракта
  paragraphizer version и цитат. Это обычный рендеринг, AI-генерации не требует.

### 2. Материалы и процессуальные состояния

- **[#247](https://github.com/arvidsever/Sudrf/issues/247) → [#246](https://github.com/arvidsever/Sudrf/issues/246)** — отдельно представлять тип регистрации «материал» и вид
  производства; после доказанного перехода к принятому делу выбирать актуальный
  номер и lifecycle, сохраняя прежнюю регистрацию. Классификация нужна и [#222](https://github.com/arvidsever/Sudrf/issues/222).
- **[#256](https://github.com/arvidsever/Sudrf/issues/256)** — опубликованные истребование дела и итог КСОЮ по КоАП включать в движение
  с датами источника, без выдуманных событий и дублей.
- **[#86](https://github.com/arvidsever/Sudrf/issues/86)** — effective legal-force status после рассмотрения жалобы по КоАП;
  использовать завершённый lifecycle foundation [#56](https://github.com/arvidsever/Sudrf/issues/56), сверить результат с [#256](https://github.com/arvidsever/Sudrf/issues/256).

### 3. Обновление, импорт и источники

- **[#237](https://github.com/arvidsever/Sudrf/issues/237)** — частично реализовано в 0.53.3: обход вышестоящих целей по сохранённому
  УИД при временной недоступности базовой карточки. Issue остаётся открытым:
  проверить все failure/CAPTCHA/partial paths, независимое сохранение успешных
  источников и отсутствие продления TTL полного успеха; устранить остаточные пробелы.
- **[#238](https://github.com/arvidsever/Sudrf/issues/238)** — использовать сохранённые точные URL вышестоящих карточек независимо
  от доступности поиска; discovery по УИД сохранить. Дополняет [#237](https://github.com/arvidsever/Sudrf/issues/237).
- **[#87](https://github.com/arvidsever/Sudrf/issues/87)** — фоновое обнаружение новых вышестоящих производств; после него
  **[#156](https://github.com/arvidsever/Sudrf/issues/156) + [#76](https://github.com/arvidsever/Sudrf/issues/76)** добавляют registry `r_juid` и правильную маршрутизацию как evidence.
  **[#104](https://github.com/arvidsever/Sudrf/issues/104)** использует [#87](https://github.com/arvidsever/Sudrf/issues/87) и выполненный [#56](https://github.com/arvidsever/Sudrf/issues/56) для привязки производств ВС РФ.
- **[#165](https://github.com/arvidsever/Sudrf/issues/165)** — прямой уголовный поиск ВС РФ поднимается сразу после получения
  конкретного номера и HTML-fixture; [#76](https://github.com/arvidsever/Sudrf/issues/76) — соседняя регрессия, а не блокер.
- **[#250](https://github.com/arvidsever/Sudrf/issues/250)** — проверка связей импорта с определённым прогрессом, продолжением в фоне
  и приоритетом интерактивных запросов в существующей очереди. Согласовать с текущим
  восстановлением ссылок; отдельный scheduler не нужен.
- **[#248](https://github.com/arvidsever/Sudrf/issues/248)** — частично: 0.56.2 исправила классификацию исторических КАС-карточек;
  0.57.3 добавила восстановление федеральных SUDRF-ссылок, 0.57.7 — составные номера КСОЮ. Остаются полная
  приёмка vintage URL, импорт через существующие клиенты Мосгорсуда, `msudrf`, ВС РФ
  и поддержка мировых Москвы/СПб. Issue закрывается только после проверки всех семейств.
- **[#164](https://github.com/arvidsever/Sudrf/issues/164)** — этап 1 уже собирает принятые судом ручные CAPTCHA-пары. Следующий этап
  ждёт 500 уникальных картинок минимум с трёх host и независимый eligibility-gate;
  существующий session-flow [#207](https://github.com/arvidsever/Sudrf/issues/207) переиспользуется без второго сетевого решения.
- **[#106](https://github.com/arvidsever/Sudrf/issues/106) → [#108](https://github.com/arvidsever/Sudrf/issues/108) → [#107](https://github.com/arvidsever/Sudrf/issues/107)** — московский источник мировых по проверенному reference,
  общий routing, затем СПб. Основания [#88](https://github.com/arvidsever/Sudrf/issues/88), этап 1 [#164](https://github.com/arvidsever/Sudrf/issues/164) и level-1 fixtures [#181](https://github.com/arvidsever/Sudrf/issues/181) готовы;
  новые источники разблокируют соответствующие части [#248](https://github.com/arvidsever/Sudrf/issues/248), существующие их не ждут.
- **[#68](https://github.com/arvidsever/Sudrf/issues/68) + [#65](https://github.com/arvidsever/Sudrf/issues/65)** — диагностика источников и независимый live canary.
  **[#180](https://github.com/arvidsever/Sudrf/issues/180)** начинается с измерений [#87](https://github.com/arvidsever/Sudrf/issues/87) и host-health instrumentation [#68](https://github.com/arvidsever/Sudrf/issues/68) на 200+ делах;
  новый scheduler допустим лишь при подтверждённом starvation/лишней нагрузке.
  Полный Diagnostics UI и [#65](https://github.com/arvidsever/Sudrf/issues/65) не являются техническими блокерами этих измерений.

### 4. Журнал и пользовательские проекции

- Завершённые **[#155](https://github.com/arvidsever/Sudrf/issues/155) + [#181](https://github.com/arvidsever/Sudrf/issues/181)** дали shadow-журнал и два уровня fixture contract.
  Непокрытые реальные captures остаются явными пробелами матрицы; синтетические
  примеры их не заменяют. Исчезновение или неоднозначная перезапись строки остаются
  диагностикой, а не пользовательским событием. Его стабилизация не завершена: **[#261](https://github.com/arvidsever/Sudrf/issues/261) + [#262](https://github.com/arvidsever/Sudrf/issues/262) → [#179](https://github.com/arvidsever/Sudrf/issues/179)**.
- **[#262](https://github.com/arvidsever/Sudrf/issues/262)** — полезный partial-кэш не должен продвигать обработанный semantic baseline
  и терять изменения; baseline и журнал должны переживать relaunch согласованно.
- **[#179](https://github.com/arvidsever/Sudrf/issues/179)** — после исправлений и фактической shadow-сверки перевести ленту,
  уведомления и badges на единый журнал без повторных уведомлений.
- **[#179](https://github.com/arvidsever/Sudrf/issues/179) → [#93](https://github.com/arvidsever/Sudrf/issues/93) + [#101](https://github.com/arvidsever/Sudrf/issues/101) + [#133](https://github.com/arvidsever/Sudrf/issues/133)** — движение жалоб в общем event/feed contract,
  стороны и суд в уведомлениях, понятные названия дел в центральных панелях «Обзора».
- **[#148](https://github.com/arvidsever/Sudrf/issues/148)** — односторонняя проекция в Apple Calendar после event identity и
  deadline semantics; правка `EKEvent` не меняет судебное состояние.
- **[#149](https://github.com/arvidsever/Sudrf/issues/149)** — backend/APNs после проверенного event contract, базовой надёжности
  источников и refresh-health измерений. Apple Calendar технически не блокирует.

### 5. Юридические сроки

- Завершённые **[#56](https://github.com/arvidsever/Sudrf/issues/56) + [#70](https://github.com/arvidsever/Sudrf/issues/70)** позволяют активировать оставшиеся typed rules **[#222](https://github.com/arvidsever/Sudrf/issues/222)**
  поверх полного registry. Это не равнозначно завершению всей пользовательской функции.
- **[#224](https://github.com/arvidsever/Sudrf/issues/224)** — единый исторический LegalCalendar 2002+; **[#129](https://github.com/arvidsever/Sudrf/issues/129)** — месяцы и годы,
  **[#111](https://github.com/arvidsever/Sudrf/issues/111)** — нерабочие дни и перенос окончания, **[#125](https://github.com/arvidsever/Sudrf/issues/125)** — различение решения и
  определения с правильной counting policy. Календарные политики используют [#224](https://github.com/arvidsever/Sudrf/issues/224),
  а не локальные списки праздников; арифметику можно проверять независимо.
- Полная приёмка **[#222](https://github.com/arvidsever/Sudrf/issues/222)** требует [#224](https://github.com/arvidsever/Sudrf/issues/224), [#129](https://github.com/arvidsever/Sudrf/issues/129), [#111](https://github.com/arvidsever/Sudrf/issues/111) и [#125](https://github.com/arvidsever/Sudrf/issues/125), объяснения расчёта в UI
  и сохранения ручных корректировок. **[#223](https://github.com/arvidsever/Sudrf/issues/223)** — отдельный registry и отображение
  сроков рассмотрения с тем же календарём и проверенной арифметикой.
- **[#128](https://github.com/arvidsever/Sudrf/issues/128)** — итоговая регрессия: без доказанного итогового акта срок апелляции
  не появляется. Закрытый [#80](https://github.com/arvidsever/Sudrf/issues/80) остаётся negative fixture и live acceptance case.

### Параллельная системная и визуальная приёмка

- **[#264](https://github.com/arvidsever/Sudrf/issues/264)** — обязательный gate перед следующим изменением схемы: установить реальные
  исторические модели V1/V2 и проверить upgrade соответствующих stores. Риск подтверждён
  по декларациям схем; сбой конкретной старой базы пока не воспроизведён.
- **[#46](https://github.com/arvidsever/Sudrf/issues/46) + [#186](https://github.com/arvidsever/Sudrf/issues/186) → [#66](https://github.com/arvidsever/Sudrf/issues/66) (APPLE-6)** — cold-start App Intents, Spotlight identity
  Debug/Developer ID, clean install/upgrade, recovery и независимые системные сценарии.
  Отложенные AI-проверки остаются непроверенными; [#66](https://github.com/arvidsever/Sudrf/issues/66) целиком не закрывать преждевременно.
- **[#69](https://github.com/arvidsever/Sudrf/issues/69)** — notary credentials, submission, stapling и production release workflow;
  TestFlight не заменяет Developer ID/notarization.
- **[#182](https://github.com/arvidsever/Sudrf/issues/182)** — остаточная визуальная приёмка: карточки [#85](https://github.com/arvidsever/Sudrf/issues/85)/[#102](https://github.com/arvidsever/Sudrf/issues/102), экран поиска, узкое окно
  1180 pt и настройки 720 pt. Выполняется независимо от архитектурной очереди.
- **[#215](https://github.com/arvidsever/Sudrf/issues/215)** — отложенная пользовательская visual QA исправления [#210](https://github.com/arvidsever/Sudrf/issues/210): обычная карточка,
  движение дела, глобальный поиск и resize 1180/1280 pt; основной merge не блокирует.
- **[#217](https://github.com/arvidsever/Sudrf/issues/217)** — отложенная пользовательская visual QA ссылок [#151](https://github.com/arvidsever/Sudrf/issues/151): шапка дела,
  точные ссылки инстанций, отсутствие fallback и узкая ширина; основной merge не блокирует.
- **[#221](https://github.com/arvidsever/Sudrf/issues/221)** — отложенная пользовательская visual QA файловых актов [#213](https://github.com/arvidsever/Sudrf/issues/213): несколько
  вложений, переключение, оригиналы и понятный fallback при ошибке; основной merge не блокирует.
- **[#226](https://github.com/arvidsever/Sudrf/issues/226)** — отложенная пользовательская visual QA военного поиска [#219](https://github.com/arvidsever/Sudrf/issues/219): скрытый
  регион, допустимые картотеки GV/OV/AV/KV и возврат к общей ветви; основной merge не блокирует.
- **[#228](https://github.com/arvidsever/Sudrf/issues/228)** — отложенная пользовательская visual QA [#211](https://github.com/arvidsever/Sudrf/issues/211): узкие колонки «Обзора»,
  длинные номера и разные исторические инстанции; основной merge не блокирует.
- **[#230](https://github.com/arvidsever/Sudrf/issues/230)** — отложенная пользовательская visual QA [#220](https://github.com/arvidsever/Sudrf/issues/220): двусторонний выбор региона
  и суда, очистка на ВС РФ и узкое окно; основной merge не блокирует.
- **[#241](https://github.com/arvidsever/Sudrf/issues/241)** — живая проверка 3 КСОЮ после [#88](https://github.com/arvidsever/Sudrf/issues/88)/[#89](https://github.com/arvidsever/Sudrf/issues/89): флапающие страницы техработ,
  точная ссылка карточки, опубликованный акт и сохранение последнего успешного снимка;
  основной merge не блокирует.

### Отложенные AI-задачи

Решение автора от **8 сентября 2026 года**: генерация сводок и другие AI-функции
по делу отложены до появления подходящего проверенного способа генерации.
Это не относится к CAPTCHA/OCR, обычному просмотру актов, Spotlight, App Intents
и независимым проверкам хранения данных.

- **[#43](https://github.com/arvidsever/Sudrf/issues/43)** — отмена устаревшей генерации при refresh; вернуться вместе с AI-генерацией.
- **[#43](https://github.com/arvidsever/Sudrf/issues/43) → [#67](https://github.com/arvidsever/Sudrf/issues/67)** — выделение live-case session также отложено, чтобы не переносить
  известную гонку в новый компонент. Persistence prerequisites [#44](https://github.com/arvidsever/Sudrf/issues/44)/[#64](https://github.com/arvidsever/Sudrf/issues/64) уже выполнены.
- **CASEAI-7** — после выбора и проверки способа генерации, [#43](https://github.com/arvidsever/Sudrf/issues/43), APPLE-6,
  event journal и rules engine: сводки изменений, retrieval, digest и command bar.
- AI-зависимая часть **PUBLIC-8** остаётся отложенной; общий gate сохраняет
  завершённые CASEAI-7/APPLE-6, production Developer ID/notarization и backend/APNs.
  BYOK сохраняется; cloud требует proxy, квот, privacy/legal review и отсутствия
  хранения текстов судебных актов. Независимые работы [#69](https://github.com/arvidsever/Sudrf/issues/69) и [#149](https://github.com/arvidsever/Sudrf/issues/149) продолжаются по своим prerequisites.

## Правила ведения

### Источник правды

- Текущие приоритеты, статусы и решения живут только в этом файле.
- [`Docs/roadmap-history.md`](roadmap-history.md) — versioned audit trail, а не второй план.
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
