//  RootView.swift — Sudrf · корневой каркас (v15)
//  Плавающая стеклянная капсула-навигатор: Обзор · Мои дела · Поиск · Календарь.
//  Экран «Поиск» (ContentView) держится смонтированным постоянно — живой поиск
//  и выдача не сбрасываются при переключении вкладок. Роутер прокидывается и в
//  поиск (для кнопки «отслеживать»), и в разделы мониторинга.
//  Карточка дела, открытая из мониторинга, ПЕРЕЗАПРАШИВАЕТ движение с портала
//  (та же CaseMovementView, что и в поиске) + панель судебных актов справа.

import SwiftUI
import SwiftData
import SudrfKit
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
final class AppBootstrap: ObservableObject {
    struct Failure: Equatable {
        let message: String
        let storeURL: URL?
        let canQuarantine: Bool
        let recoveryDirectory: URL?
    }

    struct Quarantined: Equatable {
        let directory: URL
        let freshStartError: String?
    }

    enum State {
        case loading
        case ready(AppRouter)
        case failed(Failure)
        case quarantined(Quarantined)
    }

    @Published private(set) var state: State = .loading
    private var operationInFlight = false
    private let loader: @Sendable () async throws -> ModelContainer
    private let quarantine: @Sendable (URL, String) async throws -> URL

    init(loader: @escaping @Sendable () async throws -> ModelContainer = {
        try await Task.detached(priority: .userInitiated) {
            try PersistentStoreBootstrapper().prepareProduction()
        }.value
    }, quarantine: (@Sendable (URL, String) async throws -> URL)? = nil) {
        self.loader = loader
        self.quarantine = quarantine ?? { storeURL, message in
            try await Task.detached(priority: .userInitiated) {
                let error = NSError(
                    domain: "ru.sudrf.app.store-recovery", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
                return try SudrfPersistentStoreBackup.quarantineUnopenableStore(
                    storeURL: storeURL, error: error)
            }.value
        }
    }

    func start() async {
        guard case .loading = state else { return }
        await load()
    }

    func retry() async {
        guard !operationInFlight,
              case .failed(let failure) = state,
              failure.recoveryDirectory == nil else { return }
        state = .loading
        await load()
    }

    func quarantineStore() async {
        guard !operationInFlight,
              case .failed(let failure) = state,
              failure.canQuarantine,
              let storeURL = failure.storeURL else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        do {
            let directory = try await quarantine(storeURL, failure.message)
            state = .quarantined(Quarantined(
                directory: directory, freshStartError: nil))
        } catch {
            let recoveryDirectory = (error as? SudrfStoreQuarantineError)?.recoveryDirectory
            state = .failed(Failure(
                message: error.localizedDescription,
                storeURL: storeURL,
                canQuarantine: recoveryDirectory == nil && failure.canQuarantine,
                recoveryDirectory: recoveryDirectory ?? failure.recoveryDirectory))
        }
    }

    /// После карантина это единственная команда, которая может создать новый
    /// store. Та же операция используется для повторной попытки после ошибки.
    func continueWithCleanDatabase() async {
        guard !operationInFlight,
              case .quarantined(let quarantined) = state else { return }
        state = .loading
        await load(keeping: quarantined)
    }

    private func load(keeping quarantined: Quarantined? = nil) async {
        guard !operationInFlight else { return }
        operationInFlight = true
        do {
            let container = try await loader()
            state = .ready(try AppRouter(
                modelContainer: container, modelContainerIsPrepared: true))
        } catch {
            let failure = makeFailure(from: error)
            if let quarantined {
                state = .quarantined(Quarantined(
                    directory: quarantined.directory,
                    freshStartError: failure.message))
            } else {
                state = .failed(failure)
            }
        }
        operationInFlight = false
    }

    private func makeFailure(from error: Error) -> Failure {
        guard let bootstrapError = error as? SudrfStoreBootstrapError else {
            return Failure(message: error.localizedDescription, storeURL: nil,
                           canQuarantine: false, recoveryDirectory: nil)
        }
        return Failure(message: bootstrapError.localizedDescription,
                       storeURL: bootstrapError.storeURL,
                       canQuarantine: bootstrapError.canQuarantine,
                       recoveryDirectory: bootstrapError.recoveryDirectory)
    }
}

struct RootView: View {
    @StateObject private var bootstrap = AppBootstrap()

