//  CalendarScreen.swift — Sudrf · раздел «Календарь» (v15, реальные даты)
//  Прежде календарь жил на «индексе дня в июне». Теперь события приходят из
//  движения отслеживаемых дел и разнесены по реальным датам и месяцам, поэтому
//  сетка строится для произвольного месяца (router.calMonth) с навигацией.
//  Три вида: большой календарь-месяц (4A) · панель дня справа (4B) · повестка (4C).

import SwiftUI
import SudrfKit

// MARK: - Событие календаря

private enum CalEventKind { case hearing, deadlineProposed, deadlineConfirmed }

private struct CalEvent: Identifiable {
    var date: Date
    var sortTime: String
    var kind: CalEventKind
    var chip: String
    var time: String
    var heading: String
    var title: String
    var sub: String
    var caseNumber: String?
    var deadlineId: String?
    var parties: String = ""
    var court: String = ""
    var room: String = ""
    var judge: String = ""

    var id: String {
        "\(Int(date.timeIntervalSinceReferenceDate))|\(heading)|\(caseNumber ?? deadlineId ?? title)"
    }
    var accent: Color {
        switch kind {
        case .hearing:           return Color.accentColor
        case .deadlineProposed:  return Palette.proposed
        case .deadlineConfirmed: return Palette.confirmed
        }
    }
}

