# Handoff: Track B — баги `main` (не относящиеся к captcha-солверу)

> Обновлено: 2026-07-11, после merge PR #6 (captcha-auto-solver) в `main`.
> Для новой сессии, которая берёт Track B. Самодостаточный документ.

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

### High (подтверждены построчно) — рекомендуемый порядок: B5 → B7 → B3 → B6 → B2

- **B5 · [P1] ЯНАО → неверный кассационный суд.**
  `Sources/SudrfKit/CourtDirectory.swift` — `regionsMatch` (≈180-184):
  `return x.contains(y) || y.contains(x)` — двунаправленное вхождение подстроки;
  «ямалоненецкийавтономныйокруг» содержит «ненецкийавтономныйокруг» (Ненецкий АО,
  3 КСОЮ), скан 1→9 → ЯНАО резолвится в `3kas` вместо `7kas`. **Юридически критично.**
  *Фикс:* нормализованное сравнение с exact-root бонусом (образец — соседний
  `subjectNumericCode`, где уже решена коллизия сахалин/саха). *Тест:* ЯНАО→7kas,
  НАО→3kas, Сахалин↔Саха корректны.
- **B7 · [P1] Третьи лица склеиваются в имя ответчика.**
  `Sources/SudrfKit/Parties.swift` — `rolePattern` (≈322-327) знает
  «третьи лица»/«заинтересованные лица», но НЕ голый лейбл «ЛИЦА:», который печатает
  `sud_delo` (сверено с самарской фикстурой) → ответчик «ФСИН России ЛИЦА:
  Рыжкова Е.А.», третье лицо теряется. *Фикс:* добавить альтернативу голого
  `лица`/`ЛИЦА` как роль «третьи лица» (длинные альтернативы раньше коротких). *Тест:*
  самарская фикстура → ответчик «ФСИН России» + отдельное третье лицо.
- **B3 · [P1] Новые акты не дают уведомлений/бейджей.**
  `Sources/SudrfApp/MovementDerivation.swift` — `CaseSnapshot` (≈46-63) содержит
  `sessions`/`deadlines`, но **не `acts`**; детект изменений (сравнение снимков в
  `RefreshCenter`) не видит публикацию акта без новой сессии → `seenAt` не
  сбрасывается, запись «рождается прочитанной». *Фикс:* добавить в снимок отпечаток
  актов (`actsFingerprint: [String]` из id+date+title или хеш) и учесть в сравнении.
  *Тест:* снапшот меняется при добавлении акта.
- **B6 · [P1] Гарнизонные суды ломают резолв райсудов.**
  `Sources/SudrfKit/DistrictCourtResolver.swift` — субъект метится «загруженным»
  (`loadedSubjects`, ≈365) по цифрам классификационного кода любого кэш-суда;
  общенациональные военные harvests персистят суды без субъекта портала → на след.
  запуске субъект (напр. «66») считается загруженным, fetch портала пропускается,
  фильтр райсудов пуст для Свердловской обл. *Фикс:* не метить субъект загруженным по
  записям без субъекта портала (гарнизонные/военные). *Тест:* после военного harvest
  субъект «66» всё ещё требует fetch портала.
- **B2 · [P1] Частично-успешный фоновый refresh затирает полный кэш.**
  `Sources/SudrfKit/Movement.swift` — `catch { continue }` (≈576) роняет вышестоящий
  суд по сетевому сбою; `MovementCachePolicy.merge` спасал только заглушки.
  **Captcha-часть закрыта в A16** (`transientError`-стаб). Остаётся полный контракт:
  гарантия, что любой частично-успешный fetch НИКОГДА не ухудшает сохранённое движение
  (не только captcha/transient случаи). *Тест:* таймаут любого вышестоящего суда не
  ухудшает кэш.

### Medium (верифицировать → фикс)

- **BM1** `Sources/SudrfKit/Cyrillic1251.swift` (≈19-21) — одиночный `0x98` (cp1252-
  артефакт) роняет декод всей страницы в nil → `decodingFailed`. Нужен lossy-фолбэк.
- **BM2** `Sources/SudrfKit/SudrfClient.swift` (≈170) — один упавший URL-вариант
  обрывает весь variant-loop; decommissioned endpoint не даёт дойти до рабочего primary.
- **BM3** `Sources/SudrfKit/MagistrateClient.swift` (≈26-39) — кириллица кодируется
  UTF-8 через URLComponents против cp1251-формы → кириллические запросы дают пусто.
  Кодировать в cp1251 вручную (образец `SudrfURLBuilder`).
- **BM4** `Sources/SudrfKit/Parties.swift` (≈166) — «ведётся» с «ё», суды печатают
  «ВЕДЕТСЯ» → ветка мёртвая. Ё-less.
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
- **BM11** `SudrfCLI.swift` (≈138) — `route` матчит по подстроке, «Республика Коми» →
  «не найден» (род. падеж «республики»).
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
- **BM16** `CalendarWeekLayout.swift` (≈121-127) — раздутая min-высота клеток vs
  start-time-based top следующего блока → перекрытие карточек и клик-таргетов.
- **BM17** `AppModel.swift` (≈615-625) — гонка cancel-then-restart импорта: cleanup
  старой задачи обнуляет handle новой → двойной неотменяемый импорт.

### Low (кратко; верифицировать перед фиксом)

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

### Security (обсудить с owner перед изменением поведения TLS)

`Sources/SudrfKit/SudrfClient.swift` (≈444-457) — TLS soft-accept: результат
`SecTrustEvaluateWithError(trust, nil)` **отбрасывается** (`_ =`). Docstring: намеренно
для сломанных винтажных цепочек судов. Но soft-accept покрывает и `mos-gorsud.ru`, где
обоснование неприменимо, а по соединению едут cookies и решённые captcha-токены.
*Фикс:* сузить soft-accept строго до судебных `*.sudrf.ru`-суффиксов; для `mos-gorsud.ru`
— штатная проверка `SecTrustEvaluateWithError`.

## Как начать (новая сессия)

1. `git fetch origin main && git checkout main` (должно быть на `7f20e96`+, версия
   0.39.29). Прочитать `AGENTS.md` (конвенции changelog/архитектуры) и этот handoff.
2. Взять первую задачу (B5). `git checkout -b codex/b5-yanao-cassation`.
3. **Re-grep** якорь по сигнатуре (`regionsMatch`), не по номеру строки. Внести
   фикс + тест.
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