    var body: some View {
        switch bootstrap.state {
        case .loading:
            StorageStartupLoadingView()
                .task { await bootstrap.start() }
        case .ready(let router):
            OperationalRootView(router: router)
        case .failed(let failure):
            StorageStartupFailureView(failure: failure,
                                      onRetry: { Task { await bootstrap.retry() } },
                                      onQuarantine: { Task { await bootstrap.quarantineStore() } })
        case .quarantined(let quarantined):
            StorageQuarantinedView(
                quarantined: quarantined,
                onContinue: { Task { await bootstrap.continueWithCleanDatabase() } })
        }
    }
}

private struct StorageStartupLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Подготовка базы Sudrf…").font(.headline)
            Text("Проверяем резервную копию, миграцию и каталог судебных актов.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

/// Рабочее дерево создаётся только после успешного открытия persistent store.
/// В аварийном состоянии нет ни ModelContainer, ни меню/обработчиков импорта,
/// поэтому записать данные во временную базу невозможно.
private struct OperationalRootView: View {
    @ObservedObject var router: AppRouter

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

            // Полоса навигации: капсула строго по центру окна, глобальный поиск
            // прижат вправо. ZStack, а не HStack со Spacer'ами, — иначе ширина
            // поля сдвигала бы капсулу с центра.
            ZStack {
                NavCapsule()
                HStack {
                    Spacer(minLength: 0)
                    GlobalSearchField()
                }
            }
            .frame(maxWidth: .infinity)
            .environmentObject(router)
            .padding(.top, NavChrome.topPadding)
            .padding(.horizontal, 20)
        }
        .ignoresSafeArea()
        .background(WindowChrome())
        .modelContainer(router.modelContainer)
        .frame(minWidth: 1180, minHeight: 720)
        .animation(.easeOut(duration: 0.18), value: router.section)
        .animation(.easeOut(duration: 0.18), value: router.openedCase)
        .onReceive(NotificationCenter.default.publisher(for: .sudrfImportCases)) { _ in
            pickCSVAndImport()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .sudrfSpotlightPreferenceChanged)) { note in
            guard let enabled = note.object as? Bool else { return }
            router.setSpotlightEnabled(enabled)
        }
        .onOpenURL { router.handleDeepLink($0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier]
                    as? String else { return }
            router.handleSpotlightItem(identifier: identifier)
        }
        .sheet(isPresented: Binding(
            get: { router.importState != nil || router.repairSummary != nil },
            set: { shown in
                if !shown {
                    if case .running = router.importState { router.cancelImport() }
                    else if router.importState != nil { router.dismissImportSummary() }
                    else { router.dismissRepairSummary() }
                }
            })) {
            ImportSheet()
                .environmentObject(router)
        }
        .sheet(item: $router.fsspCaptcha) { presentation in
            FSSPCaptchaSheet(
                challenge: presentation.challenge,
                documentNumber: presentation.document.electronicID
                    ?? presentation.document.blankNumber
                    ?? "—",
                isSubmitting: presentation.isSubmitting,
                message: presentation.message,
                onSubmit: { router.submitFSSPCaptcha($0, for: presentation) },
                onCancel: { router.dismissFSSPCaptcha() })
        }
        .sheet(isPresented: Binding(
            get: { router.spotlightOnboardingRequired },
            set: { _ in })) {
            SpotlightOnboardingView()
                .environmentObject(router)
                .interactiveDismissDisabled()
        }
        .alert("Не удалось сохранить изменения", isPresented: Binding(
            get: { router.persistenceError != nil },
            set: { shown in if !shown { router.persistenceError = nil } }
        )) {
            Button("Понятно", role: .cancel) { router.persistenceError = nil }
        } message: {
            Text(router.persistenceError ?? "")
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

private struct SpotlightOnboardingView: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Поиск Sudrf через Spotlight", systemImage: "sparkle.magnifyingglass")
                .font(.title2.bold())
            Text("macOS может индексировать реквизиты, стороны и полный текст опубликованных судебных актов, чтобы находить их из Spotlight и Shortcuts. Индекс хранится локально в системном Spotlight.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Включить системный Spotlight для Sudrf",
                   isOn: $router.spotlightOnboardingDraft)
                .toggleStyle(.switch)
            Text("Настройку можно изменить позднее в разделе «Мои дела» и в настройках приложения. При отключении Sudrf удаляет свой системный индекс целиком.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Продолжить") { router.completeSpotlightOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 540)
    }
}

