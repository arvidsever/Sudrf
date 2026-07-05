# Что изменилось — v10 «Liquid Glass»

## v10.5 — фикс краша компилятора при Archive

При Archive (Release, -O) бета-компилятор Swift 6.4 падал на коде SwiftSoup
2.13.x («Found outside of lifetime use … CopyPropagation …
Element.appendNormalisedText») — это баг оптимизатора, в Debug не
проявляется. SwiftSoup запинен точно на 2.7.7 (до байтового переписывания
парсера, API тот же), старый Package.resolved удалён. После обновления
папки: в Xcode File → Packages → Reset Package Caches (или просто переоткрыть
проект) — зависимость перерезолвится на 2.7.7. Когда Apple починит
компилятор, можно вернуть `from: "2.7.0"`.

## v10.4 — фикс депрекейшена + сборка для передачи

1. `WindowChrome.swift`: убран вызов `showsBaselineSeparator` (депрекейтнут
   с macOS 15 и ничего не делает).
2. `Scripts/make-app.sh` теперь собирает универсальный бинарь
   (`--arch arm64 --arch x86_64`) и кладёт рядом `build/Sudrf.zip` (ditto) —
   готовый архив для пересылки. В README — раздел «Передать сборку»
   (требования получателя, обход Gatekeeper без нотаризации).

## v10.3 — светофор и иконка

1. **Светофор**: с hiddenTitleBar кнопки окна прижимались к самому углу и
   налезали на скругление стеклянной панели. Новый `WindowChrome.swift`
   (NSViewRepresentable) вешает на окно пустой прозрачный unified-тулбар —
   тайтлбар-зона становится выше, светофор встаёт с нормальным отступом
   на верх сайдбара. Отступ «ПОИСК ДЕЛА» увеличен до 50 pt.
2. **Иконка** — весы Фемиды на синем сквиркле (акцентный градиент,
   белый глиф): `Assets.xcassets/AppIcon.appiconset` со всеми размерами
   16–1024. В Xcode-проекте подключена через ассет-каталог
   (ASSETCATALOG_COMPILER_APPICON_NAME в project.yml — перегенерируйте
   проект: `xcodegen`); в `Scripts/make-app.sh` — через `iconutil`
   (собирает AppIcon.icns при сборке). В именах PNG вместо `@2x`
   используется суффикс `-2x` — имена прописаны в Contents.json,
   Xcode это устраивает.

## v10.2 — плавающие стеклянные панели + Xcode-проект

1. **Каркас «как в макете»** (`ContentView.swift`, `SudrfApp.swift`):
   системные NavigationSplitView/.inspector давали плоские панели — заменены
   на ручной каркас: контент во всё окно, сайдбар (300 pt) и инспектор
   (400 pt) — плавающие панели `.glassEffect(.regular, in: .rect(cornerRadius: 18))`
   с отступом 10 pt от краёв окна. Окно — `.windowStyle(.hiddenTitleBar)`,
   светофор ложится на верх сайдбара; заголовок «Выдача / Движение дела»
   и чип «Найдено: N» переехали в шапку контента. Инспектор
   появляется/уходит с анимацией от правого края. Компромисс: нет
   системного схлопывания сайдбара и перетаскивания границ — ширины
   фиксированы (константы в `enum Layout`).
2. **Xcode-проект без скрипта**: добавлен `project.yml` (XcodeGen) —
   `xcodegen && open Sudrf.xcodeproj`, схема Sudrf, ⌘R. В README — и ручной
   способ через File → New Project + Add Local Package. SwiftPM сам по себе
   .app собрать не умеет — поэтому либо проект, либо `Scripts/make-app.sh`.

## v10.1 — фиксы по скриншоту первого запуска

