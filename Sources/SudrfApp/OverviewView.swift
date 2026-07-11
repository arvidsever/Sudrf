//  OverviewView.swift — Sudrf · раздел «Обзор» (v27)
//  Масштабируемая главная: три независимые прокручиваемые колонки + «Вся лента».

import SwiftUI
import SudrfKit

private enum OverviewTone { case neutral, blue, red }

struct OverviewView: View {
    @EnvironmentObject var router: AppRouter

    private var today: Date { DateUtil.today }
    private var sidePadding: CGFloat { router.overviewRoute == .fullFeed ? 190 : 18 }

    var body: some View {
        Group {
            if router.isEmpty {
                EmptyTrackingNote()
            } else {
                switch router.overviewRoute {
                case .dashboard: dashboard
                case .fullFeed: fullFeed
                }
            }
        }
        .padding(EdgeInsets(top: 54, leading: sidePadding, bottom: 18, trailing: sidePadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .sudrfContent).ignoresSafeArea())
    }

    // MARK: Главная панель

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            dashboardHeader
            HStack(alignment: .top, spacing: 12) {
                hearingsColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                deadlinesColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                feedColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(DateUtil.weekday(today)), \(DateUtil.fmt(today))")
                    .font(.system(size: 21, weight: .bold))
                HStack(spacing: 0) {
                    Text("\(router.caseCount) \(DateUtil.plural(router.caseCount, "дело", "дела", "дел")) под наблюдением · ")
                    Text("\(router.monthlyHearingsCount) \(DateUtil.plural(router.monthlyHearingsCount, "заседание", "заседания", "заседаний")) за месяц · ")
                    Text("\(router.waitingCount) \(DateUtil.plural(router.waitingCount, "срок", "срока", "сроков")) ждут подтверждения")
                        .fontWeight(.semibold)
                        .foregroundStyle(router.waitingCount == 0 ? Palette.green : Palette.confirmed)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(refreshMeta)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button("Проверить сейчас") { router.refreshCenter.refreshAll(force: true) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(router.refreshCenter.walkProgress != nil)
        }
        .padding(.horizontal, 6)
    }

    private var refreshMeta: String {
        if let p = router.refreshCenter.walkProgress {
            return "обновляется \(min(p.done + 1, p.total)) из \(p.total)"
        }
        let checked = router.lastOverviewRefreshAt.map { time($0) } ?? "ещё не проверялось"
        return "фоновая проверка каждые \(RefreshSettings.ttlHours) ч · \(checked) — проверено \(router.caseCount) дел"
    }

    // MARK: Заседания

    private var hearingsColumn: some View {
        let buckets = AppRouter.hearingBuckets(router.hearings, today: today)
        return columnCard {
            columnHeader("ЗАСЕДАНИЯ",
                         pill: "\(router.monthlyHearingsCount) за месяц",
                         tone: .neutral)
            scrollBody {
                sectionLabel("БЛИЖАЙШИЕ 7 ДНЕЙ · \(DateUtil.shortDM(today))–\(DateUtil.shortDM(DateUtil.addDays(today, 7)))",
                             tone: .blue)
                if buckets.next7Days.isEmpty {
                    Text(hearingsEmptyText(buckets))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.bottom, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(buckets.next7Days) { hearingRow($0) }
                }
                if !buckets.later.isEmpty {
                    sectionLabel("ПОЗЖЕ", tone: .neutral)
                    ForEach(buckets.later) { hearingRow($0) }
                }
            }
            footer(left: footerMore(buckets.later.count), right: "Календарь") {
                router.openCalendar(date: nil)
            }
        }
    }

    private func hearingsEmptyText(_ buckets: OverviewHearingBuckets) -> String {
        if let days = buckets.firstLaterDays {
            return "заседаний нет — первое через \(days) \(DateUtil.plural(days, "день", "дня", "дней"))"
        }
        return "заседаний нет"
    }

    private func hearingRow(_ h: TrackedHearing) -> some View {
        Button { router.openCalendar(date: h.date) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.dateLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(h.time.isEmpty ? "—" : h.time)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 72, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("№ \(h.caseNumber)").font(.system(size: 13, weight: .semibold))
                    Text(h.parties)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(h.court + (h.room.isEmpty ? "" : " · \(h.room)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.top, 5)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(DateUtil.isToday(h.date) ? Color.accentColor.opacity(0.05) : .clear)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: Сроки

    private var deadlinesColumn: some View {
        let pinned = AppRouter.pinnedDeadline(router.deadlines, today: today)
        let overdue = AppRouter.overdueDeadlines(router.deadlines, today: today)
        let remaining = AppRouter.remainingPendingDeadlines(router.deadlines, pinned: pinned, today: today)
        return columnCard {
            columnHeader("СРОКИ ОБЖАЛОВАНИЯ",
                         pill: router.overdueDeadlineCount > 0
                            ? "\(router.overdueDeadlineCount) просрочено"
                            : "\(router.waitingCount) ждут",
                         tone: router.overdueDeadlineCount > 0 ? .red : .neutral)
            if let pinned {
                pinnedDeadlineRow(pinned)
            } else {
                Text("Все расчётные сроки подтверждены")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.green)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Divider(), alignment: .top)
            }
            scrollBody {
                if !overdue.isEmpty {
                    sectionLabel("ПРОСРОЧЕННЫЕ · \(overdue.count)", tone: .red)
                    ForEach(overdue) { deadlineRow($0, tone: .red) }
                }
                if !remaining.isEmpty {
                    sectionLabel("БЛИЖАЙШИЕ", tone: .neutral)
                    ForEach(remaining) { deadlineRow($0, tone: .neutral) }
                }
            }
            footer(left: footerMore(max(0, overdue.count + remaining.count - 5)),
                   right: "Все сроки") {
                router.openCalendar(date: pinned?.date)
            }
        }
    }

    private func pinnedDeadlineRow(_ d: TrackedDeadline) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("БЛИЖАЙШИЙ")
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 12) {
                dateChip(d, tone: .blue)
                deadlineBody(d)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 11)
        .padding(.bottom, 12)
        .overlay(Divider(), alignment: .top)
        .overlay(Divider(), alignment: .bottom)
    }

    private func deadlineRow(_ d: TrackedDeadline, tone: OverviewTone) -> some View {
        HStack(alignment: .top, spacing: 12) {
            dateChip(d, tone: tone)
            deadlineBody(d)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .overlay(Divider(), alignment: .top)
    }

    private func deadlineBody(_ d: TrackedDeadline) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(d.what) · № \(d.caseNumber)")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(2)
            Text(d.basis)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            DeadlineActions(id: d.id, compact: true).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dateChip(_ d: TrackedDeadline, tone: OverviewTone) -> some View {
        let fg: Color = tone == .red ? Palette.confirmed : (tone == .blue ? Color.accentColor : Palette.proposed)
        return VStack(spacing: 1) {
            Text(DateUtil.fmt(d.date)).font(.system(size: 12.5, weight: .bold))
            Text(DateUtil.relative(d.date)).font(.system(size: 10, weight: .semibold)).opacity(0.75)
        }
        .foregroundStyle(fg)
        .frame(width: 70)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(fg.opacity(tone == .red ? 0.09 : 0.11)))
    }

    // MARK: Лента

    private var feedColumn: some View {
        let entries = router.weekFeedEntries
        return columnCard {
            columnHeader("ЛЕНТА ИЗМЕНЕНИЙ",
                         pill: "\(router.unreadFeedCount) непрочитанных",
                         tone: .blue)
            scrollBody {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    if showsDayHeader(entries, at: i) {
                        sectionLabel(feedDayTitle(entry.date, full: false), tone: .neutral)
                    }
                    feedRow(entry, full: false)
                }
                if entries.isEmpty {
                    emptyLine("За последние 7 дней событий не найдено")
                }
            }
            footer(left: "Прокрутка — 7 дней, \(router.feed.count) \(DateUtil.plural(router.feed.count, "событие", "события", "событий"))",
                   right: "Вся лента") {
                router.openFullFeed()
            }
        }
    }

