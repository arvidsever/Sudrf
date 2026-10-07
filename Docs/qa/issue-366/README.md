# #366 — боковая панель настроек и верхний отступ

Проверка от 7 октября 2026 года. **Результат частичный:** обрезание названия исправлено; верхний отступ требует живой проверки. Issue остаётся открытой.

## Подтверждённое исправление

Причина обрезания — прежняя фиксированная ширина боковой панели 184 pt. При неизменном `Label` название «Экспериментальные» обрезается; минимальная и предпочтительная ширина 220 pt позволяют показать его целиком. Название сохранено; добавлены системная подсказка и явное доступное имя.

Ниже — невидимый `NSHostingView` размером 720 × 470 pt на **macOS 27.2 (26B5101f)**. Оболочка и список извлекаются из настоящего `SettingsHub.swift`; содержимое всех разделов заменено синтетическим grouped Form. Пользовательские настройки, реальные AI-разделы, Keychain, база и приложение не открываются. Чёрная выбранная строка — артефакт offscreen-отрисовки, не подтверждение её внешнего вида в приложении. Изображения имеют масштаб 2×.

| До: 184 pt | После: минимум / предпочтительно 220 pt |
| --- | --- |
| ![Название обрезано](sidebar-before-720pt.png) | ![Полное название помещается](sidebar-after-720pt.png) |

Воспроизведение из корня репозитория на macOS с Xcode:

```sh
python3 Docs/qa/issue-366/render-sidebar.py --output-dir /private/tmp/sudrf-366/qa
```

Это инструмент получения свидетельств, а не автоматический тест визуальной приёмки. Он не вызывает `orderFront`, `makeKeyAndOrderFront` или запуск Sudrf.

## Верхний отступ — пока не подтверждён

Дефект зарегистрирован на macOS 26. На доступной macOS 27.2 синтетический grouped Form в этой оболочке уже показывает первый заголовок примерно в 22 pt от верха содержимого. Общий `.frame(..., alignment: .top)`, `VStack` и `.contentMargins` в отдельном пробном host не изменили итоговое расположение. Поэтому эти неподтверждённые изменения не включены.

Синтетическая форма и текущая версия ОС не доказывают, что отступ исправлен в пяти настоящих разделах на macOS 26.

## Автоматические проверки

- SwiftPM app build: прошёл, журнал `/private/tmp/sudrf-366/build-final.log`.
- `xcodegen generate`: прошёл, журнал `/private/tmp/sudrf-366/xcodegen.log`.
- Канонический Xcode Debug app build без подписи и запуска: прошёл, журнал `/private/tmp/sudrf-366/xcodebuild.log`. Все три поставляемые CoreML-модели в собранном бандле совпали с SHA-256 manifests.
- Полная проверка SwiftPM с `-strict-concurrency=complete`: прошла; 1930 XCTest (20 штатных пропусков), 28 Swift Testing, 0 failures. Журнал `/private/tmp/sudrf-366/tests.log`.
- `git diff --check`: прошёл.

Команды используют отдельные scratch/cache/DerivedData каталоги:

```sh
swift build --scratch-path /private/tmp/sudrf-366/build --cache-path /private/tmp/sudrf-366/cache --product SudrfApp
swift test --scratch-path /private/tmp/sudrf-366/build --cache-path /private/tmp/sudrf-366/cache -Xswiftc -strict-concurrency=complete
xcodegen generate
xcodebuild -project Sudrf.xcodeproj -scheme Sudrf -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/sudrf-366/XcodeDerivedData -clonedSourcePackagesDirPath /private/tmp/sudrf-366/XcodePackages CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Осталась живая приёмка

На macOS 26 получить скриншоты **всех пяти настоящих разделов** («Обновление», «Поиск», «CAPTCHA», «AI и приватность», «Экспериментальные») при ширине 720 pt и стандартной ширине, в светлом и тёмном оформлении. Проверить:

- ни один пункт боковой панели не обрезан; полные названия доступны в tooltip и VoiceOver;
- первый заголовок секции начинается под заголовком окна с одинаковым обычным системным отступом во всех пяти разделах;
- длинные формы прокручиваются, настройки и кнопки доступны.

До такой проверки устранение верхнего отступа и полная приёмка #366 не заявляются.
