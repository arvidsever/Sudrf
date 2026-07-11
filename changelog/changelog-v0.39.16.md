# Captcha auto-solver — v0.39.16

## Контекст

FIXPLAN A4 [P1]: «CoreML-decoder жёстко 5-значный; неверные ответы
уходят на сервер». Премисса: на rotated/struck-through captcha
spb/1КСОЮ/облсудов CoreML выдаёт уверенно-неверный ответ.

**Bug не воспроизводится на наших 3 уникальных captcha spb/nsk.**
Ground truth получен человеком (PNG открыты в Preview, цифры
прочитаны и вписаны в имена файлов как префикс):

- `spb_1`–`_3` (1 уникальная captcha, captchaid `v3ruvq…`) → `90299`
- `spb_4`–`_5` (1 уникальная captcha, captchaid `1l2tq…`) → `56667`
- `nsk_21`–`_25` (1 уникальная captcha, captchaid `pr641…`) → `60984`

CoreML на этих captcha выдаёт корректные 5-значные ответы:
- spb: `90299@0.893` / `56667@0.717` — exact match
- nsk: `60984@0.995` — exact match (проверено пользователем)

Vision на тех же captcha ошибается: `667`/`1909` (3-4 из 5
символов) для spb, пусто для nsk. **Vision был источником
«неверного ground truth» в FIXPLAN A4** (`labels.csv` до правки
содержал `expected=667/1909/UNREADABLE` — Vision-ошибки, не
реальные значения captcha).

**Премисса FIXPLAN A4 («выход модели = неверный ответ») была
ошибочной.** Это исправление допущения, а не молчаливое
переворачивание. Captcha всегда 5-значная, Vision просто не
справляется с rotated/struck-through стилями — потому и появился
CoreML-солвер.

## За пределами выборки

3 уникальные captcha — это не статистически значимая выборка. За
пределами наших фикстур модель может ошибаться (на captcha с
другой палитрой чернил, на vnkod+буквы Краснодарского края, на
msudrf). Эти случаи не покрыты ни A4, ни marker'ом.

## Что сделано (минимальный scope)

- **Перелейблены PNG-фикстуры:** `Tests/CaptchaSolverTests/Fixtures/sudrf/`
  — 10 файлов с префиксом истинного ответа (`90299_*`, `56667_*`,
  `60984_*`). Отдельный коммит `chore(captcha): rename spb/nsk
  fixture PNGs with ground truth prefix` (пользователь инициировал
  переименование; источник ground truth — ручное чтение с PNG).
- **`Tests/CaptchaSolverTests/Fixtures/sudrf/labels.csv`**: 10 строк,
  `expected` = истинные 5 цифр, `notes` обновлены (убрано «Vision
  raw reads '667'» и «Vision returns empty» — это были Vision-ошибки,
  не ground truth).
- **`Tests/CaptchaSolverTests/CoreMLCaptchaStrategyTests.swift`**:
  `testLocalSudrfFixturesAccuracy` рефакторен — накапливает
  `(filename, attempt, expected)`, `total == 10` (вместо 5),
  добавлен **голый `XCTAssertTrue`** marker-assert (без
  `XCTExpectFailure` — он бы проглотил регрессию, см. фидбек).
  Докстринг обновлён.
- **`Tests/CaptchaSolverTests/VisionOCRStrategyTests.swift`**:
  `testSudrfFixturesAccuracy` **удалён** вместе с мёртвым кодом
  (`LabeledFixture`, `FixtureLoader`). Раньше этот тест ожидал
  `correct ≥ 3` из 5 readable — Vision на rotated/struck-through
  captcha давал 3/5 correct (667/1909 из 90299/56667). После
  перелейбла `labels.csv` Vision на тех же captcha даёт 0/10
  correct, что **отражает реальную** responsibility Vision —
  rotated 5-значные не её область (потому и появился CoreML).
  Тест больше не имеет смысла.
