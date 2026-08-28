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
        return SourceCardObservation(
            cardIdentity: card,
            caseUID: nonEmpty(context.caseUID) ?? nonEmpty(known?.caseUID),
            caseNumber: nonEmpty(context.caseNumber),
            judicialUID: JudicialUIDObservation(
                rawValue: nonEmpty(movement?.uid) ?? nonEmpty(context.judicialUID),
                provenance: provenance),
            outcome: outcome,
            provenance: provenance)
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
        let provenance = record.sourceRefreshAttempt?.provenance ?? SourceProvenance(
            operation: .discovery, sourceFamily: family(for: context),
            host: context?.searchDomain ?? record.displayDomain,
            observedAt: record.movementFetchedAt ?? record.addedAt)
        let observation = observation(
            context: context, record: record, provenance: provenance)
        return LogicalCaseState(logicalCaseID: logicalCaseID, observation: observation)
    }

    static func persist(_ state: LogicalCaseState, to record: TrackedCaseRecord) {
        record.logicalCaseID = state.logicalCaseID
        record.identityStateData = try? JSONEncoder().encode(state)
    }

    static func bootstrapObservation(for record: TrackedCaseRecord) -> SourceCardObservation {
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
        let provenance = record.sourceRefreshAttempt?.provenance ?? SourceProvenance(
            operation: .discovery, sourceFamily: family(for: record.context),
            host: record.context?.searchDomain ?? record.displayDomain,
            observedAt: record.movementFetchedAt ?? record.addedAt)
        return observation(context: record.context, record: record, provenance: provenance)
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

    private static func family(for context: MovementContext?) -> String {
        guard let context else { return "legacy" }
        if MosGorSudRouting.isMosGorSud(domain: context.searchDomain) { return "mosgorsud" }
        return context.courtLevel == .magistrate ? "msudrf" : "sudrf"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
