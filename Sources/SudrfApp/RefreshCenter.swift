//  RefreshCenter.swift — Sudrf
//  Движок обновления кэша карточек отслеживаемых дел.
//
//  Три режима (все сходятся в refresh(key:)):
//   • периодический обход: start() → каждые ~10 мин проверка, какие дела
//     старше TTL (RefreshSettings), устаревшие обновляются по очереди;
//   • принудительный: refreshAll(force: true) — кнопка «Проверить все»;
//   • точечный: refresh(key:) — при открытии дела (SWR) и кнопка «Обновить».
//
//  Дедупликация по ключу: повторный refresh того же дела возвращает уже
//  идущую задачу. Полный обход использует один судебный воркер: разные домены
//  могут вести на один backend. Все запросы приложения дополнительно проходят
//  через общую FIFO-очередь SudrfClient с интервалом стартов 1,5 с.
//  Ошибка одного дела не прерывает обход и НИКОГДА не трогает уже сохранённый кэш.

import Foundation
import SudrfKit
import CaptchaSolver
import os

private let semanticEventLog = Logger(
    subsystem: "ru.sudrf.app", category: "SemanticEventShadow")

private extension CourtEnforcementDocument {
    /// FSSP accepts the electronic identifier when present and otherwise the
    /// paper writ number. Empty HTML cells are not searchable documents.
    var fsspNumber: String? {
        let value = [electronicID, blankNumber].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CaptchaPendingGroup: Equatable, Identifiable {
    var host: String
    var requests: [CaptchaPendingRequest]

    var id: String { host }
    var count: Int { requests.count }
    var keys: [String] { requests.map(\.key) }
    var caseNumbers: [String] { requests.map(\.caseNumber) }
}

struct CaptchaPendingRequest: Equatable, Identifiable {
    var key: String
    var caseNumber: String
    var formURL: URL

    var id: String { key }
}

struct CaptchaPendingQueue: Equatable {
    private var groupsByHost: [String: CaptchaPendingGroup] = [:]

    var groups: [CaptchaPendingGroup] {
        groupsByHost.values.sorted { $0.host < $1.host }
    }

    static func normalizedHost(_ host: String) -> String {
        SudrfHost.moduleHost(host.lowercased())
    }

    func group(forHost host: String?) -> CaptchaPendingGroup? {
        guard let host else { return nil }
        return groupsByHost[Self.normalizedHost(host)]
    }

    func request(forKey key: String) -> CaptchaPendingRequest? {
        groupsByHost.values.lazy.flatMap(\.requests).first { $0.key == key }
    }

    mutating func add(key: String, caseNumber: String, formURL: URL) {
        remove(key: key)
        let host = Self.normalizedHost(formURL.host ?? "")
        var group = groupsByHost[host] ?? CaptchaPendingGroup(host: host, requests: [])
        group.requests.append(CaptchaPendingRequest(
            key: key, caseNumber: caseNumber, formURL: formURL))
        groupsByHost[host] = group
    }

    mutating func remove(key: String) {
        for host in groupsByHost.keys {
            guard var group = groupsByHost[host],
                  let index = group.requests.firstIndex(where: { $0.key == key }) else { continue }
            group.requests.remove(at: index)
            groupsByHost[host] = group.requests.isEmpty ? nil : group
            return
        }
    }

    mutating func drain(host rawHost: String) -> CaptchaPendingGroup? {
        groupsByHost.removeValue(forKey: Self.normalizedHost(rawHost))
    }
}

/// Проверяемый результат точечного обновления из App Intent. Shortcuts не
/// умеет показать интерактивную CAPTCHA, поэтому этот API явно отличает её от
/// сетевой ошибки и не выдаёт сохранённый кэш за свежие данные.
enum CaseRefreshOutcome: Sendable, Equatable {
    case refreshed
    case partial(String)
    case cancelled
    case captchaRequired
    case failed(String)
    case notFound
}

struct RefreshExecution: Sendable, Equatable {
    let effectiveKey: String
    let outcome: CaseRefreshOutcome
}

@MainActor
final class RefreshCenter: ObservableObject {

    struct WalkProgress: Equatable { var done: Int; var total: Int }

    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var refreshingEnforcement: Set<String> = []
    @Published private(set) var walkProgress: WalkProgress? = nil
    @Published private(set) var lastErrors: [String: String] = [:]
    @Published private(set) var enforcementErrors: [String: String] = [:]
    @Published private var captchaPending = CaptchaPendingQueue()

    /// После успешного обновления записи: survivor key, слитая карточка для
    /// показа и удалённые persistent keys, переехавшие на survivor.
    var onRefreshed: ((String, CaseMovement, [String: String]) -> Void)?
    /// При ошибке обновления (ключ, короткий текст).
    var onRefreshFailed: ((String, String) -> Void)?
    /// После успешной проверки исполнения AppRouter перестраивает ленту и
    /// открытую карточку. Ошибка источника сюда не попадает: суд уже получил
    /// собственный независимый outcome.
    var onEnforcementRefreshed: ((String) -> Void)?
    /// Ключ открытой сейчас карточки — фоновое обновление не должно гасить
    /// ей бейдж «обновлено» (см. правило seenAt в задаче обновления).
    var openedKey: (() -> String?)?
    /// Точечный repair-preflight. Может переякорить запись и вернуть
    /// новый ключ; отказ commit поднимается в refresh как persistence failure.
    var repairBeforeRefresh: ((String) async throws -> String)?

    private let store: TrackedStore
    private let client: SudrfClient
    private let vsrfClient = VSRFClient()
    private let mosGorSudClient = MosGorSudClient()
    /// Опциональный авто-солвер капчи. `nil` — поведение прежнее
    /// (ручной ввод через CaptchaAssistSheet). Передаётся из AppRouter
    /// в init.
    private let captchaSolver: CaptchaSolver?
    private let captchaSettings: CaptchaSettings?
    /// Шаг авто-решения капчи. Дефолт зовёт реальный `AutoCaptchaSolver.solve`;
    /// подменяется в тестах, чтобы не зависеть от сети. Сигнатура повторяет
    /// статический `AutoCaptchaSolver.solve`, чтобы в проде замыкание было
    /// прозрачной обёрткой.
    private let autoSolve: (URL, SudrfClient, CaptchaSolver,
                            AutoCaptchaSolver.Settings) async -> AutoCaptchaSolver.SolveResult
    /// Сборщик `MovementProviding` по `MovementContext`. Дефолт строит
    /// `MovementService` через `ctx.makeService(...)`; подменяется в тестах,
    /// чтобы скриптовать `service.movement(...)` без сети.
    private let serviceBuilder: (MovementContext) -> any MovementProviding
    /// Инъекция замыкания оставляет production-клиент actor-ом, но даёт тестам
    /// детерминированный источник без одноразового protocol/factory слоя.
    private let treasuryDiscover: (CourtEnforcementDocument, String?, String?) async throws
        -> EnforcementLookup
    /// FSSP uses a separate public search flow and its own CAPTCHA. Keep the
    /// lookup seam beside the Treasury seam so tests never need the live
    /// service, while production still uses the actor client.
    private let fsspDiscover: (CourtEnforcementDocument) async throws -> FSSPSearchStep
    private var tasks: [String: Task<RefreshExecution, Never>] = [:]
    private var enforcementTasks: [String: Task<Void, Never>] = [:]
    /// Поколения не дают позднему завершению отменённой задачи очистить
    /// registry новой задачи того же дела после повторного добавления.
    private var taskGenerations: [String: Int] = [:]
    private var enforcementTaskGenerations: [String: Int] = [:]
    /// Repair может переякорить запись, пока task всё ещё зарегистрирован под
    /// исходным ключом. Карта позволяет untrack канонического дела отменить и
    /// такую задачу.
    private var effectiveKeysByTaskKey: [String: String] = [:]
    /// One OCR/network continuation per court module. A refresh walk can reach
    /// the same higher-court form from several cards; share that solve instead
    /// of putting concurrent OCR and retry traffic on the source.
    private var captchaSolveTasks: [String: Task<AutoCaptchaSolver.SolveResult, Never>] = [:]
    private var walkTask: Task<Void, Never>? = nil
    /// Поколение обхода: отменённый принудительным перезапуском обход не должен
    /// своим завершением сбросить walkTask/walkProgress нового обхода.
    private var walkGeneration = 0
    private var timerTask: Task<Void, Never>? = nil
    private static let persistenceFailureMessage =
        "Не удалось сохранить обновление дела в локальной базе. Повторите попытку."

    init(store: TrackedStore, client: SudrfClient,
         captchaSolver: CaptchaSolver? = nil,
         captchaSettings: CaptchaSettings? = nil,
         autoSolve: ((URL, SudrfClient, CaptchaSolver,
                      AutoCaptchaSolver.Settings) async -> AutoCaptchaSolver.SolveResult)? = nil,
         serviceBuilder: ((MovementContext) -> any MovementProviding)? = nil,
         treasuryDiscover: ((CourtEnforcementDocument, String?, String?) async throws
            -> EnforcementLookup)? = nil,
         fsspClient: FSSPClient? = nil,
         fsspAutoModelEnabled: Bool? = nil,
         fsspDiscover: ((CourtEnforcementDocument) async throws -> FSSPSearchStep)? = nil) {
        self.store = store
        self.client = client
        self.captchaSolver = captchaSolver
        self.captchaSettings = captchaSettings
        // Локальные копии — чтобы default-замыкания не захватывали self
        // до завершения инициализации (vsrfClient/mosGorSudClient — let stored,
        // self в escaping-замыкании до init-completion = ошибка компиляции).
        let vsrf = vsrfClient
        let mgs = mosGorSudClient
        self.serviceBuilder = serviceBuilder ?? { ctx in
            let provider: any CaseProviding = ctx.courtLevel == .magistrate
                ? MagistrateClient(sudrfClient: client)
                : client
            return ctx.makeService(client: provider, vsrf: vsrf, mosgorsud: mgs)
        }
        self.autoSolve = autoSolve ?? { url, c, s, settings in
            await AutoCaptchaSolver.solve(formURL: url, client: c,
                                          solver: s, settings: settings)
        }
        let treasury = TreasuryClient()
        self.treasuryDiscover = treasuryDiscover ?? { document, caseNumber, court in
            try await treasury.discover(document: document, caseNumber: caseNumber, court: court)
        }
        let fssp = fsspClient ?? FSSPClient()
        let fsspModelEnabled = fsspAutoModelEnabled
            ?? CaptchaSolverFactory.hasEligibleFSSPModel()
        self.fsspDiscover = fsspDiscover ?? { document in
            if let captchaSolver, let captchaSettings {
                return await FSSPAutoCaptchaSolver.solve(
                    document: document,
                    client: fssp,
                    solver: captchaSolver,
                    enabled: fsspModelEnabled && captchaSettings.isEffectivelyEnabled,
                    settings: .init(
                        maxAttempts: captchaSettings.maxAttempts,
                        minConfidence: captchaSettings.minConfidence))
            }
            return try await fssp.discover(document: document)
        }
    }

    func isRefreshing(_ key: String) -> Bool { refreshing.contains(key) }
    func isRefreshingEnforcement(_ key: String) -> Bool { refreshingEnforcement.contains(key) }
    func enforcementError(forKey key: String?) -> String? {
        key.flatMap { enforcementErrors[$0] }
    }

    var captchaPendingGroups: [CaptchaPendingGroup] { captchaPending.groups }

    func captchaPendingCount(forHost host: String?) -> Int {
        captchaPending.group(forHost: host)?.count ?? 0
    }

    func captchaPendingCaseNumbers(forHost host: String?, limit: Int = 4) -> [String] {
        Array((captchaPending.group(forHost: host)?.caseNumbers ?? []).prefix(limit))
    }

    func captchaPendingRequest(forKey key: String?) -> CaptchaPendingRequest? {
        guard let key else { return nil }
        return captchaPending.request(forKey: key)
    }

    func retryPendingCaptcha(host: String) {
        guard let group = captchaPending.drain(host: host) else { return }
        for key in group.keys {
            lastErrors[key] = nil
            refresh(key: key)
        }
    }

    /// Останавливает только работу удалённого дела. Общая CAPTCHA-задача суда
    /// может обслуживать соседние дела и потому намеренно остаётся активной.
    func cancelTracking(for key: String) {
        let courtTaskKeys = tasks.keys.filter {
            $0 == key || effectiveKeysByTaskKey[$0] == key
        }
        for taskKey in courtTaskKeys {
            taskGenerations[taskKey, default: 0] += 1
            tasks.removeValue(forKey: taskKey)?.cancel()
            effectiveKeysByTaskKey[taskKey] = nil
            refreshing.remove(taskKey)
            lastErrors[taskKey] = nil
            captchaPending.remove(key: taskKey)
        }
        taskGenerations[key, default: 0] += 1
        enforcementTaskGenerations[key, default: 0] += 1
        enforcementTasks.removeValue(forKey: key)?.cancel()
        refreshing.remove(key)
        refreshingEnforcement.remove(key)
        lastErrors[key] = nil
        enforcementErrors[key] = nil
        captchaPending.remove(key: key)
    }

    // MARK: Периодический цикл

    /// Идемпотентный запуск таймера: первый проход ~через 5 с после старта,
    /// далее проверка каждые 10 мин (реально обновляются только устаревшие).
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                self?.refreshAll(force: false)
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    // MARK: Обход всех дел

    /// Последовательно обновляет отслеживаемые дела: force — все подряд,
    /// иначе только те, чей кэш старше TTL. Периодический (не-force) вызов —
    /// no-op, если обход уже идёт; force (кнопка «Проверить все») отменяет
    /// текущий обход и начинает заново.
    func refreshAll(force: Bool) {
        if force {
            walkTask?.cancel()
            walkTask = nil
        } else if walkTask != nil {
            return
        }
        let now = Date()
        let ttl = RefreshSettings.ttl
        var courtKeys = Set<String>()
        let keys = store.all().compactMap { rec -> String? in
            let courtDue = force
                || rec.movementFetchedAt.map { now.timeIntervalSince($0) > ttl } ?? true
            let enforcementDue = needsEnforcementRefresh(rec, now: now, ttl: ttl)
            if courtDue { courtKeys.insert(rec.key) }
            return courtDue || enforcementDue ? rec.key : nil
        }
        guard !keys.isEmpty else { return }
        let dueCourtKeys = courtKeys

        // Группируем дела по домашнему суду (displayDomain денормализован в записи —
        // декодировать контекст не нужно). Порядок дел внутри суда сохраняется.
        let groups = Dictionary(grouping: keys) { key in
            store.record(forKey: key)?.displayDomain ?? key
        }
        let total = keys.count

        walkGeneration += 1
        let gen = walkGeneration
        walkTask = Task { [weak self] in
            defer {
                if let self, self.walkGeneration == gen {
                    self.walkTask = nil; self.walkProgress = nil
                }
            }
            guard let self else { return }
            self.walkProgress = WalkProgress(done: 0, total: total)

            // Один последовательный воркер на суд; при production-лимите 1
            // следующая группа запускается после завершения предыдущей. Ручные
            // запросы в это время встают в общую FIFO-очередь SudrfClient.
            let courts = Array(groups.values)
            let limit = max(1, RefreshSettings.maxConcurrentCourts)
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addWorker() {
                    guard next < courts.count else { return }
                    let caseKeys = courts[next]
                    next += 1
                    group.addTask { [weak self] in
                        for key in caseKeys {
                            if Task.isCancelled { return }
                            if dueCourtKeys.contains(key) {
                                _ = await self?.refresh(key: key, forceEnforcement: false)?.value
                            } else {
                                _ = await self?.startEnforcementRefresh(key: key, force: false)?.value
                            }
                            await self?.bumpWalkProgress(total: total, generation: gen)
                        }
                    }
                }
                for _ in 0..<limit { addWorker() }
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    addWorker()
                }
            }
        }
    }