private struct StorageStartupFailureView: View {
    let failure: AppBootstrap.Failure
    let onRetry: () -> Void
    let onQuarantine: () -> Void
    @State private var showingQuarantineConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("База Sudrf не открыта", systemImage: "externaldrive.badge.exclamationmark")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.red)
            Text("Чтобы не потерять отслеживаемые дела, приложение остановило работу с базой.")
                .font(.system(size: 13, weight: .semibold))
            if let storeURL = failure.storeURL {
                Text("Путь базы: \(storeURL.path)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Text(failure.message)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            if let recoveryDirectory = failure.recoveryDirectory {
                Text("Неполный карантин сохранён здесь: \(recoveryDirectory.path)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.orange)
            }
            Text("Закройте Sudrf перед восстановлением файлов.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if failure.recoveryDirectory == nil {
                    Button("Попробовать ещё раз", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                if let recoveryDirectory = failure.recoveryDirectory {
                    Button("Показать восстановление в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recoveryDirectory])
                    }
                    .buttonStyle(.bordered)
                }
                if failure.canQuarantine, failure.storeURL != nil {
                    Button("Отложить базу и начать заново…", role: .destructive) {
                        showingQuarantineConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.red.opacity(0.25)))
        .shadow(radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        .confirmationDialog(
            "Отложить неоткрываемую базу?",
            isPresented: $showingQuarantineConfirmation,
            titleVisibility: .visible) {
                Button("Отложить базу и начать заново", role: .destructive,
                       action: onQuarantine)
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Файлы будут перемещены в отдельную папку без удаления. Новая база появится только после следующего подтверждения.")
            }
    }
}

private struct StorageQuarantinedView: View {
    let quarantined: AppBootstrap.Quarantined
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Старая база отложена", systemImage: "externaldrive.badge.checkmark")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.orange)
            Text("Исходные файлы сохранены в отдельной папке. Проверьте её перед созданием чистой базы.")
                .font(.system(size: 13, weight: .semibold))
            Text(quarantined.directory.path)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            if let freshStartError = quarantined.freshStartError {
                Text("Не удалось создать чистую базу: \(freshStartError)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([quarantined.directory])
                }
                .buttonStyle(.bordered)
                Button(
                    quarantined.freshStartError == nil
                        ? "Продолжить с чистой базой"
                        : "Повторить создание чистой базы",
                    action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.orange.opacity(0.3)))
        .shadow(radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
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
            case .failed(let message):
                Text("Ошибка импорта").font(.system(size: 15, weight: .bold))
                Text(message)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Готово") { router.dismissImportSummary() }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        .keyboardShortcut(.defaultAction)
                }
            case nil:
                if let summary = router.repairSummary {
                    Text("Карточки дел исправлены").font(.system(size: 15, weight: .bold))
                    Text(summary.text)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !summary.captchaGroups.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Код с картинки")
                                .font(.system(size: 12, weight: .semibold))
                            ForEach(summary.captchaGroups) { group in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.courtTitle)
                                            .font(.system(size: 12, weight: .medium))
                                        Text("\(group.count) \(group.count == 1 ? "карточка" : "карточки") · \(group.caseNumbers.prefix(3).joined(separator: ", "))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Button("Ввести код") { router.beginRepairCaptcha(group) }
                                        .controlSize(.small)
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    }
                    HStack {
                        Spacer()
                        Button("Готово") { router.dismissRepairSummary() }
                            .buttonStyle(.borderedProminent).controlSize(.regular)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        // Вложенный лист нужен именно поверх отчёта ремонта: верхний RootView
        // уже показывает этот отчёт как sheet.
        .sheet(item: $router.captcha) { ctx in
            CaptchaAssistSheet(context: ctx,
                               onCardHTML: { html in Task { await router.ingestCaptchaCard(html: html) } },
                               onCaptchaPair: { host, token in router.storeCaptchaPair(host: host, token: token) },
                               onSessionUnlocked: { host in router.captchaSessionUnlocked(host: host) },
                               onCancel: { router.cancelCaptcha() })
        }
    }
}

// MARK: - Капсула-навигатор

/// Единственный источник правды о плавающей навигационной капсуле.
///
/// Капсула лежит поверх экранов отдельным слоем `ZStack` и места под себя не
/// резервирует, поэтому каждый экран обязан сам отступить от верха окна на
/// `contentInset`. Раньше это число подбиралось в пяти местах независимо:
/// «Обзор» и «Мои дела» — 54, «Календарь» — 52, хост карточки дела — 26, а
/// шапка выдачи — всего 16 при полосе капсулы 11–47. Последнее и давало
/// наезжание подзаголовка на навигацию (#75).
///
/// Отступы под светофор окна сюда не относятся: светофор живёт в левом верхнем
/// углу (`WindowChrome`), капсула — по центру. Это разные ограничения.
enum NavChrome {
    /// Высота строки вкладок.
    static let tabHeight: CGFloat = 28
    /// Внутренний отступ стеклянной капсулы вокруг вкладок.
    static let capsulePadding: CGFloat = 4
    /// Отступ капсулы от верхней кромки окна.
    static let topPadding: CGFloat = 11
    /// Зазор между нижней кромкой капсулы и первой строкой контента.
    static let contentGap: CGFloat = 7

    /// Высота капсулы целиком.
    static let capsuleHeight: CGFloat = tabHeight + capsulePadding * 2
    /// Верхний отступ контента любого экрана под капсулой.
    static let contentInset: CGFloat = topPadding + capsuleHeight + contentGap
}

/// Глобальный поиск Spotlight в верхней полосе окна — по решению автора он
/// стоит в правом углу вровень с нав-капсулой и виден на всех четырёх экранах:
/// ищет по всем делам и актам, а не по текущему разделу.
private struct GlobalSearchField: View {
    @EnvironmentObject var router: AppRouter
    @State private var presented = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Поиск по делам и актам", text: $router.globalQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .onSubmit {
                    router.searchSpotlight()
                    presented = true
                }
            if router.globalSearching {
                ProgressView().controlSize(.mini)
            } else if !router.globalQuery.isEmpty {
                Button {
                    router.clearSpotlightSearch()
                    presented = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 245, height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        .disabled(!router.spotlightEnabled)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            popover
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Локальный поиск Spotlight")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if router.globalSearching && router.globalSearchResults.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Ищу…") }
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
            } else if let error = router.globalSearchError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(14)
            } else if router.globalSearchResults.isEmpty {
                Text("Ничего не найдено")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(router.globalSearchResults) { hit in
                            Button {
                                router.handleDeepLink(hit.url)
                                presented = false
                            } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: hit.isCourtAct ? "doc.text" : "briefcase")
                                        .frame(width: 16).foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(hit.title).font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.primary).lineLimit(2)
                                        if !hit.subtitle.isEmpty {
                                            Text(hit.subtitle).font(.system(size: 10.5))
                                                .foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 36)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 360)
            }
        }
        .frame(width: 390)
    }
}

