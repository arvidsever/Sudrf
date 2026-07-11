//  ContentView.swift — Sudrf · v4.2 «Liquid Glass» (macOS 26)
//  Каркас «как в макете»: контент занимает всё окно, а сайдбар с фильтрами и
//  инспектор — ПЛАВАЮЩИЕ стеклянные панели поверх него (.glassEffect в
//  скруглённом прямоугольнике). Системные NavigationSplitView/.inspector
//  сознательно не используются: их плоские панели не дают вид макета.
//  Окно — .windowStyle(.hiddenTitleBar) (см. SudrfApp.swift), светофор ложится
//  на верх стеклянного сайдбара.
//
//  Одинарный клик по карточке — текст акта в инспекторе; двойной — «провал» в
//  движение дела по инстанциям (CaseMovementView), при этом инспектор
//  становится переключателем судебных актов. Требуется macOS 26+.

import SwiftUI
import SudrfKit

private enum Layout {
    static let sidebarWidth: CGFloat = 300
    static let inspectorWidth: CGFloat = 400
    static let margin: CGFloat = 10
    static let panelRadius: CGFloat = 18
    /// Радиус «листа» внутри стеклянной панели — КОНЦЕНТРИЧНО внешнему
    /// скруглению: радиус панели минус отступ (18 − 10 = 8). При прежних
    /// 12 центры дуг расходились и угловой зазор «гулял».
    static let sheetRadius: CGFloat = panelRadius - margin
}

struct ContentView: View {
    @StateObject private var model = SearchModel()

    private var inspectorVisible: Bool { model.selectedResultIndex != nil }
    // В режиме «движение дела» (провал в карточку) панель поиска скрывается,
    // чтобы движение по инстанциям занимало всю ширину. Просмотрщик актов справа
    // при этом остаётся. Поведение совпадает с разделом «Мои дела».
    private var searchPaneVisible: Bool { !model.isDrilled }