    /// Инкремент счётчика завершённых дел обхода (вызывается воркерами по мере
    /// готовности каждого дела). На @MainActor — гонок по walkProgress нет.
    static func acceptsWalkProgress(generation: Int, currentGeneration: Int) -> Bool {
        generation == currentGeneration
    }

    private func bumpWalkProgress(total: Int, generation: Int) {
        guard Self.acceptsWalkProgress(generation: generation, currentGeneration: walkGeneration) else { return }
        let done = (walkProgress?.done ?? 0) + 1
        walkProgress = WalkProgress(done: min(done, total), total: total)
    }

    // MARK: Обновление одного дела

    /// Запускает (или возвращает уже идущее) обновление дела по ключу записи.
    @discardableResult
    func refresh(key: String, forceEnforcement: Bool = false) -> Task<RefreshExecution, Never>? {
        if let existing = tasks[key] { return existing }
        guard store.record(forKey: key) != nil else { return nil }

        taskGenerations[key, default: 0] += 1
        let generation = taskGenerations[key]!
        refreshing.insert(key)
        let task = Task { [weak self] in
            guard let self else {
                return RefreshExecution(effectiveKey: key, outcome: .notFound)
            }
            let execution = await self.performRefresh(key: key)
            if execution.outcome != .cancelled {
                _ = await self.startEnforcementRefresh(
                    key: execution.effectiveKey, force: forceEnforcement)?.value
            }
            if self.taskGenerations[key] == generation {
                self.refreshing.remove(key)
                self.tasks[key] = nil
                self.effectiveKeysByTaskKey[key] = nil
            }
            return execution
        }
        tasks[key] = task
        return task
    }

