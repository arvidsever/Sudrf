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

/// Конкретный результат ремонта одной сохранённой карточки. `caseKey` остаётся
/// ключом карточки, с которой начался ремонт: импорт может сопоставить событие
/// со своей исходной строкой даже после merge в другой persistent key.
struct CaseRepairEvent: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case rerouted
        case reanchored
        case restoredMaterial
        case merged
        case firstInstanceNotFound
        case firstInstanceAmbiguous
        case transient
        case captcha
        case unsupportedCourt
        case cardParsing
    }

    let kind: Kind
    let caseKey: String
    let oldKey: String
    let newKey: String?
    let oldLocator: String
    let newLocator: String?
    let oldCaseNumber: String
    let newCaseNumber: String?
    let oldCourtTitle: String
    let newCourtTitle: String?
    let formURL: URL?

    var id: String {
        [kind.rawValue, caseKey, oldKey, newKey ?? "", oldLocator,
         newLocator ?? "", formURL?.absoluteString ?? ""].joined(separator: "|")
    }
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
    /// Ключи, чьи реквизиты/маршрут изменились без обязательной смены key.
    /// Потребители объединяют их со старыми и новыми ключами keyRemaps для
    /// точечного обновления projection и Spotlight.
    var affectedCaseKeys: Set<String> = []
    /// Отдельно от `unresolved`: captcha — действие пользователя, а не
    /// невозможность сопоставления карточки.
    var captchaRequests: [RepairCaptchaRequest] = []
    /// Детали нужны batch-потребителям; legacy `text` и `hasReport` сохраняют
    /// прежнюю семантику фонового глобального repair.
    var events: [CaseRepairEvent] = []

    var unresolvedEvents: [CaseRepairEvent] {
        events.filter {
            $0.kind == .firstInstanceNotFound
                || $0.kind == .firstInstanceAmbiguous
                || $0.kind == .unsupportedCourt
                || $0.kind == .cardParsing
        }
    }

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

    var hasProjectionChanges: Bool {
        !affectedCaseKeys.isEmpty || !keyRemaps.isEmpty
    }

    /// Отличает фактически сохранённую/показываемую часть прохода от ошибки,
    /// произошедшей до первого результата.
    var hasAnyResult: Bool {
        hasReport || hasProjectionChanges || !events.isEmpty
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

    /// Keeps an import report tied to its own persistent-key graph when it
    /// waits behind a global repair pass.
    func filtered(for keys: Set<String>) -> CaseRepairSummary {
        let related = Self.relatedKeys(startingWith: keys, remaps: keyRemaps)
        var filtered = CaseRepairSummary()
        filtered.keyRemaps = keyRemaps.filter {
            related.contains($0.key) || related.contains($0.value)
        }
        filtered.affectedCaseKeys = affectedCaseKeys.intersection(related)
        filtered.captchaRequests = captchaRequests.filter { related.contains($0.key) }
        filtered.events = events.filter { event in
            related.contains(event.caseKey) || related.contains(event.oldKey)
                || event.newKey.map { related.contains($0) } == true
        }
        for event in filtered.events {
            switch event.kind {
            case .merged:
                filtered.merged += 1
            case .reanchored:
                filtered.reanchored += 1
            case .restoredMaterial:
                filtered.restoredMaterials += 1
            case .rerouted:
                filtered.rerouted += 1
            case .firstInstanceNotFound, .unsupportedCourt, .cardParsing:
                filtered.notFound.append(event.newCaseNumber ?? event.oldCaseNumber)
            case .firstInstanceAmbiguous:
                filtered.ambiguous.append(event.newCaseNumber ?? event.oldCaseNumber)
            case .transient:
                filtered.transient += 1
            case .captcha:
                break
            }
        }
        filtered.merged = max(filtered.merged, filtered.keyRemaps.count)
        filtered.notFound = Self.unique(filtered.notFound)
        filtered.ambiguous = Self.unique(filtered.ambiguous)
        return filtered
    }

    var relatedCaseKeys: Set<String> {
        var keys = affectedCaseKeys
        keys.formUnion(keyRemaps.keys)
        keys.formUnion(keyRemaps.values)
        keys.formUnion(captchaRequests.map(\.key))
        for event in events {
            keys.insert(event.caseKey)
            keys.insert(event.oldKey)
            if let key = event.newKey { keys.insert(key) }
        }
        return keys
    }

    mutating func merge(_ other: CaseRepairSummary) {
        merged += other.merged
        reanchored += other.reanchored
        restoredMaterials += other.restoredMaterials
        rerouted += other.rerouted
        transient += other.transient
        notFound = Self.unique(notFound + other.notFound)
        ambiguous = Self.unique(ambiguous + other.ambiguous)
        keyRemaps.merge(other.keyRemaps) { _, new in new }
        affectedCaseKeys.formUnion(other.affectedCaseKeys)
        for request in other.captchaRequests where !captchaRequests.contains(request) {
            captchaRequests.append(request)
        }
        for event in other.events where !events.contains(event) {
            events.append(event)
        }
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

    private static func relatedKeys(startingWith keys: Set<String>, remaps: [String: String])
        -> Set<String> {
        var related = keys
        var changed = true
        while changed {
            changed = false
            for (old, new) in remaps where related.contains(old) || related.contains(new) {
                let count = related.count
                related.insert(old)
                related.insert(new)
                changed = changed || related.count != count
            }
        }
        return related
    }
}

/// Сохранённая часть repair не должна исчезать из импортного отчёта, если
/// следующая карточка того же batch не смогла завершить свой commit.
struct CaseRepairPartialError: Error, LocalizedError {
    let summary: CaseRepairSummary
    let underlying: Error

    var errorDescription: String? { underlying.localizedDescription }
}

/// Идемпотентный ремонт сохранённых цепочек. Все удаления выполняются только
/// после построения канонической записи и единым save на группу.
@MainActor
final class TrackedCaseRepairCoordinator {
    struct Outcome {
        var effectiveKey: String
        var summary: CaseRepairSummary
    }

    private struct ReconciledOrigin {
        let survivor: TrackedCaseRecord
        let remaps: [String: String]
        let previousContexts: [String: MovementContext]
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
    // v6 повторно прогоняет v5 и дополнительно пересаживает предварительные
    // `М-/9-` карточки на подтверждённое основное дело по точному УИД.
    private static let migrationID = "importChainRepair.v6"
    private var attemptsKey: String { "\(Self.migrationID).attempts" }
    private var nextRetryKey: String { "\(Self.migrationID).nextRetry" }
    private var unsupportedKey: String { "\(Self.migrationID).unsupported" }
    private var completedKey: String { "\(Self.migrationID).completed" }
    private var runningTask: Task<CaseRepairSummary, Error>?
    private var scopedTask: Task<CaseRepairSummary, Error>?

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

    func runAll() async throws -> CaseRepairSummary {
        if let runningTask { return try await runningTask.value }
        if let scopedTask {
            _ = try await scopedTask.value
            return try await runAll()
        }
        let task = Task { @MainActor [self] in
            defer { runningTask = nil }
            return try await runAllPass()
        }
        runningTask = task
        return try await task.value
    }

    /// Импортный batch не должен получить хвост общего startup repair: сначала
    /// завершаем уже идущий проход, затем ремонтируем только его persistent keys.
    func run(keys: Set<String>) async throws -> CaseRepairSummary {
        guard !keys.isEmpty else { return CaseRepairSummary() }
        var scopedKeys = keys
        var preceding = CaseRepairSummary()
        while true {
            if let runningTask {
                do {
                    let summary = try await runningTask.value.filtered(for: scopedKeys)
                    preceding.merge(summary)
                    scopedKeys.formUnion(summary.relatedCaseKeys)
                } catch let partial as CaseRepairPartialError {
                    preceding.merge(partial.summary.filtered(for: scopedKeys))
                    throw Self.partialError(partial.underlying, summary: preceding)
                } catch {
                    throw Self.partialError(error, summary: preceding)
                }
                continue
            }
            if let scopedTask {
                do {
                    let summary = try await scopedTask.value.filtered(for: scopedKeys)
                    preceding.merge(summary)
                    scopedKeys.formUnion(summary.relatedCaseKeys)
                } catch let partial as CaseRepairPartialError {
                    preceding.merge(partial.summary.filtered(for: scopedKeys))
                    throw Self.partialError(partial.underlying, summary: preceding)
                } catch {
                    throw Self.partialError(error, summary: preceding)
                }
                continue
            }
            break
        }
        let keysForPass = scopedKeys
        let task = Task { @MainActor [self] in
            defer { scopedTask = nil }
            return try await runScopedPass(keys: keysForPass)
        }
        scopedTask = task
        do {
            preceding.merge(try await task.value)
            return preceding
        } catch let partial as CaseRepairPartialError {
            preceding.merge(partial.summary)
            throw Self.partialError(partial.underlying, summary: preceding)
        } catch {
            throw Self.partialError(error, summary: preceding)
        }
    }

    /// Выполняет синхронную запись сразу после последней проверки простоя.
    /// Между этой проверкой и `operation` нет suspension point, поэтому новый
    /// repair не успеет начать запись в тот же `ModelContext`.
    func performWhenIdle<T>(_ operation: () throws -> T) async throws -> T {
        while true {
            if let runningTask {
                _ = try? await runningTask.value
                continue
            }
            if let scopedTask {
                _ = try? await scopedTask.value
                continue
            }
            return try operation()
        }
    }

    /// Ожидает текущие repair-задачи. Для записи используйте
    /// `performWhenIdle`, чтобы idle-проверка и commit оставались одним ходом.
    func waitUntilIdle() async {
        _ = try? await performWhenIdle {}
    }

    private func runAllPass() async throws -> CaseRepairSummary {
        var summary = CaseRepairSummary()
        do {
            let normalized = try normalizeStoredKoAPRoutes()
            summary.rerouted += normalized.count
            summary.affectedCaseKeys.formUnion(normalized.keys)
            summary.events.append(contentsOf: normalized.events)

            // Снимок ключей после локального слияния: сеть не должна работать с уже
            // удалёнными managed objects.
            let keys = try store.allForMutation().compactMap { rec -> String? in
                guard let ctx = rec.context, shouldRepair(ctx) else { return nil }
                return rec.key
            }
            for key in keys {
                guard !Task.isCancelled else { break }
                guard shouldAttempt(key: key) else { continue }
                try await repairHigherAnchor(key: key, summary: &summary)
            }
            summary.notFound = Self.unique(summary.notFound)
            summary.ambiguous = Self.unique(summary.ambiguous)
            return summary
        } catch {
            summary.notFound = Self.unique(summary.notFound)
            summary.ambiguous = Self.unique(summary.ambiguous)
            throw Self.partialError(error, summary: summary)
        }
    }

    private func runScopedPass(keys: Set<String>) async throws -> CaseRepairSummary {
        var summary = CaseRepairSummary()
        do {
            let normalized = try normalizeStoredKoAPRoutes(keys: keys)
            summary.rerouted += normalized.count
            summary.affectedCaseKeys.formUnion(normalized.keys)
            summary.events.append(contentsOf: normalized.events)

            // A preceding repair may merge and delete another requested record.
            // Keep only persistent keys here and let `repairHigherAnchor` refetch.
            let repairKeys = try store.allForMutation().compactMap { record -> String? in
                guard (keys.contains(record.key) || !Set(record.legacyKeyAliases).isDisjoint(with: keys)),
                      let context = record.context,
                      shouldRepair(context) else { return nil }
                return record.key
            }
            for key in repairKeys {
                guard !Task.isCancelled,
                      try store.recordForMutation(forKey: key) != nil,
                      shouldAttempt(key: key) else { continue }
                try await repairHigherAnchor(key: key, caseKey: key, summary: &summary)
            }
            summary.notFound = Self.unique(summary.notFound)
            summary.ambiguous = Self.unique(summary.ambiguous)
            return summary
        } catch {
            summary.notFound = Self.unique(summary.notFound)
            summary.ambiguous = Self.unique(summary.ambiguous)
            throw Self.partialError(error, summary: summary)
        }
    }

    private static func partialError(_ error: Error, summary: CaseRepairSummary) -> Error {
        guard summary.hasAnyResult else { return error }
        return CaseRepairPartialError(summary: summary,
                                      underlying: (error as? CaseRepairPartialError)?.underlying ?? error)
    }

    /// Точечный preflight для RefreshCenter. Общий reconciler гарантирует,
    /// что refresh продолжится уже по каноническому persistent locator.
    func repairIfNeeded(key: String) async throws -> Outcome {
        let summary = try await run(keys: [key])
        return Outcome(effectiveKey: summary.effectiveKey(for: key), summary: summary)
    }

    private func repairHigherAnchor(key: String, caseKey: String? = nil,
                                    summary: inout CaseRepairSummary,
                                    allowAutoSolve: Bool = true) async throws {
        guard let rec = try store.recordForMutation(forLocator: key),
              let anchorContext = rec.context else { return }
        let anchorKey = rec.key
        let eventKey = caseKey ?? anchorKey
        // Самостоятельный материал уже является корректным базовым якорем:
        // он участвует в локальном UID-слиянии, но не требует даже загрузки
        // карточки. Сетевой поиск нужен только 13/13а с проверяемым родителем.
        if anchorContext.baseInstanceLevel == .material,
           !Self.mayBecomeMainCase(anchorContext),
           !CaseIndexClassifier.requiresVerifiedParent(caseNumber: anchorContext.caseNumber,
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
                try store.synchronizeCourtActMetadata(caseKey: anchorKey)
                try store.save()
                summary.rerouted += 1
                summary.affectedCaseKeys.insert(anchorKey)
                appendEvent(.rerouted, caseKey: eventKey, oldKey: anchorKey,
                            old: anchorContext, newKey: anchorKey, new: effectiveContext,
                            summary: &summary)
            }
            if Self.mayBecomeMainCase(effectiveContext) {
                let origin = try await originResolver.resolveMainCase(
                    anchorContext: effectiveContext, anchorCard: anchorCard)
                var canonical = makeContext(origin: origin, anchor: effectiveContext,
                                            anchorCard: anchorCard)
                let primaryNumber = CaseNumberPresentation.primary(canonical.caseNumber)
                if !primaryNumber.isEmpty { canonical.caseNumber = primaryNumber }
                guard let result = try reconcileResolvedOrigin(
                    anchor: rec, canonicalContext: canonical,
                    canonicalCard: origin.card) else {
                    summary.transient += 1
                    recordTransient(key: key)
                    appendEvent(.transient, caseKey: eventKey, oldKey: anchorKey,
                                old: effectiveContext, summary: &summary)
                    return
                }
                clearRetry(key: key)
                summary.keyRemaps.merge(result.remaps) { _, new in new }
                summary.affectedCaseKeys.formUnion(result.remaps.keys)
                summary.affectedCaseKeys.formUnion(result.remaps.values)
                summary.affectedCaseKeys.insert(result.survivor.key)
                summary.reanchored += 1
                summary.merged += result.remaps.count
                appendResolvedEvents(result, kind: .reanchored, caseKey: eventKey,
                                     oldKey: anchorKey, old: effectiveContext,
                                     canonical: canonical, summary: &summary)
                return
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
                appendEvent(.unsupportedCourt, caseKey: eventKey, oldKey: anchorKey,
                            old: effectiveContext, summary: &summary)
                return
            }
            let origin = try await originResolver.resolve(anchorContext: effectiveContext,
                                                          anchorCard: anchorCard)
            let canonical = makeContext(origin: origin, anchor: effectiveContext,
                                        anchorCard: anchorCard)
            guard let result = try reconcileResolvedOrigin(
                anchor: rec, canonicalContext: canonical,
                canonicalCard: origin.card) else {
                summary.transient += 1
                recordTransient(key: key)
                appendEvent(.transient, caseKey: eventKey, oldKey: anchorKey,
                            old: effectiveContext, summary: &summary)
                return
            }
            clearRetry(key: key)
            summary.keyRemaps.merge(result.remaps) { _, new in new }
            summary.affectedCaseKeys.formUnion(result.remaps.keys)
            summary.affectedCaseKeys.formUnion(result.remaps.values)
            summary.affectedCaseKeys.insert(result.survivor.key)
            if canonical.baseInstanceLevel == .material {
                summary.restoredMaterials += 1
            } else {
                summary.reanchored += 1
            }
            summary.merged += result.remaps.count
            appendResolvedEvents(result,
                                 kind: canonical.baseInstanceLevel == .material
                                    ? .restoredMaterial : .reanchored,
                                 caseKey: eventKey, oldKey: anchorKey, old: effectiveContext,
                                 canonical: canonical, summary: &summary)
        } catch let error as TrackedStoreCommitError {
            // Rollback leaves both the record and retry/defaults state untouched.
            throw error
        } catch let error as CaseOriginResolutionError {
            switch error {
            case .noReference:
                // Корректная карточка пересмотра может не публиковать номер
                // нижестоящего дела (типичный случай — КоАП 12-*). Такой
                // результат не является ошибкой и не должен шуметь в отчёте.
                if Self.mayBecomeMainCase(anchorContext) { recordTransient(key: key) }
                else {
                    clearRetry(key: key)
                    recordCompleted(key: key)
                }
            case .ambiguous:
                summary.ambiguous.append(anchorContext.caseNumber)
                if Self.mayBecomeMainCase(anchorContext) { recordTransient(key: key) }
                appendEvent(.firstInstanceAmbiguous, caseKey: eventKey, oldKey: anchorKey,
                            old: anchorContext, summary: &summary)
            case .notFound:
                // Официальная ссылка может вести на карточку, которую сам
                // нижестоящий суд не опубликовал в открытой картотеке. После
                // исчерпывающего поиска по УИД и точному номеру это не ошибка
                // сопоставления: молча отложим новый поиск на потом.
                recordTransient(key: key)
                appendEvent(.firstInstanceNotFound, caseKey: eventKey, oldKey: anchorKey,
                            old: anchorContext, summary: &summary)
            case .unsupportedCourt:
                summary.notFound.append(anchorContext.caseNumber)
                appendEvent(.unsupportedCourt, caseKey: eventKey, oldKey: anchorKey,
                            old: anchorContext, summary: &summary)
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
                    if solved.cancelled || Task.isCancelled {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return
                    }
                    if let token = solved.token {
                        await CaptchaTokenStore.shared.store(
                            token, domain: formURL.host ?? anchorContext.searchDomain)
                        try await repairHigherAnchor(
                            key: key, caseKey: eventKey, summary: &summary, allowAutoSolve: false)
                        return
                    }
                }
                summary.captchaRequests.append(RepairCaptchaRequest(
                    key: key, caseNumber: anchorContext.caseNumber,
                    courtTitle: anchorContext.courtTitle, formURL: formURL))
                appendEvent(.captcha, caseKey: eventKey, oldKey: anchorKey,
                            old: anchorContext, formURL: formURL, summary: &summary)
            } else if Self.isTransientSourceError(error) {
                summary.transient += 1
                recordTransient(key: key)
                appendEvent(.transient, caseKey: eventKey, oldKey: anchorKey,
                            old: anchorContext, summary: &summary)
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
                let kind: CaseRepairEvent.Kind
                if case .parsing = error { kind = .cardParsing }
                else if case .searchModuleUnavailable = error { kind = .unsupportedCourt }
                else { kind = .firstInstanceNotFound }
                appendEvent(kind, caseKey: eventKey, oldKey: anchorKey,
                            old: anchorContext, summary: &summary)
            }
        } catch {
            summary.transient += 1
            recordTransient(key: key)
            appendEvent(.transient, caseKey: eventKey, oldKey: anchorKey,
                        old: anchorContext, summary: &summary)
        }
    }

    private func shouldRepair(_ context: MovementContext) -> Bool {
        if Self.mayBecomeMainCase(context) { return true }
        if context.baseInstanceLevel == .appeal || context.baseInstanceLevel == .cassation
            || context.baseInstanceLevel == .material {
            return true
        }
        return context.courtLevel == .district && context.cartotekaId == "admj"
            && KoAPProceduralRole.resolve(
                courtLevel: context.courtLevel, cartotekaID: context.cartotekaId,
                judicialUID: context.judicialUID) == .unknown
    }

    private static func mayBecomeMainCase(_ context: MovementContext) -> Bool {
        CaseIndexClassifier.classify(caseNumber: context.caseNumber,
                                    courtLevel: context.courtLevel,
                                    branch: context.branch)?.materialLinkPolicy == .mayBecomeMainCase
    }

    private func appendEvent(_ kind: CaseRepairEvent.Kind, caseKey: String,
                             oldKey: String, old: MovementContext,
                             newKey: String? = nil, new: MovementContext? = nil,
                             formURL: URL? = nil,
                             summary: inout CaseRepairSummary) {
        let new = new ?? old
        summary.events.append(CaseRepairEvent(
            kind: kind, caseKey: caseKey, oldKey: oldKey, newKey: newKey ?? oldKey,
            oldLocator: old.key, newLocator: new.key,
            oldCaseNumber: old.caseNumber, newCaseNumber: new.caseNumber,
            oldCourtTitle: old.courtTitle, newCourtTitle: new.courtTitle,
            formURL: formURL))
    }

    private func appendResolvedEvents(_ result: ReconciledOrigin,
                                      kind: CaseRepairEvent.Kind, caseKey: String,
                                      oldKey: String, old: MovementContext,
                                      canonical: MovementContext,
                                      summary: inout CaseRepairSummary) {
        let resolved = result.survivor.context ?? canonical
        appendEvent(kind, caseKey: caseKey, oldKey: oldKey, old: old,
                    newKey: result.survivor.key, new: resolved, summary: &summary)
        for (mergedKey, survivorKey) in result.remaps {
            guard let merged = result.previousContexts[mergedKey] else { continue }
            appendEvent(.merged, caseKey: caseKey, oldKey: mergedKey, old: merged,
                        newKey: survivorKey, new: resolved, summary: &summary)
        }
    }

    /// Исправляет сохранённые уровни и точные цели без сети. Записи admj без
    /// УИД остаются кандидатами сетевого прохода, где роль уточняется по карточке.
    private func normalizeStoredKoAPRoutes(keys: Set<String>? = nil)
        throws -> (count: Int, keys: Set<String>, events: [CaseRepairEvent]) {
        var changedKeys = Set<String>()
        var events: [CaseRepairEvent] = []
        let records = try store.allForMutation().filter { record in
            guard let keys else { return true }
            return keys.contains(record.key) || !Set(record.legacyKeyAliases).isDisjoint(with: keys)
        }
        for rec in records {
            guard let context = rec.context, context.cartotekaId.hasPrefix("adm") else { continue }
            let normalized = normalizedKoAPContext(context, card: nil)
            guard normalized.changed else { continue }
            rec.context = normalized.context
            if let uid = normalized.context.judicialUID, !uid.isEmpty {
                rec.judicialUID = TrackedStore.normalizedUID(uid)
            }
            rec.movementFetchedAt = nil
            try store.synchronizeCourtActMetadata(caseKey: rec.key)
            changedKeys.insert(rec.key)
            events.append(CaseRepairEvent(
                kind: .rerouted, caseKey: rec.key, oldKey: rec.key, newKey: rec.key,
                oldLocator: context.key, newLocator: normalized.context.key,
                oldCaseNumber: context.caseNumber, newCaseNumber: normalized.context.caseNumber,
                oldCourtTitle: context.courtTitle, newCourtTitle: normalized.context.courtTitle,
                formURL: nil))
        }
        if !changedKeys.isEmpty { try store.save() }
        return (changedKeys.count, changedKeys, events)
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

    /// A resolved lower/predecessor card is official source evidence, not a
    /// display-key heuristic. Feed it through the shared reconciler first;
    /// only its confirmed decision may merge persistent records or move the
    /// user-visible projection to the resolved card.
    private func reconcileResolvedOrigin(
        anchor: TrackedCaseRecord,
        canonicalContext: MovementContext,
        canonicalCard: CaseCard
    ) throws -> ReconciledOrigin? {
        let movement = Self.movement(from: canonicalCard, context: canonicalContext)
        guard let base = TrackedCaseIdentity.observation(
            context: canonicalContext, movement: movement, observedAt: now()) else {
            return nil
        }
        let anchorObservation = TrackedCaseIdentity.bootstrapObservation(for: anchor)
        let relation = OfficialCardRelation(
            kind: .sourceNative,
            relatedCard: anchorObservation.cardIdentity,
            provenance: base.provenance)
        let observation = SourceCardObservation(
            cardIdentity: base.cardIdentity,
            caseUID: base.caseUID,
            caseNumber: base.caseNumber,
            judicialUID: base.judicialUID,
            officialRelations: [relation],
            outcome: base.outcome,
            provenance: base.provenance)

        let recordsBefore = try store.allForMutation()
        let before = Set(recordsBefore.map(\.key))
        var previousContexts: [String: MovementContext] = [:]
        for record in recordsBefore {
            if let context = record.context { previousContexts[record.key] = context }
        }
        let survivor = try store.reconcileAndUpsert(
            context: canonicalContext,
            snapshot: MovementDerivation.snapshot(from: movement, context: canonicalContext),
            movement: movement,
            collections: anchor.collectionNames,
            identityObservation: observation,
            adoptLinkedPresentation: true,
            canonicalCard: canonicalCard)

        // A failed atomic save rolls the ModelContext back. Do not report the
        // repair as successful unless the resolved source card is actually in
        // the persisted graph.
        guard TrackedCaseIdentity.state(for: survivor)
            .contains(card: observation.cardIdentity) else { return nil }
        let removed = before.subtracting(Set(try store.allForMutation().map(\.key)))
        let remaps = Dictionary(uniqueKeysWithValues: removed.map { ($0, survivor.key) })
        return ReconciledOrigin(survivor: survivor, remaps: remaps,
                                previousContexts: previousContexts)
    }

    /// Единственное атомарное слияние persistent records. Его используют и
    /// legacy repair, и общий identity reconciler: движения, акты, подборки,
    /// aliases и весь graph identity переезжают в одном `ModelContext.save()`.
    static func atomicMerge(store: TrackedStore, survivor: TrackedCaseRecord,
                            duplicates: [TrackedCaseRecord],
                            canonicalContext: MovementContext,
                            canonicalCard: CaseCard?,
                            identityState: LogicalCaseState? = nil,
                            saveChanges: Bool = true) throws -> [String: String] {
        let all = [survivor] + duplicates
        let oldKeys = all.map(\.key)
        let oldLocators = all.flatMap { [$0.key] + $0.legacyKeyAliases }
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
            Self.normalizedMovement($0.movement, context: $0.context)
        })
        var movement = Self.mergeMovements(movements)
        if !Self.mayBecomeMainCase(context) {
            movement = Self.pruningPreliminaryAliases(movement, from: all)
        }

        let collections = all.flatMap(\.collectionNames).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        survivor.collectionNames = collections
        survivor.addedAt = all.map(\.addedAt).min() ?? survivor.addedAt
        survivor.seenAt = all.contains(where: { $0.seenAt == nil })
            ? nil : all.compactMap(\.seenAt).max()
        // `key` is a permanent technical locator since V6. The current
        // display-derived formula remains discoverable as an alias instead of
        // rotating deep links, Spotlight IDs and projected court acts.
        let locatorOwner = try store.recordForMutation(forLocator: context.key)
        let locatorBelongsToMerge = locatorOwner.map { owner in
            owner === survivor || duplicates.contains { $0 === owner }
        } ?? true
        if locatorBelongsToMerge { survivor.addLegacyKeyAlias(context.key) }
        for locator in oldLocators { survivor.addLegacyKeyAlias(locator) }
        survivor.caseNumber = context.caseNumber
        survivor.courtTitle = context.courtTitle
        survivor.displayDomain = context.displayDomain
        survivor.context = context
        survivor.judicialUID = context.judicialUID.map(TrackedStore.normalizedUID)
        var mergedIdentity = identityState ?? TrackedCaseIdentity.state(for: survivor)
        for duplicate in duplicates {
            mergedIdentity.merge(TrackedCaseIdentity.state(for: duplicate))
        }
        TrackedCaseIdentity.persist(mergedIdentity, to: survivor)
        survivor.movement = movement.map(MovementCachePolicy.stripped(forPersist:))
        let courtDocuments = movement?.executionDocuments
            ?? all.flatMap { $0.movement?.executionDocuments ?? [] }
        let enforcementRecords = all.flatMap(\.enforcementRecords).sorted {
            ($0.lastSuccessAt ?? $0.lastAttemptAt ?? .distantPast)
                < ($1.lastSuccessAt ?? $1.lastAttemptAt ?? .distantPast)
        }
        survivor.enforcementRecords = enforcementRecords.reduce(into: [EnforcementRecord]()) {
            records, record in
            records = TrackedStore.reconciledEnforcementRecords(
                existing: records, updates: [record], courtDocuments: courtDocuments)
        }
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
        try store.prepareCourtActsForReroute(from: oldKeys, to: survivor.key)
        if saveChanges {
            try store.save(projection: .cases(Set(oldKeys + [survivor.key])))
        }
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

    private static func isTransientSourceError(_ error: SudrfError) -> Bool {
        switch error {
        case .transientNetworkError, .sourceMaintenance, .caseCardTemporarilyUnavailable:
            return true
        case .http(let status):
            return (500..<600).contains(status)
        default:
            return false
        }
    }

    private static func normalizedMovement(_ movement: CaseMovement?, context: MovementContext?) -> CaseMovement? {
        guard var movement, let context else { return movement }
        for i in movement.instances.indices where
            SudrfHost.moduleHost(movement.instances[i].domain) == SudrfHost.moduleHost(context.searchDomain)
                && CaseOriginResolver.sameCaseNumber(movement.instances[i].caseNumber, context.caseNumber) {
            movement.instances[i].level = context.baseInstanceLevel
            for actID in movement.instances[i].linkedActIDs {
                if let ai = movement.acts.firstIndex(where: { $0.id == actID }) {
                    movement.acts[ai].instanceLevel = context.baseInstanceLevel
                }
            }
        }
        return movement
    }

    static func mergeMovements(_ movements: [CaseMovement]) -> CaseMovement? {
        guard var out = movements.first else { return nil }
        for movement in movements.dropFirst() {
            for inst in movement.instances {
                if let index = out.instances.firstIndex(where: {
                    SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(inst.domain)
                        && CaseOriginResolver.sameCaseNumber($0.caseNumber, inst.caseNumber)
                }) {
                    // Свежая canonicalCard может быть частичной. Обогащаем её
                    // последним успешным кэшем, не теряя заседания и акт.
                    out.instances[index].judge = out.instances[index].judge ?? inst.judge
                    out.instances[index].result = out.instances[index].result ?? inst.result
                    out.instances[index].actID = out.instances[index].actID ?? inst.actID
                    let linkedActIDs = unique(out.instances[index].linkedActIDs + inst.linkedActIDs)
                    out.instances[index].actIDs = linkedActIDs.isEmpty ? nil : linkedActIDs
                    var linkedActURLs = out.instances[index].linkedActURLs
                    for url in inst.linkedActURLs where !linkedActURLs.contains(url) {
                        linkedActURLs.append(url)
                    }
                    out.instances[index].actURLs = linkedActURLs.isEmpty ? nil : linkedActURLs
                    out.instances[index].captchaFormURL = out.instances[index].captchaFormURL
                        ?? inst.captchaFormURL
                    out.instances[index].transientError = out.instances[index].transientError
                        ?? inst.transientError
                    out.instances[index].note = out.instances[index].note ?? inst.note
                    out.instances[index].actURL = out.instances[index].actURL ?? inst.actURL
                    out.instances[index].sourceURL = out.instances[index].sourceURL ?? inst.sourceURL
                    out.instances[index].foundByUID = out.instances[index].foundByUID
                        && inst.foundByUID
                    for session in inst.sessions
                        where !out.instances[index].sessions.contains(session) {
                        out.instances[index].sessions.append(session)
                    }
                } else {
                    out.instances.append(inst)
                }
            }
            for act in movement.acts {
                if let existingIndex = out.acts.firstIndex(where: {
                    canonicalActKey($0.id) == canonicalActKey(act.id)
                }) {
                    let existing = out.acts[existingIndex]
                    if out.actBodies[existing.id] == nil, let body = movement.actBodies[act.id] {
                        out.actBodies[existing.id] = body
                    }
                    if out.acts[existingIndex].fileProvenance == nil {
                        out.acts[existingIndex].fileProvenance = act.fileProvenance
                    }
                } else {
                    out.acts.append(act)
                    if let body = movement.actBodies[act.id] { out.actBodies[act.id] = body }
                }
            }
            if out.uid.isEmpty { out.uid = movement.uid }
            if out.category == nil { out.category = movement.category }
            if out.parties.isEmpty { out.parties = movement.parties }
            var documents = out.executionDocuments ?? []
            for document in movement.executionDocuments ?? [] where !documents.contains(where: { $0.id == document.id }) {
                documents.append(document)
            }
            out.executionDocuments = documents.isEmpty ? nil : documents
            out.inForce = out.inForce || movement.inForce
        }
        out.instances.sort { MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1) }
        out.acts.sort { MovementService.actOrderKey($0) < MovementService.actOrderKey($1) }
        return out
    }

    /// После подтверждённого перехода `М-/9- → основное дело` предварительная
    /// карточка не является самостоятельным кругом движения и не должна
    /// оставлять свой акт в проекции.
    private static func pruningPreliminaryAliases(_ movement: CaseMovement?,
                                                   from records: [TrackedCaseRecord]) -> CaseMovement? {
        guard var movement else { return nil }
        let aliases = records.compactMap { record -> (String, String)? in
            guard let context = record.context,
                  CaseIndexClassifier.classify(caseNumber: context.caseNumber,
                                               courtLevel: context.courtLevel,
                                               branch: context.branch)?.materialLinkPolicy == .mayBecomeMainCase
            else { return nil }
            return (SudrfHost.moduleHost(context.searchDomain), context.caseNumber)
        }
        guard !aliases.isEmpty else { return movement }
        let removedActIDs = Set(movement.instances.flatMap { instance -> [String] in
            aliases.contains { host, number in
                SudrfHost.moduleHost(instance.domain) == host
                    && CaseOriginResolver.sameCaseNumber(instance.caseNumber, number)
            } ? instance.linkedActIDs : []
        })
        movement.instances.removeAll { instance in
            aliases.contains { host, number in
                SudrfHost.moduleHost(instance.domain) == host
                    && CaseOriginResolver.sameCaseNumber(instance.caseNumber, number)
            }
        }
        // Базовые карточки одного суда исторически используют общий
        // `act_<domain>`. Поэтому удалённая предварительная инстанция может
        // ссылаться на тот же акт, что и оставшаяся основная. Удаляем только
        // действительно осиротевшие акты, сравнивая также alternate/module host.
        let retainedActKeys = Set(movement.instances.flatMap(\.linkedActIDs).map(canonicalActKey))
        let orphanedActKeys = Set(removedActIDs.map(canonicalActKey))
            .subtracting(retainedActKeys)
        let orphanedActIDs = movement.acts.compactMap { act in
            orphanedActKeys.contains(canonicalActKey(act.id)) ? act.id : nil
        }
        movement.acts.removeAll { orphanedActKeys.contains(canonicalActKey($0.id)) }
        for id in Set(orphanedActIDs).union(removedActIDs.filter {
            orphanedActKeys.contains(canonicalActKey($0))
        }) {
            movement.actBodies[id] = nil
        }
        return movement
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
                                result: card.result, sessions: card.sessions, actID: actID,
                                sourceURL: context.cardURLString.flatMap(URL.init(string:)))
        return CaseMovement(uid: card.uid ?? context.judicialUID ?? "",
                            caseNumber: context.caseNumber,
                            inForce: card.legalForceDate != nil,
                            instances: [inst], complaints: [:], acts: acts,
                            actBodies: bodies, category: card.category, parties: card.parties,
                            executionDocuments: card.executionDocuments.isEmpty
                                ? nil : card.executionDocuments)
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
