//  MyCasesView.swift — Sudrf · раздел «Мои дела»
//  Три вида: «По доверителям» / «По стадиям» (карточки, вариант 2B) и
//  «Списком» (панель-фильтр слева + таблица, вариант 2A). Тап по делу —
//  карточка дела (CaseMovementView).

import SwiftUI
import SudrfKit

struct MyCasesView: View {
    @EnvironmentObject var router: AppRouter
    @AppStorage(RefreshSettings.ttlKey) private var ttlHours = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if router.isEmpty {
                EmptyTrackingNote()
            } else if router.myView == .list {
                listMode
            } else {
                groupedMode
            }
        }
        .padding(EdgeInsets(top: 54, leading: 20, bottom: 18, trailing: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .sudrfContent).ignoresSafeArea())
    }

    // MARK: Шапка с переключателем вида

    private var header: some View {
        HStack(spacing: 12) {
            Text("Мои дела").font(.system(size: 22, weight: .bold))
            // Стеклянный segmented (как нав-капсула): трек — стекло, активный
            // сегмент — плотный материал с акцентным текстом. Стекло НЕ кладётся
            // на стекло (гайд Apple: не стекать стеклянные слои).
            HStack(spacing: 2) {
                ForEach(MyCasesMode.allCases, id: \.self) { m in
                    let active = router.myView == m
                    Button { withAnimation(.easeOut(duration: 0.18)) { router.myView = m } } label: {
                        Text(m.title)
                            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                            .foregroundStyle(active ? Color.accentColor : .secondary)
                            .padding(.horizontal, 13).frame(height: 24)
                            .background(
                                Capsule()
                                    .fill(active ? Color(nsColor: .textBackgroundColor) : .clear)
                                    .shadow(color: .black.opacity(active ? 0.14 : 0), radius: 2, y: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            Spacer()
            Text(refreshStatus).font(.system(size: 11)).foregroundStyle(.tertiary)
            Menu {
                Picker("Интервал обновления", selection: $ttlHours) {
                    ForEach(RefreshSettings.ttlOptions, id: \.self) { h in
                        Text("\(h) ч").tag(h)
                    }
                }
            } label: {
                Label("каждые \(ttlHours) ч", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11))
            }
            .buttonStyle(.glass).controlSize(.small)
            .help("Как часто обновлять движение отслеживаемых дел в фоне")
            Button("Проверить все") { router.refreshCenter.refreshAll(force: true) }
                .buttonStyle(.glass).controlSize(.small)
                .disabled(router.refreshCenter.walkProgress != nil)
        }
        .padding(.horizontal, 2)
    }

    private var refreshStatus: String {
        if let p = router.refreshCenter.walkProgress {
            return "обновляется \(min(p.done + 1, p.total)) из \(p.total)"
        }
        return "движение обновляется в фоне и при открытии дела"
    }

    // MARK: Вид карточками

    private var groupedMode: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Text(group.0).font(.system(size: 14, weight: .bold))
                            Text(countLabel(group.1.count)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                                  spacing: 10) {
                            ForEach(group.1) { c in caseCard(c) }
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private var groups: [(String, [TrackedCase])] {
        if router.myView == .stages {
            return router.stageCounts.compactMap { (st, _) in
                let cs = router.casesIn(stage: st)
                return cs.isEmpty ? nil : (st.label, cs)
            }
        } else {
            return router.clientNames.map { ($0, router.casesIn(client: $0)) }
        }
    }

    private func caseCard(_ c: TrackedCase) -> some View {
        Button { router.openCase(key: c.recordKey) } label: {
            CardBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("№ \(c.caseNumber)").font(.system(size: 13, weight: .semibold))
                        if c.isNew { StatusChip(text: "обновлено", kind: .blue) }
                        Spacer()
                        Text(c.stageTag).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    Text(c.subject).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(2).frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(c.court).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    StepDots(steps: c.steps)
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.last).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(c.next).font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.chipFg(c.nextChip))
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Убрать из отслеживания", role: .destructive) { router.untrack(c.caseNumber) }
        }
    }

    // MARK: Вид списком (панель + таблица)

    private var listMode: some View {
        HStack(alignment: .top, spacing: 12) {
            filterSidebar.frame(width: 248)
            tablePane.frame(maxWidth: .infinity)
        }
    }

    private var filterSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarTitle("ПАПКИ").padding(.top, 14)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("Фильтр по номеру, ФИО…").font(.system(size: 12.5)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
            .padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 2)

            VStack(spacing: 1) {
                ForEach(router.folders, id: \.0) { name, n in
                    let active = router.folder == name
                    Button { router.folder = name; router.stageFilter = nil } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder.fill").font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.5, green: 0.69, blue: 0.92))
                            Text(name).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.accentColor : .primary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(n)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5.5)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(active ? Color.accentColor.opacity(0.13) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)

            Divider().padding(.horizontal, 16).padding(.vertical, 12)
            sidebarTitle("СТАДИЯ")
            VStack(spacing: 1) {
                ForEach(router.stageCounts, id: \.0) { st, n in
                    let active = router.stageFilter == st
                    Button { router.stageFilter = (router.stageFilter == st ? nil : st) } label: {
                        HStack(spacing: 9) {
                            Circle().fill(st.dot).frame(width: 8, height: 8)
                            Text(st.label).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.accentColor : .primary)
                            Spacer(minLength: 4)
                            Text("\(n)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4.5)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(active ? Color.accentColor.opacity(0.1) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.top, 2)

            Spacer(minLength: 0)
            Button { } label: {
                Text("+ Новая папка").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 8)
            Text("Дела добавляются из «Поиска». Папка = доверитель; одно дело может быть в нескольких папках.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .overlay(Divider(), alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
    }

    private func sidebarTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).kerning(0.3).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tablePane: some View {
        let rows = router.filteredCases()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(router.folder).font(.system(size: 13, weight: .bold))
                Text(countLabel(rows.count)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 6) {
                    Text("Сортировка:").foregroundStyle(.tertiary)
                    Text("по активности").fontWeight(.semibold).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 11).frame(height: 26)
                .glassEffect(.regular, in: .capsule)
            }
            .padding(.horizontal, 2)

            CardBox {
                VStack(spacing: 0) {
                    tableHeader
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows) { c in tableRow(c) }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Клик — карточка дела и движение · ⌫ — убрать из отслеживания")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .overlay(Divider(), alignment: .top)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private let cols: [GridItem] = [
        GridItem(.fixed(12), spacing: 10),
        GridItem(.fixed(112), spacing: 10),
        GridItem(.flexible(minimum: 120), spacing: 10),
        GridItem(.flexible(minimum: 110), spacing: 10),
        GridItem(.fixed(150), spacing: 10),
        GridItem(.flexible(minimum: 120), spacing: 10),
        GridItem(.fixed(96), spacing: 10),
    ]

    private var tableHeader: some View {
        LazyVGrid(columns: cols, alignment: .leading, spacing: 0) {
            Text(""); hcol("ДЕЛО"); hcol("СТОРОНЫ"); hcol("СУД · ИНСТАНЦИЯ")
            hcol("СТАТУС"); hcol("ПОСЛЕДНЕЕ СОБЫТИЕ"); hcol("ДАЛЬШЕ")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
    private func hcol(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).kerning(0.4).foregroundStyle(.tertiary)
    }

    private func tableRow(_ c: TrackedCase) -> some View {
        Button { router.openCase(key: c.recordKey) } label: {
            LazyVGrid(columns: cols, alignment: .leading, spacing: 0) {
                Circle().fill(c.newDot ? Color.accentColor : .clear).frame(width: 7, height: 7)
                Text(c.caseNumber).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(c.partiesShort).font(.system(size: 12, weight: c.newDot ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(0.78)).lineLimit(1)
                Text(c.court).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                StatusChip(text: c.statusText, kind: c.statusChip)
                Text(c.last).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Text(c.next).font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.chipFg(c.nextChip)).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .overlay(Divider(), alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Убрать из отслеживания", role: .destructive) { router.untrack(c.caseNumber) }
        }
    }

    private func countLabel(_ n: Int) -> String { "\(n) " + DateUtil.plural(n, "дело", "дела", "дел") }
}

// MARK: - Индикатор стадий (точки)

struct StepDots: View {
    let steps: [StepState]
    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 5) {
                    dot(s.kind)
                    Text(s.label)
                        .font(.system(size: 10, weight: s.kind == .active ? .bold : .regular))
                        .foregroundStyle(color(s.kind))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
    @ViewBuilder private func dot(_ k: StepState.Kind) -> some View {
        switch k {
        case .done:   Circle().fill(Color.primary.opacity(0.22)).frame(width: 9, height: 9)
        case .active: Circle().fill(Color.accentColor).frame(width: 9, height: 9)
        case .todo:   Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5).frame(width: 9, height: 9)
        }
    }
    private func color(_ k: StepState.Kind) -> Color {
        switch k {
        case .done:   return .secondary
        case .active: return .accentColor
        case .todo:   return Color.primary.opacity(0.3)
        }
    }
}
