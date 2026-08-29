# v0.46.6 — отзывчивое массовое обновление дел

## Исправлено

- После обновления одного дела приложение больше не пересчитывает на главном
  потоке lifecycle-представления всех отслеживаемых записей.
- Same-day кэш инвалидирует только обновлённое дело и обе стороны key remap;
  обычный reload и смена календарного дня по-прежнему выполняют полный пересчёт.
- Лента, календарь, счётчики, локальные уведомления и Spotlight продолжают
  собираться тем же кодом и публиковаться после каждого результата refresh.

## Диагностика

- На реальной базе из 215 дел до исправления Sudrf потреблял 77–92% CPU, а
  пятисекундный sample целиком удерживал главный поток в цепочке
  `RefreshCenter → AppRouter.reload → CaseLifecycleResolver`.
- 2 378 из 2 614 main-thread samples приходились на повторный расчёт
  `CaseLifecyclePresentation` для изменившихся и неизменившихся дел.

## Проверка

- Регрессии покрывают первый полный reload, same-day scoped invalidation,
  untouched records, deletion/key remap, смену дня и эквивалентность scoped и
  full проекций `cases`, `hearings`, `deadlines`, `feed` и счётчиков.
- Полный `swift test` — 836 тестов, ошибок нет; `swift build` проходит.

## Границы

- Пакетность обновления, UI, SwiftData V6, сетевой параллелизм и
  `CaseLifecycleResolver` не менялись.
- Сообщения Xcode `decode: bad range`, `nw_path_necp_check_for_updates` и
  диагностика task-name port для WindowServer не входят в это исправление.
