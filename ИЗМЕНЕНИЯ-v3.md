# Что изменилось (дизайн-обновление v3 — движение дела)

Это ваш проект SudrfKit целиком — файлы уже разложены по местам.
Откройте папку как Swift-пакет в Xcode и соберите таргет `SudrfApp`.
Пакет собирается и работает «из коробки»: движение дела отдаётся
демо-данными (см. ниже, как подключить реальную сборку).

## Новое в v3

| Файл | Что это |
|---|---|
| `Sources/SudrfKit/Movement.swift` | Модели движения дела (`CaseMovement`, `CaseInstance`, `CaseSession`, `PrivateComplaint`, `CaseAct`) + `MovementService`. Сейчас сервис отдаёт демо (дело 2-3204/2026); в шапке файла — схема подключения реальных вызовов ядра (карточка 1-й инстанции + поиск вышестоящих ПО УИД). |
| `Sources/SudrfApp/CaseMovementView.swift` | Вид «движение дела» (вариант B3): блоки по инстанциям, **судья в шапке блока**, частные жалобы — чип «обжаловано · ЧЖ» с раскрытием на месте. Цвета инстанций — как в прототипе. |

## Изменённые файлы

| Файл | Что изменилось |
|---|---|
| `Sources/SudrfApp/ContentView.swift` | Одинарный клик по карточке — текст акта (как раньше); **двойной клик** (`onTapGesture(count: 2)`) — «провал» в движение дела в центральной колонке. Правый инспектор в режиме движения — **переключатель судебных актов** (1-я инстанция / апелляция / кассация) с цветными точками инстанций; кнопки «отдельное окно» и PDF работают на выбранный акт. |
| `Sources/SudrfApp/SearchModel.swift` | Состояние движения: `movement`, `loadingMovement`, `selectedActID`, `expandedComplaints`; методы `openMovement(_:)`, `selectAct(_:)`, `toggleComplaint(_:)`, `exitMovement()`. `MovementService` создаётся с доменами вышестоящих судов для поиска по УИД. |

## Как подключить реальную сборку движения

В `MovementService.movement(for:court:cartoteka:)` (файл `Movement.swift`)
замените демо-возврат на:
1. `client.fetchCard(…)` 1-й инстанции → журнал заседаний + текст акта;
2. для каждого вышестоящего суда: поиск по УИД (`SearchField.uid`) →
   `fetchCard` найденной карточки → инстанция `.appeal` / `.cassation`;
3. частные жалобы — из размеченных `CaseCardParser` событий-определений.

Подписи моделей и UI при этом не меняются.

## Не тронуто

Ядро (`SudrfClient`, `ResultsParser`, `DistrictCourtResolver`, `CourtDirectory`,
`Cartoteka`, `CaseCardParser` …), CLI и тесты — без изменений.
Файлы прошлых правок (`ActTextView.swift`, `ActWindow.swift`, бел. фон акта,
постраничный PDF A4 с засечками) остаются в силе.

## Документация

`Docs/Sudrf SwiftUI Handoff.html` — спецификация передачи.
Требования: macOS 13+. HTML-прототип-источник: «Sudrf Prototype — Direction A v3.html».