    /// Дожидается той же задачи, которой пользуется UI (включая попытку
    /// авто-солва), и классифицирует итог для Shortcuts.
    func refreshForIntent(key: String) async -> CaseRefreshOutcome {
        guard let task = refresh(key: key) else { return .notFound }
        return await task.value.outcome
    }

    /// Ручная проверка исполнения. Судебное обновление не требуется: для
    /// запроса используются уже сохранённые бумажные реквизиты листов.
    @discardableResult
    func refreshEnforcement(key: String) -> Task<Void, Never>? {
        startEnforcementRefresh(key: key, force: true)
    }

    /// Сохраняет результат явного ручного шага CAPTCHA тем же способом, что
    /// фоновая проверка. Картинка и `code_id` в хранилище не попадают.
    func applyFSSPSearchStep(key: String, document: CourtEnforcementDocument,
                             step: FSSPSearchStep) throws {
        guard let record = store.record(forKey: key) else { return }
        let previous = record.enforcementRecords
        let attemptedAt = Date()
        let update: EnforcementRecord
        switch step {
        case .error(let message):
            update = fsspErrorUpdate(document: document, previous: previous,
                                     attemptedAt: attemptedAt, message: message)
            enforcementErrors[key] = "ФССП: \(message)"
        case .captchaRequired, .found, .notFound, .ambiguous:
            guard let lookup = step.lookup else { return }
            update = sourceUpdate(lookup: lookup, document: document,
                                  source: .bailiffs, attemptedAt: attemptedAt)
            enforcementErrors[key] = nil
        }
        let documents = record.movement?.executionDocuments ?? []
        let current = TrackedStore.reconciledEnforcementRecords(
            existing: previous, updates: [update], courtDocuments: documents)
        let changed = TrackedStore.enforcementHasUserVisibleChange(
            previous: previous, current: current, courtDocuments: documents)
        record.enforcementRecords = current
        if changed && openedKey?() != key { record.seenAt = nil }
        do {
            try store.save()
        } catch {
            enforcementErrors[key] = Self.persistenceFailureMessage
            throw error
        }
        onEnforcementRefreshed?(key)
    }

