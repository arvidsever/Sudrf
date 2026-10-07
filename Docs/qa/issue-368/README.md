# #368 — неподвижная навигация календаря

Автоматическая проверка пройдена (без пропуска, 10,115 с): `CalendarMonthViewTests.testNavigationButtonFramesStayFixedAcrossPeriodsAndOverlapCounts`.

Тест использует настоящий `CalendarScreen`, синтетический `AppRouter`, базу SwiftData в памяти и невидимое окно с одним `NSHostingView` на каждую ширину (760, 1180, 1920 pt). Anchor preferences снимают реальные bounds каждой из трёх кнопок. Проверяются x, y, ширина и высота после переключений всех 12 месяцев, недель 27 июля – 2 августа, 3–9 августа, границы декабря/января и отсутствующего/короткого/двузначного счётчика накладок. Тест не требует доступности дерева AX в тестовом процессе.

Легенда получает ширину окна за вычетом 800 pt, зарезервированных для навигации, названия, счётчика и переключателя режимов. Выбор её варианта зависит только от ширины; навигация находится вне `ViewThatFits`.

Ручная приёмка пользователем остаётся открытой:

- обычное, широкое, минимальное и полноэкранное окно;
- открытая и закрытая панель дня;
- светлая и тёмная темы;
- повторные щелчки в одной точке по каждой стрелке;
- клавиатурный фокус и VoiceOver, включая переход между годами.

Production-приложение, рабочая база, системные настройки и TestFlight для этой проверки не используются.

Проверка воспроизводится командой:

```sh
swift test --scratch-path /private/tmp/sudrf-368/build --filter CalendarMonthViewTests/testNavigationButtonFramesStayFixedAcrossPeriodsAndOverlapCounts
```

Лог целевой проверки: `/private/tmp/sudrf-368-test2.log`.

Итоги проверки перед коммитом:

- Полный набор: 1931 тест, 20 предусмотренных пропусков, 0 ошибок; `/private/tmp/sudrf-368-full.log`.
- Целевой набор Calendar: пройден; `/private/tmp/sudrf-368-calendar.log`.
- `xcodegen generate` и каноническая схема `Sudrf`, Debug, изолированный DerivedData: `BUILD SUCCEEDED`; `/private/tmp/sudrf-368-xcodebuild.log`.
- `git diff --check`: пройден.

## Исправление синхронизации проверки в CI

CI на macOS 26 выявил гонку в тесте: после смены режима недельные кнопки уже имели новые размеры, а эталон ещё содержал месячные координаты. `onPreferenceChange` передавал координаты через задачу MainActor, которую синхронный тест не ожидал. Это давало одинаковое расхождение для каждой недели (ширина центральной кнопки 90 вместо эталонных 73 pt), а не сдвиг между неделями.

Проверка теперь асинхронная. При создании хоста и смене режима она принудительно отрисовывает невидимое представление, затем освобождает главный поток для доставки координат. Перед недельным эталоном дополнительно ожидается получение изменившихся непустых bounds реальных кнопок; отсутствие обновления завершает проверку ошибкой. Все сравнения x/y/ширины/высоты сохранены без изменений.

Повторная целевая проверка: пройдена без пропуска, 3,418 с; `/private/tmp/sudrf-368-ci-fix-focused.log`. Изменён только тест; production-код и результат канонической Debug-сборки сохранены.

Полный повторный набор после исправления синхронизации: 1931 тест, 20 предусмотренных пропусков, 0 ошибок; `/private/tmp/sudrf-368-ci-fix-full.log`.

## Full period year and minimum width

Week titles now include their own year within a single year and retain both years across December/January. Month and week titles allow a minimum scale of 75%, with explicit full help and VoiceOver labels.

The geometry regression also measures the actual title allocation through an anchor preference. The full title at 22 pt bold, scaled no lower than 75%, must fit the allocation at every tested width, including 760 pt. All 12 months, overlap counter lengths and month/year boundary weeks are covered. The mode-switch barrier still observes only navigation button bounds.

Focused verification: 20 tests, zero failures or skips; `/private/tmp/sudrf-368-year-focused.log`. Font appearance remains subject to the existing manual visual acceptance gate.

Final year-label verification:

- Full suite: 1932 tests, 20 expected skips, zero failures; `/private/tmp/sudrf-368-year-full.log`.
- Calendar profile: 89 tests, 6 expected skips, zero failures; `/private/tmp/sudrf-368-year-calendar.log`.
- XcodeGen and canonical Sudrf Debug build: `BUILD SUCCEEDED`; `/private/tmp/sudrf-368-year-xcodebuild.log`.