    var body: some View {
        ZStack {
            Color(nsColor: .sudrfContent)

            // Контентный слой — на всю ширину окна, с отступами под панели.
            ResultsPane(model: model)
                .padding(.leading,
                         searchPaneVisible ? Layout.sidebarWidth + Layout.margin * 2 : Layout.margin)
                .padding(.trailing,
                         inspectorVisible ? Layout.inspectorWidth + Layout.margin * 2 : 0)

            // Плавающие стеклянные панели.
            HStack(spacing: 0) {
                if searchPaneVisible {
                    FilterPane(model: model)
                        .frame(width: Layout.sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .glassEffect(.regular, in: .rect(cornerRadius: Layout.panelRadius))
                        .padding(Layout.margin)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if inspectorVisible {
                    InspectorPane(model: model)
                        .frame(width: Layout.inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .glassEffect(.regular, in: .rect(cornerRadius: Layout.panelRadius))
                        .padding(Layout.margin)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
        .background(WindowChrome())
        .animation(.easeOut(duration: 0.22), value: inspectorVisible)
        .animation(.easeOut(duration: 0.22), value: searchPaneVisible)
        .frame(minWidth: 1100, minHeight: 640)
        .task { await model.resolveCourts() }
    }
}

// MARK: - Сайдбар: фильтры + три поля запроса (внутри стеклянной панели)

private struct FilterPane: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Отступ под светофор окна (unified-тайтлбар, см. WindowChrome).
            Text("ПОИСК ДЕЛА")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(EdgeInsets(top: 50, leading: 16, bottom: 2, trailing: 16))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 9) {
                GridRow {
                    FormLabel("Суды")
                    Picker("", selection: $model.branch) {
                        ForEach(CourtBranch.allCases, id: \.self) { b in
                            Text(b.title).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    FormLabel("Звено")
                    Picker("", selection: $model.tier) {
                        ForEach(CourtTier.cases(for: model.branch)) { t in
                            Text(t.title(branch: model.branch)).tag(t)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    FormLabel("Регион")
                    Picker("", selection: $model.region) {
                        ForEach(CourtDirectory.subjectRegionNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .disabled(!model.regionPickerEnabled)
                }
                GridRow {
                    FormLabel("Суд")
                    Picker("", selection: $model.selectedDomain) {
                        Text("— выберите —").tag("")
                        ForEach(model.courts, id: \.domain) { court in
                            Text(court.title).tag(court.domain)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.courts.isEmpty)
                }
                GridRow {
                    FormLabel("Картотека")
                    Picker("", selection: $model.cartotekaId) {
                        ForEach(model.cartoteki, id: \.id) { c in
                            Text(c.title).tag(c.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.cartoteki.isEmpty)
                }
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            Divider().padding(.horizontal, 16)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 9) {
                GridRow {
                    FormLabel("№ дела")
                    TextField("напр. 5-470/2026", text: $model.queryCaseNumber)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.runSearch() } }
                }
                GridRow {
                    FormLabel("ФИО")
                    TextField("участник дела", text: $model.queryName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.runSearch() } }
                }
                GridRow {
                    FormLabel("УИД")
                    TextField("11RS0001-01-…", text: $model.queryUID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.uidSearchEnabled)
                        .onSubmit { Task { await model.runSearch() } }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))

            HStack(spacing: 7) {
                Spacer()
                Button("Сбросить") { model.resetQueries() }
                    .buttonStyle(.glass)
                Button("Искать") { Task { await model.runSearch() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.searching || model.selectedDomain.isEmpty)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))

            HStack(alignment: .top, spacing: 7) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 10, leading: 16, bottom: 0, trailing: 16))

            Spacer()

            Divider().padding(.horizontal, 16)
            Text("Поля запроса объединяются по «И». Пустая выдача не означает "
               + "отсутствие дела — часть категорий не публикуется (262-ФЗ).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(EdgeInsets(top: 10, leading: 16, bottom: 14, trailing: 16))
        }
        .onChange(of: model.region) {
            Task { await model.resolveCourts() }
        }
        .onChange(of: model.branch) {
            model.branchOrTierChanged()
        }
        .onChange(of: model.tier) {
            model.branchOrTierChanged()
        }
    }

    private var statusText: String {
        if let c = model.selectedCourt, !model.busy, !model.status.isEmpty {
            return "\(model.status) · \(c.domain)"
        }
        return model.status
    }
}

private struct FormLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

// MARK: - Центральная колонка: заголовок + карточки дел

private struct ResultsPane: View {
    @ObservedObject var model: SearchModel
    @EnvironmentObject var router: AppRouter
    @State private var singleClickTask: Task<Void, Never>?

    private var paneTitle: String { model.isDrilled ? "Движение дела" : "Выдача" }

    private var paneSubtitle: String {
        var parts: [String] = []
        if let c = model.selectedCourt { parts.append(c.title) }
        if let cart = model.cartoteka { parts.append(cart.title) }
        return parts.isEmpty ? "ГАС «Правосудие» · суды общей юрисдикции"
                             : parts.joined(separator: " · ")
    }

    var body: some View {
        // Шапка «Выдача» над живым списком лежит в safe-area ПОВЕРХ него:
        // карточки уходят под шапку и мягко растворяются (scroll edge effect,
        // .soft) вместо жёсткого среза по нижней кромке.
        Group {
            if showsFloatingHeader {
                resultsList
                    .safeAreaInset(edge: .top, spacing: 0) { header }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    header
                    stateContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Лист капчи — на уровне всей панели: он нужен и базовому поиску
        // (rerunSearch), и заглушкам инстанций в движении дела.
        .sheet(item: $model.captcha) { ctx in
            CaptchaAssistSheet(
                context: ctx,
                onCardHTML: { html in Task { await model.ingestCaptchaCard(html: html) } },
                onCaptchaPair: { host, token in model.storeCaptchaPair(host: host, token: token) },
                onSessionUnlocked: { host in model.captchaSessionUnlocked(host: host) },
                onCancel: { model.captcha = nil })
        }
        .onDisappear { singleClickTask?.cancel() }
    }

    /// Плавающая шапка уместна только над списком карточек выдачи.
    private var showsFloatingHeader: Bool {
        !model.isDrilled && !model.searching && !model.results.isEmpty
    }

    // Шапка контента (тулбара у окна нет — hiddenTitleBar).
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(paneTitle)
                    .font(.system(size: 15, weight: .bold))
                Text(paneSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if !model.results.isEmpty, !model.isDrilled {
                Text("Найдено: \(model.results.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassEffect()
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 6, trailing: 16))
    }

    private var resultsList: some View {
        let rows = model.results
        return ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(rows) { result in
                    ResultCard(result: result,
                               selected: model.selectedResultID == result.stableID)
                        .onTapGesture(count: 2) {
                            singleClickTask?.cancel()
                            singleClickTask = nil
                            Task { await model.openMovement(result) }
                        }
                        .onTapGesture {
                            singleClickTask?.cancel()
                            singleClickTask = Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                guard !Task.isCancelled else { return }
                                await model.openCard(result)
                            }
                        }
                }
                Text("Двойной клик по карточке — движение дела по инстанциям.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        if model.isDrilled {
            if model.loadingMovement {
                CenterNote(spinner: true, title: "Собираю движение дела…",
                           caption: "Вышестоящие инстанции ищутся по УИД.")
            } else if let mv = model.movement {
                CaseMovementView(movement: mv, expanded: $model.expandedComplaints,
                                 onBack: { model.exitMovement() },
                                 onSolveCaptcha: { model.beginCaptcha(for: $0) },
                                 isTracked: model.currentContext().map { router.isTracked($0) } ?? false,
                                 onTrack: {
                                     if let ctx = model.currentContext() {
                                         router.track(context: ctx, movement: model.movement)
                                     }
                                 })
            } else {
                CenterNote(title: "Нет данных о движении дела",
                           caption: "Карточки вышестоящих инстанций по этому УИД не найдены либо дело не обжаловалось.")
            }
        } else if model.searching {
            CenterNote(spinner: true, title: "Идёт поиск…")
        } else if !model.results.isEmpty {
            resultsList   // запасная ветка: обычно список идёт с плавающей шапкой
        } else if model.hasSearched {
            CenterNote(title: "Ничего не найдено",
                       caption: "Часть категорий дел не публикуется (262-ФЗ): "
                              + "пустой результат не означает отсутствие дела.")
        } else {
            CenterNote(title: "Карточки дел появятся здесь",
                       caption: "Заполните поля запроса слева. Двойной клик по карточке — движение дела.")
        }
    }
}

private struct ResultCard: View {
    let result: CaseSearchResult
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("№ \(result.caseNumber)")
                    .font(.system(size: 13.5, weight: .semibold))
                ForceBadge(inForce: result.legalForceDate != nil)
                Spacer()
                if let d = result.receiptDate {
                    Text(d).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
            }
            // Существо иска — без хвоста «Истец: … Ответчик: …»: стороны
            // уходят в отдельную строку с ролями (вариант 1A из макета).
            let split = CaseParties.split(essence: result.essence)
            if let essence = split.residual {
                Text(essence)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let parties = split.parties {
                PartiesLine(parties: parties)
            }
            HStack(spacing: 6) {
                if let j = result.judge {
                    Text("судья \(j)").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                if let res = result.result {
                    Text("· \(res)").font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(selected ? Color.accentColor.opacity(0.12)
                               : Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(selected ? 0 : 0.05), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55)
                                       : Color.primary.opacity(0.06),
                              lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// Строка участников в карточке выдачи (вариант 1A из макета): первый
/// истец ⚔ первый ответчик, остальные — счётчиком «и ещё N», третьи лица —
/// «+ N третьих лиц». Карточка НЕ растёт по высоте даже при 200+ истцах
/// (групповые иски) — всё всегда в одну строку.
private struct PartiesLine: View {
    let parties: CaseParties

    var body: some View {
        HStack(spacing: 7) {
            if let first = parties.plaintiffs.first {
                side(first, extra: parties.plaintiffs.count - 1)
            }
            if let first = parties.defendants.first {
                // Скрещённые мечи — текстовый глиф (в SF Symbols мечей нет);
                // FE0E форсирует монохромное (не emoji) начертание.
                Text("\u{2694}\u{FE0E}")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                side(first, extra: parties.defendants.count - 1)
            }
            if !parties.thirdParties.isEmpty {
                // КАС: «+ N заинтересованных лиц» вместо «третьих лиц» — по виду процесса.
                Text(parties.kind.thirdCounter(parties.thirdParties.count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }

    private func side(_ name: String, extra: Int) -> Text {
        // macOS 26 объявил оператор `+` у Text устаревшим — склеиваем через
        // AttributedString (стиль каждого фрагмента сохраняется).
        var head = AttributedString(name)
        head.font = .system(size: 12, weight: .semibold)
        if extra > 0 {
            var tail = AttributedString(" и ещё \(extra)")
            tail.font = .system(size: 11.5)
            tail.foregroundColor = .secondary
            return Text(head + tail)
        }
        return Text(head)
    }
}

// MARK: - Инспектор: текст акта / переключатель актов (внутри стеклянной панели)
//  Текст акта — «лист» со скруглением 12 с отступом 10 от краёв панели.

private struct InspectorPane: View {
    @ObservedObject var model: SearchModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if model.isDrilled {
                ActSwitcherPane(model: model, openWindow: openWindow)
            } else if let r = model.selectedResult {
                InspectorHeader(model: model, result: r, openWindow: openWindow)
                Group {
                    if model.loadingCard {
                        CenterNote(spinner: true, title: "Загружаю карточку…")
                    } else if model.actMissing && model.actText.isEmpty {
                        CenterNote(title: "Текст акта по делу № \(r.caseNumber) не опубликован",
                                   caption: "Карточка получена, но судебный акт отсутствует "
                                          + "в публикации (262-ФЗ).")
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if model.actMissing {
                                    Text("Текст акта не опубликован (262-ФЗ) — ниже сырой текст карточки.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ActTextView(text: model.actText)
                            }
                            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Layout.sheetRadius).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Layout.sheetRadius).strokeBorder(Color.primary.opacity(0.05)))
                .clipShape(RoundedRectangle(cornerRadius: Layout.sheetRadius))
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
            }
        }
    }
}

private struct InspectorHeader: View {
    @ObservedObject var model: SearchModel
    let result: CaseSearchResult
    let openWindow: OpenWindowAction

    private var meta: [(String, String)] {
        [("Судья", result.judge ?? "—"),
         ("Поступило", result.receiptDate ?? "—"),
         ("Решение", result.decisionDate ?? "—"),
         ("В силе с", result.legalForceDate ?? "—")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Дело № \(result.caseNumber)")
                    .font(.system(size: 14.5, weight: .bold))
                    .lineLimit(1)
                ForceBadge(inForce: result.legalForceDate != nil)
                Spacer()
                // Кластер действий — единая стеклянная группа (гайд Apple).
                GlassEffectContainer(spacing: 5) {
                HStack(spacing: 5) {
                    Button {
                        openWindow(value: ActWindowPayload(caseNumber: result.caseNumber,
                                                           actText: model.actText))
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Открыть в отдельном окне")
                    .disabled(model.loadingCard || model.actText.isEmpty)

                    Button {
                        ActPDFExporter.save(caseNumber: result.caseNumber, text: model.actText)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Сохранить в PDF")
                    .disabled(model.loadingCard || model.actMissing || model.actText.isEmpty)

                    Button {
                        model.closeInspector()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Закрыть")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      spacing: 4) {
                ForEach(meta, id: \.0) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(item.0)
                            .foregroundStyle(.tertiary)
                            .frame(width: 60, alignment: .leading)
                        Text(item.1)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 11))
                }
            }
            if let url = result.cardURL {
                Link("Открыть на sudrf.ru ↗", destination: url)
                    .font(.caption)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 10, trailing: 16))
    }
}

// MARK: - Переключатель актов (инспектор в режиме движения)

private struct ActSwitcherPane: View {
    @ObservedObject var model: SearchModel
    let openWindow: OpenWindowAction

    private var acts: [CaseAct] { model.movement?.acts ?? [] }
    private var body0: String? { model.selectedActText }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Судебные акты по делу")
                        .font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                    Spacer()
                    // Кластер действий — единая стеклянная группа (гайд Apple).
                    GlassEffectContainer(spacing: 5) {
                    HStack(spacing: 5) {
                        Button {
                            openWindow(value: ActWindowPayload(
                                caseNumber: model.movement?.caseNumber ?? "",
                                actText: body0 ?? ""))
                        } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Открыть в отдельном окне").disabled(body0 == nil)
                        Button {
                            ActPDFExporter.save(caseNumber: model.movement?.caseNumber ?? "",
                                                text: body0 ?? "")
                        } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Сохранить в PDF").disabled(body0 == nil)
                        Button { model.closeInspector() } label: { Image(systemName: "xmark") }
                        .help("Закрыть")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    }
                }
                ForEach(acts) { a in
                    ActListRow(act: a, selected: a.id == model.selectedActID) {
                        model.selectAct(a.id)
                    }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
            Group {
                if let txt = body0 {
                    ScrollView {
                        ActTextView(text: txt)
                            .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    CenterNote(title: "Судебные акты по делу не опубликованы",
                               caption: "Карточки инстанций получены, но тексты актов отсутствуют в публикации (262-ФЗ).")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: Layout.sheetRadius).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Layout.sheetRadius).strokeBorder(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: Layout.sheetRadius))
            .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
        }
    }
}

private struct ActListRow: View {
    let act: CaseAct
    let selected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle().fill(act.instanceLevel.tint).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(act.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary).lineLimit(1)
                    Text("\(act.date) · \(act.courtShort)")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.13) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Общее

struct ForceBadge: View {
    let inForce: Bool

    var body: some View {
        // Тонированное стекло вместо плоской заливки (§6 макета):
        // зелёное — акт в силе, серое — нет; текст белый на обоих.
        Text(inForce ? "Вступило в силу" : "Не вступило в силу")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .glassEffect(.regular.tint(inForce ? Color.green.opacity(0.75)
                                               : Color.gray.opacity(0.55)),
                         in: .capsule)
    }
}

struct CenterNote: View {
    var spinner = false
    let title: String
    var caption: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            if spinner { ProgressView().controlSize(.small) }
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 300)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Цвет подложки контента
//  Не берём системные цвета: underPageBackgroundColor резолвится в тёмно-серый
//  «фон под страницей», а windowBackgroundColor у SwiftPM-исполняемого файла
//  без бандла может быть белым. Цвета — из макета: #f2f3f6 / #232428.
extension NSColor {
    static let sudrfContent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 35/255, green: 36/255, blue: 40/255, alpha: 1)
            : NSColor(srgbRed: 242/255, green: 243/255, blue: 246/255, alpha: 1)
    }
}