    private func startEnforcementRefresh(key: String, force: Bool) -> Task<Void, Never>? {
        if let existing = enforcementTasks[key] { return existing }
        guard let record = store.record(forKey: key),
              !enforcementDocuments(for: record).isEmpty,
              force || needsEnforcementRefresh(record, now: Date(), ttl: RefreshSettings.ttl)
        else { return nil }

        enforcementTaskGenerations[key, default: 0] += 1
        let generation = enforcementTaskGenerations[key]!
        refreshingEnforcement.insert(key)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performEnforcementRefresh(key: key)
            if self.enforcementTaskGenerations[key] == generation {
                self.refreshingEnforcement.remove(key)
                self.enforcementTasks[key] = nil
            }
        }
        enforcementTasks[key] = task
        return task
    }

    /// Суд может не ответить, но ранее сохранённые исполнительные листы всё
    /// равно проверяются. Ошибка Казначейства сохраняется отдельно от исхода
    /// судебного refresh и не трогает кэш движения/снимок.
    private func performEnforcementRefresh(key: String) async {
        guard let record = store.record(forKey: key) else { return }
        let documents = enforcementDocuments(for: record)
        guard !documents.isEmpty else { return }

        let previous = record.enforcementRecords
        var updates: [EnforcementRecord] = []
        var errors: [String] = []
        for document in documents {
            // FSSP is checked for every document carrying an electronic ID or
            // paper number. A CAPTCHA is a persisted source state, not a
            // transport failure; the manual UI can then fetch a fresh task.
            if document.fsspNumber != nil {
                let attemptedAt = Date()
                do {
                    let step = try await fsspDiscover(document)
                    guard !Task.isCancelled else { return }
                    switch step {
                    case .captchaRequired(_):
                        if let lookup = step.lookup {
                            updates.append(sourceUpdate(
                                lookup: lookup, document: document, source: .bailiffs,
                                attemptedAt: attemptedAt))
                        }
                    case .found(let lookup), .notFound(let lookup), .ambiguous(let lookup):
                        updates.append(sourceUpdate(
                            lookup: lookup, document: document, source: .bailiffs,
                            attemptedAt: attemptedAt))
                    case .error(let message):
                        errors.append("ФССП: \(message)")
                        updates.append(fsspErrorUpdate(
                            document: document, previous: previous,
                            attemptedAt: attemptedAt, message: message))
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    let message = error.localizedDescription
                    errors.append("ФССП: \(message)")
                    updates.append(fsspErrorUpdate(
                        document: document, previous: previous,
                        attemptedAt: attemptedAt, message: message))
                }
            }

            // Treasury remains deliberately narrower: only paper documents
            // not explicitly directed to bailiffs are eligible there.
            guard document.isTreasuryEligible else { continue }
            let attemptedAt = Date()
            do {
                let lookup = try await treasuryDiscover(document, record.caseNumber, record.courtTitle)
                guard !Task.isCancelled else { return }
                updates.append(sourceUpdate(
                    lookup: lookup, document: document, source: .treasury,
                    attemptedAt: attemptedAt))
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                errors.append("Казначейство: \(message)")
                updates.append(treasuryErrorUpdate(
                    document: document, previous: previous,
                    attemptedAt: attemptedAt, message: message))
            }
        }

        guard !Task.isCancelled else { return }

        // Сеть могла ждать CAPTCHA/throttle, пока ручной поток уже сохранил
        // более свежий результат. Сливаем в актуальное состояние записи, а не
        // в снимок, сделанный до await.
        let latest = record.enforcementRecords
        let current = TrackedStore.reconciledEnforcementRecords(
            existing: latest, updates: updates,
            courtDocuments: record.movement?.executionDocuments ?? [])
        let changed = TrackedStore.enforcementHasUserVisibleChange(
            previous: latest, current: current,
            courtDocuments: record.movement?.executionDocuments ?? [])
        record.enforcementRecords = current
        if changed && openedKey?() != key { record.seenAt = nil }
        do {
            try store.save()
        } catch {
            enforcementErrors[key] = Self.persistenceFailureMessage
            return
        }

        let hasSuccess = updates.contains {
            $0.discoveryState != .error
        }
        if errors.isEmpty {
            enforcementErrors[key] = nil
        } else {
            enforcementErrors[key] = errors.joined(separator: "\n")
        }
        if hasSuccess { onEnforcementRefreshed?(key) }
    }

    /// Every court row with a searchable identifier belongs to FSSP; Treasury
    /// keeps its existing eligibility rule. The small computed property also
    /// prevents an empty court row from creating a permanent error record.
    private func enforcementDocuments(
        for record: TrackedCaseRecord
    ) -> [CourtEnforcementDocument] {
        (record.movement?.executionDocuments ?? []).filter {
            $0.fsspNumber != nil || $0.isTreasuryEligible
        }
    }

    private func needsEnforcementRefresh(_ record: TrackedCaseRecord, now: Date,
                                         ttl: TimeInterval) -> Bool {
        let records = record.enforcementRecords
        return enforcementDocuments(for: record).contains { document in
            if document.fsspNumber != nil {
                guard let saved = records.first(where: {
                    $0.source == .bailiffs && $0.courtDocumentID == document.id
                }) else { return true }
                let checkedAt = saved.lastAttemptAt ?? saved.lastSuccessAt ?? .distantPast
                if now.timeIntervalSince(checkedAt) > ttl { return true }
            }
            if document.isTreasuryEligible {
                guard let saved = records.first(where: {
                    $0.source == .treasury && $0.courtDocumentID == document.id
                }) else { return true }
                let checkedAt = saved.lastAttemptAt ?? saved.lastSuccessAt ?? .distantPast
                return now.timeIntervalSince(checkedAt) > ttl
            }
            return false
        }
    }

    private func sourceUpdate(
        lookup: EnforcementLookup,
        document: CourtEnforcementDocument,
        source: EnforcementChannel,
        attemptedAt: Date
    ) -> EnforcementRecord {
        var update = lookup.record ?? EnforcementRecord(
            courtDocumentID: document.id, source: source,
            discoveryState: lookup.state, status: "", lastAttemptAt: attemptedAt)
        update.courtDocumentID = document.id
        update.source = source
        update.discoveryState = lookup.state
        update.lastAttemptAt = attemptedAt
        if lookup.state != .error && lookup.state != .captchaRequired {
            update.lastSuccessAt = update.lastSuccessAt ?? attemptedAt
            update.error = nil
        }
        return update
    }

    private func sourceErrorUpdate(
        document: CourtEnforcementDocument,
        previous: [EnforcementRecord],
        source: EnforcementChannel,
        attemptedAt: Date,
        message: String
    ) -> EnforcementRecord {
        var update = previous.first {
            $0.source == source && $0.courtDocumentID == document.id
        } ?? EnforcementRecord(
            courtDocumentID: document.id, source: source,
            discoveryState: .error, status: "", lastAttemptAt: attemptedAt,
            error: message)
        update.courtDocumentID = document.id
        update.source = source
        update.lastAttemptAt = attemptedAt
        update.error = message
        return update
    }

    private func fsspErrorUpdate(
        document: CourtEnforcementDocument,
        previous: [EnforcementRecord],
        attemptedAt: Date,
        message: String
    ) -> EnforcementRecord {
        sourceErrorUpdate(document: document, previous: previous,
                          source: .bailiffs, attemptedAt: attemptedAt,
                          message: message)
    }

    private func treasuryErrorUpdate(
        document: CourtEnforcementDocument,
        previous: [EnforcementRecord],
        attemptedAt: Date,
        message: String
    ) -> EnforcementRecord {
        sourceErrorUpdate(document: document, previous: previous,
                          source: .treasury, attemptedAt: attemptedAt,
                          message: message)
    }

    private func performRefresh(key: String) async -> RefreshExecution {
        let effectiveKey: String
        do {
            effectiveKey = try await repairBeforeRefresh?(key) ?? key
        } catch is TrackedStoreCommitError {
            return failure(key, Self.persistenceFailureMessage)
        } catch {
            return failure(key, error.localizedDescription)
        }
        effectiveKeysByTaskKey[key] = effectiveKey
        if Task.isCancelled {
            return RefreshExecution(effectiveKey: effectiveKey, outcome: .cancelled)
        }
        guard let rec = store.record(forKey: effectiveKey),
              var ctx = rec.context, let cart = ctx.cartoteka else {
            return failure(effectiveKey, "Не удалось восстановить параметры поиска по делу.")
        }
        if JudicialUIDObservation.validity(of: ctx.judicialUID) != .valid,
           let cachedUID = rec.movement?.uid.trimmingCharacters(in: .whitespacesAndNewlines),
           JudicialUIDObservation.validity(of: cachedUID) == .valid {
            ctx.judicialUID = cachedUID
        }
        let service = serviceBuilder(ctx)
        do {
            let outcome = try await fetchOutcome(service: service, ctx: ctx, cart: cart)
            guard !Task.isCancelled else {
                return RefreshExecution(effectiveKey: effectiveKey, outcome: .cancelled)
            }
            return try await handle(outcome, service: service, key: effectiveKey,
                                    ctx: ctx, cart: cart, mayAutoSolve: true)
        } catch is CancellationError {
            return RefreshExecution(effectiveKey: effectiveKey, outcome: .cancelled)
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            return RefreshExecution(effectiveKey: effectiveKey, outcome: .cancelled)
        } catch is TrackedStoreCommitError {
            return failure(effectiveKey, Self.persistenceFailureMessage)
        } catch {
            return failure(effectiveKey,
                           "Не удалось собрать движение дела: \(error.localizedDescription)")
        }
    }

    private func fetchOutcome(service: any MovementProviding, ctx: MovementContext,
                              cart: Cartoteka) async throws -> SourceOutcome<CaseMovement> {
        let family = MosGorSudRouting.isMosGorSud(domain: ctx.searchDomain)
            ? "mosgorsud"
            : (ctx.courtLevel == .magistrate ? "msudrf" : "sudrf")
        do {
            let movement = try await service.movement(for: ctx.baseResult,
                                                      court: ctx.searchCourt,
                                                      cartoteka: cart)
            let attempt = SourceOutcomeClassifier.attempt(
                for: movement, sourceFamily: family, host: ctx.searchDomain)
            return attempt.kind == .partial
                ? .partial(movement, attempt)
                : .usableSnapshot(movement, attempt)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw error
        } catch SudrfError.captchaRequired(let url) {
            let attempt = SourceOutcomeClassifier.attempt(
                for: SudrfError.captchaRequired(formURL: url), operation: .movement,
                sourceFamily: family, host: ctx.searchDomain)
            return .captcha(formURL: url, attempt)
        } catch {
            let attempt = SourceOutcomeClassifier.attempt(
                for: error, operation: .movement, sourceFamily: family,
                host: ctx.searchDomain)
            let message = (error as? SudrfError)?.description
                ?? "Не удалось собрать движение дела: \(error.localizedDescription)"
            switch attempt.kind {
            case .maintenance: return .maintenance(message: message, attempt)
            case .transportFailure: return .transportFailure(message: message, attempt)
            default: return .parserFailure(message: message, attempt)
            }
        }
    }

    /// CAPTCHA вышестоящего суда находится внутри пригодного или частичного
    /// движения. До публикации промежуточного стаба запускаем тот же автосолв
    /// и полный retry, что для top-level `.captcha`. nil сохраняет прежний
    /// ручной fallback, если автосолв выключен или не уверен в ответе.
    private func retryEmbeddedCaptchaIfNeeded(
        movement: CaseMovement,
        service: any MovementProviding,
        key: String,
        ctx: MovementContext,
        cart: Cartoteka,
        mayAutoSolve: Bool
    ) async throws -> RefreshExecution? {
        guard mayAutoSolve,
              let formURL = movement.instances.first(where: { $0.captchaFormURL != nil })?.captchaFormURL,
              let solver = captchaSolver,
              let settings = captchaSettings,
              settings.isEffectivelyEnabled else { return nil }

        let result = await solveCaptcha(formURL: formURL, solver: solver, settings: settings)
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        guard result.token != nil else { return nil }

        let retry = try await fetchOutcome(service: service, ctx: ctx, cart: cart)
        return try await handle(retry, service: service, key: key, ctx: ctx,
                                cart: cart, mayAutoSolve: false)
    }

    /// CAPTCHA может дать одну inline-попытку с новым токеном. Повтор снова
    /// проходит через тот же типизированный контракт, но уже без рекурсии
    /// авто-солвера и без обхода таблицы дедупликации `tasks`.
    private func handle(_ outcome: SourceOutcome<CaseMovement>,
                        service: any MovementProviding, key: String,
                        ctx: MovementContext, cart: Cartoteka,
                        mayAutoSolve: Bool) async throws -> RefreshExecution {
        guard !Task.isCancelled else { throw CancellationError() }
        switch outcome {
        case .usableSnapshot(let movement, let attempt):
            if let retry = try await retryEmbeddedCaptchaIfNeeded(
                movement: movement, service: service, key: key, ctx: ctx, cart: cart,
                mayAutoSolve: mayAutoSolve) {
                return retry
            }
            return try applyMovement(key: key, ctx: ctx, mv: movement,
                                     attempt: attempt, isComplete: true)
        case .partial(let movement, let attempt):
            guard let movement else {
                try persistAttempt(key, attempt)
                return failure(key, "Суд вернул неполный ответ без пригодного движения дела.")
            }
            if let retry = try await retryEmbeddedCaptchaIfNeeded(
                movement: movement, service: service, key: key, ctx: ctx, cart: cart,
                mayAutoSolve: mayAutoSolve) {
                return retry
            }
            let failedSources = movement.incompleteHigherCourtDomains ?? []
            let failedCount = failedSources.count
            let message: String
            if failedCount == 0 {
                let zeroCount = movement.honestZeroDomains?.count ?? 0
                message = zeroCount == 1
                    ? "Один источник подтвердил пустую выдачу; сохранены ранее известные данные."
                    : "Источники подтвердили пустую выдачу; сохранены ранее известные данные."
            } else {
                message = failedCount == 1
                    ? "Не обновился источник \(SudrfHost.moduleHost(failedSources[0])); "
                        + "сохранены последние успешные данные."
                    : "Часть источников не дала полного снимка (\(failedCount)); сохранены последние успешные данные."
            }
            return try applyMovement(key: key, ctx: ctx, mv: movement,
                                     attempt: attempt, isComplete: false,
                                     partialMessage: message,
                                     reportsPartialFailure: failedCount > 0)
        case .honestZero(let attempt):
            try persistAttempt(key, attempt)
            return failure(key, "Источник подтвердил пустую выдачу; сохранённое дело не удалено.")
        case .captcha(let url, let attempt):
            guard mayAutoSolve,
                  let solver = captchaSolver,
                  let settings = captchaSettings,
                  settings.isEffectivelyEnabled else {
                queueCaptcha(key: key, formURL: url)
                try persistAttempt(key, attempt)
                fail(key, "Форма домашнего суда ждёт код с картинки: \(url.absoluteString)")
                return RefreshExecution(effectiveKey: key, outcome: .captchaRequired)
            }
            let result = await solveCaptcha(formURL: url, solver: solver, settings: settings)
            if result.cancelled || Task.isCancelled { throw CancellationError() }
            guard result.token != nil else {
                queueCaptcha(key: key, formURL: url)
                try persistAttempt(key, attempt)
                fail(key, "Форма домашнего суда ждёт код с картинки: \(url.absoluteString)")
                return RefreshExecution(effectiveKey: key, outcome: .captchaRequired)
            }
            let retry = try await fetchOutcome(service: service, ctx: ctx, cart: cart)
            return try await handle(retry, service: service, key: key, ctx: ctx,
                                    cart: cart, mayAutoSolve: false)
        case .maintenance(let message, let attempt),
             .transportFailure(let message, let attempt),
             .parserFailure(let message, let attempt):
            try persistAttempt(key, attempt)
            return failure(key, message)
        }
    }

    /// Coalesces simultaneous solves for the same canonical court module.
    /// The task is intentionally kept independent from individual refresh
    /// cancellation: one card timing out must not cancel a solve needed by
    /// the other cards that reached the same CAPTCHA.
    private func solveCaptcha(
        formURL: URL,
        solver: CaptchaSolver,
        settings: CaptchaSettings
    ) async -> AutoCaptchaSolver.SolveResult {
        let host = SudrfHost.moduleHost(formURL.host?.lowercased() ?? "")
        guard !host.isEmpty else {
            return await autoSolve(formURL, client, solver, settings.autoSolverSettings)
        }
        if let existing = captchaSolveTasks[host] {
            return await existing.value
        }

        let solve = autoSolve
        let c = client
        let solverSettings = settings.autoSolverSettings
        let task = Task {
            let result = await solve(formURL, c, solver, solverSettings)
            if let token = result.token {
                await CaptchaTokenStore.shared.store(token, domain: formURL.host ?? "")
            }
            return result
        }
        captchaSolveTasks[host] = task
        defer { captchaSolveTasks[host] = nil }
        return await task.value
    }

    /// Success-путь `performRefresh`: merge / snapshot / persist / сброс
    /// `lastErrors` + `captchaPending`. Выделен в helper, чтобы его
    /// выполнял и обычный happy path, и inline-retry после успешного
    /// авто-солва капчи (A1). Guard на удалённую запись сохранён: пока
    /// шёл сетевой вызов, пользователь мог удалить дело.
    private func applyMovement(key: String, ctx: MovementContext,
                               mv: CaseMovement, attempt: SourceAttempt,
                               isComplete: Bool, partialMessage: String? = nil,
                               reportsPartialFailure: Bool = true) throws -> RefreshExecution {
        guard let rec = store.record(forKey: key) else {
            return RefreshExecution(effectiveKey: key, outcome: .notFound)
        }
        let merged = MovementCachePolicy.merge(fresh: mv, cached: rec.movement)
        let oldMovement = rec.movement
        let oldSnapshot = rec.snapshot
        let newSnap = MovementDerivation.preservingConfirmedDeadlines(
            MovementDerivation.snapshot(from: merged, context: ctx), old: oldSnapshot)
        let persistedMovement = MovementCachePolicy.stripped(forPersist: merged)
        let snapshotSourceChanged = oldSnapshot.map {
            !$0.hasSameRefreshSource(as: newSnap)
        } ?? true
        let movementSourceChanged = oldMovement.map {
            !MovementDerivation.hasSameRefreshSource($0, persistedMovement)
        } ?? true
        let changed = movementSourceChanged || snapshotSourceChanged
        let persisted: TrackedCaseRecord
        var keyRemaps: [String: String] = [:]
        var publishedMovement = merged
        var semanticOldSnapshots = oldSnapshot.map { [$0] } ?? []
        let projectionKeys: Set<String>
        if isComplete,
           let identityObservation = TrackedCaseIdentity.observation(
               context: ctx, movement: persistedMovement, attempt: attempt,
               outcome: .usableSnapshot) {
            // A usable background snapshot enters through the same identity
            // boundary as manual tracking.  Partial/error responses never
            // establish a card/UID relation and are deliberately kept on the
            // existing record below.
            let beforeRecords = try store.allForMutation()
            let before = Set(beforeRecords.map(\.key))
            let beforeSnapshots = Dictionary(uniqueKeysWithValues: beforeRecords.compactMap {
                record in record.snapshot.map { (record.key, $0) }
            })
            let reconciled = try store.reconcileAndUpsert(
                context: ctx, snapshot: newSnap, movement: persistedMovement,
                collections: rec.collectionNames,
                identityObservation: identityObservation,
                movementFetchedAt: attempt.provenance.observedAt,
                saveChanges: false)
            persisted = reconciled
            let removed = before.subtracting(Set(store.all().map(\.key)))
            keyRemaps = Dictionary(uniqueKeysWithValues: removed.map {
                ($0, persisted.key)
            })
            projectionKeys = removed.union([persisted.key])
            semanticOldSnapshots = projectionKeys.compactMap { beforeSnapshots[$0] }
            // Reconciliation may have merged this refreshed card into a
            // dossier whose survivor already contained other instances and
            // acts. Publish the full persisted projection in that case.
            publishedMovement = persisted.movement ?? merged
        } else {
            rec.snapshot = newSnap
            rec.movement = persistedMovement
            // Some legacy/source contexts do not expose a complete
            // source-native card identity. A successful refresh must still
            // advance the last-success TTL; only identity reconciliation is
            // skipped in that case.
            if isComplete { rec.movementFetchedAt = attempt.provenance.observedAt }
            persisted = rec
            projectionKeys = [persisted.key]
        }
        persisted.sourceRefreshAttempt = attempt
        var journal = try store.requiredEventJournal(for: persisted)
        let finalSnapshot = persisted.snapshot ?? newSnap
        let derivation: CaseEventDerivationResult
        if journal.derivationVersion != CaseEventJournal.currentDerivationVersion {
            derivation = .init(events: [], diagnostics: [.derivationVersionChanged])
        } else {
            let baseline = CaseEventDeriver.conservativeBaseline(
                semanticOldSnapshots, comparedTo: finalSnapshot)
            derivation = CaseEventDeriver.derive(
                old: baseline, new: finalSnapshot,
                attempt: isComplete ? attempt : SourceAttempt(
                    kind: .partial, provenance: attempt.provenance),
                observedAt: attempt.provenance.observedAt)
        }
        journal.derivationVersion = CaseEventJournal.currentDerivationVersion
        try journal.append(derivation.events)
        persisted.eventJournalData = try JSONEncoder().encode(journal)
        // Фон нашёл изменения → бейдж «обновлено» загорается вновь;
        // кроме дела, открытого прямо сейчас (пользователь его и так видит).
        if changed && openedKey?() != persisted.key { persisted.seenAt = nil }
        try store.save(projection: .cases(projectionKeys))
        let kinds = Dictionary(grouping: derivation.events, by: \.kind)
            .map { "\($0.key.rawValue):\($0.value.count)" }.sorted()
            .joined(separator: ",")
        let reasons = derivation.diagnostics.map(\.rawValue).sorted().joined(separator: ",")
        semanticEventLog.info(
            "legacyChanged=\(changed) semanticCount=\(derivation.events.count) kinds=\(kinds, privacy: .public) reasons=\(reasons, privacy: .public)")
        captchaPending.remove(key: key)
        if persisted.key != key { captchaPending.remove(key: persisted.key) }
        onRefreshed?(persisted.key, publishedMovement, keyRemaps)
        if let partialMessage {
            if reportsPartialFailure {
                fail(persisted.key, partialMessage)
            } else {
                lastErrors[persisted.key] = nil
            }
            return RefreshExecution(effectiveKey: persisted.key, outcome: .partial(partialMessage))
        }
        lastErrors[persisted.key] = nil
        return RefreshExecution(effectiveKey: persisted.key, outcome: .refreshed)
    }

    private func persistAttempt(_ key: String, _ attempt: SourceAttempt) throws {
        guard let rec = store.record(forKey: key) else { return }
        rec.sourceRefreshAttempt = attempt
        try store.save()
    }

    private func queueCaptcha(key: String, formURL: URL) {
        guard formURL.host != nil, let rec = store.record(forKey: key) else { return }
        captchaPending.add(key: key, caseNumber: rec.caseNumber, formURL: formURL)
    }

    private func fail(_ key: String, _ text: String) {
        lastErrors[key] = text
        onRefreshFailed?(key, text)
    }

    private func failure(_ key: String, _ text: String) -> RefreshExecution {
        fail(key, text)
        return RefreshExecution(effectiveKey: key, outcome: .failed(text))
    }
}
