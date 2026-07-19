import Foundation
import SudrfKit
import CaptchaSolver

/// Запросы ремонта, остановившиеся на captcha, группируются по каноническому
/// host: одна успешно введённая пара разблокирует все такие карточки суда.
struct RepairCaptchaRequest: Equatable, Identifiable {
    let key: String
    let caseNumber: String
    let courtTitle: String
    let formURL: URL

    var id: String { key }
    var host: String { SudrfHost.moduleHost(formURL.host ?? "") }
}

struct RepairCaptchaGroup: Equatable, Identifiable {
    let host: String
    let requests: [RepairCaptchaRequest]

    var id: String { host }
    var count: Int { requests.count }
    var caseNumbers: [String] { requests.map(\.caseNumber) }
    var formURL: URL? { requests.first?.formURL }
    var courtTitle: String { requests.first?.courtTitle ?? host }
}

struct CaseRepairSummary: Equatable {
    var merged = 0
    /// Восстановлена каноническая карточка дела первой инстанции.
    var reanchored = 0
    /// Восстановлена каноническая карточка самостоятельного материала.
    var restoredMaterials = 0
    var rerouted = 0
    var notFound: [String] = []
    var ambiguous: [String] = []
    var transient = 0
    var keyRemaps: [String: String] = [:]
    /// Отдельно от `unresolved`: captcha — действие пользователя, а не
    /// невозможность сопоставления карточки.
    var captchaRequests: [RepairCaptchaRequest] = []

    var captchaGroups: [RepairCaptchaGroup] {
        Dictionary(grouping: captchaRequests, by: \.host)
            .map { RepairCaptchaGroup(host: $0.key,
                                      requests: $0.value.sorted { $0.caseNumber < $1.caseNumber }) }
            .sorted { $0.host < $1.host }
    }

    var hasReport: Bool {
        merged > 0 || reanchored > 0 || restoredMaterials > 0 || rerouted > 0
            || !notFound.isEmpty || !ambiguous.isEmpty
            || transient > 0 || !captchaRequests.isEmpty
    }

    /// Слияние дублей и последующее переякоривание могут дать цепочку
    /// `старый -> промежуточный -> канонический`. Потребители всегда должны
    /// получать конечный ключ, независимо от порядка операций repair.
    func effectiveKey(for key: String) -> String {
        var current = key
        var visited = Set<String>()
        while visited.insert(current).inserted, let next = keyRemaps[current] {
            current = next
        }
        return current
    }