    // MARK: Вся лента

    private var fullFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            fullFeedHeader
            fullFeedFilters
            fullFeedCard.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fullFeedHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { router.closeFullFeed() } label: {
                Label("Обзор", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Лента изменений").font(.system(size: 21, weight: .bold))
                Text("\(router.feed.count) \(DateUtil.plural(router.feed.count, "событие", "события", "событий")) за неделю по \(router.caseCount) делам · проверено \(router.lastOverviewRefreshAt.map { time($0) } ?? "—")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("№ дела или доверитель", text: $router.feedQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 11)
            .frame(width: 220, height: 28)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.72)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private var fullFeedFilters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(FeedTypeFilter.allCases, id: \.self) { filter in
                    let active = router.feedFilter == filter
                    Button {
                        router.feedFilter = filter
                    } label: {
                        Text("\(filter.title) · \(feedCount(filter))")
                            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? Color.accentColor : .secondary)
                            .padding(.horizontal, 12)
                            .frame(height: 24)
                            .background(Capsule().fill(active ? Color.accentColor.opacity(0.13) : .clear))
                            .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.25) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)

            Spacer()
            Toggle(isOn: $router.feedUnreadOnly) {
                Text("Только непрочитанные · \(router.unreadFeedCount)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }

    private var fullFeedCard: some View {
        CardBox {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let entries = router.fullFeedEntries
                        ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                            if showsDayHeader(entries, at: i) {
                                fullFeedDayHeader(entry.date, count: dayCount(entry.date, in: entries))
                            }
                            feedRow(entry, full: true)
                        }
                        if entries.isEmpty {
                            emptyLine("По выбранным фильтрам событий нет")
                        }
                    }
                }
                .overlay(alignment: .bottom) { bottomFade(height: 36) }

                footer(left: "Показаны события за 7 дней · дальше — прокрутка",
                       right: "Отметить всё прочитанным") {
                    router.markAllFeedRead()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func fullFeedDayHeader(_ date: Date, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(feedDayTitle(date, full: true))
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(.tertiary)
            Text("\(count) \(DateUtil.plural(count, "событие", "события", "событий"))")
                .font(.system(size: 10.5))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Divider(), alignment: .top)
    }

    private func feedRow(_ f: FeedEntry, full: Bool) -> some View {
        HStack(alignment: .top, spacing: full ? 11 : 10) {
            Circle()
                .fill(f.isUnread ? Color.accentColor : Color.clear)
                .overlay(Circle().strokeBorder(Color.primary.opacity(f.isUnread ? 0 : 0.18), lineWidth: 1.5))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            if full {
                Text(f.time)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("№ \(f.caseNumber)")
                        .font(.system(size: full ? 12.5 : 12, weight: .semibold))
                    if full {
                        Text(f.client)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        typeTag(f.kind)
                    } else {
                        Text(f.time)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(f.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if f.hasAct {
                Button("Открыть акт") { router.openFeedEntry(f, preferAct: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, full ? 18 : 15)
        .padding(.vertical, full ? 8 : 9)
        .contentShape(Rectangle())
        .onTapGesture { router.openFeedEntry(f) }
        .overlay(Divider(), alignment: .top)
    }

    private func typeTag(_ kind: FeedEntryKind) -> some View {
        let colors = tagColors(kind)
        return Text(kind.tag)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(colors.bg))
    }

    // MARK: Общие элементы

    private func columnCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        CardBox {
            VStack(spacing: 0) { content() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func columnHeader(_ title: String, pill: String, tone: OverviewTone) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.3)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(pill)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(pillColor(tone).fg)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(pillColor(tone).bg))
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    private func sectionLabel(_ text: String, tone: OverviewTone) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(tone == .blue ? Color.accentColor : tone == .red ? Palette.confirmed : Color.secondary.opacity(0.75))
            .padding(.horizontal, 15)
            .padding(.top, 10)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Divider(), alignment: .top)
    }

    private func scrollBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { bottomFade(height: 34) }
    }

    private func bottomFade(height: CGFloat) -> some View {
        LinearGradient(colors: [.clear, Color(nsColor: .textBackgroundColor)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .allowsHitTesting(false)
    }

    private func footer(left: String, right: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(left)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button {
                action()
            } label: {
                HStack(spacing: 4) {
                    Text(right)
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .overlay(Divider(), alignment: .top)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 15)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func footerMore(_ count: Int) -> String {
        count > 0 ? "Ещё \(count) ниже — колонка прокручивается" : "Колонка прокручивается"
    }

    private func feedCount(_ filter: FeedTypeFilter) -> Int {
        filter.kind.map { kind in router.feed.filter { $0.kind == kind }.count } ?? router.feed.count
    }

    private func showsDayHeader(_ entries: [FeedEntry], at index: Int) -> Bool {
        index == 0 || !DateUtil.sameDay(entries[index - 1].date, entries[index].date)
    }

    private func dayCount(_ date: Date, in entries: [FeedEntry]) -> Int {
        entries.filter { DateUtil.sameDay($0.date, date) }.count
    }

    private func feedDayTitle(_ date: Date, full: Bool) -> String {
        let diff = DateUtil.daysBetween(date, today)
        if diff == 0 { return full ? "СЕГОДНЯ · \(DateUtil.weekday(date).lowercased()), \(DateUtil.fmt(date))" : "СЕГОДНЯ" }
        if diff == 1 { return full ? "ВЧЕРА · \(DateUtil.weekday(date).lowercased()), \(DateUtil.fmt(date))" : "ВЧЕРА" }
        return full ? "\(DateUtil.weekday(date)), \(DateUtil.fmt(date))".uppercased()
                    : DateUtil.weekday(date).uppercased()
    }

    private func tagColors(_ kind: FeedEntryKind) -> (fg: Color, bg: Color) {
        switch kind {
        case .act:      return (Palette.green, Palette.green.opacity(0.14))
        case .hearing:  return (Color.accentColor, Color.accentColor.opacity(0.12))
        case .movement: return (.secondary, Color.primary.opacity(0.06))
        }
    }

    private func pillColor(_ tone: OverviewTone) -> (fg: Color, bg: Color) {
        switch tone {
        case .neutral: return (.secondary, Color.primary.opacity(0.06))
        case .blue:    return (Color.accentColor, Color.accentColor.opacity(0.12))
        case .red:     return (Palette.confirmed, Palette.confirmed.opacity(0.12))
        }
    }

    private func time(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}

// MARK: - Управление сроком (Подтвердить / Изменить дату / степпер)

struct DeadlineActions: View {
    @EnvironmentObject var router: AppRouter
    let id: String
    var compact = false

    var body: some View {
        if let d = router.deadline(id) {
            if router.editingDeadline == id {
                editor
            } else if d.status == .proposed {
                HStack(spacing: 6) {
                    Button("Подтвердить") { router.confirm(id) }
                        .buttonStyle(.glassProminent).controlSize(.small)
                    Button(compact ? "Изменить" : "Изменить дату") { router.beginEdit(id) }
                        .buttonStyle(.glass).controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    StatusChip(text: "✓ подтверждён вами", kind: .green)
                    Button("изменить") { router.beginEdit(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var editor: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Button { router.step(-1) } label: { Image(systemName: "minus") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).frame(width: 20, height: 20)
                Text(DateUtil.fmt(router.draftDate ?? router.deadline(id)?.date ?? DateUtil.today))
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                    .frame(minWidth: 64)
                Button { router.step(1) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor).frame(width: 20, height: 20)
            }
            .padding(.horizontal, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.28)))
            Button("Сохранить") { router.save(id) }
                .buttonStyle(.glassProminent).controlSize(.small)
            Button("Отмена") { router.cancelEdit() }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
