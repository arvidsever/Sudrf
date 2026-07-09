# Изменения — Alpha 0.23.0

## Поддержка «винтажных» судов (VNKOD-паттерн): 101 суд перестал молча пустовать

~101 суд платформы ГАС «Правосудие» (Воронежская, Тверская, Амурская,
Ульяновская области, Краснодарский краевой, Орловский и Самарский областные,
шесть гарнизонных военных) работает на другой, «винтажной» версии модуля
sud_delo: поиск принимает параметры `_deloId`/`_new`/`vnkod=<код суда>` с
общими полями `case__case_numberss`/`case__judicial_uidss`/`parts__namess`
вместо современных `delo_id`/`new`/`<TABLE>__CASE_NUMBERSS`. Наш запрос
современного формата такой суд молча игнорировал — приложение показывало
«ничего не найдено» по делу, которое на сайте суда есть.

Список винтажных судов и формы их запросов выверены по боевой конфигурации
проекта [tochno-st/sudrfscraper](https://github.com/tochno-st/sudrfscraper)
(масштабный скрапер, прогнанный по всем ~2270 судам платформы).

### Справочник винтажных судов — `Sources/SudrfKit/SearchPatternDirectory.swift`

- `SearchPattern` (`primary`/`vnkod`) и `SearchPatternDirectory`:
  `pattern(forDomain:)`, `vnkod(forDomain:)`, `hasCaptcha(forDomain:)`.
  Хост ищется в обеих формах (дефисной и точечной); неизвестный домен — primary.
- Ресурс `Sources/SudrfKit/Resources/VNKODCourts.json` — срез из 101 суда
  (домен, внутренний код vnkod, название, флаг капчи). Генерируется скриптом
  `Scripts/derive-vnkod.py` из `config_sudrf.json` апстрима; зарегистрирован
  в `Package.swift`.

### Варианты поискового URL — `Sources/SudrfKit/SudrfURLBuilder.swift`

- Новый API `searchURLVariants(cartoteka:field:value:)` → `[SearchURLVariant]`
  (стабильный `id` + URL). Primary-суды — один вариант (прежний `searchURL`);
  винтажные — набор известных форм: с `process-type=<deloId>_0_0` и без, для
  ФИО дополнительно запасное поле `part__namess`.
- `vnkodDeloParams`: маппинг картотек на винтажные пары `_deloId`/`_new`.
  Особенности платформы: винтажная апелляция использует `_deloId` ПЕРВОЙ
  инстанции с `_new` (уголовные `1540006&_new=4`, гражданские `1540005&_new=5` —
  в отличие от primary `delo_id=4/5`); КАС первой инстанции на части судов
  живёт в гражданской таблице — пробуются обе (`41`, затем `1540005`).
  Кассация/президиум: винтажная форма неизвестна — фолбэк на primary-вариант.
- `formURL` для винтажных судов собирается в их формате
  (`name_op=sf&_deloId=…&_caseType=0&_new=…`).

### Перебор вариантов и честные ошибки — `Sources/SudrfKit/SudrfClient.swift`

- `searchOnce` перебирает варианты по порядку; ответ каждого оценивает
  классификатор `Sources/SudrfKit/SearchPageClassifier.swift`
  (`results`/`empty`/`captcha`/`unrecognized`; маркеры текста — из боевого
  `IssueByTextIdentifier` апстрима). Пустая выдача НЕ прерывает перебор
  (запрос не в ту таблицу даёт валидную пустоту), результат — прерывает.
- Рабочий вариант запоминается per суд+картотека в
  `Sources/SudrfKit/WorkingVariantStore.swift` (actor-синглтон, JSON в Caches
  по образцу DistrictCourtResolver, TTL 30 дней) и в следующий раз пробуется
  первым. Стор инжектируется в `SudrfClient.init` (для тестов).
- Если ни один вариант не дал ни выдачи, ни валидной пустоты — новая ошибка
  `SudrfError.searchModuleUnavailable(domain:)` («модуль не отвечает в
  известных форматах, возможно JS-защита») вместо тихого «ничего не найдено».
  Поведенческое изменение: раньше нераспознанная страница парсилась в пустой
  список. В SudrfApp ошибка всплывает существующими путями (`status`).
- Предпроверка формы на капчу — только у primary-судов: у винтажных капча
  равно видна на самой выдаче, классификатор её распознаёт (минус один запрос).
- «Время жизни сессии закончилось» приравнено к капче.

### Риск (проверить вживую — из песочницы сеть до судов закрыта)

94 из 101 винтажных судов у апстрима помечены «нужен Selenium» — возможна
JS-прослойка перед выдачей. Тогда прямой GET даст `unrecognized` по всем
вариантам и честную ошибку `searchModuleUnavailable` (не пустоту) — дальше
смотреть по живому HTML. TODO: снять фикстуру выдачи винтажного суда
(например, anninsky--vrn.sudrf.ru) и добавить в классификаторные тесты.

### Тесты (171, все зелёные; было 149)

- `SearchPatternTests`: загрузка среза (101), обе формы хоста, эталонные
  строки винтажных URL по всем картотекам (1-я инстанция/апелляция/КАС-обе-таблицы/
  кассация-фолбэк), cp1251-кодирование ФИО, форма `name_op=sf`.
- `SearchPageClassifierTests`: выдача с результатами, встроенная капча-форма
  рядом с результатами (результаты побеждают), маркеры пустоты, капча,
  сессия истекла, JS-заглушка, пустая страница.
- `WorkingVariantStoreTests`: запись/чтение, нормализация формы хоста,
  раздельные ключи картотек, забывание, TTL, персистентность, работа без файла.

### Файлы

- Новые: `Sources/SudrfKit/SearchPatternDirectory.swift`,
  `Sources/SudrfKit/SearchPageClassifier.swift`,
  `Sources/SudrfKit/WorkingVariantStore.swift`,
  `Sources/SudrfKit/Resources/VNKODCourts.json`, `Scripts/derive-vnkod.py`,
  `Tests/SudrfKitTests/SearchPatternTests.swift`,
  `Tests/SudrfKitTests/SearchPageClassifierTests.swift`,
  `Tests/SudrfKitTests/WorkingVariantStoreTests.swift`.
- Изменены: `Sources/SudrfKit/SudrfURLBuilder.swift`,
  `Sources/SudrfKit/SudrfClient.swift`, `Sources/SudrfKit/Models.swift`
  (`SudrfError.searchModuleUnavailable`), `Package.swift`, `project.yml`
  (версия 23).
