//  RootView.swift — Sudrf · корневой каркас (v15)
//  Плавающая стеклянная капсула-навигатор: Обзор · Мои дела · Поиск · Календарь.
//  Экран «Поиск» (ContentView) держится смонтированным постоянно — живой поиск
//  и выдача не сбрасываются при переключении вкладок. Роутер прокидывается и в
//  поиск (для кнопки «отслеживать»), и в разделы мониторинга.
//  Карточка дела, открытая из мониторинга, ПЕРЕЗАПРАШИВАЕТ движение с портала
//  (та же CaseMovementView, что и в поиске) + панель судебных актов справа.

import SwiftUI
import SudrfKit
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var router = AppRouter()

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .sudrfContent).ignoresSafeArea()

            ContentView()
                .environmentObject(router)
                .opacity(router.section == .search ? 1 : 0)
                .allowsHitTesting(router.section == .search)
                .disabled(router.section != .search)
                .accessibilityHidden(router.section != .search)

            Group {
                switch router.section {
                case .overview: OverviewView()
                case .cases:    MyCasesView()
                case .calendar: CalendarScreen()
                case .search:   EmptyView()
                }
            }
            .environmentObject(router)
            .transition(.opacity)

            if router.openedCase != nil, router.section != .search {
                CaseCardHost()
                    .environmentObject(router)
                    .transition(.opacity)
            }

            NavCapsule()
                .environmentObject(router)
                .padding(.top, 11)
        }
        .ignoresSafeArea()
        .background(WindowChrome())
        .frame(minWidth: 1180, minHeight: 720)
        .animation(.easeOut(duration: 0.18), value: router.section)
        .animation(.easeOut(duration: 0.18), value: router.openedCase)
        .onReceive(NotificationCenter.default.publisher(for: .sudrfImportCases)) { _ in
            pickCSVAndImport()
        }
        .sheet(isPresented: Binding(
            get: { router.importState != nil },
            set: { shown in
                if !shown {
                    if case .running = router.importState { router.cancelImport() }
                    else { router.dismissImportSummary() }
                }
            })) {
            ImportSheet()
                .environmentObject(router)
        }
    }

    /// Меню «Файл → Импортировать дела из CSV…»: выбор файла и запуск импорта.
    private func pickCSVAndImport() {
        guard router.importState == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Импорт дел из CSV"
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        router.beginImport(csvText: text)
    }
}

// MARK: - Шит импорта: прогресс сетевого этапа + итоговая сводка

private struct ImportSheet: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch router.importState {
            case .running(let done, let total):
                Text("Импорт дел").font(.system(size: 15, weight: .bold))
                Text("Карточка \(min(done + 1, max(total, 1))) из \(total) — открываю прямые ссылки, чтобы сшить инстанции и материалы по УИД.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack {
                    Spacer()
                    Button("Отменить импорт") { router.cancelImport() }
                        .controlSize(.regular)
                }
            case .finished(let summary):
                Text("Импорт завершён").font(.system(size: 15, weight: .bold))
                Text(summary.text)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Движение дел загрузится фоном (обход каждые 10 минут); открытие дела подтягивает его сразу.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Готово") { router.dismissImportSummary() }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        .keyboardShortcut(.defaultAction)
                }
            case nil:
                EmptyView()
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Капсула-навигатор

