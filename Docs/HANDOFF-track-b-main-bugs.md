# Handoff: Track B — баги `main` (не относящиеся к captcha-солверу)

> Обновлено: 2026-07-12. Track B практически закрыт (релизы до `v0.39.33`).
> Открыт **один** пункт — Security (TLS). Документ сохранён как история решений.

## Статус (сверено построчно с `main` на `19e4677`, v0.39.33)

- **High — все закрыты ✅:** B5 (PR #24), B6 (PR #25), B2 (PR #26),
  B3 (PR #28, `actsFingerprint` в снимке), B7 (PR #31, голый маркер `ЛИЦА:`).
- **Low — все 15 закрыты ✅** (PR #27, `Harden low-severity edge cases`).
- **Medium — все 16 разрешены** (BM7 закрыт ранее в A16):
  - **Исправлены (12):** BM1, BM2, BM5, BM6, BM8, BM9, BM10, BM12, BM13, BM14,
    BM15, BM17 (PR #29–32; см. `changelog-v0.39.30`…`v0.39.33`).
  - **Не баги — закрыты тестами (4):** BM3, BM4, BM11, BM16. Проверка на реальных
    данных показала, что заявленный дефект не воспроизводится; корректное
    поведение зафиксировано регрессиями (напр. фикстура `kirov_koap` → `.koap`
    для BM4; `MagistrateTests.searchURL` для BM3; `CalendarWeekLayoutTests` для
    BM16; `DistrictResolverTests` для BM11). Кода не меняем.
- **Security (TLS soft-accept) — ⬜ ОТКРЫТ, решение за owner’ом:**
  `SudrfClient.swift` — `mos-gorsud.ru` всё ещё в `trustedSuffixes` (:464),
  результат `SecTrustEvaluateWithError` отбрасывается (:493). Сузить soft-accept
  строго до `*.sudrf.ru`-суффиксов, а для `mos-gorsud.ru` включить штатную
  проверку. Поведенческое изменение TLS → обсудить риск для винтажных цепочек.

**Дальнейший шаг: только пункт Security (TLS) — ждёт решения owner’а.**

## Контекст

PR #6 (on-device captcha-solver) **смёржен в `main`**, релиз `v0.39.29` (build 73),
merge-commit `7f20e96`. По ходу adversarial-ревью выявлены баги, которые **НЕ
относятся к солверу** — это пред-существующие дефекты `main`. Их сознательно
вынесли из PR #6, чтобы не раздувать diff. Это и есть **Track B**: чинить
отдельными PR от `main`.

**7 High-severity подтверждены построчно** в исходной сессии; Medium/Low —
кредибельны, но перед фиксом их надо верифицировать. `BM7` (merge восстанавливал
лишь одну инстанцию домена) уже закрыт попутно в A16 при работе над солвером —
в списке ниже его нет.

## Как работать (конвенции репозитория — обязательно)

- **Платформа:** SwiftPM-пакет `SudrfKit`, таргет **macOS 26**; ядро тянет cp1251
  из CoreFoundation → **на Linux не собирается**. Локально `swift build`/`swift test`
  только на macOS; иначе полагаться на **CI** (GitHub Actions: jobs `build-test` +
  `package-app`).
- **CoreML-модель:** не в git. CI и локальная сборка тянут её из релиза:
  `Scripts/fetch-model.sh model-v1` (проверка по `MODEL_MANIFEST.sha256`). Без
  модели captcha-CoreML тесты → `XCTSkip`. Track B модель почти не трогает.
- **Ветки/PR:** ветка на фикс (`codex/bN-...` или `claude/...`) от `main` → PR →
  merge. Один логический фикс = один PR. **Не** смешивать несколько багов в одном PR.
- **Changelog (`AGENTS.md` §Changelog):** новые заметки — в
  `Docs/branch-changelogs/<branch-slug>/vX.Y.Z.md` (прогнозная версия). **Не трогать**
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` в `project.yml`/`Scripts/make-app.sh`
  и финальные `changelog/changelog-v*.md` до merge/release. При релизе —
  материализовать черновик в финал и выставить версию (следующая — `0.39.30`+ для
  патчей, или `0.40.0` для рубежа; выбор за релизом).
- **Коммиты:** заканчивать трейлерами `Co-Authored-By: …` и `Claude-Session: <url>`.
  Не упоминать модель/внутренние идентификаторы в артефактах репо.
- **Merge в `main`** — за owner'ом. Тег/Release создаёт owner (у сессии git-доступ
  scoped на ветки, пуш тегов → 403).
- **Номера строк ниже — на момент `7f20e96`, ПРИМЕРНЫЕ.** Перед правкой всегда
  re-grep по символу (сигнатуре функции), не по номеру строки.

## Track B — задачи

### High (подтверждены построчно) — остаток: B7 → B3

- **B5 · ✅ СДЕЛАНО (PR #24) · [P1] ЯНАО → неверный кассационный суд.**
  `Sources/SudrfKit/CourtDirectory.swift` — `regionsMatch` (≈180-184):
  `return x.contains(y) || y.contains(x)` — двунаправленное вхождение подстроки;
  «ямалоненецкийавтономныйокруг» содержит «ненецкийавтономныйокруг» (Ненецкий АО,
  3 КСОЮ), скан 1→9 → ЯНАО резолвится в `3kas` вместо `7kas`. **Юридически критично.**
  *Фикс:* нормализованное сравнение с exact-root бонусом (образец — соседний
  `subjectNumericCode`, где уже решена коллизия сахалин/саха). *Тест:* ЯНАО→7kas,
  НАО→3kas, Сахалин↔Саха корректны.
- **B7 · ⬜ TODO · [P1] Третьи лица склеиваются в имя ответчика.**
  `Sources/SudrfKit/Parties.swift` — `rolePattern` (≈322-327) знает
  «третьи лица»/«заинтересованные лица», но НЕ голый лейбл «ЛИЦА:», который печатает
  `sud_delo` (сверено с самарской фикстурой) → ответчик «ФСИН России ЛИЦА:
  Рыжкова Е.А.», третье лицо теряется. *Фикс:* добавить альтернативу голого
  `лица`/`ЛИЦА` как роль «третьи лица» (длинные альтернативы раньше коротких). *Тест:*
  самарская фикстура → ответчик «ФСИН России» + отдельное третье лицо.
- **B3 · ⬜ TODO · [P1] Новые акты не дают уведомлений/бейджей.**
  `Sources/SudrfApp/MovementDerivation.swift` — `CaseSnapshot` (≈46-63) содержит
  `sessions`/`deadlines`, но **не `acts`**; детект изменений (сравнение снимков в
  `RefreshCenter`) не видит публикацию акта без новой сессии → `seenAt` не
  сбрасывается, запись «рождается прочитанной». *Фикс:* добавить в снимок отпечаток
  актов (`actsFingerprint: [String]` из id+date+title или хеш) и учесть в сравнении.
  *Тест:* снапшот меняется при добавлении акта.
- **B6 · ✅ СДЕЛАНО (PR #25) · [P1] Гарнизонные суды ломают резолв райсудов.**
  `Sources/SudrfKit/DistrictCourtResolver.swift` — субъект метится «загруженным»
  (`loadedSubjects`, ≈365) по цифрам классификационного кода любого кэш-суда;
  общенациональные военные harvests персистят суды без субъекта портала → на след.
  запуске субъект (напр. «66») считается загруженным, fetch портала пропускается,
  фильтр райсудов пуст для Свердловской обл. *Фикс:* не метить субъект загруженным по
  записям без субъекта портала (гарнизонные/военные). *Тест:* после военного harvest
  субъект «66» всё ещё требует fetch портала.
- **B2 · ✅ СДЕЛАНО (PR #26) · [P1] Частично-успешный фоновый refresh затирает полный кэш.**
  `Sources/SudrfKit/Movement.swift` — `catch { continue }` (≈576) роняет вышестоящий
  суд по сетевому сбою; `MovementCachePolicy.merge` спасал только заглушки.
  **Captcha-часть закрыта в A16** (`transientError`-стаб). Остаётся полный контракт:
  гарантия, что любой частично-успешный fetch НИКОГДА не ухудшает сохранённое движение
  (не только captcha/transient случаи). *Тест:* таймаут любого вышестоящего суда не
  ухудшает кэш.

### Medium — ✅ ВСЕ РАЗРЕШЕНЫ (12 исправлено PR #29–32; BM3/BM4/BM11/BM16 — не баги, закрыты тестами)

- **BM1** `Sources/SudrfKit/Cyrillic1251.swift` (≈19-21) — одиночный `0x98` (cp1252-
  артефакт) роняет декод всей страницы в nil → `decodingFailed`. Нужен lossy-фолбэк.
- **BM2** `Sources/SudrfKit/SudrfClient.swift` (≈170) — один упавший URL-вариант
  обрывает весь variant-loop; decommissioned endpoint не даёт дойти до рабочего primary.
- **BM3** ⛔️ НЕ БАГ (закрыт тестом) `MagistrateClient.swift` — заявлено: кириллица
  кодируется UTF-8 против cp1251-формы. На реальных данных запросы отрабатывают;
  поведение `searchURL` зафиксировано в `MagistrateTests`. Кода не меняем.
- **BM4** ⛔️ НЕ БАГ (закрыт тестом) `Parties.swift` — заявлено: «ведётся» с «ё» →
  мёртвая КоАП-ветка. Реальная карточка (`kirov_koap`) классифицируется как `.koap`
  через другие триггеры (`привлека` и т.п.); зафиксировано в `CaseCardParserTests`.
- **BM5** MosGorSud: суд = первая ячейка с «суд» (`MosGorSudParsers.swift` ≈44) →
  «судебный пристав…» как название; `inForce` хардкод false (`MosGorSudMovement.swift`
  ≈115) → московские дела не доходят до «done».
- **BM6** `Sources/SudrfKit/CaseMovementCaptcha.swift` (≈23) — captcha-акт датируется
  `receiptDate` вместо `decisionDate` → сортировка на месяцы раньше.
- **BM8** `Sources/SudrfKit/VSRFClient.swift` (≈139-147) — `throttle` обновляет
  `lastRequestAt` только после сна → 8 воркеров штурмуют vsrf.ru пачкой. Резервировать
  слот до сна (образец SudrfClient).
- **BM9** `DistrictCourtResolver.swift` (≈428-432) и `MagistrateDirectory.swift`
  (≈109-113) — персист до загрузки дискового кэша → `--refresh` перезаписывает весь
  кэш одним регионом.
- **BM10** `DistrictCourtResolver.subjectCourt(forRegion:)` (≈120-132) — симметричный
  prefix-scoring, «Сахалинская» → верховный суд Якутии. Exact-root бонус.
- **BM11** ⛔️ НЕ БАГ (закрыт тестом) `SudrfCLI.swift` — заявлено: `route` матчит по
  подстроке. Маршрутизация переведена строго на код субъекта (PR #24/#31),
  подстрочный кейс невозможен; покрыто `DistrictResolverTests`/`CourtDirectoryTests`.
- **BM12** `Sources/SudrfApp/AppModel.swift` (≈557-562) — untrack по голому номеру
  дела может удалить запись другого суда; `recordKey` доступен на обоих call site.
- **BM13** `MovementDerivation.swift` (≈238) — база кассационного срока откатывается
  к «сегодня» → срок дрейфует вперёд ежедневно, бейдж загорается каждый день.
- **BM14** `FeedNotifier.swift` (≈38-63) — делегат центра уведомлений ставится лениво
  на первом `notify()` → клик по уведомлению после перезапуска ничего не открывает.
  Ставить до завершения запуска.
- **BM15** `RootView.swift` (≈20-23) — скрытый Search смонтирован с `.opacity(0)`,
  живой `Return`-shortcut → Enter на календаре запускает невидимый поиск и вызывает
  captcha-лист.
- **BM16** ⛔️ НЕ БАГ (закрыт тестом) `CalendarWeekLayout.swift` — заявлено:
  перекрытие карточек. Регрессия `CalendarWeekLayoutTests` подтверждает, что
  последовательные заседания не накладываются. Кода не меняем.
- **BM17** `AppModel.swift` (≈615-625) — гонка cancel-then-restart импорта: cleanup
  старой задачи обнуляет handle новой → двойной неотменяемый импорт.

### Low — ✅ ВСЕ ЗАКРЫТЫ (PR #27, `Harden low-severity edge cases`)

Одним sweep’ом покрыт весь список ниже (фикс + тест по каждому пункту):

`Movement.swift` ≈911-913 (VSRF intake-complaint мёрж во все производства);
`MovementDerivation.swift` ≈133 (status-chip из поздней `.material`);
`DateUtil.swift` ≈76-79 («31.02.2026»→3 марта, двузначный год как 26 г. н.э.);
`CaseCardParser.swift` ≈547-550 (нет td/th в blockTags → склейка ячеек);
`SearchPageClassifier.swift` ≈53 («Всего найдено» как .empty без парсинга count);
`CaseCardParser.swift` ≈436-439 (неякорный regex № дела по всему HTML);
`SudrfCLI.swift` ≈25 (`--level` неверный кейс → .district молча);
`MagistrateDirectory.swift` ≈67-71 (officialSite без sudrf-фильтра);
`SudrfClient.swift` ≈241-245 (отменённые запросы не освобождают throttle-слот);
`CaptchaDetector.swift` ≈64 (nearby-text хватает чужой `<tr>` → ложный captchaRequired);
`AppModel.swift` ≈254 (дубли Identifiable ID у безвременных заседаний);
`RefreshCenter.swift` ≈189-211 (устаревшие walk-воркеры портят счётчик прогресса);
`ContentView.swift` ≈311-312 (double-click гонит два fetch);
`OverviewView.swift` ≈490 (.neutral рендерится синим);
`CaseImport.swift` ≈236-253 (гарнизонные дела как гражданские райсуды → неверная
апелляционная цепочка).

### Security — ⬜ ЕДИНСТВЕННЫЙ ОТКРЫТЫЙ ПУНКТ (обсудить с owner перед изменением поведения TLS)

> Актуальные строки на `19e4677`: `trustedSuffixes` :464, отброшенный результат :493.

`Sources/SudrfKit/SudrfClient.swift` — TLS soft-accept: результат
`SecTrustEvaluateWithError(trust, nil)` **отбрасывается** (`_ =`). Docstring: намеренно
для сломанных винтажных цепочек судов. Но soft-accept покрывает и `mos-gorsud.ru`, где
обоснование неприменимо, а по соединению едут cookies и решённые captcha-токены.
*Фикс:* сузить soft-accept строго до судебных `*.sudrf.ru`-суффиксов; для `mos-gorsud.ru`
— штатная проверка `SecTrustEvaluateWithError`.

## Как начать (новая сессия)

1. `git fetch origin main && git checkout main` (B5/B6/B2/Low уже в `main`, на
   `f690760`+). Прочитать `AGENTS.md` (конвенции changelog/архитектуры) и этот handoff.
2. Взять первую невыполненную задачу (**B7**). `git checkout -b codex/b7-third-parties`.
3. **Re-grep** якорь по сигнатуре (`rolePattern` для B7, `CaseSnapshot` для B3), не по
   номеру строки. Внести фикс + тест.
4. Черновик заметки в `Docs/branch-changelogs/<slug>/vX.Y.Z.md` (прогнозная версия).
   Версию в `project.yml` НЕ трогать.
5. Push → PR в `main` → дождаться зелёного CI (`build-test` + `package-app`) → merge
   (owner). Повторить для следующей задачи.

## Проверка

- Каждая задача: юнит-тест, воспроизводящий баг (красный до фикса, зелёный после).
  Тесты в `Tests/SudrfKitTests/` и `Tests/SudrfAppTests/` (образцы рядом с целевым
  кодом).
- Полный прогон — на CI (macOS). Локально на Linux сборка недоступна.
- High-задачи по возможности сверить на реальных данных (ЯНАО/НАО резолв; самарская
  парти-фикстура для B7).
