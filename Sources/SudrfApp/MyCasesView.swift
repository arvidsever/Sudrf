//  MyCasesView.swift — Sudrf · раздел «Мои дела» (редизайн v20)
//
//  Четыре вида, порядок фиксированный:
//    1. «Списком»          — панель-фильтр слева + двухэтажная таблица (по умолчанию)
//    2. «По стадиям»       — карточки, группы-стадии
//    3. «По производствам» — карточки, группы по виду производства
//    4. «По подборкам»     — карточки, группы-подборки (бывш. «По доверителям»)
//
//  Подборка — доверитель, тема, что угодно; одно дело может лежать в нескольких
//  подборках. В подборку — значком папки в строке или перетаскиванием строки на
//  пункт сайдбара. Тап по делу — карточка дела (CaseMovementView).

import SwiftUI
import SudrfKit

struct MyCasesView: View {
    @EnvironmentObject var router: AppRouter
    @AppStorage(RefreshSettings.ttlKey) private var ttlHours = 6
    @State private var creatingCollection = false
    @State private var newCollectionName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if router.isEmpty {
                EmptyTrackingNote()
            } else if router.myView == .list {
                listMode
            } else {
                groupedMode          // .stages / .prods / .clients
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

    // MARK: Вид карточками (стадии / производства / подборки)

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
        switch router.myView {
        case .stages:
            return router.stageCounts.compactMap { (st, _) in
                let cs = router.casesIn(stage: st)
                return cs.isEmpty ? nil : (st.label, cs)
            }
        case .prods:
            return ProductionType.allCases.compactMap { p in
                let cs = router.cases.filter { $0.production == p }
                return cs.isEmpty ? nil : (p.side, cs)
            }
        default: // .clients → «По подборкам»
            return router.collections.dropFirst().compactMap { (name, _) in
                let cs = router.casesIn(collection: name)
                return cs.isEmpty ? nil : (name, cs)
            }
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
            Button("Убрать из отслеживания", role: .destructive) { router.untrack(recordKey: c.recordKey) }
        }
    }

    // MARK: Вид списком (панель-фильтр + двухэтажная таблица)

    private var listMode: some View {
        HStack(alignment: .top, spacing: 12) {
            filterSidebar.frame(width: 248)
            tablePane.frame(maxWidth: .infinity)
        }
    }

    private var filterSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarTitle("ПОДБОРКИ").padding(.top, 14)