private struct NavCapsule: View {
    @EnvironmentObject var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sliderSpace

    var body: some View {
        // `GlassEffectContainer` здесь был и его пришлось убрать: он собирает
        // стекло потомков в один слой и кладёт этот слой НАД содержимым —
        // слайдер закрывал подпись активной вкладки. Сливать ему теперь и
        // нечего: вкладки собственного стекла не несут, стеклянных поверхностей
        // в капсуле ровно две — трек и слайдер, и они лежат в нужном порядке.
        HStack(spacing: 2) {
            ForEach(AppSection.allCases, id: \.self) { s in tab(s) }
        }
        .background(slider)
        .padding(NavChrome.capsulePadding)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
        .animation(reduceMotion ? nil : .smooth(duration: 0.34, extraBounce: 0.07),
                   value: router.section)
    }

    /// Выделение выбранной секции — ОДНА капсула, которая переезжает.
    ///
    /// Через `matchedGeometryEffect` она берёт рамку у активной вкладки:
    /// меняется `router.section` — меняется источник, и SwiftUI интерполирует
    /// рамку, то есть капсула действительно едет и меняет ширину по пути.
    ///
    /// Морфинг средствами стекла (`glassEffectID` + `.matchedGeometry`) здесь
    /// не сработал: форма гасла на старой вкладке и зажигалась на новой,
    /// перескоком. Анимируем рамку сами — материал едет вместе с ней.
    private var slider: some View {
        Capsule()
            .fill(.clear)
            .glassEffect(.regular, in: .capsule)
            .matchedGeometryEffect(id: router.section, in: sliderSpace, isSource: false)
    }