struct CalendarScreen: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        Group {
            if router.isEmpty {
                EmptyTrackingNote()
            } else if router.calMode == .month {
                monthMode
            } else if router.calMode == .week {
                weekMode
            } else {
                agendaMode
            }
        }
        .padding(EdgeInsets(top: 52, leading: 18, bottom: 18, trailing: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .sudrfContent).ignoresSafeArea())
    }

    // MARK: Сбор событий

    private var events: [CalEvent] {
        var out: [CalEvent] = []
        for h in router.hearings {
            out.append(CalEvent(date: h.date, sortTime: h.time, kind: .hearing,
                chip: "\(h.time) заседание · \(h.caseNumber)", time: h.time, heading: "ЗАСЕДАНИЕ",
                title: "№ \(h.caseNumber) — \(h.parties)",
                sub: "\(h.court)" + (h.room.isEmpty ? "" : " · \(h.room)"),
                caseNumber: h.caseNumber, deadlineId: nil,
                parties: h.parties, court: h.court, room: h.room, judge: h.judge))
        }
        for d in router.deadlines {
            let confirmed = d.status == .confirmed
            out.append(CalEvent(date: d.date, sortTime: "99:99",
                kind: confirmed ? .deadlineConfirmed : .deadlineProposed,
                chip: (confirmed ? "срок · " : "срок? ") + d.calLabel,
                time: "срок", heading: confirmed ? "ДЕДЛАЙН · ПОДТВЕРЖДЁН" : "ДЕДЛАЙН · РАСЧЁТНЫЙ",
                title: "\(d.what) · № \(d.caseNumber)", sub: d.basis,
                caseNumber: d.caseNumber, deadlineId: d.id))
        }
        return out
    }
    private func events(on date: Date) -> [CalEvent] {
        events.filter { DateUtil.sameDay($0.date, date) }.sorted { $0.sortTime < $1.sortTime }
    }

    // MARK: Сетка месяца (произвольный месяц)

    private var weeks: [[Date?]] {
        var cells: [Date?] = Array(repeating: nil, count: DateUtil.leadingBlanks(forMonth: router.calMonth))
        cells += DateUtil.datesOfMonth(router.calMonth).map { Optional($0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0+7]) }
    }
    private var weekDays: [Date] { DateUtil.weekDays(containing: router.calWeekStart) }

    // MARK: Режим МЕСЯЦ (4A / 4B)

    private var monthMode: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(DateUtil.monthTitle(router.calMonth)).font(.system(size: 22, weight: .bold))
                // Родственные действия — в одной стеклянной группе (гайд Apple:
                // group related controls). GlassEffectContainer сливает соседние
                // стеклянные элементы в единую поверхность.
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        Button { router.calStep(-1) } label: { Image(systemName: "chevron.left") }
                        Button { router.calStep(1) } label: { Image(systemName: "chevron.right") }
                        Button("Сегодня") {
                            router.calMonth = DateUtil.startOfMonth(DateUtil.today)
                            router.calWeekStart = DateUtil.startOfWeek(DateUtil.today)
                            router.calSelectedDate = DateUtil.today
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                Spacer()
                legend
                calendarModePicker
            }
            .padding(.horizontal, 2)

            HStack(alignment: .top, spacing: 12) {
                monthGrid.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let day = router.calSelectedDate {
                    dayPanel(day).frame(width: 360)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: router.calSelectedDate)
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
                            RoundedRectangle(cornerRadius: 8)
                                .fill(active ? Color(nsColor: .textBackgroundColor).opacity(0.92) : .clear)
                                .shadow(color: .black.opacity(active ? 0.14 : 0), radius: 2, y: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5))
    }

    private var monthGrid: some View {
        CardBox {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(DateUtil.weekdayShort, id: \.self) { w in
                        Text(w).font(.system(size: 10, weight: .bold)).kerning(0.4)
                            .foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 7)
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            dayCell(day)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .overlay(Divider(), alignment: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let isToday = DateUtil.isToday(day)
            let isSel = router.calSelectedDate.map { DateUtil.sameDay($0, day) } ?? false
            let evs = events(on: day)
            Button { router.calSelectedDate = day } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Spacer()
                        Text("\(DateUtil.cal.component(.day, from: day))")
                            .font(.system(size: 11.5, weight: isToday || isSel ? .bold : .medium))
                            .foregroundStyle(isToday ? .white : (isSel ? Color.accentColor : .primary))
                            .frame(minWidth: 22, minHeight: 22)
                            .background(
                                Circle().fill(isToday ? Color.accentColor
                                              : (isSel ? Color.accentColor.opacity(0.16) : .clear)))
                    }
                    ForEach(evs) { ev in chip(ev) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.top, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(isSel ? Color.accentColor.opacity(0.06) : .clear)
                .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.primary.opacity(0.04)), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.primary.opacity(0.02)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Rectangle().frame(width: 1).foregroundStyle(Color.primary.opacity(0.04)), alignment: .leading)
        }
    }

    private func chip(_ ev: CalEvent) -> some View {
        Text(ev.chip)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ev.accent)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(ev.accent.opacity(0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 5).strokeBorder(
                    ev.kind == .deadlineProposed ? ev.accent.opacity(0.6) : .clear,
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
    }

    // MARK: Панель дня (4B)

    private func dayPanel(_ day: Date) -> some View {
        let evs = events(on: day)
        let hearings = evs.filter { $0.kind == .hearing }
        let deadlines = evs.filter { $0.kind != .hearing }
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

    private func hearingCard(_ ev: CalEvent) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text(ev.time).font(.system(size: 19, weight: .bold)).foregroundStyle(Color.accentColor)
                    StatusChip(text: "заседание", kind: .blue)
                }
                Text(ev.title).font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
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
                    .background(RoundedRectangle(cornerRadius: 9).fill(ev.accent.opacity(0.12)))
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
                Button { router.calStepWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                Button { router.calStepWeek(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                Button("Эта неделя") { router.calThisWeek() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(DateUtil.sameWeek(router.calWeekStart, DateUtil.today))
                Spacer()
                legend
                calendarModePicker
            }
            .padding(.horizontal, 2)

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
        let isWeekend = index >= 5
        let weekdayColor: Color = isToday ? .accentColor : (isWeekend ? Color.primary.opacity(0.34) : .secondary)
        let numberColor: Color = isToday ? .white : (isWeekend ? Color.primary.opacity(0.38) : .primary)
        let numberBackground: Color = isToday ? .accentColor : .clear
        return VStack(spacing: 5) {
            Text(DateUtil.weekdayShort[index])
                .font(.system(size: 10, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(weekdayColor)
            Text("\(DateUtil.cal.component(.day, from: day))")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(numberColor)
                .frame(width: 26, height: 26)
                .background(Circle().fill(numberBackground))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(weekColumnTint(day, index: index))
        .overlay(Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1), alignment: .leading)
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
        if index >= 5 { return Color.black.opacity(0.015) }
        return .clear
    }

    private func weekHearingInputs(on day: Date) -> [CalendarWeekHearingLayoutInput] {
        events(on: day).filter {
            $0.kind == .hearing && CalendarWeekLayout.isWithinWindow($0.time)
        }.map { ev in
            CalendarWeekHearingLayoutInput(id: ev.id, caseNumber: ev.caseNumber ?? "",
                                           parties: ev.parties, court: ev.court,
                                           room: ev.room, judge: ev.judge, time: ev.time)
        }
    }

    private func weekBlockView(_ block: CalendarWeekBlock) -> some View {
        let minHeight = CGFloat(block.height)
        return Group {
            if block.isSingle, let item = block.hearings.first {
                Button { router.openCase(item.caseNumber) } label: {
                    weekSingleCard(item, conflict: false, minHeight: minHeight)
                }
                .buttonStyle(.plain)
            } else {
                weekStackCard(block)
            }
        }
    }

    private func weekSingleCard(_ item: CalendarWeekHearingLayoutInput,
                                conflict: Bool,
                                minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("№ \(item.caseNumber)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.parties)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            weekCardFooter(court: item.court, room: item.room, judge: item.judge, conflict: conflict)
        }
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 8, trailing: 9))
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
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
                        Text("\(timePrefix(item, in: block))№ \(item.caseNumber) · \(item.parties)")
                            .font(.system(size: 10.2, weight: .semibold))
                            .foregroundStyle(conflict ? Palette.confirmed : .primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        let details = itemDetails(item, conflict: conflict, common: first)
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
                weekCardFooter(court: first.court, room: first.room, judge: first.judge, conflict: false)
            }
        }
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 8, trailing: 9))
        .frame(maxWidth: .infinity, minHeight: CGFloat(block.height), alignment: .topLeading)
        .background(weekCardBackground(conflict: conflict))
        .overlay(weekCardBorder(conflict: conflict))
        .overlay(Rectangle().fill(conflict ? Color(red: 0.839, green: 0.271, blue: 0.227) : Color.accentColor)
            .frame(width: 3), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.09), radius: 5, y: 1)
    }

    private func weekCardFooter(court: String, room: String, judge: String, conflict: Bool) -> some View {
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

    private func timePrefix(_ item: CalendarWeekHearingLayoutInput, in block: CalendarWeekBlock) -> String {
        let allSame = block.hearings.allSatisfy { $0.time == block.hearings[0].time }
        return allSame ? "" : "\(item.time) · "
    }

    private func itemDetails(_ item: CalendarWeekHearingLayoutInput,
                             conflict: Bool,
                             common: CalendarWeekHearingLayoutInput?) -> String {
        if conflict {
            return [item.court.nilIfEmpty, item.room.nilIfEmpty,
                    item.judge.nilIfEmpty.map { "судья \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
        }
        guard let common else { return "" }
        var parts: [String] = []
        if item.room != common.room { parts.append(item.room) }
        if item.judge != common.judge, !item.judge.isEmpty { parts.append("судья \(item.judge)") }
        return parts.joined(separator: " · ")
    }

    private func weekDeadlineChip(_ ev: CalEvent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ev.kind == .deadlineConfirmed
                 ? "СРОК · № \(ev.caseNumber ?? "")"
                 : "СРОК? · № \(ev.caseNumber ?? "")")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ev.accent)
                .lineLimit(1)
            Text(ev.title.replacingOccurrences(of: " · № \(ev.caseNumber ?? "")", with: ""))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(ev.accent.opacity(ev.kind == .deadlineConfirmed ? 0.08 : 0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(ev.accent.opacity(ev.kind == .deadlineConfirmed ? 0.22 : 0.65),
                              style: StrokeStyle(lineWidth: 1, dash: ev.kind == .deadlineProposed ? [3, 2] : [])))
    }

    private func weekNoTimeHearingChip(_ ev: CalEvent) -> some View {
        let timePrefix = CalendarWeekLayout.parseTime(ev.time) == nil ? "" : "\(ev.time) · "
        return Button {
            if let num = ev.caseNumber { router.openCase(num) }
        } label: {
            Text("\(timePrefix)ЗАСЕДАНИЕ · № \(ev.caseNumber ?? "")")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
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
            Button { router.calSelectedDate = day; router.setCalMode(.month) } label: {
                VStack(spacing: 2) {
                    Text("\(DateUtil.cal.component(.day, from: day))")
                        .font(.system(size: 10.5, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(isToday ? Color.accentColor : .clear))
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
        return out
    }

    private var waitingCard: some View {
        let waiting = router.deadlines.filter { $0.status == .proposed }.sorted { $0.date < $1.date }
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
                                    Text("дело № \(d.caseNumber)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
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
