//  CalendarScreen.swift — Sudrf · раздел «Календарь» (v15, реальные даты)
//  Прежде календарь жил на «индексе дня в июне». Теперь события приходят из
//  движения отслеживаемых дел и разнесены по реальным датам и месяцам, поэтому
//  сетка строится для произвольного месяца (router.calMonth) с навигацией.
//  Три вида: большой календарь-месяц (4A) · панель дня справа (4B) · повестка (4C).

import SwiftUI
import SudrfKit

// MARK: - Событие календаря

private enum CalEventKind {
    case hearing
    case deadlineProposed
    case deadlineConfirmed
    case deadlineOverridden
    case deadlineInactive

    var isConfirmedStyle: Bool {
        self == .deadlineConfirmed || self == .deadlineOverridden
    }
}

private struct CalEvent: Identifiable {
    var id: String
    var date: Date
    var sortTime: String
    var kind: CalEventKind
    var chip: String
    var time: String
    var heading: String
    var title: String
    var sub: String
    var caseNumber: String?
    /// Подпись номера для UI; `caseNumber` остаётся сырым значением для открытия дела.
    var displayCaseNumber: String?
    /// Вторая строка для связанного материала; у обычного заседания отсутствует.
    var secondaryLabel: String?
    var deadlineId: String?
    var parties: String = ""
    var court: String = ""
    var room: String = ""
    var judge: String = ""
    /// Вид срока («Апелляционная жалоба» и т. п.) — только у дедлайнов, для
    /// карточки месяца (issue #332): заголовок карточки без опоры на `title`,
    /// который уже включает номер дела.
    var what: String? = nil

    var accent: Color {
        switch kind {
        case .hearing:           return Color.accentColor
        case .deadlineProposed:  return Palette.proposed
        case .deadlineConfirmed: return Palette.confirmed
        case .deadlineOverridden: return Palette.confirmed
        case .deadlineInactive: return Color.secondary
        }
    }
}

/// Представление федерального производственного дня для всех режимов
/// календаря. Оно отделено от SwiftUI, чтобы месяц, неделя и карточка дня
/// говорили об одном и том же основании без повторного разбора ресурсов.
struct ProductionCalendarDayPresentation: Equatable {
    let kind: LegalDayKind?
    let isShortened: Bool
    let title: String
    let symbol: String
    let accessibilityLabel: String
    let reasons: [LegalCalendarReason]
    let sources: [LegalCalendarSource]

    init(date: Date, calendar: LegalCalendar?, timeZone: TimeZone) {
        guard let calendar, let day = calendar.day(on: date, timeZone: timeZone) else {
            kind = nil
            isShortened = false
            title = "Производственный календарь не подтверждён"
            symbol = "?"
            accessibilityLabel = title
            reasons = []
            sources = []
            return
        }

        kind = day.kind
        isShortened = day.isShortened
        let base: String
        let marker: String
        switch day.kind {
        case .working:
            base = "Рабочий день"
            marker = "•"
        case .weekend:
            base = "Выходной день"
            marker = "◦"
        case .holiday:
            base = "Нерабочий праздничный день"
            marker = "✦"
        case .transferredDayOff:
            base = "Перенесённый выходной"
            marker = "↷"
        case .transferredWorkingDay:
            base = "Рабочий день по переносу"
            marker = "↺"
        case .specialNonWorking:
            base = "Специальный нерабочий день"
            marker = "!"
        }
        title = day.isShortened ? "\(base) · сокращённый" : base
        // Сокращённость видна и в сетке, где подробная подпись дня ещё не
        // открыта; для VoiceOver она разворачивается в `accessibilityLabel`.
        symbol = day.isShortened ? "\(marker)½" : marker
        accessibilityLabel = "Производственный календарь: \(title)"
        reasons = day.reasonIDs.compactMap(calendar.reason(id:))
        let reasonSourceIDs = reasons.flatMap(\.sourceIDs)
        let calendarSourceID = calendar.revision(for: day.date.year)?.calendarSourceID
        let sourceIDs = reasonSourceIDs + (calendarSourceID.map { [$0] } ?? [])
        var seen = Set<String>()
        sources = sourceIDs.filter { seen.insert($0).inserted }.compactMap(calendar.source(id:))
    }

    var isNonWorking: Bool {
        guard let kind else { return false }
        switch kind {
        case .working, .transferredWorkingDay: return false
        case .weekend, .holiday, .transferredDayOff, .specialNonWorking: return true
        }
    }

    var isConfirmed: Bool { kind != nil }
}

struct CalendarScreen: View {
    @EnvironmentObject var router: AppRouter
    /// Встроенный архив неизменен до перезапуска приложения; его декодирование
    /// не должно повторяться для каждой ячейки и каждого досье.
    private static let legalCalendar: LegalCalendar? = try? LegalCalendar.load()
    /// Фактический размер строки сетки месяца (все строки равны) — читается из
    /// `MonthRowSizeKey`: высота нужна `cellLayout`, чтобы понять, сколько
    /// карточек влезает без прокрутки (решение 6); ширина — чтобы посчитать
    /// узкую колонку выходных от РЕАЛЬНОЙ ширины окна, а не угадывать константу
    /// (ревью решения 8: 92pt оказалось шире будничной колонки при открытой
    /// панели дня на 1180pt).
    @State private var monthRowHeight: CGFloat = 0
    @State private var monthGridWidth: CGFloat = 0

    var body: some View {
        Group {
            if router.calMode == .month {
                monthMode
            } else if router.calMode == .week {
                weekMode
            } else {
                agendaMode
            }
        }
        .padding(EdgeInsets(top: NavChrome.contentInset, leading: 18, bottom: 18, trailing: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .sudrfContent).ignoresSafeArea())
    }

    // MARK: Сбор событий

    private var events: [CalEvent] {
        var out: [CalEvent] = []
        var seenIDs: [String: Int] = [:]
        func uniqueID(_ base: String) -> String {
            let seen = seenIDs[base, default: 0]
            seenIDs[base] = seen + 1
            return seen == 0 ? base : "\(base)#\(seen + 1)"
        }
        for h in router.calendarHearings {
            let primaryCaseNumber = CaseNumberPresentation.primary(h.caseNumber)
            let secondaryLabel = h.instanceLevel == .material ? h.secondaryLabel : nil
            let displayCaseNumber = secondaryLabel == nil
                ? h.reviewNumber ?? primaryCaseNumber
                : primaryCaseNumber
            out.append(CalEvent(id: uniqueID("hearing#\(h.id)"),
                date: h.date, sortTime: h.time, kind: .hearing,
                chip: "\(h.time) заседание · \(displayCaseNumber)", time: h.time, heading: "ЗАСЕДАНИЕ",
                title: "№ \(displayCaseNumber) — \(h.parties)",
                sub: "\(h.court)" + (h.room.isEmpty ? "" : " · \(h.room)"),
                caseNumber: h.caseNumber, displayCaseNumber: displayCaseNumber,
                secondaryLabel: secondaryLabel,
                deadlineId: nil,
                parties: h.parties, court: h.court, room: h.room, judge: h.judge))
        }
        for d in router.deadlines + router.inactiveDeadlines {
            let kind: CalEventKind
            let chipPrefix: String
            let heading: String
            if d.lifecycle != .active {
                kind = .deadlineInactive
                chipPrefix = "срок · история · "
                heading = d.lifecycle == .superseded
                    ? "ДЕДЛАЙН · ЗАМЕНЁН" : "ДЕДЛАЙН · ИСТЁК БЕЗ ПОДТВЕРЖДЕНИЯ"
            } else if d.status == .overridden {
                kind = .deadlineOverridden
                chipPrefix = "срок · вручную · "
                heading = "ДЕДЛАЙН · ДАТА ИЗМЕНЕНА"
            } else if d.status == .confirmed {
                kind = .deadlineConfirmed
                chipPrefix = "срок · "
                heading = "ДЕДЛАЙН · ПОДТВЕРЖДЁН"
            } else {
                kind = .deadlineProposed
                chipPrefix = "срок? "
                heading = "ДЕДЛАЙН · РАСЧЁТНЫЙ"
            }
            out.append(CalEvent(id: uniqueID("deadline#\(d.id)"),
                date: d.date, sortTime: "99:99",
                kind: kind, chip: chipPrefix + d.calLabel,
                time: "срок", heading: heading,
                title: "\(d.what) · № \(CaseNumberPresentation.primary(d.caseNumber))", sub: d.basis,
                caseNumber: d.caseNumber, displayCaseNumber: CaseNumberPresentation.primary(d.caseNumber),
                secondaryLabel: nil,
                deadlineId: d.id, what: d.what))
        }
        return out
    }
    private func events(on date: Date) -> [CalEvent] {
        events.filter { DateUtil.sameDay($0.date, date) }.sorted { $0.sortTime < $1.sortTime }
    }