private struct NavCapsule: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.allCases, id: \.self) { s in tab(s) }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
    }

    @ViewBuilder
    private func tab(_ s: AppSection) -> some View {
        let active = router.section == s
        Button {
            router.go(s)
        } label: {
            HStack(spacing: 7) {
                Text(s.title)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                if s == .cases, router.caseCount > 0 {
                    Text("\(router.caseCount)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 16, minHeight: 16)
                        .padding(.horizontal, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .foregroundStyle(active ? Color.accentColor : Color.primary.opacity(0.62))
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Capsule().fill(active ? Color.accentColor.opacity(0.13) : .clear))
            .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.25) : .clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Хост живой карточки дела (движение + акты)

private struct CaseCardHost: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        ZStack {
            Color(nsColor: .sudrfContent).ignoresSafeArea()
            content
        }
        .padding(.top, 26)   // чтобы кнопка «Назад» не налезала на светофор окна
        .sheet(item: $router.captcha) { ctx in
            CaptchaAssistSheet(context: ctx,
                               onCardHTML: { html in Task { await router.ingestCaptchaCard(html: html) } },
                               onCaptchaPair: { host, token in router.storeCaptchaPair(host: host, token: token) },
                               onSessionUnlocked: { host in router.captchaSessionUnlocked(host: host) },
                               onCancel: { router.captcha = nil })
        }
    }

    @ViewBuilder
    private var content: some View {
        if router.loadingMovement {
            CenterNote(spinner: true, title: "Собираю движение дела…",
                       caption: "Вышестоящие инстанции ищутся по УИД.")
        } else if let mv = router.liveMovement {
            HStack(spacing: 0) {
                CaseMovementView(
                    movement: mv,
                    expanded: Binding(get: { router.expandedComplaints },
                                      set: { router.expandedComplaints = $0 }),
                    backTitle: "Назад",
                    onBack: { router.closeCase() },
                    onSolveCaptcha: { router.beginCaptcha(for: $0) },
                    lastUpdated: router.movementFetchedAt,
                    isRefreshing: router.isRefreshingOpenCase,
                    refreshNote: router.refreshNote,
                    onRefresh: { router.refreshOpenCase() })
                    .frame(maxWidth: .infinity)
                if !mv.acts.isEmpty {
                    LiveActsPane().frame(width: 400)
                }
            }
        } else if let err = router.movementError {
            CenterNote(title: "Не удалось загрузить карточку", caption: err)
        } else {
            CenterNote(title: "Нет данных о движении дела",
                       caption: "Карточки инстанций по этому делу не найдены либо дело не обжаловалось.")
        }
    }
}

// MARK: - Панель судебных актов живой карточки

private struct LiveActsPane: View {
    @EnvironmentObject var router: AppRouter
    @Environment(\.openWindow) private var openWindow

    private var acts: [CaseAct] { router.liveMovement?.acts ?? [] }
    private var body0: String? { router.selectedActText }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Судебные акты по делу").font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                    Spacer()
                    // Кластер действий — единая стеклянная группа (гайд Apple).
                    GlassEffectContainer(spacing: 5) {
                    HStack(spacing: 5) {
                        Button {
                            openWindow(value: ActWindowPayload(
                                caseNumber: router.liveMovement?.caseNumber ?? "", actText: body0 ?? ""))
                        } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Открыть в отдельном окне").disabled(body0 == nil)
                        Button {
                            ActPDFExporter.save(caseNumber: router.liveMovement?.caseNumber ?? "",
                                                text: body0 ?? "")
                        } label: { Image(systemName: "square.and.arrow.down") }
                        .help("Сохранить в PDF").disabled(body0 == nil)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                    }
                }
                ForEach(acts) { a in
                    Button { router.selectAct(a.id) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(a.instanceLevel.tint).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.title)
                                    .font(.system(size: 12, weight: a.id == router.selectedActID ? .semibold : .regular))
                                    .foregroundStyle(.primary).lineLimit(1)
                                Text("\(a.date) · \(a.courtShort)")
                                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 9)
                            .fill(a.id == router.selectedActID ? Color.accentColor.opacity(0.13) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(a.id == router.selectedActID ? Color.accentColor.opacity(0.25) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                    CenterNote(title: "Тексты актов не опубликованы",
                               caption: "Карточки инстанций получены, но тексты отсутствуют в публикации (262-ФЗ).")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(EdgeInsets(top: 0, leading: 10, bottom: 10, trailing: 10))
        }
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(10)
    }
}

// MARK: - Общие компоненты разделов

/// Тонированная капсула-статус (как чипы в макете).
struct StatusChip: View {
    let text: String
    var kind: Palette.Chip = .gray
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Palette.chipFg(kind))
            .padding(.horizontal, 8).padding(.vertical, 2.5)
            .background(Capsule().fill(Palette.chipBg(kind)))
            .lineLimit(1)
    }
}

/// Заголовок раздела с отступом под капсулу-навигатор.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 22, weight: .bold))
            if let subtitle {
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// Белая карточка-контейнер (как панели в макете).
struct CardBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 2, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Пустое состояние раздела (когда отслеживаемых дел ещё нет).
struct EmptyTrackingNote: View {
    @EnvironmentObject var router: AppRouter
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("Пока нет отслеживаемых дел")
                .font(.system(size: 14, weight: .semibold))
            Text("Найдите дело в «Поиске», откройте его движение и нажмите «Отслеживать» — оно появится здесь, в Обзоре и Календаре.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Перейти к поиску") { router.go(.search) }
                .buttonStyle(.glassProminent).controlSize(.regular).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