- **`Sources/CaptchaSolver/CoreMLCaptchaStrategy.swift`**:
  докстринг обновлён — убрано «conf=0.00» (Vision на spb не
  всегда conf=0.00, иногда 3-4 из 5 цифр), уточнено про CoreML
  in-distribution и regression marker.
- **`Scripts/train-coreml-captcha.swift`**: комментарий в шапке
  о A4 regression marker и source of confusion (Vision-ошибки
  в labels.csv как источник FIXPLAN A4).

## Закрытие A4

Премисса FIXPLAN A4 не подтверждается на наших 3 уникальных
captcha: описанного бага «уверенно-неверные ответы уходят на
сервер» нет. CoreML in-distribution, exact match на наших
captcha. Правки `KindDispatchingStrategy`/`CoreMLCaptchaStrategy`/
порога `minConfidence` не нужны.

Marker (`XCTAssertTrue` без wrapper) сохранён как
**регрессионный тест**: при будущих изменениях модели/солвера
поймает деградацию (начнёт выдавать 00000-99999 random, или
точность упадёт на rotated-стилях). CI: без модели → XCTSkip
(модель gitignored, см. A5), тест не выполняется.

## Что остаётся (backlog, не P1)

- **Krasnodar krai** (vnkod + буквенноцифровая): CoreML выдаёт
  цифры (10 классов, не покрывают `[а-я]`), суд отвергает.
  Отдельная фича: новый `CaptchaKind` + mapping domain→kind +
  правки `AppModel`/`KindDispatchingStrategy`.
- **msudrf auto-solver**: см. A3 v0.39.15 backlog.
- **Vision на rotated/struck-through**: не область Vision
  (потому CoreML). Если когда-нибудь понадобится — отдельная
  фича (например, новый preprocessing + обучение Vision на
  нашем корпусе).
- **Расширение held-out фикстур:** если появятся captcha других
  стилей (Краснодар, неизвестные ОСЮ) — расширить `labels.csv`
  и marker. Текущие 3 уникальные — валидный baseline для spb/nsk.

## Тесты (v0.39.16)

- 1 тест в `CoreMLCaptchaStrategyTests` — `testLocalSudrfFixturesAccuracy`
  с regression marker (голый `XCTAssertTrue`).
- 7 тестов в `VisionOCRStrategyTests` (было 8, удалён
  `testSudrfFixturesAccuracy` + мёртвый код `LabeledFixture`/
  `FixtureLoader`).
- Без модели → `XCTSkip` (модель gitignored, см. A5).
- С моделью и валидным ground truth → зелёный (verified: 10/10
  exact match, conf 0.717-0.995).
- С моделью и регрессией → красный, поймает.

## Release notes (lift at merge)

- **Ground truth выправлен:** `labels.csv` для 10 captcha spb/nsk
  перелейблен истинными 5 цифрами (источник: человек прочитал с
  PNG; было `667/1909/UNREADABLE` — Vision-ошибки). 10 PNG
  переименованы с префиксом ответа.
- **Regression marker:** `testLocalSudrfFixturesAccuracy` ловит
  «уверенно-неверный ответ» (failure-mode из FIXPLAN A4 P1) —
  голый `XCTAssertTrue`, без wrapper'а.
- **Vision-тест удалён:** `testSudrfFixturesAccuracy` больше не
  имеет смысла после перелейбла. Vision на rotated 5-значных
  captcha не работает (и не должна — это область CoreML).
- **Документация:** `CoreMLCaptchaStrategy.swift` и
  `train-coreml-captcha.swift` отмечают, что модель
  in-distribution и корректна на наших 3 уникальных captcha
  spb/nsk (verified человеком с PNG).
- **Закрытие A4:** премисса FIXPLAN A4 («выход = неверный»)
  не подтверждается на наших 3 фикстурах. Правки
  `KindDispatchingStrategy`/`minConfidence`/переобучение не
  нужны. За пределами выборки ничего не заявляем.