    private func productionDay(_ date: Date) -> ProductionCalendarDayPresentation {
        ProductionCalendarDayPresentation(date: date, calendar: Self.legalCalendar,
                                          timeZone: DateUtil.cal.timeZone)
    }

    private var calendarCoverage: String {
        guard let calendar = Self.legalCalendar else {
            return "Производственный календарь не подтверждён"
        }
        let years = calendar.archive.revisions.map(\.year)
        guard let first = years.min(), let last = years.max() else {
            return "Производственный календарь не подтверждён"
        }
        return "Федеральный производственный календарь \(first)–\(last) · региональные праздники не учитываются"
    }

    private var productionCalendarNotice: some View {
        HStack(spacing: 5) {
            Image(systemName: "calendar")
            Text(calendarCoverage)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .accessibilityLabel(calendarCoverage)
        .padding(.horizontal, 3)
    }

    // MARK: Сетка месяца (произвольный месяц)

    private var weeks: [[Date?]] {
        var cells: [Date?] = Array(repeating: nil, count: DateUtil.leadingBlanks(forMonth: router.calMonth))
        cells += DateUtil.datesOfMonth(router.calMonth).map { Optional($0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0+7]) }
    }
    private var weekDays: [Date] {
        let start = DateUtil.startOfWeek(router.calWeekStart)
        return (0..<7).map { DateUtil.addDays(start, $0) }
    }

    // MARK: Режим МЕСЯЦ (4A / 4B)

    private var monthMode: some View {
        let model = buildMonthModel()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(DateUtil.monthTitle(router.calMonth)).font(.system(size: 22, weight: .bold))
                navCapsule(title: "Сегодня",
                           previous: "Предыдущий месяц",
                           next: "Следующий месяц",
                           onPrevious: { router.calStep(-1) },
                           onTitle: {
                               router.calMonth = DateUtil.startOfMonth(DateUtil.today)
                               router.calWeekStart = DateUtil.startOfWeek(DateUtil.today)
                               router.calSelectedDate = DateUtil.today
                           },
                           onNext: { router.calStep(1) })
                if !model.overlapDayList.isEmpty {
                    overlapCounterButton(model)
                }
                Spacer()
                monthLegend
                calendarModePicker
            }
            .padding(.horizontal, 2)
            productionCalendarNotice

