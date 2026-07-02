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
                caseNumber: h.caseNumber, deadlineId: nil))
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
                            router.calSelectedDate = DateUtil.today
                        }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                Spacer()
                legend
                Button { router.calMode = .agenda } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.glass).controlSize(.small).help("Свернуть в повестку")
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

    // MARK: Режим ПОВЕСТКА (4C)

    private var agendaMode: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Повестка").font(.system(size: 22, weight: .bold))
                Text("\(DateUtil.monthTitle(router.calMonth)) · хронология заседаний и сроков")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
                Button { router.calMode = .month } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass).controlSize(.small).help("Развернуть календарь")
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

    @ViewBuilder
    private func miniCell(_ day: Date?) -> some View {
        if let day {
            let isToday = DateUtil.isToday(day)
            let evs = events(on: day)
            Button { router.calMode = .month; router.calSelectedDate = day } label: {
                VStack(spacing: 2) {
                    Text("\(DateUtil.cal.component(.day, from: day))")
                        .font(.system(size: 10.5, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(isToday ? Color.accentColor : .clear))
                    HStack(spacing: 2) {
                        ForEach(evs) { ev in Circle().fill(ev.accent).frame(width: 4, height: 4) }
                    }
                    .frame(height: 4)
                }
                .frame(maxWidth: .infinity).frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(height: 36).frame(maxWidth: .infinity)
        }
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
                }
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

    private var agendaList: some View {
        let byDay = Dictionary(grouping: events) { DateUtil.startOfDay($0.date) }
        let days = byDay.keys.sorted()
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(days, id: \.self) { day in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(DateUtil.weekday(day)), \(DateUtil.fmt(day))")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(DateUtil.isToday(day) ? Color.accentColor : .primary)
                            if DateUtil.isToday(day) { StatusChip(text: "сегодня", kind: .blue) }
                        }
                        .frame(width: 150, alignment: .leading).padding(.top, 9)
                        VStack(spacing: 7) {
                            ForEach((byDay[day] ?? []).sorted { $0.sortTime < $1.sortTime }) { ev in
                                agendaRow(ev)
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
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
