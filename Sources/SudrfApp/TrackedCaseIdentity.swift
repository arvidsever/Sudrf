import Foundation
import SudrfKit

/// Тонкий adapter между персистентным App-слоем и чистой domain-моделью
/// identity. URL и display-derived key намеренно не участвуют в source card
/// identity; `key` нужен здесь только как synthetic locator для старых строк,
/// где портал уже не оставил source-native ID.
enum TrackedCaseIdentity {
    static func observation(
        context: MovementContext,
        movement: CaseMovement? = nil,
        attempt: SourceAttempt? = nil,
        outcome: SourceOutcomeKind = .usableSnapshot,
        observedAt: Date = .now
    ) -> SourceCardObservation? {
        let known = context.sourceKnownCard
        let sourceNativeID = nonEmpty(context.caseID) ?? nonEmpty(known?.caseID)
        guard let sourceNativeID else { return nil }

        let sourceFamily = nonEmpty(attempt?.provenance.sourceFamily) ?? family(for: context)
        let host = nonEmpty(attempt?.provenance.host) ?? context.searchDomain
        let provenance = attempt?.provenance ?? SourceProvenance(
            operation: .discovery, sourceFamily: sourceFamily, host: host,
            observedAt: observedAt)
        let card = SourceNativeCardIdentity(
            sourceFamily: sourceFamily,
            courtKey: nonEmpty(context.courtCode)
                ?? SudrfHost.moduleHost(known?.domain ?? context.searchDomain),
            cartotekaKey: nonEmpty(known?.cartotekaID) ?? context.cartotekaId,
            sourceNativeID: sourceNativeID)
        let officialRelations = (predecessorRelation(
            context: context, movement: movement, sourceCard: card,
            sourceFamily: sourceFamily, outcome: outcome, provenance: provenance
        ).map { [$0] } ?? [])
            + reviewRelations(
                context: context, movement: movement, sourceCard: card,
                sourceFamily: sourceFamily,
                outcome: outcome, provenance: provenance,
                excludedHosts: attempt?.kind == .partial
                    ? Set((attempt?.provenance.affectedSources ?? []).map(canonicalHost))
                    : [])
        return SourceCardObservation(
            cardIdentity: card,
            caseUID: nonEmpty(context.caseUID) ?? nonEmpty(known?.caseUID),
            caseNumber: nonEmpty(context.caseNumber),
            judicialUID: JudicialUIDObservation(
                rawValue: nonEmpty(movement?.uid) ?? nonEmpty(context.judicialUID),
                provenance: provenance),
            officialRelations: officialRelations,
            outcome: outcome,
            provenance: provenance)
    }

    /// A partial chain may still contain review cards that were fetched in
    /// this attempt. Feed only those exact source relations to identity; the
    /// partial payload must not publish a new number or UID observation.
    static func partialRefreshObservation(
        context: MovementContext,
        movement: CaseMovement,
        attempt: SourceAttempt
    ) -> SourceCardObservation? {
        guard let base = observation(
            context: context, movement: movement, attempt: attempt,
            outcome: .usableSnapshot),
              base.officialRelations.contains(where: { $0.kind == .sourceNative }) else {
            return nil
        }
        return SourceCardObservation(
            cardIdentity: base.cardIdentity,
            officialRelations: base.officialRelations.filter { $0.kind == .sourceNative },
            outcome: .usableSnapshot,
            provenance: base.provenance)
    }

    /// Decodes the domain graph if possible, or rebuilds a conservative legacy
    /// graph from the persisted card context. The synthetic card cannot equal
    /// a real source card; a future live observation may still join it by a
    /// full valid judicial UID.
    static func state(for record: TrackedCaseRecord) -> LogicalCaseState {
        let logicalCaseID = ensuredLogicalCaseID(for: record)
        if let data = record.identityStateData,
           let decoded = try? JSONDecoder().decode(LogicalCaseState.self, from: data) {
            return decoded.logicalCaseID == logicalCaseID
                ? decoded : rebased(decoded, logicalCaseID: logicalCaseID)
        }

        let context = record.context
        let provenance = usableProvenance(for: record) ?? SourceProvenance(
            operation: .discovery, sourceFamily: family(for: context),
            host: context?.searchDomain ?? record.displayDomain,
            observedAt: record.movementFetchedAt ?? record.addedAt)
        let observation = observation(
            context: context, record: record, provenance: provenance)
        return LogicalCaseState(logicalCaseID: logicalCaseID, observation: observation)
    }