            HStack(alignment: .top, spacing: 12) {
                monthGrid(model).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let day = router.calSelectedDate {
                    dayPanel(day).frame(width: 360)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: router.calSelectedDate)
        }
    }

    // MARK: Модель месяца (issue #332) — считается ОДИН РАЗ на вычисление тела
    // `monthMode`, а не по разу на каждую из 35 ячеек: короткие имена судов и
    // сокращение сторон используют регулярки (`CourtNamePresentation`,
    // `PartyNamePresentation`), накладки и серии — сравнение всех заседаний
    // месяца между собой. Раньше `events(on:)` заново фильтровал весь список
    // событий в каждой ячейке — здесь события группируются по дню один раз.

    private struct MonthModel {
        var itemsByDay: [Date: [CalEvent]] = [:]        // карточки дня (без «истории»), уже отсортированы
        var inactiveCountByDay: [Date: Int] = [:]        // сроки «в истории» — только счётчик
        var overlapDays: Set<Date> = []
        var overlapDayList: [Date] = []                  // отсортированы — для «Накладки: N дней»
        var overlapByID: [String: CalendarMonthOverlap] = [:]
        var seriesByID: [String: (index: Int, total: Int)] = [:]
        var courtShort: [String: String] = [:]           // сырой court заседания → короткое имя (с учётом коллизий)
        var courtTier: [String: CourtTier?] = [:]        // сырой court заседания → звено
    }

    private func buildMonthModel() -> MonthModel {
        let monthDays = Set(DateUtil.datesOfMonth(router.calMonth).map { DateUtil.startOfDay($0) })
        let monthEvents = events.filter { monthDays.contains(DateUtil.startOfDay($0.date)) }
        let hearings = monthEvents.filter { $0.kind == .hearing }

        let courtRaws = hearings.map(\.court)
        let courtKeys = CourtNamePresentation.canonicalKeys(courtRaws)
        let courtShorts = CourtNamePresentation.disambiguatedShortNames(courtRaws)
        var courtTier: [String: CourtTier?] = [:]
        for raw in Set(courtRaws) { courtTier[raw] = CourtNamePresentation.display(raw).tier }

        let hearingInputs = hearings.map { ev in
            CalendarMonthHearingInput(id: ev.id, date: ev.date, time: ev.time,
                                       caseNumber: ev.caseNumber ?? ev.id,
                                       courtKey: courtKeys[ev.court] ?? ev.court,
                                       courtShort: courtShorts[ev.court] ?? ev.court)
        }
        let overlapByID = CalendarMonthLayout.overlaps(hearingInputs)
        let overlapDayList = CalendarMonthLayout.overlapDays(hearingInputs)
        let seriesByID = CalendarMonthLayout.seriesPositions(hearingInputs)

        var itemsByDay: [Date: [CalEvent]] = [:]
        var inactiveCountByDay: [Date: Int] = [:]
        for ev in monthEvents {
            let day = DateUtil.startOfDay(ev.date)
            if ev.kind == .deadlineInactive {
                inactiveCountByDay[day, default: 0] += 1
            } else {
                itemsByDay[day, default: []].append(ev)
            }
        }
        for day in itemsByDay.keys {
            itemsByDay[day]?.sort {
                CalendarMonthLayout.sortKey(isDeadline: $0.kind != .hearing, time: $0.time) <
                CalendarMonthLayout.sortKey(isDeadline: $1.kind != .hearing, time: $1.time)
            }
        }

        return MonthModel(itemsByDay: itemsByDay, inactiveCountByDay: inactiveCountByDay,
                           overlapDays: Set(overlapDayList), overlapDayList: overlapDayList,
                           overlapByID: overlapByID, seriesByID: seriesByID,
                           courtShort: courtShorts, courtTier: courtTier)
    }

    private func overlapCounterButton(_ model: MonthModel) -> some View {
        let count = model.overlapDayList.count
        let label = "Накладки: \(count) \(DateUtil.plural(count, "день", "дня", "дней"))"
        return Button {
            if let next = CalendarMonthLayout.nextOverlapDay(after: DateUtil.today, in: model.overlapDayList) {
                router.calMonth = DateUtil.startOfMonth(next)
                router.calSelectedDate = next
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                Text(label)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.confirmed)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Palette.confirmed.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label). Перейти к ближайшему дню с накладкой.")
    }

    /// Легенда месяца: цвета звеньев суда + статусы сроков + метка накладки.
    /// Легенда недели (`legend`) — отдельная и не меняется (#332 — только месяц).
    /// Заголовок месяца (заголовок + навигация + счётчик накладок + легенда +
    /// переключатель вида) не должен переполняться на 1100–1180pt — легенда
    /// схлопывается по ширине первой (решение автора при ревью): полная →
    /// только звенья → ничего.
    private var monthLegend: some View {
        ViewThatFits(in: .horizontal) {
            monthLegendFull
            monthLegendTiersOnly
            EmptyView()
        }
    }
    private var monthLegendFull: some View {
        HStack(spacing: 12) {
            monthLegendTiersOnly
            Divider().frame(height: 12)
            legendItem(Palette.confirmed, "срок · подтверждён", dashed: false)
            legendItem(Palette.proposed, "срок · расчётный", dashed: true)
            HStack(spacing: 4) {
                Text("накладка")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Capsule().fill(Palette.confirmed))
                Text("разные суды")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
    private var monthLegendTiersOnly: some View {
        HStack(spacing: 12) {
            Text("Звено").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(CourtTier.allCases) { tier in
                legendSwatch(CourtTierPalette.color(tier), tierLegendLabel(tier))
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
    private func legendSwatch(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
            Text(t)
        }
    }
    private func tierLegendLabel(_ tier: CourtTier) -> String {
        switch tier {
        case .district:   return "районный"
        case .subject:    return "суд субъекта"
        case .appeal:     return "АСОЮ"
        case .cassation:  return "КСОЮ"
        case .supreme:    return "ВС РФ"
        case .magistrate: return "мировой"
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Color.accentColor, "заседание", dashed: false)
            legendItem(Palette.confirmed, "срок · подтверждён", dashed: false)
            legendItem(Color(red: 0.79, green: 0.54, blue: 0.12), "срок · расчётный", dashed: true)
            if router.calMode == .week {
                HStack(spacing: 5) {
                    Text("⚠").font(.system(size: 10, weight: .bold))
                    Text("разные суды")
                }
                .foregroundStyle(Palette.confirmed)
                .fontWeight(.semibold)
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }
    private func legendItem(_ c: Color, _ t: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            if dashed {
                RoundedRectangle(cornerRadius: 2).strokeBorder(c, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    .frame(width: 9, height: 9)
            } else {
                Circle().fill(c).frame(width: 8, height: 8)
            }
            Text(t)
        }
    }

    /// #329: навигация «‹ Сегодня ›» — одна стеклянная капсула той же конструкции,
    /// что переключатели режима календаря и вида «Моих дел»: общая подложка
    /// .glassEffect, внутри — простые кнопки. Системный ControlGroup и слияние
    /// .glass-кнопок на macOS 26 дают другой вид (серая плашка, разрозненные стрелки).
    private func navCapsule(title: LocalizedStringKey,
                            titleEnabled: Bool = true,
                            previous: LocalizedStringKey,
                            next: LocalizedStringKey,
                            onPrevious: @escaping () -> Void,
                            onTitle: @escaping () -> Void,
                            onNext: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(previous)
            Divider().frame(height: 12)
            Button(action: onTitle) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(titleEnabled ? Color.primary : Color.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .contentShape(Rectangle())
            }
            .disabled(!titleEnabled)
            Divider().frame(height: 12)
            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(next)
        }
        .buttonStyle(.plain)
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
    }

    private var calendarModePicker: some View {
        HStack(spacing: 2) {
            ForEach(CalMode.allCases, id: \.self) { mode in
                let active = router.calMode == mode
                Button { withAnimation(.easeOut(duration: 0.18)) { router.setCalMode(mode) } } label: {
                    Text(mode.title)
                        .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? Color.accentColor : .secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 22)
                        .background(
                            Capsule()
                                .fill(active ? Color(nsColor: .textBackgroundColor).opacity(0.92) : .clear)
                                .shadow(color: .black.opacity(active ? 0.14 : 0), radius: 2, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5))
    }

    // Выходные — узкие колонки (решение 8), фиксированная ширина — потолок:
    // при открытой панели дня на 1180pt эта константа шире будничной колонки
    // (ревью), поэтому реальная ширина считается от ИЗМЕРЕННОЙ ширины сетки
    // (`monthGridWidth`, та же техника, что и высота строки) и никогда не
    // превышает потолок. До первого измерения (ширина ещё 0) используется
    // потолок как безопасное значение по умолчанию.
    private static let weekendColumnWidthCeiling: CGFloat = 92
    /// Будничная ширина, взятая для оценки «0.6× будничной» колонки — здесь
    /// используется РАВНОМЕРНОЕ деление (gridWidth / 7) как приближение
    /// будничной ширины: точная неподвижная точка (ширина выходных зависит от
    /// будничной, а та — от ширины выходных) не стоит усложнения ради
    /// «примерно 0.6×» из решения ревью.
    private var weekendColumnWidth: CGFloat {
        guard monthGridWidth > 0 else { return Self.weekendColumnWidthCeiling }
        let approxWeekdayWidth = monthGridWidth / 7
        return min(Self.weekendColumnWidthCeiling, approxWeekdayWidth * 0.6)
    }
    /// nil, пока ширина сетки не измерена — тогда колонка использует прежнее
    /// поведение (`.frame(maxWidth: .infinity)`), чтобы не схлопнуться в 0.
    private var weekdayColumnWidth: CGFloat? {
        guard monthGridWidth > 0 else { return nil }
        return max(0, (monthGridWidth - 2 * weekendColumnWidth) / 5)
    }
    // Заголовок ячейки (символ производственного календаря / бейджи / число
    // дня) — фиксированная высота, чтобы `cellLayout` мог вычесть её из
    // высоты строки и получить точную высоту под карточки.
    private static let dayHeaderHeight: CGFloat = 22
    private static let dayCellVerticalPadding: CGFloat = 13 // top 5 + bottom 8

    private func monthGrid(_ model: MonthModel) -> some View {
        CardBox {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(DateUtil.weekdayShort.enumerated()), id: \.offset) { idx, w in
                        Text(w).font(.system(size: 10, weight: .bold)).kerning(0.4)
                            .foregroundStyle(.tertiary)
                            .modifier(ColumnWidth(isWeekend: idx >= 5,
                                                  weekendWidth: weekendColumnWidth,
                                                  weekdayWidth: weekdayColumnWidth))
                    }
                }
                .padding(.vertical, 7)
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { idx, day in
                            dayCell(day, isWeekend: idx >= 5, model: model)
                        }
                    }
                    // maxWidth обязателен: колонки после первого замера фиксированы,
                    // и без него строка мерила бы сумму прежних ширин, а не окно.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: MonthRowSizeKey.self, value: geo.size)
                    })
                    .overlay(Divider(), alignment: .top)
                }
            }
        }
        .onPreferenceChange(MonthRowSizeKey.self) { size in
            monthRowHeight = size.height
            monthGridWidth = size.width
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date?, isWeekend: Bool, model: MonthModel) -> some View {
        if let day {
            let isToday = DateUtil.isToday(day)
            let isSel = router.calSelectedDate.map { DateUtil.sameDay($0, day) } ?? false
            let key = DateUtil.startOfDay(day)
            let items = model.itemsByDay[key] ?? []
            let inactiveCount = model.inactiveCountByDay[key] ?? 0
            let hasOverlap = model.overlapDays.contains(key)
            let production = productionDay(day)
            let isPast = day < DateUtil.today && !isToday
            let available = max(0, monthRowHeight - Self.dayHeaderHeight
                                 - Self.dayCellVerticalPadding - CalendarMonthLayout.itemSpacing)
            let layout = CalendarMonthLayout.cellLayout(itemCount: items.count, availableHeight: available)
            Button { router.calSelectedDate = day } label: {
                VStack(alignment: .leading, spacing: CalendarMonthLayout.itemSpacing) {
                    HStack(spacing: 5) {
                        Text(production.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(productionTint(production))
                            .accessibilityHidden(true)
                        if inactiveCount > 0 { historyBadge(inactiveCount) }
                        if hasOverlap { overlapBadge }
                        Spacer(minLength: 0)
                        Text("\(DateUtil.cal.component(.day, from: day))")
                            .font(.system(size: 11.5, weight: isToday || isSel ? .bold : .medium))
                            .foregroundStyle(isToday ? .white : (isSel ? Color.accentColor : .primary))
                            .frame(minWidth: 22, minHeight: 22)
                            .background(
                                Circle().fill(isToday ? Color.accentColor
                                              : (isSel ? Color.accentColor.opacity(0.16) : .clear)))
                    }
                    .frame(height: Self.dayHeaderHeight)
                    monthCellBody(items: items, layout: layout, model: model)
                        .opacity(isPast ? 0.7 : 1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.top, 5).padding(.bottom, 8)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .modifier(ColumnWidth(isWeekend: isWeekend, weekendWidth: weekendColumnWidth,
                                      weekdayWidth: weekdayColumnWidth))
                .background(isSel ? Color.accentColor.opacity(0.06)
                            : productionBackground(production))
                .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.primary.opacity(0.04)), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dayCellAccessibilityLabel(day, production: production, items: items,
                                                           layout: layout, model: model,
                                                           hasOverlap: hasOverlap,
                                                           inactiveCount: inactiveCount))
        } else {
            Color.primary.opacity(0.02)
                .frame(maxHeight: .infinity)
                .modifier(ColumnWidth(isWeekend: isWeekend, weekendWidth: weekendColumnWidth,
                                      weekdayWidth: weekdayColumnWidth))
                .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.primary.opacity(0.04)), alignment: .leading)
        }
    }

    /// Полный текст видимых карточек дня — иначе он «проглатывается» общей
    /// кнопкой ячейки: `.accessibilityElement(children: .ignore)` на каждой
    /// карточке (нужен, чтобы VoiceOver не читал их построчно как отдельные
    /// элементы внутри кнопки) означает, что их `.accessibilityLabel` нигде
    /// не звучит, если не добавить его сюда явно (ревью решения 7).
    private func dayCellAccessibilityLabel(_ day: Date, production: ProductionCalendarDayPresentation,
                                           items: [CalEvent], layout: CalendarMonthCellLayout,
                                           model: MonthModel, hasOverlap: Bool, inactiveCount: Int) -> String {
        let hearingsCount = items.filter { $0.kind == .hearing }.count
        let deadlineCount = items.filter { $0.kind != .hearing }.count
        var parts = [DateUtil.fmt(day), production.accessibilityLabel, summary(hearingsCount, deadlineCount)]
        if hasOverlap { parts.append("есть накладка") }
        if inactiveCount > 0 {
            parts.append("\(inactiveCount) \(DateUtil.plural(inactiveCount, "срок", "срока", "сроков")) в истории")
        }
        let visible: [CalEvent]
        switch layout.mode {
        case .twoLine, .oneLine: visible = items
        case .oneLineWithMore:   visible = Array(items.prefix(layout.visibleCount))
        }
        parts.append(contentsOf: visible.map { itemAccessibilityText($0, model: model) })
        if layout.hiddenCount > 0 { parts.append("ещё \(layout.hiddenCount) скрыто") }
        return parts.joined(separator: ". ")
    }

    private func itemAccessibilityText(_ ev: CalEvent, model: MonthModel) -> String {
        if ev.kind == .hearing {
            let overlap = model.overlapByID[ev.id]
            let seriesLabel = model.seriesByID[ev.id].map { "\($0.index) из \($0.total)" }
            return hearingAccessibilityLabel(ev, overlap: overlap, seriesLabel: seriesLabel)
        }
        let what = ev.what ?? ""
        let number = ev.displayCaseNumber ?? ev.caseNumber ?? ""
        return "Срок: \(what), № \(number), \(deadlineStatusText(ev))"
    }

    private func historyBadge(_ count: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "clock").font(.system(size: 8.5))
            Text("\(count)").font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(.tertiary)
        .help("\(count) \(DateUtil.plural(count, "срок", "срока", "сроков")) в истории")
    }

    /// В узкой (выходной) колонке символ дня + бейдж истории + бейдж накладки
    /// + число дня легко превышают ~70pt — «накладка» текстом схлопывается до
    /// компактного «!» (ревью решения 5); история — не трогаем, она и так
    /// компактна.
    private var overlapBadge: some View {
        ViewThatFits(in: .horizontal) {
            overlapBadgeFull
            overlapBadgeCompact
        }
    }
    private var overlapBadgeFull: some View {
        Text("накладка")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(Palette.confirmed))
            .help("Накладка: заседания в разных судах")
    }
    private var overlapBadgeCompact: some View {
        Text("!")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Palette.confirmed))
            .help("Накладка: заседания в разных судах")
    }

    // MARK: Плотность ячейки — двухстрочные / однострочные / «ещё N» (решение 6)

    @ViewBuilder
    private func monthCellBody(items: [CalEvent], layout: CalendarMonthCellLayout, model: MonthModel) -> some View {
        VStack(alignment: .leading, spacing: CalendarMonthLayout.itemSpacing) {
            switch layout.mode {
            case .twoLine:
                ForEach(items) { ev in cardView(ev, model: model, twoLine: true) }
            case .oneLine:
                ForEach(items) { ev in cardView(ev, model: model, twoLine: false) }
            case .oneLineWithMore:
                ForEach(items.prefix(layout.visibleCount)) { ev in cardView(ev, model: model, twoLine: false) }
                if layout.hiddenCount > 0 { moreLabel(layout.hiddenCount) }
            }
        }
    }

    @ViewBuilder
    private func cardView(_ ev: CalEvent, model: MonthModel, twoLine: Bool) -> some View {
        if ev.kind == .hearing {
            if twoLine { hearingCardTwoLine(ev, model: model) } else { hearingCardOneLine(ev, model: model) }
        } else {
            if twoLine { deadlineCardTwoLine(ev) } else { deadlineCardOneLine(ev) }
        }
    }

    /// «ещё N» — не отдельная кнопка: клик по ней и так попадает в кнопку всей
    /// ячейки дня (`dayCell`), которая уже выполняет то же действие
    /// (`calSelectedDate = day`) — вложенные `Button` в SwiftUI ненадёжны.
    private func moreLabel(_ hidden: Int) -> some View {
        HStack(spacing: 2) {
            Text("ещё \(hidden)")
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.accentColor)
        .frame(height: CalendarMonthLayout.moreHeight, alignment: .leading)
        .help("Открыть панель дня")
    }

    // MARK: Карточка заседания (решение 1–2)

    private func partiesView(_ parties: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(PartyNamePresentation.level1(parties)).lineLimit(1)
            Text(PartyNamePresentation.level2(parties)).lineLimit(1)
            Text(PartyNamePresentation.level2(parties)).lineLimit(1).truncationMode(.tail)
        }
    }

    /// Полный текст номера — для `.help`/VoiceOver, никогда не сокращается.
    private func hearingNumberFullLabel(_ ev: CalEvent) -> String {
        ev.secondaryLabel ?? "№ \(ev.displayCaseNumber ?? ev.caseNumber ?? "")"
    }

    /// Для карточки: у материала «Материал № 13-2471/2026» не влезает даже в
    /// одну будничную колонку — показываем «мат. 13-2471/2026» (ревью решения
    /// 7), полный текст остаётся в `.help`/VoiceOver через `hearingNumberFullLabel`.
    private func hearingNumberLabel(_ ev: CalEvent) -> String {
        guard let secondary = ev.secondaryLabel else {
            return "№ \(ev.displayCaseNumber ?? ev.caseNumber ?? "")"
        }
        if let range = secondary.range(of: "Материал № ") {
            return "мат. " + secondary[range.upperBound...]
        }
        if secondary.hasPrefix("Материал") {
            return "мат." + secondary.dropFirst("Материал".count)
        }
        return secondary
    }

    @ViewBuilder
    private func hearingTrailingNote(overlap: CalendarMonthOverlap?, seriesLabel: String?) -> some View {
        if let overlap {
            ViewThatFits(in: .horizontal) {
                Text("↔ \(overlap.otherCourtShort) \(overlap.otherTime)")
                Text("↔ \(overlap.otherTime)")
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Palette.confirmed)
            .lineLimit(1)
        } else if let seriesLabel {
            ViewThatFits(in: .horizontal) {
                Text(seriesLabel)
                Color.clear.frame(width: 0, height: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func hearingHelpText(_ ev: CalEvent, overlap: CalendarMonthOverlap?) -> String {
        var s = "\(ev.time) · \(ev.parties)\n\(hearingNumberFullLabel(ev)) · \(ev.court)"
        if let overlap { s += "\nНакладка: \(overlap.otherCourtShort) \(overlap.otherTime)" }
        return s
    }

    private func hearingAccessibilityLabel(_ ev: CalEvent, overlap: CalendarMonthOverlap?, seriesLabel: String?) -> String {
        var s = "Заседание \(ev.time), \(ev.parties), \(hearingNumberFullLabel(ev)), \(ev.court)"
        if let overlap {
            s += ". Накладка с заседанием в \(overlap.otherCourtShort) в \(overlap.otherTime)"
        } else if let seriesLabel {
            s += ". \(seriesLabel) заседаний по этому делу"
        }
        return s
    }

    private func courtText(_ s: String, color: Color) -> Text {
        Text(s).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
    }
    private func numberText(_ s: String) -> Text {
        Text(s).font(.system(size: 10.5)).foregroundStyle(.secondary)
    }

    /// Вторая строка двухстрочной карточки: суд + номер + пометка накладки/серии
    /// не помещаются в будничную колонку (~78pt при открытой панели дня на
    /// 1180pt) — «Сыктывкарский № 2-3685/2026» ≈150pt. Лестница по ширине
    /// (решение автора при ревью): суд+номер+пометка → суд+номер → номер →
    /// суд. Номер и распознанное короткое имя суда — `.fixedSize()` (никогда
    /// не обрезаются многоточием, это idle-требование issue); нераспознанный
    /// суд (`tier == nil`) — исключение: `short == full`, может быть сколь
    /// угодно длинным, поэтому он не участвует в лестнице через `.fixedSize()`,
    /// а обрезается многоточием сам.
    @ViewBuilder
    private func hearingSecondLine(_ ev: CalEvent, model: MonthModel,
                                   overlap: CalendarMonthOverlap?, seriesLabel: String?) -> some View {
        let tier = model.courtTier[ev.court] ?? nil
        let color = CourtTierPalette.color(tier)
        let courtShort = model.courtShort[ev.court] ?? ev.court
        let number = hearingNumberLabel(ev)

        if tier == nil {
            HStack(spacing: 6) {
                courtText(courtShort, color: color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                numberText(number).fixedSize()
                Spacer(minLength: 0)
                hearingTrailingNote(overlap: overlap, seriesLabel: seriesLabel)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    courtText(courtShort, color: color).fixedSize()
                    numberText(number).fixedSize()
                    Spacer(minLength: 0)
                    hearingTrailingNote(overlap: overlap, seriesLabel: seriesLabel)
                }
                HStack(spacing: 6) {
                    courtText(courtShort, color: color).fixedSize()
                    numberText(number).fixedSize()
                }
                HStack(spacing: 6) {
                    numberText(number).fixedSize()
                }
                HStack(spacing: 6) {
                    courtText(courtShort, color: color).fixedSize()
                }
            }
        }
    }

    private func hearingCardTwoLine(_ ev: CalEvent, model: MonthModel) -> some View {
        let tier = model.courtTier[ev.court] ?? nil
        let color = CourtTierPalette.color(tier)
        let tint = CourtTierPalette.tint(tier)
        let overlap = model.overlapByID[ev.id]
        let series = model.seriesByID[ev.id]
        let seriesLabel = series.map { "\($0.index) из \($0.total)" }
        let timeColor = overlap != nil ? Palette.confirmed : color

        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ev.time)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(timeColor)
                partiesView(ev.parties)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            hearingSecondLine(ev, model: model, overlap: overlap, seriesLabel: seriesLabel)
        }
        .padding(EdgeInsets(top: 3, leading: 6, bottom: 4, trailing: 6))
        .frame(maxWidth: .infinity, minHeight: CalendarMonthLayout.twoLineHeight,
               maxHeight: CalendarMonthLayout.twoLineHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(overlap != nil ? Palette.confirmed.opacity(0.55) : .clear, lineWidth: 1.5))
        .clipped()
        .help(hearingHelpText(ev, overlap: overlap))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hearingAccessibilityLabel(ev, overlap: overlap, seriesLabel: seriesLabel))
    }

    private func hearingCardOneLine(_ ev: CalEvent, model: MonthModel) -> some View {
        let tier = model.courtTier[ev.court] ?? nil
        let color = CourtTierPalette.color(tier)
        let tint = CourtTierPalette.tint(tier)
        let overlap = model.overlapByID[ev.id]
        let timeColor = overlap != nil ? Palette.confirmed : color

        return HStack(spacing: 6) {
            Text(ev.time)
                .font(.system(size: 11.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(timeColor)
            partiesView(ev.parties)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: CalendarMonthLayout.oneLineHeight,
               maxHeight: CalendarMonthLayout.oneLineHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(tint))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(overlap != nil ? Palette.confirmed.opacity(0.55) : .clear, lineWidth: 1.5))
        .clipped()
        .help(hearingHelpText(ev, overlap: overlap))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hearingAccessibilityLabel(ev, overlap: overlap, seriesLabel: nil))
    }

    // MARK: Карточка срока (решение 6 — только действующие; «история» — бейдж в шапке дня)

    private func deadlineStatusText(_ ev: CalEvent) -> String {
        if DateUtil.isToday(ev.date) { return "сегодня последний день" }
        switch ev.kind {
        case .deadlineConfirmed:   return "подтверждён"
        case .deadlineOverridden:  return "изменён вручную"
        case .deadlineProposed:    return "расчётный"
        default:                   return ""
        }
    }

    private static let shortDeadlineKinds: [String: String] = [
        "Апелляционная жалоба": "Апел. жалоба",
        "Кассационная жалоба": "Касс. жалоба"
    ]
    private func shortDeadlineKind(_ what: String) -> String {
        Self.shortDeadlineKinds[what] ?? what
    }

    private func deadlineCardTwoLine(_ ev: CalEvent) -> some View {
        let confirmedStyle = ev.kind.isConfirmedStyle
        let what = ev.what ?? ""
        let number = ev.displayCaseNumber ?? ev.caseNumber ?? ""
        let status = deadlineStatusText(ev)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "flag.fill").font(.system(size: 8.5))
                Text(what).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Text("№ \(number) · \(status)").font(.system(size: 10.5)).lineLimit(1)
        }
        .foregroundStyle(ev.accent)
        .padding(EdgeInsets(top: 3, leading: 6, bottom: 4, trailing: 6))
        .frame(maxWidth: .infinity, minHeight: CalendarMonthLayout.twoLineHeight,
               maxHeight: CalendarMonthLayout.twoLineHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(confirmedStyle ? ev.accent.opacity(0.12) : Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(ev.accent.opacity(confirmedStyle ? 0.35 : 0.75),
                          style: StrokeStyle(lineWidth: 1, dash: confirmedStyle ? [] : [3, 2])))
        .clipped()
        .help("\(what) · № \(number) · \(status)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Срок: \(what), № \(number), \(status)")
    }

    private func deadlineCardOneLine(_ ev: CalEvent) -> some View {
        let confirmedStyle = ev.kind.isConfirmedStyle
        let what = ev.what ?? ""
        let number = ev.displayCaseNumber ?? ev.caseNumber ?? ""
        let status = deadlineStatusText(ev)
        return HStack(spacing: 5) {
            Image(systemName: "flag.fill").font(.system(size: 8))
            Text("\(shortDeadlineKind(what)) · \(number)").font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(ev.accent)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: CalendarMonthLayout.oneLineHeight,
               maxHeight: CalendarMonthLayout.oneLineHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(confirmedStyle ? ev.accent.opacity(0.12) : Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(ev.accent.opacity(confirmedStyle ? 0.35 : 0.75),
                          style: StrokeStyle(lineWidth: 1, dash: confirmedStyle ? [] : [3, 2])))
        .clipped()
        .help("\(what) · № \(number) · \(status)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Срок: \(what), № \(number), \(status)")
    }

    // MARK: Панель дня (4B)

    private func dayPanel(_ day: Date) -> some View {
        let evs = events(on: day)
        let hearings = evs.filter { $0.kind == .hearing }
        let deadlines = evs.filter { $0.kind != .hearing }
        let production = productionDay(day)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(DateUtil.weekday(day)), \(DateUtil.fmt(day))").font(.system(size: 15, weight: .bold))
                    Text(summary(hearings.count, deadlines.count)).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button { router.calSelectedDate = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 12))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    productionDayCard(production)
                    if evs.isEmpty {
                        Text("На этот день нет заседаний и сроков")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 26)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .padding(.horizontal, 12)
                    }
                    ForEach(hearings) { ev in hearingCard(ev) }
                    if !deadlines.isEmpty {
                        Text("СРОКИ").font(.system(size: 11, weight: .bold)).kerning(0.3)
                            .foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.top, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(deadlines) { ev in deadlineCard(ev) }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
    }

    private func productionDayCard(_ production: ProductionCalendarDayPresentation) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(production.symbol).font(.system(size: 14, weight: .bold))
                        .foregroundStyle(productionTint(production))
                    Text(production.title).font(.system(size: 11.5, weight: .semibold))
                }
                ForEach(production.reasons, id: \.id) { reason in
                    Text(reason.title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if let note = reason.note, !note.isEmpty {
                        Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                ForEach(production.sources, id: \.id) { source in
                    Link(source.title, destination: source.url)
                        .font(.system(size: 10.5))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(production.accessibilityLabel)
    }

    private func productionTint(_ production: ProductionCalendarDayPresentation) -> Color {
        guard let kind = production.kind else { return .secondary }
        switch kind {
        case .working: return .secondary
        case .transferredWorkingDay: return Palette.green
        case .weekend, .holiday, .transferredDayOff: return Palette.confirmed
        case .specialNonWorking: return Color.orange
        }
    }

    private func productionBackground(_ production: ProductionCalendarDayPresentation) -> Color {
        production.isNonWorking ? Palette.confirmed.opacity(0.035) : .clear
    }

    private func hearingCard(_ ev: CalEvent) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text(ev.time).font(.system(size: 19, weight: .bold)).foregroundStyle(Color.accentColor)
                    StatusChip(text: "заседание", kind: .blue)
                }
                Text(ev.title).font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let label = ev.secondaryLabel {
                    Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Text(ev.sub).font(.system(size: 11)).foregroundStyle(.tertiary)
                if let num = ev.caseNumber {
                    Button("Открыть дело") { router.openCase(num) }.buttonStyle(.glass).controlSize(.small)
                }
            }
            .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }

    private func deadlineCard(_ ev: CalEvent) -> some View {
        CardBox {
            HStack(alignment: .top, spacing: 11) {
                Text(DateUtil.shortDM(ev.date)).font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(ev.accent).frame(width: 62).padding(.vertical, 6)
                    .background(Capsule().fill(ev.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ev.title).font(.system(size: 12, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ev.sub).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let did = ev.deadlineId { DeadlineActions(id: did, compact: true).padding(.top, 5) }
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 11, leading: 14, bottom: 11, trailing: 14))
        }
        .padding(.horizontal, 12)
    }

    private func summary(_ h: Int, _ d: Int) -> String {
        let a = h > 0 ? "\(h) " + DateUtil.plural(h, "заседание", "заседания", "заседаний") : "заседаний нет"
        let b = d > 0 ? "\(d) " + DateUtil.plural(d, "срок", "срока", "сроков") : "сроков нет"
        return "\(a) · \(b)"
    }

    // MARK: Режим НЕДЕЛЯ (4D)

    private var weekMode: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(DateUtil.weekTitle(starting: router.calWeekStart))
                    .font(.system(size: 22, weight: .bold))
                    .frame(minWidth: 150, alignment: .leading)
                navCapsule(title: "Эта неделя",
                           titleEnabled: !DateUtil.sameWeek(router.calWeekStart, DateUtil.today),
                           previous: "Предыдущая неделя",
                           next: "Следующая неделя",
                           onPrevious: { router.calStepWeek(-1) },
                           onTitle: { router.calThisWeek() },
                           onNext: { router.calStepWeek(1) })
                Spacer()
                legend
                calendarModePicker
            }
            .padding(.horizontal, 2)
            productionCalendarNotice

            weekGrid.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var weekGrid: some View {
        CardBox {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section(header: weekPinnedHeader) {
                        weekHourGrid
                    }
                }
            }
        }
    }

    private var weekPinnedHeader: some View {
        VStack(spacing: 0) {
            weekHeader
            weekDeadlineLane
        }
    }

    private var weekHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 56)
            ForEach(Array(weekDays.enumerated()), id: \.offset) { idx, day in
                weekHeaderCell(day, index: idx)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1), alignment: .bottom)
    }

    private func weekHeaderCell(_ day: Date, index: Int) -> some View {
        let isToday = DateUtil.isToday(day)
        let production = productionDay(day)
        let isNonWorking = production.isNonWorking
        let weekdayColor: Color = isToday ? .accentColor : (isNonWorking ? Color.primary.opacity(0.34) : .secondary)
        let numberColor: Color = isToday ? .white : (isNonWorking ? Color.primary.opacity(0.38) : .primary)
        let numberBackground: Color = isToday ? .accentColor : .clear
        return Button {
            router.calSelectedDate = day
            router.setCalMode(.month)
        } label: {
            VStack(spacing: 5) {
                Text(DateUtil.weekdayShort[index])
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(weekdayColor)
                Text("\(DateUtil.cal.component(.day, from: day))")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(numberColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(numberBackground))
                Text(production.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(productionTint(production))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(weekColumnTint(day, index: index))
            .overlay(Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(DateUtil.weekday(day)), \(DateUtil.fmt(day)). \(production.accessibilityLabel)")
        .help("Открыть сведения за \(DateUtil.fmt(day))")
    }

    private var weekDeadlineLane: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("СРОКИ")
                .font(.system(size: 8, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(Color.primary.opacity(0.3))
                .frame(width: 48, alignment: .trailing)
                .padding(.top, 13)
                .padding(.trailing, 8)
            ForEach(Array(weekDays.enumerated()), id: \.offset) { idx, day in
                let deadlines = events(on: day).filter { $0.kind != .hearing }
                let laneHearings = events(on: day).filter {
                    $0.kind == .hearing && !CalendarWeekLayout.isWithinWindow($0.time)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(deadlines) { ev in weekDeadlineChip(ev) }
                    ForEach(laneHearings) { ev in weekNoTimeHearingChip(ev) }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .background(weekColumnTint(day, index: idx))
                .overlay(Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1), alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(Rectangle().fill(Color.black.opacity(0.05)).frame(height: 1), alignment: .bottom)
    }

    private var weekHourGrid: some View {
        let blocksByDay = weekDays.map { CalendarWeekLayout.blocks(for: weekHearingInputs(on: $0)) }
        let height = CGFloat(CalendarWeekLayout.gridHeight(for: blocksByDay))
        return HStack(spacing: 0) {
            weekTimeAxis(height: height).frame(width: 56, height: height)
            ForEach(Array(weekDays.enumerated()), id: \.offset) { idx, day in
                weekDayColumn(day, index: idx, blocks: blocksByDay[idx], height: height)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        .frame(height: height)
    }

    private func weekTimeAxis(height: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            ForEach(CalendarWeekLayout.startHour...CalendarWeekLayout.endHour, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.primary.opacity(0.32))
                    .offset(y: CGFloat(hour - CalendarWeekLayout.startHour) * CGFloat(CalendarWeekLayout.hourHeight) - 6)
                    .padding(.trailing, 8)
            }
        }
        .frame(height: height, alignment: .topTrailing)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func weekDayColumn(_ day: Date, index: Int,
                               blocks: [CalendarWeekBlock],
                               height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            weekColumnBackground(day, index: index, height: height)
            ForEach(blocks) { block in
                weekBlockView(block)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .offset(y: CGFloat(block.top))
            }
        }
        .frame(height: height, alignment: .top)
        .overlay(Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1), alignment: .leading)
    }

    private func weekColumnBackground(_ day: Date, index: Int, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            weekColumnTint(day, index: index)
            ForEach(0...(CalendarWeekLayout.endHour - CalendarWeekLayout.startHour), id: \.self) { i in
                Rectangle()
                    .fill(Color.black.opacity(0.05))
                    .frame(height: 1)
                    .offset(y: CGFloat(i) * CGFloat(CalendarWeekLayout.hourHeight))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .topLeading)
    }

    private func weekColumnTint(_ day: Date, index: Int) -> Color {
        if DateUtil.isToday(day) { return Color.accentColor.opacity(0.05) }
        if productionDay(day).isNonWorking { return Palette.confirmed.opacity(0.025) }
        return .clear
    }

    private func weekHearingInputs(on day: Date) -> [CalendarWeekHearingLayoutInput] {
        events(on: day).filter {
            $0.kind == .hearing && CalendarWeekLayout.isWithinWindow($0.time)
        }.map { ev in
            CalendarWeekHearingLayoutInput(id: ev.id, caseNumber: ev.caseNumber ?? "",
                                           displayCaseNumber: ev.displayCaseNumber,
                                           secondaryLabel: ev.secondaryLabel,
                                           parties: ev.parties, court: ev.court,
                                           room: ev.room, judge: ev.judge, time: ev.time)
        }
    }

    private func weekBlockView(_ block: CalendarWeekBlock) -> some View {
        let height = CGFloat(block.height)
        return Group {
            if block.isSingle, let item = block.hearings.first {
                Button { router.openCase(item.caseNumber) } label: {
                    weekSingleCard(item, conflict: false, height: height)
                }
                .buttonStyle(.plain)
            } else {
                weekStackCard(block)
            }
        }
    }

    private func weekSingleCard(_ item: CalendarWeekHearingLayoutInput,
                                conflict: Bool,
                                height: CGFloat) -> some View {
        let displayCaseNumber = item.displayCaseNumber ?? CaseNumberPresentation.primary(item.caseNumber)
        return VStack(alignment: .leading, spacing: 5) {
            Text("№ \(displayCaseNumber)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let label = item.secondaryLabel {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.parties)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            weekCardFooter(court: item.court, room: item.room, judge: item.judge, conflict: conflict)
        }
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 8, trailing: 9))
        // Высота блока — пол, а не потолок: длинные стороны и двухстрочное имя
        // суда карточку не обрезают. `fixedSize` обязателен — без него `Spacer`
        // принимает высоту, которую предлагает ZStack дня, и карточка
        // растягивается до конца временной сетки (#83).
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(weekCardBackground(conflict: conflict))
        .overlay(weekCardBorder(conflict: conflict))
        .overlay(Rectangle().fill(conflict ? Color(red: 0.839, green: 0.271, blue: 0.227) : Color.accentColor)
            .frame(width: 3), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.09), radius: 5, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private func weekStackCard(_ block: CalendarWeekBlock) -> some View {
        let conflict = block.isConflict
        let first = block.hearings.first
        return VStack(alignment: .leading, spacing: 7) {
            if let badge = block.badge {
                Text(badge)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(conflict ? Palette.confirmed : Color(red: 0.04, green: 0.40, blue: 0.84))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((conflict ? Palette.confirmed : Color.accentColor).opacity(0.14)))
            }
            ForEach(block.hearings) { item in
                Button { router.openCase(item.caseNumber) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        let displayCaseNumber = item.displayCaseNumber
                            ?? CaseNumberPresentation.primary(item.caseNumber)
                        let judge = CalendarWeekLayout.itemJudge(item, conflict: conflict)
                        let judgePart = judge.isEmpty ? "" : " · \(judge)"
                        Text("\(item.time) · № \(displayCaseNumber)\(judgePart) · \(item.parties)")
                            .font(.system(size: 10.2, weight: .semibold))
                            .foregroundStyle(conflict ? Palette.confirmed : .primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let label = item.secondaryLabel {
                            Text(label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.primary.opacity(0.60))
                                .lineLimit(1)
                        }
                        let details = CalendarWeekLayout.itemDetails(item, conflict: conflict, common: first)
                        if !details.isEmpty {
                            Text(details)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.primary.opacity(0.42))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Divider().opacity(0.6)
            if conflict {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Успеть лично нельзя")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Palette.confirmed)
                    Text("ходатайство об отложении или второй представитель")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.primary.opacity(0.45))
                }
            } else if let first {
                weekCardFooter(court: first.court, room: first.room, conflict: false)
            }
        }
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 8, trailing: 9))
        .frame(maxWidth: .infinity, minHeight: CGFloat(block.height), alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(weekCardBackground(conflict: conflict))
        .overlay(weekCardBorder(conflict: conflict))
        .overlay(Rectangle().fill(conflict ? Color(red: 0.839, green: 0.271, blue: 0.227) : Color.accentColor)
            .frame(width: 3), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.09), radius: 5, y: 1)
    }

    private func weekCardFooter(court: String, room: String, judge: String = "", conflict: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Divider().opacity(0.6)
            Text(court)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color.primary.opacity(conflict ? 0.76 : 0.82))
                .lineLimit(2)
            let details = [room.nilIfEmpty, judge.nilIfEmpty.map { "судья \($0)" }]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !details.isEmpty {
                Text(details)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .lineLimit(2)
            }
        }
        .padding(.top, 2)
    }

    private func weekCardBackground(conflict: Bool) -> some ShapeStyle {
        LinearGradient(
            colors: conflict
                ? [Palette.confirmed.opacity(0.10), Palette.confirmed.opacity(0.05)]
                : [Color.accentColor.opacity(0.15), Color.accentColor.opacity(0.09)],
            startPoint: .top,
            endPoint: .bottom)
    }

    private func weekCardBorder(conflict: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder((conflict ? Palette.confirmed : Color.accentColor).opacity(conflict ? 0.30 : 0.22),
                          lineWidth: 1)
    }

    private func weekDeadlineChip(_ ev: CalEvent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ev.kind.isConfirmedStyle
                 ? "СРОК · № \(CaseNumberPresentation.primary(ev.caseNumber ?? ""))"
                 : ev.kind == .deadlineInactive
                    ? "СРОК · ИСТОРИЯ · № \(CaseNumberPresentation.primary(ev.caseNumber ?? ""))"
                    : "СРОК? · № \(CaseNumberPresentation.primary(ev.caseNumber ?? ""))")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ev.accent)
                .lineLimit(1)
            Text(ev.title.replacingOccurrences(of: " · № \(CaseNumberPresentation.primary(ev.caseNumber ?? ""))", with: ""))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(ev.accent.opacity(ev.kind.isConfirmedStyle ? 0.08 : 0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(ev.accent.opacity(ev.kind.isConfirmedStyle ? 0.22 : 0.65),
                              style: StrokeStyle(lineWidth: 1, dash: ev.kind == .deadlineProposed ? [3, 2] : [])))
    }

    private func weekNoTimeHearingChip(_ ev: CalEvent) -> some View {
        let timePrefix = CalendarWeekLayout.parseTime(ev.time) == nil ? "" : "\(ev.time) · "
        let displayCaseNumber = ev.displayCaseNumber
            ?? CaseNumberPresentation.primary(ev.caseNumber ?? "")
        return Button {
            if let num = ev.caseNumber { router.openCase(num) }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(timePrefix)ЗАСЕДАНИЕ · № \(displayCaseNumber)")
                    .font(.system(size: 8.5, weight: .bold))
                    .lineLimit(1)
                if let label = ev.secondaryLabel {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
            }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Режим ПОВЕСТКА (4C)

    private var agendaMode: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Повестка").font(.system(size: 22, weight: .bold))
                Text("\(DateUtil.monthTitle(router.calMonth)) · хронология заседаний и сроков")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                calendarModePicker
            }
            .padding(.horizontal, 2)
            productionCalendarNotice

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    miniCalendar
                    waitingCard
                }
                .frame(width: 296)
                agendaList.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var miniCalendar: some View {
        CardBox {
            VStack(spacing: 3) {
                HStack {
                    Text(DateUtil.monthTitle(router.calMonth)).font(.system(size: 13, weight: .bold))
                    Spacer()
                    Button { router.calStep(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 10))
                    Button { router.calStep(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 10))
                }
                .padding(.bottom, 4)
                HStack(spacing: 0) {
                    ForEach(DateUtil.weekdayShort, id: \.self) { w in
                        Text(w).font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            miniCell(day)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // Индикация дня (вариант 1C): ряд тип-точек (≤ 3, одна на присутствующий тип)
    // + хитмап-плитка под числом по количеству событий. Раньше рисовалась точка
    // на каждое событие — при 10+ делах ряд перерастал ячейку и уползал в соседние.
    @ViewBuilder
    private func miniCell(_ day: Date?) -> some View {
        if let day {
            let isToday = DateUtil.isToday(day)
            let evs = events(on: day)
            let count = evs.count
            let production = productionDay(day)
            Button { router.calSelectedDate = day; router.setCalMode(.month) } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 1) {
                        Text("\(DateUtil.cal.component(.day, from: day))")
                            .font(.system(size: 10.5, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? .white : .primary)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(isToday ? Color.accentColor : .clear))
                        Text(production.symbol)
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(productionTint(production))
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 2.5) {
                        ForEach(Array(miniDots(evs).enumerated()), id: \.offset) { _, c in
                            Circle().fill(c).frame(width: 4, height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(                                   // хитмап под числом
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(
                            count == 0 ? 0 : min(0.055 + Double(count) / 15 * 0.185, 0.25)))
                        .padding(2)                            // зазор между плитками (эффект gap)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(DateUtil.fmt(day)). \(production.accessibilityLabel)")
        } else {
            Color.clear.frame(height: 36).frame(maxWidth: .infinity)
        }
    }

    // ≤ 3 точки: одна на присутствующий тип, порядок заседание → расчётный → подтверждён.
    private func miniDots(_ evs: [CalEvent]) -> [Color] {
        var out: [Color] = []
        if evs.contains(where: { $0.kind == .hearing }) {
            out.append(.accentColor)                                   // #0a7aff
        }
        if evs.contains(where: { $0.kind == .deadlineProposed }) {
            out.append(Color(red: 0.878, green: 0.576, blue: 0.165))   // #e0932a
        }
        if evs.contains(where: { $0.kind == .deadlineConfirmed }) {
            out.append(Color(red: 0.839, green: 0.271, blue: 0.227))   // #d6453a
        }
        if evs.contains(where: { $0.kind == .deadlineOverridden }) {
            out.append(Palette.confirmed)
        }
        if evs.contains(where: { $0.kind == .deadlineInactive }) {
            out.append(.secondary)
        }
        return Array(out.prefix(3))
    }

    private var waitingCard: some View {
        let waiting = AppRouter.pendingDeadlines(router.deadlines, today: DateUtil.today)
        return CardBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("ЖДУТ ПОДТВЕРЖДЕНИЯ").font(.system(size: 11, weight: .bold)).kerning(0.3)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    StatusChip(text: "\(waiting.count)", kind: waiting.isEmpty ? .green : .proposed)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                Text("Сроки рассчитаны по правилам, но дата-основание взята с сайта суда. Проверьте по своим документам и подтвердите.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                if waiting.isEmpty {
                    Text("✓ Все сроки подтверждены").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.green)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.green.opacity(0.1)))
                        .padding(.horizontal, 14).padding(.bottom, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(waiting) { d in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(DateUtil.fmt(d.date)) · \(d.what)").font(.system(size: 12, weight: .semibold))
                                    Text("дело № \(CaseNumberPresentation.primary(d.caseNumber))")
                                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                    DeadlineActions(id: d.id, compact: true)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(Divider(), alignment: .top)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // Повестка · прокрутка со «липкими» днями. Дата дня — не боковая колонка,
    // а закреплённый заголовок-разделитель (nativeный аналог position:sticky).
    private var agendaList: some View {
        let byDay = Dictionary(grouping: events) { DateUtil.startOfDay($0.date) }
        let days = byDay.keys.sorted()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.self) { day in
                    let items = (byDay[day] ?? []).sorted { $0.sortTime < $1.sortTime }
                    Section(header: dayHeader(day, count: items.count)) {
                        VStack(spacing: 7) {
                            ForEach(items) { ev in agendaRow(ev) }
                        }
                    }
                }
            }
            .padding(.trailing, 8)   // место под скроллбар
        }
    }

    private func dayHeader(_ day: Date, count: Int) -> some View {
        HStack(spacing: 9) {
            Text("\(DateUtil.weekday(day)), \(DateUtil.fmt(day))")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(DateUtil.isToday(day) ? Color.accentColor : .primary)
            if DateUtil.isToday(day) { StatusChip(text: "сегодня", kind: .blue) }
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            Text("\(count) \(DateUtil.plural(count, "событие", "события", "событий"))")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(                        // маскирует карточки под закреплённым заголовком
            LinearGradient(
                colors: [Color(nsColor: .sudrfContent), Color(nsColor: .sudrfContent).opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    private func agendaRow(_ ev: CalEvent) -> some View {
        CardBox {
            HStack(spacing: 13) {
                Text(ev.time).font(.system(size: 13, weight: .bold)).foregroundStyle(ev.accent)
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ev.heading).font(.system(size: 9.5, weight: .bold)).kerning(0.5).foregroundStyle(ev.accent)
                    Text(ev.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if let label = ev.secondaryLabel {
                        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(ev.sub).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let did = ev.deadlineId {
                    DeadlineActions(id: did, compact: true)
                }
            }
            .padding(EdgeInsets(top: 11, leading: 15, bottom: 11, trailing: 15))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let num = ev.caseNumber, ev.kind == .hearing { router.openCase(num) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Размер строки сетки месяца (issue #332, решение 6 и 8) — все строки равны,
/// так что `reduce` просто берёт последнее значение (гонки между строками
/// нет). Высота нужна `cellLayout` (сколько карточек влезает), ширина — чтобы
/// посчитать реальную ширину узкой колонки выходных вместо константы,
/// которая на 1180pt с открытой панелью дня оказывается ШИРЕ будничной
/// колонки (найдено при ревью решения 8).
private struct MonthRowSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Ширина колонки месяца: выходные — фиксированная (посчитанная выше)
/// ширина, будние — либо тоже фиксированная (после первого измерения сетки),
/// либо `.frame(maxWidth: .infinity)` до этого момента, чтобы колонки не
/// схлопывались в 0 на первый рендер.
private struct ColumnWidth: ViewModifier {
    let isWeekend: Bool
    let weekendWidth: CGFloat
    let weekdayWidth: CGFloat?

    func body(content: Content) -> some View {
        if isWeekend {
            content.frame(width: weekendWidth)
        } else if let weekdayWidth {
            content.frame(width: weekdayWidth)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

/// Шесть цветов звена суда для карточки месяца (issue #332, решение 4) — из
/// артефакта автора («TIER» в `mockup-month.dc.html`), плюс нейтральный серый
/// для нераспознанного суда. Светлая/тёмная тема — тот же приём, что у
/// `NSColor.sudrfContent` в ContentView.swift: `NSColor(name:dynamicProvider:)`.
private enum CourtTierPalette {
    static func color(_ tier: CourtTier?) -> Color { Color(nsColor: nsColor(tier)) }
    static func tint(_ tier: CourtTier?) -> Color { Color(nsColor: tint(tier)) }

    private static func nsColor(_ tier: CourtTier?) -> NSColor {
        switch tier {
        case .district:   return dynamic(light: (0x28, 0x56, 0xc4), dark: (0x7c, 0xa6, 0xf5))
        case .subject:    return dynamic(light: (0x6d, 0x3a, 0xb5), dark: (0xbd, 0x97, 0xf2))
        case .appeal:     return dynamic(light: (0x9c, 0x4f, 0x0b), dark: (0xe3, 0xa7, 0x66))
        case .cassation:  return dynamic(light: (0xa3, 0x21, 0x5a), dark: (0xec, 0x84, 0xb4))
        case .supreme:    return dynamic(light: (0x1f, 0x6b, 0x4a), dark: (0x73, 0xcf, 0xa4))
        case .magistrate: return dynamic(light: (0x5b, 0x64, 0x72), dark: (0xb2, 0xba, 0xc5))
        case nil:         return dynamic(light: (0x6b, 0x6b, 0x73), dark: (0x9a, 0x9a, 0xa2))
        }
    }
    private static func tint(_ tier: CourtTier?) -> NSColor {
        switch tier {
        case .district:   return dynamic(light: (0xea, 0xf0, 0xfc), dark: (0x1c, 0x28, 0x40))
        case .subject:    return dynamic(light: (0xf2, 0xec, 0xfb), dark: (0x2a, 0x21, 0x3a))
        case .appeal:     return dynamic(light: (0xfb, 0xf0, 0xe2), dark: (0x33, 0x28, 0x18))
        case .cassation:  return dynamic(light: (0xfb, 0xe9, 0xf0), dark: (0x35, 0x1f, 0x2a))
        case .supreme:    return dynamic(light: (0xe5, 0xf3, 0xec), dark: (0x18, 0x2c, 0x24))
        case .magistrate: return dynamic(light: (0xee, 0xf0, 0xf3), dark: (0x2a, 0x2c, 0x30))
        case nil:         return dynamic(light: (0xf0, 0xf0, 0xf2), dark: (0x2c, 0x2d, 0x31))
        }
    }
    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
    }
}
