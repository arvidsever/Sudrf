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
//  идущую задачу. Обход ПАРАЛЛЕЛЕН ПО СУДАМ (до RefreshSettings.maxConcurrentCourts
//  одновременно): у каждого суда СОЮ свой сервер. Внутри одного суда дела идут
//  последовательно, темп внутри суда задаёт пер-хост троттл SudrfClient (1.5 с).
//  Ошибка одного дела не прерывает обход и НИКОГДА не трогает уже сохранённый кэш.

import Foundation
import SudrfKit
import CaptchaSolver

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

    /// После успешного обновления записи (ключ, слитая карточка для показа).
    var onRefreshed: ((String, CaseMovement) -> Void)?
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
    /// новый ключ; nil сохраняет поведение тестов и старых вызовов.
    var repairBeforeRefresh: ((String) async -> String)?

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
    private var tasks: [String: Task<RefreshExecution, Never>] = [:]
    private var enforcementTasks: [String: Task<Void, Never>] = [:]
    private var walkTask: Task<Void, Never>? = nil
    /// Поколение обхода: отменённый принудительным перезапуском обход не должен
    /// своим завершением сбросить walkTask/walkProgress нового обхода.
    private var walkGeneration = 0
    private var timerTask: Task<Void, Never>? = nil

    init(store: TrackedStore, client: SudrfClient,
         captchaSolver: CaptchaSolver? = nil,
         captchaSettings: CaptchaSettings? = nil,
         autoSolve: ((URL, SudrfClient, CaptchaSolver,
                      AutoCaptchaSolver.Settings) async -> AutoCaptchaSolver.SolveResult)? = nil,
         serviceBuilder: ((MovementContext) -> any MovementProviding)? = nil,
         treasuryDiscover: ((CourtEnforcementDocument, String?, String?) async throws
            -> EnforcementLookup)? = nil) {
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
        let keys = store.all().filter { rec in
            force
                || rec.movementFetchedAt.map { now.timeIntervalSince($0) > ttl } ?? true
                || needsEnforcementRefresh(rec, now: now, ttl: ttl)
        }.map(\.key)
        guard !keys.isEmpty else { return }

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

            // Один последовательный воркер на суд; параллельно не более
            // maxConcurrentCourts судов (seed N, затем добавляем следующий по мере
            // освобождения). Дела разных судов бьют разные серверы одновременно,
            // внутри суда пер-хост троттл держит 1.5 с.
            let courts = Array(groups.values)
            let limit = max(1, RefreshSettings.maxConcurrentCourts)
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func addWorker() {
                    guard next < courts.count else { return }
                    let courtKeys = courts[next]
                    next += 1
                    group.addTask { [weak self] in
                        for key in courtKeys {
                            if Task.isCancelled { return }
                            _ = await self?.refresh(key: key, forceEnforcement: force)?.value
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

        refreshing.insert(key)
        let task = Task { [weak self] in
            guard let self else {
                return RefreshExecution(effectiveKey: key, outcome: .notFound)
            }
            let execution = await self.performRefresh(key: key)
            _ = await self.startEnforcementRefresh(
                key: execution.effectiveKey, force: forceEnforcement)?.value
            self.refreshing.remove(key)
            self.tasks[key] = nil
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

    private func startEnforcementRefresh(key: String, force: Bool) -> Task<Void, Never>? {
        if let existing = enforcementTasks[key] { return existing }
        guard let record = store.record(forKey: key),
              force || needsEnforcementRefresh(record, now: Date(), ttl: RefreshSettings.ttl)
        else { return nil }

        refreshingEnforcement.insert(key)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performEnforcementRefresh(key: key)
            self.refreshingEnforcement.remove(key)
            self.enforcementTasks[key] = nil
        }
        enforcementTasks[key] = task
        return task
    }

    /// Суд может не ответить, но ранее сохранённые исполнительные листы всё
    /// равно проверяются. Ошибка Казначейства сохраняется отдельно от исхода
    /// судебного refresh и не трогает кэш движения/снимок.
    private func performEnforcementRefresh(key: String) async {
        guard let record = store.record(forKey: key) else { return }
        let documents = paperEnforcementDocuments(for: record)
        guard !documents.isEmpty else { return }

        let previous = record.enforcementRecords
        var updates: [EnforcementRecord] = []
        var errors: [String] = []
        for document in documents {
            let attemptedAt = Date()
            do {
                let lookup = try await treasuryDiscover(document, record.caseNumber, record.courtTitle)
                var update = lookup.record ?? EnforcementRecord(
                    courtDocumentID: document.id, source: .treasury,
                    discoveryState: lookup.state, status: "", lastAttemptAt: attemptedAt)
                update.discoveryState = lookup.state
                update.lastAttemptAt = attemptedAt
                if lookup.state != .error {
                    update.lastSuccessAt = update.lastSuccessAt ?? attemptedAt
                    update.error = nil
                }
                updates.append(update)
            } catch {
                let message = error.localizedDescription
                errors.append(message)
                if var update = previous.first(where: {
                    $0.source == .treasury && $0.courtDocumentID == document.id
                }) {
                    // Ошибка транспорта не меняет последний строгий результат
                    // сопоставления и не стирает статус/историю.
                    update.lastAttemptAt = attemptedAt
                    update.error = message
                    updates.append(update)
                } else {
                    updates.append(EnforcementRecord(
                        courtDocumentID: document.id, source: .treasury,
                        discoveryState: .error, status: "", lastAttemptAt: attemptedAt,
                        error: message))
                }
            }
        }

        let current = TrackedStore.reconciledEnforcementRecords(
            existing: previous, updates: updates, courtDocuments: record.movement?.executionDocuments ?? [])
        let changed = TrackedStore.enforcementHasUserVisibleChange(
            previous: previous, current: current, courtDocuments: record.movement?.executionDocuments ?? [])
        record.enforcementRecords = current
        if changed && openedKey?() != key { record.seenAt = nil }
        store.save()

        let hasSuccess = updates.contains { $0.discoveryState != .error }
        if errors.isEmpty {
            enforcementErrors[key] = nil
        } else {
            enforcementErrors[key] = errors.joined(separator: "\n")
        }
        if hasSuccess { onEnforcementRefreshed?(key) }
    }

    private func paperEnforcementDocuments(for record: TrackedCaseRecord) -> [CourtEnforcementDocument] {
        (record.movement?.executionDocuments ?? []).filter {
            !($0.blankNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private func needsEnforcementRefresh(_ record: TrackedCaseRecord, now: Date,
                                         ttl: TimeInterval) -> Bool {
        let records = record.enforcementRecords
        return paperEnforcementDocuments(for: record).contains { document in
            guard let saved = records.first(where: {
                $0.source == .treasury && $0.courtDocumentID == document.id
            }) else { return true }
            let checkedAt = saved.lastAttemptAt ?? saved.lastSuccessAt ?? .distantPast
            return now.timeIntervalSince(checkedAt) > ttl
        }
    }

    private func performRefresh(key: String) async -> RefreshExecution {
        let effectiveKey = await repairBeforeRefresh?(key) ?? key
        guard let rec = store.record(forKey: effectiveKey),
              let ctx = rec.context, let cart = ctx.cartoteka else {
            return failure(effectiveKey, "Не удалось восстановить параметры поиска по делу.")
        }
        let service = serviceBuilder(ctx)
        do {
            return try await fetchAndApply(service: service, key: effectiveKey,
                                           ctx: ctx, cart: cart)
        } catch SudrfError.captchaRequired(let url) {
            // Сначала пробуем авто-солвер. Если он вернёт уверенный
            // ответ и токен попадёт в CaptchaTokenStore, повторный
            // `service.movement` пройдёт без капчи и без ручного ввода.
            // Если солвер выключен / не уверен / исчерпал попытки — ставим
            // в `CaptchaPendingQueue` и ждём пользователя.
            //
            // A1: повтор `service.movement` идёт INLINE в этой же Task.
            // Прежний путь звал `refresh(key:)` → `refresh` дедуплицирует
            // по `tasks[key]`, который чистится только ПОСЛЕ возврата
            // `performRefresh`. Получалось, что `refresh` возвращал
            // текущий task, и токен оставался в сторе не потреблённым.
            guard let solver = captchaSolver,
                  let settings = captchaSettings,
                  settings.isEffectivelyEnabled else {
                queueCaptcha(key: effectiveKey, formURL: url)
                let message = "Форма домашнего суда ждёт код с картинки: \(url.absoluteString)"
                fail(effectiveKey, message)
                return RefreshExecution(effectiveKey: effectiveKey, outcome: .captchaRequired)
            }
            let result = await autoSolve(url, client, solver, settings.autoSolverSettings)
            if let token = result.token {
                await CaptchaTokenStore.shared.store(token, domain: url.host ?? "")
                // v0.38.9: bootstrap в CorpusStore НЕ делаем здесь
                // (нет гарантии, что retry с токеном прошёл; это
                // шумный сигнал, лучше перебдеть). Bootstrap живёт
                // в `SearchModel.executeSearch`.
                do {
                    return try await fetchAndApply(service: service, key: effectiveKey,
                                                   ctx: ctx, cart: cart)
                } catch SudrfError.captchaRequired(let url2) {
                    queueCaptcha(key: effectiveKey, formURL: url2)
                    let message = "Форма домашнего суда ждёт код с картинки: \(url2.absoluteString)"
                    fail(effectiveKey, message)
                    return RefreshExecution(effectiveKey: effectiveKey, outcome: .captchaRequired)
                } catch let e as SudrfError {
                    return failure(effectiveKey, e.description)
                } catch {
                    return failure(effectiveKey,
                                   "Не удалось собрать движение дела: \(error.localizedDescription)")
                }
            } else {
                queueCaptcha(key: effectiveKey, formURL: url)
                let message = "Форма домашнего суда ждёт код с картинки: \(url.absoluteString)"
                fail(effectiveKey, message)
                return RefreshExecution(effectiveKey: effectiveKey, outcome: .captchaRequired)
            }
        } catch let e as SudrfError {
            return failure(effectiveKey, e.description)
        } catch {
            return failure(effectiveKey,
                           "Не удалось собрать движение дела: \(error.localizedDescription)")
        }
    }

    /// Выполняет один сетевой запрос движения и атомарно применяет его к
    /// кэшу. Общий happy-path нужен и для первой попытки, и для inline-retry
    /// после CAPTCHA: повтор не должен звать `refresh(key:)`, пока текущая
    /// task остаётся в таблице дедупликации.
    private func fetchAndApply(service: any MovementProviding, key: String,
                               ctx: MovementContext, cart: Cartoteka) async throws -> RefreshExecution {
        let movement = try await service.movement(for: ctx.baseResult,
                                                  court: ctx.searchCourt,
                                                  cartoteka: cart)
        return applyMovement(key: key, ctx: ctx, mv: movement)
    }

    /// Success-путь `performRefresh`: merge / snapshot / persist / сброс
    /// `lastErrors` + `captchaPending`. Выделен в helper, чтобы его
    /// выполнял и обычный happy path, и inline-retry после успешного
    /// авто-солва капчи (A1). Guard на удалённую запись сохранён: пока
    /// шёл сетевой вызов, пользователь мог удалить дело.
    private func applyMovement(key: String, ctx: MovementContext,
                               mv: CaseMovement) -> RefreshExecution {
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
        rec.snapshot = newSnap
        rec.movement = persistedMovement
        rec.movementFetchedAt = Date()
        // Фон нашёл изменения → бейдж «обновлено» загорается вновь;
        // кроме дела, открытого прямо сейчас (пользователь его и так видит).
        if changed && openedKey?() != key { rec.seenAt = nil }
        store.save(projection: .cases([key]))
        captchaPending.remove(key: key)
        lastErrors[key] = nil
        onRefreshed?(key, merged)
        return RefreshExecution(effectiveKey: key, outcome: .refreshed)
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
