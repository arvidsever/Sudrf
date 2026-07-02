//  OverviewView.swift — Sudrf · раздел «Обзор» (вариант 1A прототипа)
//  Три колонки: ближайшие заседания · сроки обжалования · лента изменений.

import SwiftUI
import SudrfKit

struct OverviewView: View {
    @EnvironmentObject var router: AppRouter

    private var today: Date { DateUtil.today }
    private var sortedDeadlines: [TrackedDeadline] {
        router.deadlines.sorted { $0.date < $1.date }
    }
    private var nearestDeadline: String {
        sortedDeadlines.first.map { DateUtil.fmt($0.date) } ?? "—"
    }
    private var headerTitle: String { "\(DateUtil.weekday(today)), \(DateUtil.fmt(today))" }
    private var headerSubtitle: String {
        let upd = router.newBadge
        let hToday = router.hearings.filter { DateUtil.isToday($0.date) }.count
        let a = "\(upd) " + DateUtil.plural(upd, "обновление", "обновления", "обновлений")
        let b = "\(hToday) " + DateUtil.plural(hToday, "заседание", "заседания", "заседаний") + " сегодня"
        return "\(a) · \(b) · ближайший срок — \(nearestDeadline)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: headerTitle, subtitle: headerSubtitle) {
                HStack(spacing: 10) {
                    Text("движение подтягивается при открытии дела")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)

            if router.isEmpty {
                EmptyTrackingNote()
            } else {
                HStack(alignment: .top, spacing: 12) {
                    hearingsColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                    deadlinesColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                    feedColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(EdgeInsets(top: 54, leading: 18, bottom: 18, trailing: 18))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .sudrfContent).ignoresSafeArea())
    }

    // MARK: Заседания

    private var hearingsColumn: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                colTitle("БЛИЖАЙШИЕ ЗАСЕДАНИЯ")
                ForEach(router.hearings) { h in
                    Button { router.openCalendar(date: h.date) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(h.dateLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DateUtil.isToday(h.date) ? Color.accentColor : .secondary)
                                Text(h.time)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 72, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("№ \(h.caseNumber)").font(.system(size: 13, weight: .semibold))
                                Text(h.parties).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Text("\(h.court) · \(h.room)")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .background(DateUtil.isToday(h.date) ? Color.accentColor.opacity(0.06) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(Divider(), alignment: .top)
                }
                Spacer(minLength: 0)
                Button { router.go(.calendar) } label: {
                    Text("Открыть календарь →")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(Divider(), alignment: .top)
            }
        }
    }

    // MARK: Сроки

    private var deadlinesColumn: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    colTitle("СРОКИ ОБЖАЛОВАНИЯ")
                    Spacer()
                    let n = router.waitingCount
                    StatusChip(text: n == 0 ? "всё подтверждено"
                                            : "\(n) " + DateUtil.plural(n, "ждёт", "ждут", "ждут") + " подтверждения",
                               kind: n == 0 ? .green : .proposed)
                        .padding(.trailing, 15).padding(.top, 13)
                }
                ForEach(sortedDeadlines) { d in
                    HStack(alignment: .top, spacing: 12) {
                        dateBox(d)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.what).font(.system(size: 12.5, weight: .semibold))
                            Text("дело № \(d.caseNumber)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text(d.basis).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            DeadlineActions(id: d.id).padding(.top, 5)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .overlay(Divider(), alignment: .top)
                }
                Spacer(minLength: 0)
                Text("Расчётный срок — ориентир по ГПК/КАС/КоАП. Дата считается рабочей только после вашего подтверждения.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 15).padding(.vertical, 11)
                    .overlay(Divider(), alignment: .top)
            }
        }
    }

    private func dateBox(_ d: TrackedDeadline) -> some View {
        let confirmed = d.status == .confirmed
        return VStack(spacing: 1) {
            Text(DateUtil.fmt(d.date)).font(.system(size: 12.5, weight: .bold))
            Text(DateUtil.relative(d.date)).font(.system(size: 10, weight: .semibold)).opacity(0.75)
        }
        .foregroundStyle(confirmed ? Palette.confirmed : Palette.proposed)
        .frame(width: 78)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill((confirmed ? Palette.confirmed : Color.orange).opacity(0.12)))
    }

    // MARK: Лента

    private var feedColumn: some View {
        CardBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    colTitle("ЛЕНТА ИЗМЕНЕНИЙ")
                    ForEach(router.feed) { f in
                        if let head = f.dayHead {
                            Text(head.uppercased())
                                .font(.system(size: 10.5, weight: .bold)).kerning(0.3)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 15).padding(.top, 11).padding(.bottom, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(Divider(), alignment: .top)
                        }
                        Button { router.openCase(f.caseNumber) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Color.accentColor).frame(width: 7, height: 7).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 8) {
                                        Text("№ \(f.caseNumber)").font(.system(size: 12, weight: .semibold))
                                        Text(f.time).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                    }
                                    Text(f.text).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if f.hasAct {
                                        Text("Открыть карточку дела →")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(Color.accentColor).padding(.top, 2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 15).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func colTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).kerning(0.3)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 15).padding(.top, 13).padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Управление сроком (Подтвердить / Изменить дату / степпер) — общий компонент

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
