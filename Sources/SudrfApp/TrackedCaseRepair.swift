import Foundation
import SudrfKit

struct CaseRepairSummary: Equatable {
    var merged = 0
    var reanchored = 0
    var unresolved: [String] = []
    var transient = 0
    var keyRemaps: [String: String] = [:]

    var hasReport: Bool { merged > 0 || reanchored > 0 || !unresolved.isEmpty || transient > 0 }

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
        if transient > 0 { lines.append("Временно недоступно, будет повторено: \(transient).") }
        if !unresolved.isEmpty {
            lines.append("Не удалось однозначно связать: \(unresolved.count).")
            lines.append(contentsOf: unresolved.prefix(12).map { "• \($0)" })
        }
        return lines.joined(separator: "\n")
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
    private let originResolver: any CaseOriginResolving
    private let anchorCardFetcher: (MovementContext) async throws -> CaseCard
    private let defaults: UserDefaults
    private let now: () -> Date
    private static let migrationID = "importChainRepair.v1"
    private var attemptsKey: String { "\(Self.migrationID).attempts" }
    private var nextRetryKey: String { "\(Self.migrationID).nextRetry" }
    private var unsupportedKey: String { "\(Self.migrationID).unsupported" }
    private var runningTask: Task<CaseRepairSummary, Never>?

    init(store: TrackedStore, client: SudrfClient, originResolver: any CaseOriginResolving,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         anchorCardFetcher: ((MovementContext) async throws -> CaseCard)? = nil) {
        self.store = store; self.originResolver = originResolver
        self.defaults = defaults; self.now = now
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
        mergeKnownUIDDuplicates(into: &summary)

        // Снимок ключей после локального слияния: сеть не должна работать с уже
        // удалёнными managed objects.
        let keys = store.all().compactMap { rec -> String? in
            guard let ctx = rec.context,
                  ctx.baseInstanceLevel == .appeal || ctx.baseInstanceLevel == .cassation else { return nil }
            return rec.key
        }
        for key in keys {
            guard shouldAttempt(key: key) else { continue }
            await repairHigherAnchor(key: key, summary: &summary)
        }
        summary.unresolved = Self.unique(summary.unresolved)
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
        mergeKnownUIDDuplicates(into: &summary)
        let localKey = summary.effectiveKey(for: key)
        guard let rec = store.record(forKey: localKey),
              let ctx = rec.context,
              ctx.baseInstanceLevel == .appeal || ctx.baseInstanceLevel == .cassation,
              shouldAttempt(key: localKey) else {
            return Outcome(effectiveKey: localKey, summary: summary)
        }
        await repairHigherAnchor(key: localKey, summary: &summary)
        return Outcome(effectiveKey: summary.effectiveKey(for: key), summary: summary)
    }

    private func repairHigherAnchor(key: String, summary: inout CaseRepairSummary) async {
        guard let rec = store.record(forKey: key), let anchorContext = rec.context else { return }
        do {
            let anchorCard = try await fetchAnchorCard(anchorContext)
            let origin = try await originResolver.resolve(anchorContext: anchorContext,
                                                          anchorCard: anchorCard)
            let canonical = makeContext(origin: origin, anchor: anchorContext,
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
            summary.reanchored += 1
            summary.merged += duplicates.count
        } catch let error as CaseOriginResolutionError {
            summary.unresolved.append(anchorContext.caseNumber)
            if error == .noReference || error == .unsupportedCourt {
                recordUnsupported(key: key)
            }
        } catch let error as SudrfError {
            if case .transientNetworkError = error {
                summary.transient += 1
                recordTransient(key: key)
            } else {
                summary.unresolved.append(anchorContext.caseNumber)
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
        case .appeal: return 1
        case .cassation: return 2
        case .material: return 3
        default: return 4
        }
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
        ctx.judicialUID = origin.card.uid ?? anchorCard.uid ?? anchor.judicialUID
        ctx.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        ctx.sourceKnownCard = Self.knownCard(from: ctx)
        var known = anchor.knownCards ?? []
        if let source = anchor.sourceKnownCard ?? Self.knownCard(from: anchor) { known.append(source) }
        ctx.knownCards = Self.dedupKnown(known)
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

        let movements = all.compactMap { normalizedMovement($0.movement, context: $0.context) }
        var movement = Self.mergeMovements(movements)
        if movement == nil, let card = canonicalCard {
            movement = Self.movement(from: card, context: context)
        }

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
        guard store.save() else { return nil }
        return Dictionary(uniqueKeysWithValues: oldKeys.filter { $0 != survivor.key }
            .map { ($0, survivor.key) })
    }

    // MARK: Persistent retry policy

    private func shouldAttempt(key: String) -> Bool {
        let unsupported = Set(defaults.stringArray(forKey: unsupportedKey) ?? [])
        guard !unsupported.contains(key) else { return false }
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

    private func recordUnsupported(key: String) {
        var unsupported = Set(defaults.stringArray(forKey: unsupportedKey) ?? [])
        unsupported.insert(key)
        defaults.set(Array(unsupported), forKey: unsupportedKey)
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
        let params = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard let id = params["case_id"], let guid = params["case_uid"] else { return nil }
        return KnownCard(domain: ctx.searchDomain, courtTitle: ctx.courtTitle,
                         caseID: id, caseUID: guid,
                         deloID: params["delo_id"] ?? ctx.cartoteka?.deloID ?? "",
                         new: params["new"] ?? ctx.cartoteka?.new ?? "0",
                         caseNumber: ctx.caseNumber,
                         levelRaw: ctx.baseInstanceLevel.rawValue,
                         cartotekaID: ctx.cartotekaId)
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

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