    static func persist(_ state: LogicalCaseState, to record: TrackedCaseRecord) {
        if record.logicalCaseID != state.logicalCaseID {
            record.logicalCaseID = state.logicalCaseID
        }
        if let data = record.identityStateData,
           let persisted = try? JSONDecoder().decode(LogicalCaseState.self, from: data),
           persisted == state { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        record.identityStateData = data
    }

    /// Returns the graph only when the V6 identity payload is complete enough
    /// to be trusted by the startup reconciliation pass. A missing,
    /// undecodable, rebased, or incomplete payload takes the normal repair path.
    static func persistedState(for record: TrackedCaseRecord) -> LogicalCaseState? {
        guard let logicalCaseID = record.logicalCaseID,
              let data = record.identityStateData,
              let state = try? JSONDecoder().decode(LogicalCaseState.self, from: data),
              state.logicalCaseID == logicalCaseID,
              !state.cards.isEmpty,
              state.cards.allSatisfy({ $0.identity.isComplete }),
              state.uidBindings.allSatisfy({ $0.cardIdentity.isComplete }) else {
            return nil
        }
        return state
    }

    static func bootstrapObservation(for record: TrackedCaseRecord) -> SourceCardObservation {
        let bootstrapProvenance = usableProvenance(for: record) ?? SourceProvenance(
            operation: .discovery, sourceFamily: family(for: record.context),
            host: record.context?.searchDomain ?? record.displayDomain,
            observedAt: record.movementFetchedAt ?? record.addedAt)
        if let context = record.context, let movement = record.movement,
           let observation = observation(
               context: context, movement: movement, outcome: .usableSnapshot,
               observedAt: bootstrapProvenance.observedAt) {
            return observation
        }
        let state = state(for: record)
        if let card = state.cards.sorted(by: { $0.id < $1.id }).first {
            let uid = state.uidBindings.first { $0.cardIdentity == card.identity }
            let provenance = uid?.provenance ?? card.provenance
            return SourceCardObservation(
                cardIdentity: card.identity,
                caseUID: card.caseUID,
                caseNumber: card.currentCaseNumber ?? record.caseNumber,
                judicialUID: JudicialUIDObservation(rawValue: uid?.rawValue,
                                                    provenance: provenance),
                outcome: .usableSnapshot,
                provenance: provenance)
        }
        return observation(context: record.context, record: record,
                           provenance: bootstrapProvenance)
    }

    static func ensuredLogicalCaseID(for record: TrackedCaseRecord) -> UUID {
        if let logicalCaseID = record.logicalCaseID { return logicalCaseID }
        let logicalCaseID = UUID()
        record.logicalCaseID = logicalCaseID
        return logicalCaseID
    }

    private static func observation(context: MovementContext?, record: TrackedCaseRecord,
                                    provenance: SourceProvenance) -> SourceCardObservation {
        if let context,
           let observation = observation(
               context: context, movement: record.movement,
               outcome: .usableSnapshot, observedAt: provenance.observedAt) {
            return observation
        }
        let card = SourceNativeCardIdentity(
            sourceFamily: "legacy",
            courtKey: nonEmpty(context?.courtCode)
                ?? SudrfHost.moduleHost(context?.searchDomain ?? record.displayDomain),
            cartotekaKey: nonEmpty(context?.cartotekaId) ?? "legacy",
            sourceNativeID: record.key)
        return SourceCardObservation(
            cardIdentity: card,
            caseUID: context?.caseUID,
            caseNumber: record.caseNumber,
            judicialUID: JudicialUIDObservation(
                rawValue: nonEmpty(context?.judicialUID)
                    ?? nonEmpty(record.movement?.uid)
                    ?? nonEmpty(record.judicialUID),
                provenance: provenance),
            outcome: .usableSnapshot,
            provenance: provenance)
    }

    private static func rebased(_ state: LogicalCaseState,
                                logicalCaseID: UUID) -> LogicalCaseState {
        LogicalCaseState(
            logicalCaseID: logicalCaseID,
            cards: state.cards,
            uidBindings: state.uidBindings,
            numberHistory: state.numberHistory,
            officialRelations: state.officialRelations,
            provenance: state.provenance)
    }

    /// A predecessor is authoritative only when it is tied to the exact source
    /// card being refreshed. The published display number deliberately does
    /// not participate in this identity edge.
    private static func predecessorRelation(
        context: MovementContext,
        movement: CaseMovement?,
        sourceCard: SourceNativeCardIdentity,
        sourceFamily: String,
        outcome: SourceOutcomeKind,
        provenance: SourceProvenance
    ) -> OfficialCardRelation? {
        // The Moscow portal has a separate, unconfirmed card-link contract.
        guard sourceFamily == "sudrf",
              !MosGorSudRouting.isMosGorSud(domain: context.searchDomain),
              let movement else { return nil }

        let matchingInstances = movement.instances.filter {
            sourceCardIdentity(for: $0.sourceURL, context: context,
                               sourceFamily: sourceFamily) == sourceCard
        }
        guard let reference = matchingInstances.first?.previousRegistration,
              !matchingInstances.isEmpty,
              matchingInstances.allSatisfy({ $0.previousRegistration == reference }),
              let predecessor = sourceCardIdentity(for: reference.url, context: context,
                                                   sourceFamily: sourceFamily),
              movement.instances.contains(where: { instance in
                  sourceCardIdentity(for: instance.sourceURL, context: context,
                                     sourceFamily: sourceFamily) == predecessor
                      && samePublishedCaseNumber(instance.caseNumber, reference.caseNumber)
              }) else {
            return nil
        }
        return OfficialCardRelation(
            kind: .predecessor, relatedCard: predecessor, outcome: outcome,
            provenance: provenance)
    }

    /// Exact review cards discovered through the source's UID route are
    /// authoritative links. Materials and failed/captcha placeholders remain
    /// separate dossiers even when they carry a superficially similar URL.
    private static func reviewRelations(
        context: MovementContext,
        movement: CaseMovement?,
        sourceCard: SourceNativeCardIdentity,
        sourceFamily: String,
        outcome: SourceOutcomeKind,
        provenance: SourceProvenance,
        excludedHosts: Set<String>
    ) -> [OfficialCardRelation] {
        guard sourceFamily == "sudrf", context.baseInstanceLevel != .material,
              let movement else { return [] }
        var seen = Set<SourceNativeCardIdentity>()
        return movement.instances.compactMap { instance in
            guard [.appeal, .cassation].contains(instance.level),
                  instance.foundByUID,
                  instance.captchaFormURL == nil,
                  instance.transientError != true,
                  !excludedHosts.contains(canonicalHost(instance.domain)),
                  let card = reviewCardIdentity(for: instance, context: context),
                  card != sourceCard,
                  seen.insert(card).inserted else { return nil }
            return OfficialCardRelation(
                kind: .sourceNative, relatedCard: card,
                outcome: outcome, provenance: provenance)
        }
    }

    private static func reviewCardIdentity(
        for instance: CaseInstance,
        context: MovementContext
    ) -> SourceNativeCardIdentity? {
        guard let url = instance.sourceURL,
              let link = try? SudrfCaseCardLink(url: url),
              let sourceNativeID = link.caseID,
              link.moduleHost == canonicalHost(instance.domain) else {
            return nil
        }
        let targetLevels = (context.higherCourtTargets ?? []).compactMap { target -> CourtLevel? in
            guard canonicalHost(target.domain) == link.moduleHost,
                  target.instanceLevel == nil || target.instanceLevel == instance.level else {
                return nil
            }
            return target.courtLevel
        }.reduce(into: [CourtLevel]()) { levels, level in
            if !levels.contains(level) { levels.append(level) }
        }
        let directoryLevel = CourtDirectory.court(forDomain: link.moduleHost)?.level
            ?? SudrfHost.alternate(link.moduleHost)
                .flatMap { CourtDirectory.court(forDomain: $0)?.level }
        if let directoryLevel, !targetLevels.isEmpty,
           targetLevels != [directoryLevel] { return nil }
        let levels = targetLevels.isEmpty ? directoryLevel.map { [$0] } ?? [] : targetLevels
        guard levels.count == 1, let level = levels.first else { return nil }
        guard let cartoteka = CartotekaRegistry.resolve(
            level: level, deloID: link.deloID, new: link.new,
            caseNumber: "") else { return nil }
        return SourceNativeCardIdentity(
            sourceFamily: "sudrf", courtKey: link.moduleHost,
            cartotekaKey: cartoteka.id, sourceNativeID: sourceNativeID)
    }

    /// Builds a source-native card identity directly from a published card URL.
    /// A relation is ignored when the link is ambiguous, points to another
    /// court, or cannot name a known cartoteka without looking at its number.
    private static func sourceCardIdentity(
        for url: URL?,
        context: MovementContext,
        sourceFamily: String
    ) -> SourceNativeCardIdentity? {
        guard let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let host = url.host else { return nil }

        let known = context.sourceKnownCard
        let expectedHost = SudrfHost.moduleHost(known?.domain ?? context.searchDomain)
        guard SudrfHost.moduleHost(host) == expectedHost else { return nil }

        let courtKey = nonEmpty(context.courtCode) ?? expectedHost
        if let linkedCourtCode = queryValue(named: ["vnkod"], in: url),
           let contextCourtCode = nonEmpty(context.courtCode),
           linkedCourtCode.caseInsensitiveCompare(contextCourtCode) != .orderedSame {
            return nil
        }

        guard let sourceNativeID = queryValue(named: ["case_id", "_id"], in: url),
              let deloID = queryValue(named: ["delo_id", "_deloId"], in: url),
              let cartoteka = CartotekaRegistry.resolve(
                  level: context.cartotekaLevel, deloID: deloID,
                  new: queryValue(named: ["new", "_new"], in: url),
                  caseNumber: "") else {
            return nil
        }

        return SourceNativeCardIdentity(
            sourceFamily: sourceFamily, courtKey: courtKey,
            cartotekaKey: cartoteka.id, sourceNativeID: sourceNativeID)
    }

    /// Repeated source parameters are safe only when they all say the same
    /// thing. This accepts sud_delo's duplicate `delo_id` spelling while
    /// declining conflicting links rather than guessing.
    private static func queryValue(named names: [String], in url: URL) -> String? {
        let values = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item -> String? in
                guard names.contains(where: {
                    item.name.caseInsensitiveCompare($0) == .orderedSame
                }) else { return nil }
                return nonEmpty(item.value)
            }
        guard let value = values.first, values.allSatisfy({ $0 == value }) else { return nil }
        return value
    }

    private static func samePublishedCaseNumber(_ lhs: String, _ rhs: String) -> Bool {
        func parts(_ value: String) -> [String] {
            value.components(separatedBy: "~").compactMap { part in
                let normalized = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "ё", with: "е")
                    .replacingOccurrences(of: "Ё", with: "Е")
                    .lowercased()
                return normalized.isEmpty ? nil : normalized
            }
        }
        return parts(lhs).contains { left in parts(rhs).contains(left) }
    }

    private static func family(for context: MovementContext?) -> String {
        guard let context else { return "legacy" }
        if MosGorSudRouting.isMosGorSud(domain: context.searchDomain) { return "mosgorsud" }
        return context.courtLevel == .magistrate ? "msudrf" : "sudrf"
    }

    private static func usableProvenance(for record: TrackedCaseRecord) -> SourceProvenance? {
        guard record.sourceRefreshAttempt?.kind == .usableSnapshot else { return nil }
        return record.sourceRefreshAttempt?.provenance
    }

    private static func canonicalHost(_ value: String) -> String {
        SudrfHost.moduleHost(value.lowercased())
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