    private func tab(_ s: AppSection) -> some View {
        let active = router.section == s
        return Button {
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
            // Акцент в переключателе остаётся только на счётчике дел: в системном
            // Calendar выбранная секция не красится вовсе, её выделяет материал.
            .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.62))
            .padding(.horizontal, 16)
            .frame(height: NavChrome.tabHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Каждая вкладка — источник геометрии для слайдера; сама она стекла
        // не несёт, иначе слоёв стало бы столько же, сколько вкладок.
        .matchedGeometryEffect(id: s, in: sliderSpace, isSource: true)
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
        // Отступ под капсулу — он же покрывает светофор окна, на который
        // рассчитывались прежние 26pt: кнопка «Назад» лежит ниже обоих.
        .padding(.top, NavChrome.contentInset)
        .sheet(item: $router.captcha) { ctx in
            CaptchaAssistSheet(context: ctx,
                               onCardHTML: { html in Task { await router.ingestCaptchaCard(html: html) } },
                               onCaptchaPair: { host, token in router.storeCaptchaPair(host: host, token: token) },
                               onSessionUnlocked: { host in router.captchaSessionUnlocked(host: host) },
                               onCancel: { router.cancelCaptcha() })
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
                    onRefresh: { router.refreshOpenCase() },
                    hasPendingRefreshCaptcha: router.openCaseCaptchaRequest != nil,
                    onSolvePendingRefreshCaptcha: { router.beginOpenCaseCaptcha() },
                    enforcementRecords: router.openEnforcementRecords,
                    isRefreshingEnforcement: router.isRefreshingOpenEnforcement,
                    enforcementError: router.openEnforcementError,
                    onRefreshEnforcement: { router.refreshOpenEnforcement() },
                    onSolveFSSPCaptcha: { router.beginFSSPCaptcha(for: $0) })
                    .frame(maxWidth: .infinity)
                if !mv.acts.isEmpty {
                    LiveActsPane().frame(width: 400)
                }
            }
        } else if let err = router.movementError {
            VStack(spacing: 12) {
                Text("Не удалось загрузить карточку")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(err).font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                if router.openCaseCaptchaRequest != nil {
                    Button("Ввести код") { router.beginOpenCaseCaptcha() }
                        .buttonStyle(.glassProminent).controlSize(.regular)
                }
            }
            .frame(maxWidth: 420)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var showingSummary = false

    private var acts: [CaseAct] { router.liveMovement?.acts ?? [] }
    private var body0: String? { router.selectedActText }
    private var selectedParagraphs: [ActParagraph]? { router.selectedActParagraphs }

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
                        Button {
                            router.loadSelectedActSummary()
                            showingSummary = true
                        } label: { Image(systemName: "sparkles") }
                        .help("AI-сводка судебного акта").disabled(body0 == nil)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                    }
                }
                ForEach(acts) { a in
                    CourtActListRow(act: a, selected: a.id == router.selectedActID) {
                        router.selectAct(a.id)
                    }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))

            Group {
                if let txt = body0 {
                    ScrollViewReader { proxy in
                        ScrollView {
                            ActTextView(text: txt,
                                        highlightedParagraphID: router.highlightedParagraphID,
                                        paragraphs: selectedParagraphs)
                                .padding(EdgeInsets(top: 18, leading: 22, bottom: 24, trailing: 22))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: router.highlightedParagraphID) { _, paragraphID in
                            guard let paragraphID else { return }
                            withAnimation { proxy.scrollTo(paragraphID, anchor: .center) }
                        }
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
        .sheet(isPresented: $showingSummary) {
            ActSummarySheet().environmentObject(router)
        }
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