1. **Тёмно-серый фон контента** — `underPageBackgroundColor` резолвился в
   тёмный «фон под страницей». Заменён на адаптивный `NSColor.sudrfContent`
   (#f2f3f6 светлый / #232428 тёмный — как в макете). Правки в
   `ContentView.swift` и `CaseMovementView.swift`.
2. **Liquid Glass не включался** (прямоугольные кнопки, плоский сайдбар):
   «голый» исполняемый файл без бандла macOS 26 рендерит в режиме
   совместимости. Добавлен `Scripts/make-app.sh` — собирает
   `build/SudrfApp.app` с Info.plist (`LSMinimumSystemVersion 26.0`) и
   ad-hoc-подписью; в бандле стекло включается. Запуск:
   `bash Scripts/make-app.sh`.

Редизайн SudrfApp под macOS 26 (Tahoe) по согласованному макету
(«Sudrf Liquid Glass — макет» в Claude Design). Логика, модель и ядро
SudrfKit не тронуты — изменения только в слое представления.

## Сводка

| Файл | Что изменилось |
|---|---|
| `Package.swift` | Платформа `.macOS(.v13)` → `.macOS("26.0")`. Liquid Glass API существуют только с macOS 26, фолбэков сознательно нет. |
| `Sources/SudrfApp/ContentView.swift` | **Каркас**: `HSplitView` → `NavigationSplitView` (сайдбар получает системное «плавающее» стекло Tahoe бесплатно) + системный `.inspector(isPresented:)` вместо третьей панели сплита. Инспектор открыт, пока выбрана карточка; закрытие через биндинг зовёт `closeInspector()`. **Стиль**: кнопки «Сбросить»/«Искать» → `.buttonStyle(.glass)` / `.glassProminent`; чип «Найдено: N» в тулбаре → `.glassEffect()`; иконки шапки инспектора → круглые стеклянные (`.buttonBorderShape(.circle)`); карточки выдачи — радиус 14, мягкая тень, выбранная — акцентная заливка с обводкой; текст акта — «лист» с радиусом 12 и отступом 10 от краёв инспектора; фон контента — `underPageBackgroundColor`. |
| `Sources/SudrfApp/CaseMovementView.swift` | Блоки инстанций — радиус 14 + тень; шапка блока — вертикальный градиент цвета инстанции (0.14 → 0.08); кнопка «‹ Выдача» → стеклянная; «Ввести код» (капча вышестоящего суда) → `.glassProminent`. Цвета инстанций прежние (синий/индиго/бирюзовый). |
| `Sources/SudrfApp/CaptchaWebView.swift` | Шапка шита: иконка `lock.shield.fill` в цвете акцента, заголовок + подсказка двумя строками, «Отмена» → `.glass`. Нижняя подсказка влита в шапку. |
| `Sources/SudrfApp/SudrfApp.swift` | `defaultSize` 1240×724 → 1280×800. |
| `README.md` | Требования: Xcode 26 / macOS 26+. |

Не менялись: `SearchModel.swift`, `ActTextView.swift`, `ActWindow.swift`
(тулбар-кнопка PDF на Tahoe становится стеклянной сама), всё ядро `SudrfKit`.

## Тёмная тема

Получается автоматически: все цвета в вьюхах семантические
(`textBackgroundColor`, `underPageBackgroundColor`, `.primary/.secondary`,
системный акцент), стеклянные материалы адаптируются сами.

## Если компилятор ругнётся (сборка здесь не прогонялась)

- `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` — macOS 26 SDK
  (Xcode 26). Если SDK старее — поставить Xcode 26.
- `.glassEffect()` на чипе «Найдено» — форма по умолчанию капсула; при желании
  прямоугольник: `.glassEffect(.regular, in: .rect(cornerRadius: 12))`.
- Условный `ToolbarItem` внутри `if` — если builder заупрямится, обернуть
  содержимое в `ToolbarItem { if … { … } }`.
- `.onChange(of: model.region) { … }` — новая сигнатура без параметров
  (macOS 14+), на 26 валидна.

## Идеи на потом (не делал)

- `GlassEffectContainer` для группы иконок инспектора — слияние стекла
  при анимации появления/скрытия.
- `.scrollEdgeEffectStyle(.soft, for: .top)` на списке карточек — мягкое
  «подныривание» контента под тулбар.
- `.backgroundExtensionEffect()` для контента под плавающим сайдбаром.