    var text: String {
        var lines = ["Объединено дублирующих карточек: \(merged).",
                     "Восстановлено карточек первой инстанции: \(reanchored)."]
        if restoredMaterials > 0 {
            lines.append("Восстановлено карточек материалов: \(restoredMaterials).")
        }
        if rerouted > 0 { lines.append("Исправлено маршрутов КоАП: \(rerouted).") }
        if !captchaRequests.isEmpty {
            lines.append("Нужен код с картинки: \(captchaRequests.count) (судов: \(captchaGroups.count)).")
        }
        if transient > 0 { lines.append("Временно недоступно, будет повторено: \(transient).") }
        if !notFound.isEmpty {
            lines.append("Нижестоящая карточка не найдена: \(notFound.count).")
            lines.append(contentsOf: notFound.prefix(12).map { "• \($0)" })
        }
        if !ambiguous.isEmpty {
            lines.append("Найдено несколько точных совпадений: \(ambiguous.count).")
            lines.append(contentsOf: ambiguous.prefix(12).map { "• \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    var unresolved: [String] { Self.unique(notFound + ambiguous) }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// Идемпотентный ремонт сохранённых цепочек. Все удаления выполняются только
/// после построения канонической записи и единым save на группу.
@MainActor
final class TrackedCaseRepairCoordinator {
    struct Outcome {
        var effectiveKey: String
        var summary: CaseRepairSummary
    }

    private let store: TrackedStore
    private let client: SudrfClient
    private let originResolver: any CaseOriginResolving
    private let anchorCardFetcher: (MovementContext) async throws -> CaseCard
    private let defaults: UserDefaults
    private let now: () -> Date
    private let captchaSolver: CaptchaSolver?
    private let captchaSettings: CaptchaSettings?
    private let autoSolve: (URL, SudrfClient, CaptchaSolver,
                            AutoCaptchaSolver.Settings) async -> AutoCaptchaSolver.SolveResult
    // v5 повторно прогоняет v4: поиск по УИД мог вернуть строку другой
    // картотеки и преждевременно завершиться до точного поиска по номеру.
    private static let migrationID = "importChainRepair.v5"
    private var attemptsKey: String { "\(Self.migrationID).attempts" }
    private var nextRetryKey: String { "\(Self.migrationID).nextRetry" }
    private var unsupportedKey: String { "\(Self.migrationID).unsupported" }
    private var completedKey: String { "\(Self.migrationID).completed" }
    private var runningTask: Task<CaseRepairSummary, Never>?

    init(store: TrackedStore, client: SudrfClient, originResolver: any CaseOriginResolving,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         captchaSolver: CaptchaSolver? = nil,
         captchaSettings: CaptchaSettings? = nil,
         autoSolve: ((URL, SudrfClient, CaptchaSolver,
                      AutoCaptchaSolver.Settings) async -> AutoCaptchaSolver.SolveResult)? = nil,
         anchorCardFetcher: ((MovementContext) async throws -> CaseCard)? = nil) {
        self.store = store; self.client = client; self.originResolver = originResolver
        self.defaults = defaults; self.now = now
        self.captchaSolver = captchaSolver
        self.captchaSettings = captchaSettings
        self.autoSolve = autoSolve ?? { url, client, solver, settings in
            await AutoCaptchaSolver.solve(formURL: url, client: client,
                                          solver: solver, settings: settings)
        }
        self.anchorCardFetcher = anchorCardFetcher ?? { ctx in
            if let url = ctx.cardURLString.flatMap(URL.init(string:)) {
                return try await client.fetchCard(url: url)
            }
            guard let id = ctx.caseID, let guid = ctx.caseUID, let cart = ctx.cartoteka else {
                throw CaseOriginResolutionError.noReference
            }
            return try await client.fetchCard(court: ctx.searchCourt, caseID: id, caseUID: guid,
                                              deloID: cart.deloID, new: cart.new)
        }
    }

    func runAll() async -> CaseRepairSummary {
        if let runningTask { return await runningTask.value }
        let task = Task { @MainActor [self] in await runAllPass() }
        runningTask = task
        let summary = await task.value
        runningTask = nil
        return summary
    }

    private func runAllPass() async -> CaseRepairSummary {
        var summary = CaseRepairSummary()
        summary.rerouted += normalizeStoredKoAPRoutes()
        mergeKnownUIDDuplicates(into: &summary)

        // Снимок ключей после локального слияния: сеть не должна работать с уже
        // удалёнными managed objects.
        let keys = store.all().compactMap { rec -> String? in
            guard let ctx = rec.context, shouldRepair(ctx) else { return nil }
            return rec.key
        }
        for key in keys {
            guard shouldAttempt(key: key) else { continue }
            await repairHigherAnchor(key: key, summary: &summary)
        }
        summary.notFound = Self.unique(summary.notFound)
        summary.ambiguous = Self.unique(summary.ambiguous)
        return summary
    }

    /// Точечный preflight для RefreshCenter. Локальное UID-слияние дешёвое и
    /// гарантирует, что refresh продолжится уже по каноническому ключу.
    func repairIfNeeded(key: String) async -> Outcome {
        if let runningTask {
            let summary = await runningTask.value
            return Outcome(effectiveKey: summary.effectiveKey(for: key), summary: summary)
        }
        var summary = CaseRepairSummary()
        summary.rerouted += normalizeStoredKoAPRoutes()
        mergeKnownUIDDuplicates(into: &summary)
        let localKey = summary.effectiveKey(for: key)
        guard let rec = store.record(forKey: localKey),
              let ctx = rec.context,
              shouldRepair(ctx),
              shouldAttempt(key: localKey) else {
            return Outcome(effectiveKey: localKey, summary: summary)
        }
        await repairHigherAnchor(key: localKey, summary: &summary)
        return Outcome(effectiveKey: summary.effectiveKey(for: key), summary: summary)
    }

    private func repairHigherAnchor(key: String, summary: inout CaseRepairSummary,
                                    allowAutoSolve: Bool = true) async {
        guard let rec = store.record(forKey: key), let anchorContext = rec.context else { return }
        // Самостоятельный материал уже является корректным базовым якорем:
        // он участвует в локальном UID-слиянии, но не требует даже загрузки
        // карточки. Сетевой поиск нужен только 13/13а с проверяемым родителем.
        if anchorContext.baseInstanceLevel == .material,
           !CaseOriginResolver.requiresVerifiedParent(number: anchorContext.caseNumber,
                                                      courtLevel: anchorContext.courtLevel) {
            clearRetry(key: key)
            return
        }
        do {
            let anchorCard = try await fetchAnchorCard(anchorContext)
            let normalized = normalizedKoAPContext(anchorContext, card: anchorCard)
            let effectiveContext = normalized.context
            if normalized.changed {
                rec.context = effectiveContext
                if let uid = effectiveContext.judicialUID, !uid.isEmpty {
                    rec.judicialUID = TrackedStore.normalizedUID(uid)
                }
                rec.movementFetchedAt = nil
                _ = store.save()
                summary.rerouted += 1
            }
            if normalized.role == .authorityJudicialReview
                || normalized.role == .firstInstance {
                clearRetry(key: key)
                return
            }
            guard effectiveContext.baseInstanceLevel == .appeal
                    || effectiveContext.baseInstanceLevel == .cassation
                    || effectiveContext.baseInstanceLevel == .material else {
                summary.notFound.append(effectiveContext.caseNumber)
                recordUnsupported(key: key)
                return
            }
            let origin = try await originResolver.resolve(anchorContext: effectiveContext,
                                                          anchorCard: anchorCard)
            let canonical = makeContext(origin: origin, anchor: effectiveContext,
                                        anchorCard: anchorCard)
            let survivor = store.record(forKey: canonical.key) ?? rec
            let duplicates = survivor === rec ? [] : [rec]
            guard let remaps = merge(survivor: survivor, duplicates: duplicates,
                                     canonicalContext: canonical,
                                     canonicalCard: origin.card) else {
                summary.transient += 1
                recordTransient(key: key)
                return
            }
            clearRetry(key: key)
            summary.keyRemaps.merge(remaps) { _, new in new }
            if canonical.baseInstanceLevel == .material {
                summary.restoredMaterials += 1
            } else {
                summary.reanchored += 1
            }
            summary.merged += duplicates.count
        } catch let error as CaseOriginResolutionError {
            switch error {
            case .noReference:
                // Корректная карточка пересмотра может не публиковать номер
                // нижестоящего дела (типичный случай — КоАП 12-*). Такой
                // результат не является ошибкой и не должен шуметь в отчёте.
                clearRetry(key: key)
                recordCompleted(key: key)
            case .ambiguous:
                summary.ambiguous.append(anchorContext.caseNumber)
            case .notFound:
                // Официальная ссылка может вести на карточку, которую сам
                // нижестоящий суд не опубликовал в открытой картотеке. После
                // исчерпывающего поиска по УИД и точному номеру это не ошибка
                // сопоставления: молча отложим новый поиск на потом.
                recordTransient(key: key)
            case .unsupportedCourt:
                summary.notFound.append(anchorContext.caseNumber)
            }
        } catch let error as SudrfError {
            if case .captchaRequired(let formURL) = error {
                // У обычного sudrf-поиска captcha — GET-токен, совместимый с
                // AutoCaptchaSolver. У msudrf это cookie/POST-сессия: её
                // оставляем ручному CaptchaAssistSheet и не отправляем в
                // несовместимый token-flow.
                if allowAutoSolve,
                   !SudrfHost.isMSudrfHost(formURL.host ?? ""),
                   let solver = captchaSolver,
                   let settings = captchaSettings,
                   settings.isEffectivelyEnabled {
                    let solved = await autoSolve(
                        formURL, client, solver, settings.autoSolverSettings)
                    if let token = solved.token {
                        await CaptchaTokenStore.shared.store(
                            token, domain: formURL.host ?? anchorContext.searchDomain)
                        await repairHigherAnchor(
                            key: key, summary: &summary, allowAutoSolve: false)
                        return
                    }
                }
                summary.captchaRequests.append(RepairCaptchaRequest(
                    key: key, caseNumber: anchorContext.caseNumber,
                    courtTitle: anchorContext.courtTitle, formURL: formURL))
            } else if case .transientNetworkError = error {
                summary.transient += 1
                recordTransient(key: key)
            } else {
                if Self.isPublishedKoAPReview(anchorContext),
                   Self.isTerminalCardReadError(error) {
                    // У карточки уже достаточно сохранённых данных, чтобы
                    // считать её корректным звеном КоАП. Невозможность
                    // перечитать необязательную ссылку вниз не превращает
                    // такую карточку в ошибку и не заносит её в unsupported.
                    clearRetry(key: key)
                    recordCompleted(key: key)
                    return
                }
                summary.notFound.append(anchorContext.caseNumber)
                if case .parsing = error { recordUnsupported(key: key) }
                if case .searchModuleUnavailable = error { recordUnsupported(key: key) }
            }
        } catch {
            summary.transient += 1
            recordTransient(key: key)
        }
    }

    private func mergeKnownUIDDuplicates(into summary: inout CaseRepairSummary) {
        let groups = Dictionary(grouping: store.all().filter { !($0.judicialUID ?? "").isEmpty },
                                by: { $0.judicialUID! })
        for records in groups.values where records.count > 1 {
            let sorted = records.sorted { rank($0.context?.baseInstanceLevel) < rank($1.context?.baseInstanceLevel) }
            guard let survivor = sorted.first, let canonical = survivor.context else { continue }
            let duplicates = Array(sorted.dropFirst())
            guard let remaps = merge(survivor: survivor, duplicates: duplicates,
                                     canonicalContext: canonical, canonicalCard: nil) else { continue }
            summary.keyRemaps.merge(remaps) { _, new in new }
            summary.merged += duplicates.count
        }
    }

    private func rank(_ level: CaseInstance.Level?) -> Int {
        switch level {
        case .first: return 0
        case .material: return 1
        case .appeal: return 2
        case .cassation: return 3
        default: return 4
        }
    }

    private func shouldRepair(_ context: MovementContext) -> Bool {
        if context.baseInstanceLevel == .appeal || context.baseInstanceLevel == .cassation
            || context.baseInstanceLevel == .material {
            return true
        }
        return context.courtLevel == .district && context.cartotekaId == "admj"
            && KoAPProceduralRole.resolve(
                courtLevel: context.courtLevel, cartotekaID: context.cartotekaId,
                judicialUID: context.judicialUID) == .unknown
    }

    /// Исправляет сохранённые уровни и точные цели без сети. Записи admj без
    /// УИД остаются кандидатами сетевого прохода, где роль уточняется по карточке.
    private func normalizeStoredKoAPRoutes() -> Int {
        var changedCount = 0
        for rec in store.all() {
            guard let context = rec.context, context.cartotekaId.hasPrefix("adm") else { continue }
            let normalized = normalizedKoAPContext(context, card: nil)
            guard normalized.changed else { continue }
            rec.context = normalized.context
            rec.movementFetchedAt = nil
            changedCount += 1
        }
        if changedCount > 0 { _ = store.save() }
        return changedCount
    }

    private func normalizedKoAPContext(_ original: MovementContext, card: CaseCard?)
        -> (context: MovementContext, role: KoAPProceduralRole, changed: Bool) {
        var context = original
        if let uid = card?.uid, !uid.isEmpty { context.judicialUID = uid }
        let role = KoAPProceduralRole.resolve(
            courtLevel: context.courtLevel, cartotekaID: context.cartotekaId,
            judicialUID: context.judicialUID,
            lowerCourtTitle: card?.lowerCourt?.courtTitle)
        if let level = role.instanceLevel { context.baseInstanceLevelRaw = level.rawValue }

        if let cart = context.cartoteka {
            let districtCourts = (context.higherCourtTargets ?? []).compactMap { target
                -> (domain: String, title: String)? in
                guard target.courtLevel == .district else { return nil }
                return (target.domain, target.courtTitle ?? "Районный суд")
            }
            context.higherCourtTargets = MovementTargetBuilder.targets(
                branch: context.branch, courtLevel: context.courtLevel,
                baseCartoteka: cart, caseNumber: context.caseNumber,
                judicialUID: context.judicialUID, courtTitle: context.courtTitle,
                courtCode: context.courtCode, region: context.region,
                displayDomain: context.displayDomain, districtCourts: districtCourts)
        }
        return (context, role, context != original)
    }

    private func fetchAnchorCard(_ ctx: MovementContext) async throws -> CaseCard {
        try await anchorCardFetcher(ctx)
    }

    private func makeContext(origin: ResolvedCaseOrigin, anchor: MovementContext,
                             anchorCard: CaseCard) -> MovementContext {
        let row = origin.result
        let display = SudrfHost.alternate(origin.court.domain) ?? origin.court.domain
        let cardURL: URL? = row.cardURL ?? {
            guard let id = row.caseID, let guid = row.caseUID else { return nil }
            return try? SudrfURLBuilder(court: origin.court).cardURL(
                caseID: id, caseUID: guid, deloID: origin.cartoteka.deloID,
                new: origin.cartoteka.new)
        }()
        var ctx = MovementContext(
            branchRaw: origin.branch.rawValue, region: origin.region,
            searchDomain: SudrfHost.moduleHost(origin.court.domain),
            displayDomain: display, courtTitle: origin.court.title,
            courtLevelRaw: origin.court.level.rawValue, courtCode: origin.courtCode,
            cartotekaId: origin.cartoteka.id, cartotekaLevelRaw: origin.court.level.rawValue,
            caseNumber: origin.card.caseNumber ?? row.caseNumber,
            caseID: row.caseID, caseUID: row.caseUID,
            essence: row.essence ?? anchor.essence,
            judge: row.judge ?? origin.card.judge,
            receiptDate: row.receiptDate ?? origin.card.receiptDate,
            decisionDate: row.decisionDate ?? origin.card.decisionDate,
            resultText: row.result ?? origin.card.result,
            legalForceDate: row.legalForceDate ?? origin.card.legalForceDate,
            cardURLString: cardURL?.absoluteString)
        ctx.judicialUID = Self.firstNonEmpty(origin.card.uid, anchorCard.uid, anchor.judicialUID)
        // `m` — самостоятельная карточка материала, а нижестоящий номер
        // апелляции не должен притворяться первой инстанцией.
        ctx.baseInstanceLevelRaw = MovementContext.instanceLevel(
            cartotekaID: origin.cartoteka.id, courtLevel: origin.court.level,
            judicialUID: ctx.judicialUID).rawValue
        ctx.sourceKnownCard = Self.knownCard(from: ctx)
        var known = anchor.knownCards ?? []
        if let source = anchor.sourceKnownCard ?? Self.knownCard(from: anchor) { known.append(source) }
        known.append(contentsOf: origin.intermediateCards.compactMap { intermediate in
            Self.knownCard(court: intermediate.court, cartoteka: intermediate.cartoteka,
                           result: intermediate.result, card: intermediate.card)
        })
        ctx.knownCards = Self.dedupKnown(known)
        ctx.higherCourtTargets = MovementTargetBuilder.targets(
            branch: origin.branch, courtLevel: origin.court.level,
            baseCartoteka: origin.cartoteka, caseNumber: ctx.caseNumber,
            judicialUID: ctx.judicialUID, courtTitle: origin.court.title,
            courtCode: origin.courtCode, region: origin.region,
            displayDomain: display,
            districtCourts: origin.districtAppealCourts.map { ($0.domain, $0.title) })
        return ctx
    }

    @discardableResult
    private func merge(survivor: TrackedCaseRecord, duplicates: [TrackedCaseRecord],
                       canonicalContext: MovementContext,
                       canonicalCard: CaseCard?) -> [String: String]? {
        let all = [survivor] + duplicates
        let oldKeys = all.map(\.key)
        var context = canonicalContext
        var known = context.knownCards ?? []
        for rec in all {
            guard let old = rec.context else { continue }
            known.append(contentsOf: old.knownCards ?? [])
            if old.key != context.key,
               let source = old.sourceKnownCard ?? Self.knownCard(from: old) { known.append(source) }
        }
        context.knownCards = Self.dedupKnown(known)

        // Каноническая карточка участвует в merge всегда. Иначе после
        // переякоривания старый кэш апелляции продолжает задавать заголовок и
        // скрывает уже загруженное движение первой инстанции/материала.
        var movements: [CaseMovement] = []
        if let card = canonicalCard {
            movements.append(Self.movement(from: card, context: context))
        }
        movements.append(contentsOf: all.compactMap {
            normalizedMovement($0.movement, context: $0.context)
        })
        let movement = Self.mergeMovements(movements)

        let collections = all.flatMap(\.collectionNames).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        survivor.collectionNames = collections
        survivor.addedAt = all.map(\.addedAt).min() ?? survivor.addedAt
        survivor.seenAt = all.contains(where: { $0.seenAt == nil })
            ? nil : all.compactMap(\.seenAt).max()
        survivor.key = context.key
        survivor.caseNumber = context.caseNumber
        survivor.courtTitle = context.courtTitle
        survivor.displayDomain = context.displayDomain
        survivor.context = context
        survivor.judicialUID = context.judicialUID.map(TrackedStore.normalizedUID)
        survivor.movement = movement.map(MovementCachePolicy.stripped(forPersist:))
        survivor.movementFetchedAt = nil
        if let movement {
            var snapshot = MovementDerivation.snapshot(from: movement, context: context)
            // Канонический survivor идёт первым в `all`, поэтому применяем
            // его подтверждённые сроки после дублей: они имеют приоритет.
            for old in all.compactMap(\.snapshot).reversed() {
                snapshot = MovementDerivation.preservingConfirmedDeadlines(snapshot, old: old)
            }
            survivor.snapshot = snapshot
        }
        for rec in duplicates { store.deleteWithoutSaving(rec) }
        guard store.save(rebuildProjection: true) else { return nil }
        return Dictionary(uniqueKeysWithValues: oldKeys.filter { $0 != survivor.key }
            .map { ($0, survivor.key) })
    }

    // MARK: Persistent retry policy

    private func shouldAttempt(key: String) -> Bool {
        let unsupported = Set(defaults.stringArray(forKey: unsupportedKey) ?? [])
        let completed = Set(defaults.stringArray(forKey: completedKey) ?? [])
        guard !unsupported.contains(key), !completed.contains(key) else { return false }
        let next = (defaults.dictionary(forKey: nextRetryKey) as? [String: Double])?[key] ?? 0
        return next <= now().timeIntervalSince1970
    }

    private func recordTransient(key: String) {
        var attempts = defaults.dictionary(forKey: attemptsKey) as? [String: Int] ?? [:]
        let attempt = min((attempts[key] ?? 0) + 1, 3)
        attempts[key] = attempt
        var next = defaults.dictionary(forKey: nextRetryKey) as? [String: Double] ?? [:]
        let delays: [TimeInterval] = [3_600, 21_600, 86_400]
        next[key] = now().addingTimeInterval(delays[attempt - 1]).timeIntervalSince1970
        defaults.set(attempts, forKey: attemptsKey)
        defaults.set(next, forKey: nextRetryKey)
    }

    private func clearRetry(key: String) {
        var attempts = defaults.dictionary(forKey: attemptsKey) as? [String: Int] ?? [:]
        var next = defaults.dictionary(forKey: nextRetryKey) as? [String: Double] ?? [:]
        attempts[key] = nil; next[key] = nil
        defaults.set(attempts, forKey: attemptsKey)
        defaults.set(next, forKey: nextRetryKey)
    }

    private func recordCompleted(key: String) {
        var completed = Set(defaults.stringArray(forKey: completedKey) ?? [])
        completed.insert(key)
        defaults.set(Array(completed), forKey: completedKey)
    }

    private func recordUnsupported(key: String) {
        var unsupported = Set(defaults.stringArray(forKey: unsupportedKey) ?? [])
        unsupported.insert(key)
        defaults.set(Array(unsupported), forKey: unsupportedKey)
    }

    private static func isPublishedKoAPReview(_ context: MovementContext) -> Bool {
        guard context.cartotekaId.hasPrefix("adm") else { return false }
        switch KoAPProceduralRole.resolve(
            courtLevel: context.courtLevel, cartotekaID: context.cartotekaId,
            judicialUID: context.judicialUID) {
        case .magistrateAppeal, .subjectReview, .finalActReview:
            return true
        default:
            return false
        }
    }

    private static func isTerminalCardReadError(_ error: SudrfError) -> Bool {
        if case .parsing = error { return true }
        if case .searchModuleUnavailable = error { return true }
        return false
    }

    private func normalizedMovement(_ movement: CaseMovement?, context: MovementContext?) -> CaseMovement? {
        guard var movement, let context else { return movement }
        for i in movement.instances.indices where
            SudrfHost.moduleHost(movement.instances[i].domain) == SudrfHost.moduleHost(context.searchDomain)
                && CaseOriginResolver.sameCaseNumber(movement.instances[i].caseNumber, context.caseNumber) {
            movement.instances[i].level = context.baseInstanceLevel
            if let actID = movement.instances[i].actID,
               let ai = movement.acts.firstIndex(where: { $0.id == actID }) {
                movement.acts[ai].instanceLevel = context.baseInstanceLevel
            }
        }
        return movement
    }

    static func mergeMovements(_ movements: [CaseMovement]) -> CaseMovement? {
        guard var out = movements.first else { return nil }
        for movement in movements.dropFirst() {
            for inst in movement.instances where !out.instances.contains(where: {
                SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(inst.domain)
                    && CaseOriginResolver.sameCaseNumber($0.caseNumber, inst.caseNumber)
            }) { out.instances.append(inst) }
            for act in movement.acts {
                if let existing = out.acts.first(where: {
                    canonicalActKey($0.id) == canonicalActKey(act.id)
                }) {
                    if out.actBodies[existing.id] == nil, let body = movement.actBodies[act.id] {
                        out.actBodies[existing.id] = body
                    }
                } else {
                    out.acts.append(act)
                    if let body = movement.actBodies[act.id] { out.actBodies[act.id] = body }
                }
            }
            if out.uid.isEmpty { out.uid = movement.uid }
            if out.category == nil { out.category = movement.category }
            if out.parties.isEmpty { out.parties = movement.parties }
            out.inForce = out.inForce || movement.inForce
        }
        out.instances.sort { MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1) }
        out.acts.sort { MovementService.actOrderKey($0) < MovementService.actOrderKey($1) }
        return out
    }

    static func movement(from card: CaseCard, context: MovementContext) -> CaseMovement {
        let level = context.baseInstanceLevel
        var acts: [CaseAct] = []
        var bodies: [String: String] = [:]
        var actID: String?
        if let body = card.actText {
            let id = "act_\(context.searchDomain)#\(context.caseNumber)"
            acts.append(CaseAct(id: id, title: card.acts.first?.label ?? "Судебный акт",
                                date: card.decisionDate ?? card.receiptDate ?? "—",
                                courtShort: context.courtTitle, instanceLevel: level))
            bodies[id] = body; actID = id
        }
        let inst = CaseInstance(level: level, court: context.courtTitle,
                                caseNumber: context.caseNumber, judge: card.judge,
                                domain: context.searchDomain, foundByUID: false,
                                result: card.result, sessions: card.sessions, actID: actID)
        return CaseMovement(uid: card.uid ?? context.judicialUID ?? "",
                            caseNumber: context.caseNumber,
                            inForce: card.legalForceDate != nil,
                            instances: [inst], complaints: [:], acts: acts,
                            actBodies: bodies, category: card.category, parties: card.parties)
    }

    static func knownCard(from ctx: MovementContext) -> KnownCard? {
        if let source = ctx.sourceKnownCard { return source }
        guard let url = ctx.cardURLString.flatMap(URL.init(string:)) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func uniqueValue(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }.compactMap(\.value)
            guard matches.count == 1 else { return nil }
            return matches[0]
        }
        guard let id = uniqueValue("case_id"), let guid = uniqueValue("case_uid") else {
            return nil
        }
        return KnownCard(domain: ctx.searchDomain, courtTitle: ctx.courtTitle,
                         caseID: id, caseUID: guid,
                         deloID: uniqueValue("delo_id") ?? ctx.cartoteka?.deloID ?? "",
                         new: uniqueValue("new") ?? ctx.cartoteka?.new ?? "0",
                         caseNumber: ctx.caseNumber,
                         levelRaw: ctx.baseInstanceLevel.rawValue,
                         cartotekaID: ctx.cartotekaId)
    }

    static func knownCard(court: Court, cartoteka: Cartoteka,
                          result: CaseSearchResult, card: CaseCard) -> KnownCard? {
        guard let id = result.caseID, let guid = result.caseUID else { return nil }
        return KnownCard(domain: court.domain, courtTitle: court.title,
                         caseID: id, caseUID: guid, deloID: cartoteka.deloID,
                         new: cartoteka.new, caseNumber: card.caseNumber ?? result.caseNumber,
                         levelRaw: MovementContext.instanceLevel(
                            cartotekaID: cartoteka.id, courtLevel: court.level,
                            judicialUID: card.uid).rawValue,
                         cartotekaID: cartoteka.id)
    }

    static func dedupKnown(_ cards: [KnownCard]) -> [KnownCard] {
        var seen = Set<String>()
        return cards.filter {
            seen.insert("\(SudrfHost.moduleHost($0.domain))|\($0.caseID)|\($0.caseUID)|\($0.deloID)|\($0.new)").inserted
        }
    }

    private static func canonicalActKey(_ id: String) -> String {
        guard id.hasPrefix("act_") else { return id }
        let raw = String(id.dropFirst(4))
        let parts = raw.split(separator: "#", maxSplits: 1).map(String.init)
        let host = SudrfHost.moduleHost(parts[0])
        return parts.count == 2 ? "\(host)#\(CartotekaRegistry.normalizedNumber(parts[1]))" : host
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }.first
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
