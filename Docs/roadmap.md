# Sudrf roadmap

> Единственный актуальный план работ. Подробная история вынесена в
> [`Docs/roadmap-history.md`](roadmap-history.md); она не задаёт текущие приоритеты.

## Сделано

Текущий baseline: **main 0.58.11**, build 181. Последняя зафиксированная полная локальная
проверка приложения — в 0.58.10: 1338 XCTest (5 штатных пропусков) и 28 Swift Testing,
сборка и живая приёмка Xcode 27; CI того выпуска проверил тесты и упаковку на macOS 26.
Документационная правка 0.58.11 не сопровождалась новым локальным запуском Swift/Xcode.
Полный registry сроков обжалования подключён; оставшиеся typed rules относятся к #222.

### Последние результаты

- **0.58.11 / PR [#297](https://github.com/arvidsever/Sudrf/pull/297):** исправлена нормативная [карта маршрутов КоАП](legal-deadlines/koap-appeal-routes.md): исключена вымышленная первая инстанция областного звена, разграничены мировая и общая ветви пересмотра после 10.05.2026, исправлены связанные правила. Выполнены 13 структурных проверок документа; Git blob совпал с локальным файлом. Это reference, не изменение runtime; #222/#223 не закрываются.
- **0.58.10 / #291:** восстановлен поиск апелляций КАС/УПК/ГПК из суда субъекта и окружного/флотского военного суда, точные URL и проверка кандидатов. В приложении приняты КАС-обновление и перезапуск, уголовные поиск и открытие без акта. Военное UID-связывание покрыто тестами; живой пример не публикует УИД. PR [#296](https://github.com/arvidsever/Sudrf/pull/296) влит; кассационная часть #76 остаётся.

- **0.58.9 / PR [#295](https://github.com/arvidsever/Sudrf/pull/295):** исправлена нормативная [карта маршрутов КАС](legal-deadlines/kas-appeal-routes.md): обычная районная и специальная избирательная кассация разграничены, вымышленная первая инстанция АСОЮ/КСОЮ исключена, учтена реформа кассации мировых актов с 10.05.2026. Проверены структура Markdown, ссылки-идентификаторы и совпадение Git blob с локальным файлом. Runtime и остальные три справки не изменены; #222/#223 не закрываются.
- **0.58.8 / #256:** полная опубликованная хронология жалоб КоАП КСОЮ, согласование результатов и три вида событий shadow-журнала. Четыре строки 16-2038/2023 и перезапуск проверены; PR [#293](https://github.com/arvidsever/Sudrf/pull/293) влит.

- **0.58.7 / #284:** принятое дело КАС показывает подтверждённый номер 2а/3а; прежние номера доступны поиску, отдельная предыдущая регистрация сохраняется. Три М-регистрации и перезапуск проверены. PR [#292](https://github.com/arvidsever/Sudrf/pull/292) влит.
- **0.58.6 / #45:** единое оформление коротких и длинных однострочных актов; старые снимки переразбиты, несовместимые цитаты прежних сводок отключены. Проверены откат на macOS 26, Xcode 27, 27-страничный PDF и перезапуск с 468 делами. PR [#283](https://github.com/arvidsever/Sudrf/pull/283) влит.
- **0.58.5 / #273:** события материалов подписаны собственным номером в обеих лентах и календаре; точный переход, совместимость прочитанности и перезапуск проверены. PR [#282](https://github.com/arvidsever/Sudrf/pull/282) влит.
- **0.58.4 / #233:** пять фильтров поиска применяются после выхода из SwiftUI handler; пройдены профильные и полные тесты, Xcode 27 build и живая приёмка.
- **0.58.3 / #261:** граница refresh, сроков, CAPTCHA и слияния стала атомарной; #262 и переход #179 остаются отдельными.
- **0.58.2 / #263:** точная связь акта с инстанцией имеет приоритет над совпадением уровня.
- **0.58.1 / #133:** названия дел добавлены в сроки и обе ленты «Обзора» без зависимости от #179.

Полный реестр выпусков и доказательная история — в [roadmap-history](roadmap-history.md) и [`changelog/`](../changelog/).

## Очередь

Все открытые GitHub Issues распределены ниже как активные, зависимые или отложенные.
Сверка после #291: 57 открытых issues на 12 сентября 2026 года, каждая учтена в очереди.
Ссылки ведут к подробным критериям приёмки. Закрытые issues упоминаются только
как выполненные основания или reference cases, а не как открытые задачи.

Приоритет читается сверху вниз; независимая приёмка может идти параллельно.
`→` обозначает техническую зависимость, `+` — независимые задачи общего направления.
После каждого merge перепроверяются prerequisites: сначала P1 и достоверность данных,
затем короткие заметные исправления и более крупные продуктовые линии.

### Срочная конкретная регрессия сроков

- **[#294](https://github.com/arvidsever/Sudrf/issues/294)** — диагностировать отсутствие специальных сроков обжалования по четырём избирательным делам `3а-682/683/684/685/2026`: различить решение и определение, проверить основание, сохранение и видимость срока. Адресная приёмка #222/#125; не требует окончания всей инвентаризации правил или перехода на журнал. Причина пока не установлена.

### 1. Материалы и процессуальные состояния

- **[#247](https://github.com/arvidsever/Sudrf/issues/247) → [#246](https://github.com/arvidsever/Sudrf/issues/246)** — отдельно представлять тип регистрации «материал» и вид
  производства; после доказанного перехода к принятому делу выбирать актуальный
  номер и lifecycle, сохраняя прежнюю регистрацию. Общий механизм подтверждения,
  атомарного переякоривания и поиска прежних номеров выполнен для КАС в #284;
  гражданское расширение #246 и его приёмка, включая #288, остаются. Классификация нужна и [#222](https://github.com/arvidsever/Sudrf/issues/222).
- **[#86](https://github.com/arvidsever/Sudrf/issues/86)** — effective legal-force status после рассмотрения жалобы по КоАП;
  использовать завершённый lifecycle foundation [#56](https://github.com/arvidsever/Sudrf/issues/56) и выполненную хронологию [#256](https://github.com/arvidsever/Sudrf/issues/256); статус законной силы ею не исправлен.
- **[#275](https://github.com/arvidsever/Sudrf/issues/275) + [#276](https://github.com/arvidsever/Sudrf/issues/276)** — отдельно проверить lifecycle возвращённой жалобы 8Г-162/2019 и загрузку её связанной цепочки.
- **[#285](https://github.com/arvidsever/Sudrf/issues/285) + [#286](https://github.com/arvidsever/Sudrf/issues/286) + [#289](https://github.com/arvidsever/Sudrf/issues/289)** — диагностировать активные апелляции после итогового постановления УПК, изменения постановления КоАП и снятия с рассмотрения. Сначала подтвердить полный результат источника; общую причину заранее не предполагать. Историю и отдельные активные производства сохранять.
- **[#288](https://github.com/arvidsever/Sudrf/issues/288)** — установить новую регистрацию дела Беляева `9-727/2020`; конкретный гражданский кейс для #246, без автоматического закрытия после КАС-исправления #284.

### 2. Обновление, импорт и источники

- **[#287](https://github.com/arvidsever/Sudrf/issues/287) + [#290](https://github.com/arvidsever/Sudrf/issues/290)** — восстановить подтверждённые нижестоящие карточки для `88-18789/2020` и `22-227/2020`; диагностика цепочки отделена от определения стадии #289.
- **[#237](https://github.com/arvidsever/Sudrf/issues/237)** — частично реализовано в 0.53.3: обход вышестоящих целей по сохранённому
  УИД при временной недоступности базовой карточки. Issue остаётся открытым:
  проверить все failure/CAPTCHA/partial paths, независимое сохранение успешных
  источников и отсутствие продления TTL полного успеха; устранить остаточные пробелы.
- **[#238](https://github.com/arvidsever/Sudrf/issues/238)** — использовать сохранённые точные URL вышестоящих карточек независимо
  от доступности поиска; discovery по УИД сохранить. Дополняет [#237](https://github.com/arvidsever/Sudrf/issues/237).
- **[#87](https://github.com/arvidsever/Sudrf/issues/87)** — фоновое обнаружение новых вышестоящих производств; после него
  **[#156](https://github.com/arvidsever/Sudrf/issues/156) + [#76](https://github.com/arvidsever/Sudrf/issues/76)** добавляют registry `r_juid` и правильную маршрутизацию как evidence.
  Апелляционная часть #76 для общих и военных судов выполнена в #291; остаются следующий кассационный маршрут и его приёмка, включая недопустимость территориального КСОЮ для соответствующего уголовного дела суда субъекта.
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
  ждёт 500 уникальных картинок минимум с трёх host и независимого eligibility-gate;
  существующий session-flow [#207](https://github.com/arvidsever/Sudrf/issues/207) переиспользуется без второго сетевого решения.
- **[#106](https://github.com/arvidsever/Sudrf/issues/106) → [#108](https://github.com/arvidsever/Sudrf/issues/108) → [#107](https://github.com/arvidsever/Sudrf/issues/107)** — московский источник мировых по проверенному reference,
  общий routing, затем СПб. Основания [#88](https://github.com/arvidsever/Sudrf/issues/88), этап 1 [#164](https://github.com/arvidsever/Sudrf/issues/164) и level-1 fixtures [#181](https://github.com/arvidsever/Sudrf/issues/181) готовы;
  новые источники разблокируют соответствующие части [#248](https://github.com/arvidsever/Sudrf/issues/248), существующие их не ждут.
- **[#68](https://github.com/arvidsever/Sudrf/issues/68) + [#65](https://github.com/arvidsever/Sudrf/issues/65)** — диагностика источников и независимый live canary.
  **[#180](https://github.com/arvidsever/Sudrf/issues/180)** начинается с измерений [#87](https://github.com/arvidsever/Sudrf/issues/87) и host-health instrumentation [#68](https://github.com/arvidsever/Sudrf/issues/68) на 200+ делах;
  новый scheduler допустим лишь при подтверждённом starvation/лишней нагрузке.
  Полный Diagnostics UI и [#65](https://github.com/arvidsever/Sudrf/issues/65) не являются техническими блокерами этих измерений.

### 3. Журнал и пользовательские проекции

- Завершённые **[#155](https://github.com/arvidsever/Sudrf/issues/155) + [#181](https://github.com/arvidsever/Sudrf/issues/181)** дали shadow-журнал и два уровня fixture contract.
  Непокрытые реальные captures остаются явными пробелами матрицы; синтетические
  примеры их не заменяют. Исчезновение или неоднозначная перезапись строки остаются
  диагностикой, а не пользовательским событием. Повторные occurrences и rollback [#261](https://github.com/arvidsever/Sudrf/issues/261) исправлены в 0.58.3; до перехода
  остаётся **[#262](https://github.com/arvidsever/Sudrf/issues/262) → [#179](https://github.com/arvidsever/Sudrf/issues/179)**.
- **[#262](https://github.com/arvidsever/Sudrf/issues/262)** — полезный partial-кэш не должен продвигать обработанный semantic baseline
  и терять изменения; baseline и журнал должны переживать relaunch согласованно.
- **[#179](https://github.com/arvidsever/Sudrf/issues/179)** — после исправлений и фактической shadow-сверки перевести ленту,
  уведомления и badges на единый журнал без повторных уведомлений.
  При переходе проверить одинаковые события разных предыдущих регистраций первой
  инстанции: прежние идентификаторы ленты не различают их по карточке источника.
  #284 сохраняет этот формат и прочитанность; отдельную миграцию идентичности событий не вводит.
- **[#179](https://github.com/arvidsever/Sudrf/issues/179) → [#93](https://github.com/arvidsever/Sudrf/issues/93) + [#101](https://github.com/arvidsever/Sudrf/issues/101)** — движение жалоб в общем event/feed contract,
  стороны и суд в уведомлениях.
- Выпущенные #133 и #273 не зависят от #179; системные уведомления [#101](https://github.com/arvidsever/Sudrf/issues/101) сохраняют отдельную приёмку.
- **[#148](https://github.com/arvidsever/Sudrf/issues/148)** — односторонняя проекция в Apple Calendar после event identity и
  deadline semantics; правка `EKEvent` не меняет судебное состояние.
- **[#149](https://github.com/arvidsever/Sudrf/issues/149)** — backend/APNs после проверенного event contract, базовой надёжности
  источников и refresh-health измерений. Apple Calendar технически не блокирует.

### 4. Юридические сроки

- Нормативная [карта маршрутов КоАП](legal-deadlines/koap-appeal-routes.md), PR #297: суд субъекта не является первоначальным судом по делу о правонарушении; мировая ветвь после 10.05.2026 идёт в суд субъекта по ч. 1.1 ст. 30.13, с переходом по дате подачи жалобы. Справка не активирует эти правила в приложении; непроверенные специальные маршруты не автоматизировать.
- Нормативная [карта маршрутов КАС](legal-deadlines/kas-appeal-routes.md), исправленная в PR #295, — reference для будущей маршрутизации, а не подтверждение изменения runtime. Для прямой избирательной кассации требуется конкретный пункт 7–11 ч. 1 ст. 20; районное происхождение дела сохраняет КСОЮ. Первую инстанцию АСОЮ/КСОЮ не моделировать. Ветка мировых актов учитывает реформу и переходные правила 10.05.2026; открытые текстовые вопросы перечислены в справке.
- Завершённые **[#56](https://github.com/arvidsever/Sudrf/issues/56) + [#70](https://github.com/arvidsever/Sudrf/issues/70)** позволяют активировать оставшиеся typed rules **[#222](https://github.com/arvidsever/Sudrf/issues/222)**
  поверх полного registry. Это не равнозначно завершению всей пользовательской функции.
- **[#224](https://github.com/arvidsever/Sudrf/issues/224)** — в 0.58.0 реализован и принят федеральный LegalCalendar 2013–2026 с расчётом и UI. [Источники и обновление](legal-calendar.md), [проверки](../changelog/changelog-v0.58.00.md). Годы до 2013, региональные особенности и исторические редакции процессуальных норм остаются последующими этапами; issue не закрывается. **[#129](https://github.com/arvidsever/Sudrf/issues/129)** — месяцы и годы,
  **[#111](https://github.com/arvidsever/Sudrf/issues/111)** — федеральные нерабочие дни и перенос окончания подключены в 0.58.0 (#224); полная приёмка и региональные исключения остаются, **[#125](https://github.com/arvidsever/Sudrf/issues/125)** — различение решения и
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

### Явно отложено

- **[#260](https://github.com/arvidsever/Sudrf/issues/260) (P1)** — строгая TLS-проверка в production, включая CAPTCHA и запрет скрытого downgrade на HTTP. Задача остаётся P1, но автор явно исключил её из ближайшей очереди; не предлагать её повторно до нового решения автора. Bundled roots остаются дополнительными trust anchors.

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