            // Живой фильтр: сужает таблицу по номеру, сторонам, подборкам, суду.
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("Фильтр по номеру, ФИО…", text: $router.query)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                if !router.query.isEmpty {
                    Button { router.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06)))
            .padding(.horizontal, 12).padding(.bottom, 8).padding(.top, 2)

            // Подборки — одновременно drop-цели: строку таблицы можно перетащить
            // на подборку, дело добавится в неё (кроме «Все дела»).
            VStack(spacing: 1) {
                ForEach(router.collections, id: \.0) { name, n in
                    CollectionRow(name: name, count: n)
                }
            }
            .padding(.horizontal, 10)

            Divider().padding(.horizontal, 16).padding(.vertical, 12)
            sidebarTitle("ВИД ПРОИЗВОДСТВА")
            VStack(spacing: 1) {
                ForEach(ProductionType.allCases, id: \.self) { p in
                    let active = router.prodFilter == p
                    Button { router.prodFilter = active ? nil : p } label: {
                        HStack(spacing: 9) {
                            Text(p.abbr)
                                .font(.system(size: 8.5, weight: .bold))
                                .frame(width: 24, height: 15)
                                .background(RoundedRectangle(cornerRadius: 4).fill(p.color.opacity(0.12)))
                                .foregroundStyle(p.color)
                            Text(p.side).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? Color.accentColor : .primary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(router.count(prod: p))").font(.system(size: 11)).foregroundStyle(.tertiary)
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

            // «+ Новая подборка» — инлайн-поле: Enter создаёт (и выбирает), Esc отменяет.
            if creatingCollection {
                HStack(spacing: 6) {
                    TextField("Название подборки", text: $newCollectionName)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12.5))
                        .focused($nameFieldFocused)
                        .onSubmit(commitNewCollection)
                        .onExitCommand { creatingCollection = false; newCollectionName = "" }
                    Button(action: commitNewCollection) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    }.controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.bottom, 4)
                Text("Enter — создать · Esc — отмена")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            } else {
                Button { creatingCollection = true; nameFieldFocused = true } label: {
                    Text("+ Новая подборка").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 8)
            }
            Text("Дела добавляются из «Поиска» или перетаскиванием строки на подборку; одно дело может быть в нескольких подборках.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .overlay(Divider(), alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
    }

    private func commitNewCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        if router.createCollection(named: name) { router.folder = name }
        creatingCollection = false; newCollectionName = ""
    }

    private func sidebarTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .bold)).kerning(0.3).foregroundStyle(.tertiary)
            .padding(.horizontal, 16).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Таблица — двухэтажные строки, ничего не обрезается

    private var tablePane: some View {
        let rows = router.filteredCases()   // подборка + производство + стадия + query, затем sortBy
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(router.folder).font(.system(size: 13, weight: .bold))
                Text(countLabel(rows.count)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Spacer()
                sortMenu
            }
            .padding(.horizontal, 2)

            CardBox {
                VStack(spacing: 0) {
                    tableHeader
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows) { c in tableRow(c) }
                            if rows.isEmpty {
                                Text("Ничего не найдено — измените запрос или снимите фильтры")
                                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 30)
                                    .overlay(Divider(), alignment: .top)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Text("Клик — карточка дела · в подборку — значок или перетаскивание строки · ⌫ — убрать из отслеживания")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .overlay(Divider(), alignment: .top)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Меню сортировки: по активности / по ближайшему событию / по номеру дела.
    private var sortMenu: some View {
        Menu {
            ForEach(CaseSort.allCases, id: \.self) { s in
                Button {
                    router.sortBy = s
                } label: {
                    if router.sortBy == s { Image(systemName: "checkmark") }
                    Text(s.label); Text(s.hint)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("Сортировка:").foregroundStyle(.tertiary)
                Text(router.sortBy.label).fontWeight(.semibold).foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 11).frame(height: 26)
        }
        .menuStyle(.borderlessButton)
        .glassEffect(.regular, in: .capsule)
    }

    // Колонки: точка · «Дело · вид» · «Стороны · суд» · «Статус · событие» · «Дальше».
    // Строка — HStack с min/max-фреймами ячеек, НЕ LazyVGrid: грид не отдаёт
    // остаток ширины от колонок, упёршихся в max, безлимитной колонке — строки
    // не дотягивались до правого края. HStack остаток докладывает.

    private var tableHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            Color.clear.frame(width: 12, height: 1)
            hcol("ДЕЛО · ВИД").frame(minWidth: 86, maxWidth: 150, alignment: .leading)
            hcol("СТОРОНЫ · СУД").frame(minWidth: 152, maxWidth: .infinity, alignment: .leading)
            hcol("СТАТУС · СОБЫТИЕ").frame(minWidth: 128, maxWidth: 210, alignment: .leading)
            hcol("ДАЛЬШЕ").frame(minWidth: 94, maxWidth: 130, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
    private func hcol(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).kerning(0.4).foregroundStyle(.tertiary)
    }

    /// «ФИО ⟨щит⟩ статьи» для строки «Списком» (подсудимый/привлекаемый). Без
    /// статей — просто ФИО (гражданские, где статей нет).
    private func chargedLine(_ name: String, _ articles: String?) -> Text {
        guard let a = articles, !a.isEmpty else {
            return Text(name)
        }
        return Text("\(Text(name))  \(Text(Image(systemName: "shield")).foregroundStyle(.secondary))  \(Text(a).foregroundStyle(.secondary))")
    }

    private func tableRow(_ c: TrackedCase) -> some View {
        let prod = c.production
        return Button { router.openCase(key: c.recordKey) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(c.newDot ? Color.accentColor : .clear).frame(width: 7, height: 7)
                    .frame(width: 12, alignment: .leading).padding(.top, 5)
                // Дело · вид — номер может переноситься, ничего не обрезается
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.caseNumber).font(.system(size: 12.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(prod.row).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(prod.color)
                }
                .frame(minWidth: 86, maxWidth: 150, alignment: .topLeading)
                // Стороны · суд — стороны через «⚔»; впитывает остаток ширины
                VStack(alignment: .leading, spacing: 2) {
                    // У уголовных/КоАП — ФИО ⟨щит⟩ статьи (без слова-роли).
                    chargedLine(c.partiesShort, c.leadCharges)
                        .font(.system(size: 12.5, weight: c.newDot ? .semibold : .regular))
                        .foregroundStyle(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    // Второй подсудимый / «и N других» — отдельной строкой.
                    if let s = c.secondPartyLine {
                        if let name = s.name {
                            chargedLine(name, s.articles)
                                .font(.system(size: 12.5, weight: c.newDot ? .semibold : .regular))
                                .foregroundStyle(.primary.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let more = s.more {
                            Text(more).font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(c.court).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 152, maxWidth: .infinity, alignment: .topLeading)
                // Статус · последнее событие
                VStack(alignment: .leading, spacing: 3) {
                    StatusChip(text: c.statusText, kind: c.statusChip)
                    Text(c.last).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 128, maxWidth: 210, alignment: .topLeading)
                // Дальше + меню подборок
                HStack(alignment: .center, spacing: 5) {
                    Text(c.next).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.chipFg(c.nextChip))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    collectionsMenu(for: c)
                }
                .frame(minWidth: 94, maxWidth: 130, alignment: .topLeading)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Разделитель — на Button, не на label: внутри label кнопки Divider
        // раскладывается вертикально (полоса по центру, уже чинили в v18).
        .overlay(Divider(), alignment: .top)
        .draggable(c.recordKey)   // drop — на подборку в сайдбаре
        .contextMenu {
            Button("Убрать из отслеживания", role: .destructive) { router.untrack(recordKey: c.recordKey) }
        }
    }

    /// Значок папки в строке: чек-лист подборок, членство переключается кликом.
    private func collectionsMenu(for c: TrackedCase) -> some View {
        Menu {
            Section("В подборках") {
                let names = router.collections.dropFirst()   // без «Все дела»
                if names.isEmpty {
                    Button("Подборок пока нет") {}.disabled(true)
                }
                ForEach(names, id: \.0) { name, _ in
                    Button {
                        c.collections.contains(name)
                            ? router.remove(caseKey: c.recordKey, from: name)
                            : router.add(caseKey: c.recordKey, to: name)
                    } label: {
                        if c.collections.contains(name) { Image(systemName: "checkmark") }
                        Text(name)
                    }
                }
            }
        } label: {
            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("В подборки…")
    }

    private func countLabel(_ n: Int) -> String { "\(n) " + DateUtil.plural(n, "дело", "дела", "дел") }
}

// MARK: - Пункт «подборка» в сайдбаре

/// Кнопка-фильтр + drop-цель для перетаскиваемой строки таблицы (payload —
/// recordKey). При наведении подсвечивается: fill accent 0.2 + ring accent 0.55.
/// «Все дела» drop не принимает.
private struct CollectionRow: View {
    @EnvironmentObject var router: AppRouter
    let name: String
    let count: Int
    @State private var targeted = false

    private var acceptsDrop: Bool { name != "Все дела" }

    var body: some View {
        let active = router.folder == name
        Button { router.folder = name; router.stageFilter = nil } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill").font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.5, green: 0.69, blue: 0.92))
                Text(name).font(.system(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.accentColor : .primary).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).padding(.vertical, 5.5)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(targeted ? Color.accentColor.opacity(0.2)
                      : active ? Color.accentColor.opacity(0.13) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.accentColor.opacity(targeted ? 0.55 : 0), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { keys, _ in
            guard acceptsDrop else { return false }
            keys.forEach { router.add(caseKey: $0, to: name) }
            return true
        } isTargeted: { over in
            targeted = over && acceptsDrop
        }
    }
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
