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
    var keys: [String]
    var caseNumbers: [String]

    var id: String { host }
    var count: Int { keys.count }
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

    mutating func add(key: String, caseNumber: String, host rawHost: String) {
        remove(key: key)
        let host = Self.normalizedHost(rawHost)
        var group = groupsByHost[host] ?? CaptchaPendingGroup(host: host, keys: [], caseNumbers: [])
        group.keys.append(key)
        group.caseNumbers.append(caseNumber)
        groupsByHost[host] = group
    }

    mutating func remove(key: String) {
        for host in groupsByHost.keys {
            guard var group = groupsByHost[host],
                  let index = group.keys.firstIndex(of: key) else { continue }
            group.keys.remove(at: index)
            if group.caseNumbers.indices.contains(index) {
                group.caseNumbers.remove(at: index)
            }
            groupsByHost[host] = group.keys.isEmpty ? nil : group
            return
        }
    }

    mutating func drain(host rawHost: String) -> CaptchaPendingGroup? {
        groupsByHost.removeValue(forKey: Self.normalizedHost(rawHost))
    }
}

@MainActor
final class RefreshCenter: ObservableObject {

    struct WalkProgress: Equatable { var done: Int; var total: Int }

    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var walkProgress: WalkProgress? = nil
    @Published private(set) var lastErrors: [String: String] = [:]
    @Published private var captchaPending = CaptchaPendingQueue()

    /// После успешного обновления записи (ключ, слитая карточка для показа).
    var onRefreshed: ((String, CaseMovement) -> Void)?
    /// При ошибке обновления (ключ, короткий текст).
    var onRefreshFailed: ((String, String) -> Void)?
    /// Ключ открытой сейчас карточки — фоновое обновление не должно гасить
    /// ей бейдж «обновлено» (см. правило seenAt в задаче обновления).
    var openedKey: (() -> String?)?

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
    private var tasks: [String: Task<Void, Never>] = [:]
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
         serviceBuilder: ((MovementContext) -> any MovementProviding)? = nil) {
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
    }

    func isRefreshing(_ key: String) -> Bool { refreshing.contains(key) }

    var captchaPendingGroups: [CaptchaPendingGroup] { captchaPending.groups }

    func captchaPendingCount(forHost host: String?) -> Int {
        captchaPending.group(forHost: host)?.count ?? 0
    }

    func captchaPendingCaseNumbers(forHost host: String?, limit: Int = 4) -> [String] {
        Array((captchaPending.group(forHost: host)?.caseNumbers ?? []).prefix(limit))
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
        let ttl = RefreshSettings.ttl
        let keys = store.all().filter { rec in
            force || rec.movementFetchedAt.map { Date().timeIntervalSince($0) > ttl } ?? true
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
                            await self?.refresh(key: key)?.value
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
    func refresh(key: String) -> Task<Void, Never>? {
        if let existing = tasks[key] { return existing }
        guard store.record(forKey: key) != nil else { return nil }

        refreshing.insert(key)
        let task = Task { [weak self] in
            await self?.performRefresh(key: key)
            self?.refreshing.remove(key)
            self?.tasks[key] = nil
        }
        tasks[key] = task
        return task
    }

    private func performRefresh(key: String) async {
        guard let rec = store.record(forKey: key),
              let ctx = rec.context, let cart = ctx.cartoteka else {
            fail(key, "Не удалось восстановить параметры поиска по делу.")
            return
        }
        let service = serviceBuilder(ctx)
        do {
            let mv = try await service.movement(for: ctx.baseResult,
                                                court: ctx.searchCourt, cartoteka: cart)
            applyMovement(key: key, ctx: ctx, mv: mv)
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
                queueCaptcha(key: key, formURL: url)
                fail(key, "Форма домашнего суда ждёт код с картинки: \(url.absoluteString)")
                return
            }
            let result = await autoSolve(url, client, solver, settings.autoSolverSettings)
            if let token = result.token {
                await CaptchaTokenStore.shared.store(token, domain: url.host ?? "")
                // v0.38.9: bootstrap в CorpusStore НЕ делаем здесь
                // (нет гарантии, что retry с токеном прошёл; это
                // шумный сигнал, лучше перебдеть). Bootstrap живёт
                // в `SearchModel.executeSearch`.
                do {
                    let mv = try await service.movement(for: ctx.baseResult,
                                                        court: ctx.searchCourt,
                                                        cartoteka: cart)
                    applyMovement(key: key, ctx: ctx, mv: mv)
                } catch SudrfError.captchaRequired(let url2) {
                    queueCaptcha(key: key, formURL: url2)
                    fail(key, "Форма домашнего суда ждёт код с картинки: \(url2.absoluteString)")
                } catch let e as SudrfError {
                    fail(key, e.description)
                } catch {
                    fail(key, "Не удалось собрать движение дела: \(error.localizedDescription)")
                }
            } else {
                queueCaptcha(key: key, formURL: url)
                fail(key, "Форма домашнего суда ждёт код с картинки: \(url.absoluteString)")
            }
        } catch let e as SudrfError {
            fail(key, e.description)
        } catch {
            fail(key, "Не удалось собрать движение дела: \(error.localizedDescription)")
        }
    }

    /// Success-путь `performRefresh`: merge / snapshot / persist / сброс
    /// `lastErrors` + `captchaPending`. Выделен в helper, чтобы его
    /// выполнял и обычный happy path, и inline-retry после успешного
    /// авто-солва капчи (A1). Guard на удалённую запись сохранён: пока
    /// шёл сетевой вызов, пользователь мог удалить дело.
    private func applyMovement(key: String, ctx: MovementContext, mv: CaseMovement) {
        guard let rec = store.record(forKey: key) else { return }
        let merged = MovementCachePolicy.merge(fresh: mv, cached: rec.movement)
        let newSnap = MovementDerivation.preservingConfirmedDeadlines(
            MovementDerivation.snapshot(from: merged, context: ctx), old: rec.snapshot)
        let changed = rec.snapshot != newSnap
        rec.snapshot = newSnap
        rec.movement = MovementCachePolicy.stripped(forPersist: merged)
        rec.movementFetchedAt = Date()
        // Фон нашёл изменения → бейдж «обновлено» загорается вновь;
        // кроме дела, открытого прямо сейчас (пользователь его и так видит).
        if changed && openedKey?() != key { rec.seenAt = nil }
        store.save()
        captchaPending.remove(key: key)
        lastErrors[key] = nil
        onRefreshed?(key, merged)
    }

    private func queueCaptcha(key: String, formURL: URL) {
        guard let host = formURL.host,
              let rec = store.record(forKey: key) else { return }
        captchaPending.add(key: key, caseNumber: rec.caseNumber, host: host)
    }

    private func fail(_ key: String, _ text: String) {
        lastErrors[key] = text
        onRefreshFailed?(key, text)
    }
}
