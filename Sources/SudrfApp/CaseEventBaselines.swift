import Foundation
import CryptoKit
import SudrfKit

/// These are handled facts, not the display cache. A partial refresh may change
/// the latter without consuming a transition in the shadow journal (#262).
struct CaseEventCourtBaseline: Codable, Equatable, Sendable {
    var cards: [String: String]
    var sessions: [StoredSession]
    var instances: [StoredInstanceObservation]
    var acts: [StoredActObservation]
    var complaints: [StoredComplaintObservation]
    var actContentHashes: [String: String]?

    init(snapshot: CaseSnapshot, cards: [String: String], actBodies: [String: String] = [:]) {
        self.cards = cards
        let ids = Set(cards.values)
        sessions = snapshot.sessions.filter { $0.sourceCardID.map(ids.contains) == true }
        instances = (snapshot.instanceObservations ?? []).filter { $0.sourceCardID.map(ids.contains) == true }
        acts = (snapshot.actObservations ?? []).filter { $0.sourceCardID.map(ids.contains) == true }
        complaints = (snapshot.complaintObservations ?? []).filter { $0.sourceCardID.map(ids.contains) == true }
        let actIDs = Set(acts.map(\.sourceActID))
        actContentHashes = Dictionary(uniqueKeysWithValues: actBodies.compactMap { id, text in
            guard actIDs.contains(id) else { return nil }
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                  !body.isEmpty else { return nil }
            return (id, SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined())
        })
    }

    func snapshot(using template: CaseSnapshot) -> CaseSnapshot {
        var result = template
        result.semanticProjectionVersion = CaseEventJournal.currentDerivationVersion
        result.inForce = false
        result.deadlines = []
        result.sessions = sessions
        result.instanceObservations = instances
        result.actObservations = acts
        result.complaintObservations = complaints
        return result
    }

    /// An absent card is not a tombstone. Replace only cards actually loaded in
    /// this attempt; preserve observations for the other known productions.
    func replacingLoadedCards(with fresh: Self) -> Self {
        let oldIDs = Set(fresh.cards.keys.compactMap { cards[$0] })
            .union(fresh.cards.values)
        var result = self
        result.cards.merge(fresh.cards) { _, new in new }
        result.sessions = sessions.filter { !($0.sourceCardID.map(oldIDs.contains) ?? false) } + fresh.sessions
        result.instances = instances.filter { !($0.sourceCardID.map(oldIDs.contains) ?? false) } + fresh.instances
        result.acts = acts.filter { !($0.sourceCardID.map(oldIDs.contains) ?? false) } + fresh.acts
        result.complaints = complaints.filter { !($0.sourceCardID.map(oldIDs.contains) ?? false) } + fresh.complaints
        let retainedActIDs = Set(result.acts.map(\.sourceActID))
        result.actContentHashes = (actContentHashes ?? [:]).filter { retainedActIDs.contains($0.key) }
        result.actContentHashes?.merge(fresh.actContentHashes ?? [:]) { _, new in new }
        return result
    }

    func selecting(_ nativeCards: [String: String]) -> Self {
        var result = self
        result.cards = nativeCards
        let ids = Set(nativeCards.values)
        result.sessions = sessions.filter { $0.sourceCardID.map(ids.contains) == true }
        result.instances = instances.filter { $0.sourceCardID.map(ids.contains) == true }
        result.acts = acts.filter { $0.sourceCardID.map(ids.contains) == true }
        result.complaints = complaints.filter { $0.sourceCardID.map(ids.contains) == true }
        let actIDs = Set(result.acts.map(\.sourceActID))
        result.actContentHashes = actContentHashes?.filter { actIDs.contains($0.key) }
        return result
    }

    mutating func reidentifyActs(using fresh: Self) {
        for index in acts.indices {
            let old = acts[index]
            guard let hash = actContentHashes?[old.sourceActID] else { continue }
            let matches = fresh.acts.filter {
                $0.sourceCardID == old.sourceCardID && $0.title == old.title
                    && $0.dateRaw == old.dateRaw && $0.levelRaw == old.levelRaw
                    && fresh.actContentHashes?[$0.sourceActID] == hash
            }
            guard matches.count == 1, let newID = matches.first?.sourceActID else { continue }
            acts[index].sourceActID = newID
            actContentHashes?[newID] = hash
        }
    }

    /// Exact native locator continuity may change a projection's technical ID.
    /// Remap handled observations, never copy values from the display cache.
    func reidentified(using fresh: Self) -> Self {
        let mapping = Dictionary(uniqueKeysWithValues: cards.compactMap { native, old in
            fresh.cards[native].map { (old, $0) }
        })
        var result = self
        result.cards = cards.mapValues { mapping[$0] ?? $0 }
        result.sessions = sessions.map { var value = $0; value.sourceCardID = value.sourceCardID.map { mapping[$0] ?? $0 }; return value }
        result.instances = instances.map { var value = $0; value.sourceCardID = value.sourceCardID.map { mapping[$0] ?? $0 }; return value }
        result.acts = acts.map { var value = $0; value.sourceCardID = value.sourceCardID.map { mapping[$0] ?? $0 }; return value }
        result.complaints = complaints.map { var value = $0; value.sourceCardID = value.sourceCardID.map { mapping[$0] ?? $0 }; return value }
        return result
    }

    private static func sameFacts<T: Equatable>(_ left: [T], _ right: [T]) -> Bool {
        left.allSatisfy(right.contains) && right.allSatisfy(left.contains)
    }

    static func merged(_ values: [Self]) -> Self? {
        guard var result = values.first else { return nil }
        for value in values.dropFirst() {
            result = result.reidentified(using: value)
            let shared = Set(result.cards.keys).intersection(value.cards.keys)
            for native in shared {
                guard let left = result.cards[native], let right = value.cards[native], left == right,
                      sameFacts(result.sessions.filter { $0.sourceCardID == left }, value.sessions.filter { $0.sourceCardID == right }),
                      sameFacts(result.instances.filter { $0.sourceCardID == left }, value.instances.filter { $0.sourceCardID == right }),
                      sameFacts(result.acts.filter { $0.sourceCardID == left }, value.acts.filter { $0.sourceCardID == right }),
                      sameFacts(result.complaints.filter { $0.sourceCardID == left }, value.complaints.filter { $0.sourceCardID == right }) else { return nil }
            }
            for (id, hash) in result.actContentHashes ?? [:] {
                if let other = value.actContentHashes?[id], hash != other { return nil }
            }
            result = result.replacingLoadedCards(with: value)
            guard Set(result.cards.values).count == result.cards.count else { return nil }
        }
        return result
    }
}

struct CaseEventGlobalBaseline: Codable, Equatable, Sendable {
    var inForce: Bool
    var deadlines: [StoredDeadline]
}

struct CaseEventBaselines: Codable, Equatable, Sendable {
    var derivationVersion = CaseEventJournal.currentDerivationVersion
    var courts: [String: CaseEventCourtBaseline] = [:]
    var global: CaseEventGlobalBaseline?
    var conflictingCourts: Set<String> = []
    var globalConflict = false

    static func merged(_ values: [Self]) -> Self {
        var result = Self()
        let values = values.filter { $0.derivationVersion == CaseEventJournal.currentDerivationVersion }
        result.conflictingCourts = values.reduce(into: []) { $0.formUnion($1.conflictingCourts) }
        let keys = Set(values.flatMap { $0.courts.keys })
        for key in keys where !result.conflictingCourts.contains(key) {
            if let baseline = CaseEventCourtBaseline.merged(values.compactMap { $0.courts[key] }) {
                result.courts[key] = baseline
            } else { result.conflictingCourts.insert(key) }
        }
        let globals = values.compactMap(\.global)
        result.globalConflict = values.contains(where: \.globalConflict)
            || globals.contains { $0 != globals.first }
        if !result.globalConflict { result.global = globals.first }
        return result
    }
}

enum CaseEventBaselineTransition {
    static func refresh(journal: CaseEventJournal, freshSnapshot: CaseSnapshot,
                        globalSnapshot: CaseSnapshot,
                        admittedCourts: [String: [String: String]],
                        attempt: SourceAttempt, isComplete: Bool,
                        actBodies: [String: String] = [:],
                        nativeContinuities: [String: String] = [:])
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        var state = journal.semanticBaselines ?? CaseEventBaselines()
        var events: [CaseEvent] = []
        var diagnostics: [CaseEventDiagnosticReason] = []
        let usable = SourceAttempt(kind: .usableSnapshot, provenance: attempt.provenance)
        if journal.derivationVersion != CaseEventJournal.currentDerivationVersion
            || state.derivationVersion != CaseEventJournal.currentDerivationVersion {
            state = CaseEventBaselines()
            diagnostics.append(.derivationVersionChanged)
        }
        // A verified host repair may move the same card between court scopes.
        // Transfer handled facts only; a pending display change must still diff.
        for (priorNative, currentNative) in nativeContinuities.sorted(by: { $0.key < $1.key }) {
            let priorScopes = state.courts.keys.filter { state.courts[$0]?.cards[priorNative] != nil }
            let currentScopes = admittedCourts.keys.filter { admittedCourts[$0]?[currentNative] != nil }
            guard priorScopes.count == 1, currentScopes.count == 1,
                  let priorScope = priorScopes.first, let currentScope = currentScopes.first,
                  priorScope != currentScope, let prior = state.courts[priorScope],
                  let priorID = prior.cards[priorNative] else { continue }
            let fresh = CaseEventCourtBaseline(snapshot: freshSnapshot,
                cards: admittedCourts[currentScope] ?? [:], actBodies: actBodies)
            var moved = prior.selecting([priorNative: priorID])
            moved.cards = [currentNative: priorID]
            moved = moved.reidentified(using: fresh)
            moved.reidentifyActs(using: fresh)
            let combined: CaseEventCourtBaseline?
            if let target = state.courts[currentScope] {
                combined = CaseEventCourtBaseline.merged([target, moved])
            } else { combined = moved }
            state.courts[currentScope] = combined
            if combined == nil { state.conflictingCourts.insert(currentScope) }
            state.courts[priorScope] = prior.selecting(prior.cards.filter { $0.key != priorNative })
        }
        for scope in admittedCourts.keys.sorted() {
            let fresh = CaseEventCourtBaseline(snapshot: freshSnapshot, cards: admittedCourts[scope] ?? [:], actBodies: actBodies)
            let old = state.courts[scope]?.reidentified(using: fresh)
            let updated = old?.replacingLoadedCards(with: fresh) ?? fresh
            let result = CaseEventDeriver.derive(
                old: old?.snapshot(using: freshSnapshot),
                new: updated.snapshot(using: freshSnapshot), attempt: usable,
                observedAt: attempt.provenance.observedAt)
            events += result.events
            diagnostics += result.diagnostics
            state.courts[scope] = updated
            state.conflictingCourts.remove(scope)
        }
        if isComplete, !admittedCourts.isEmpty {
            var new = globalSnapshot
            // Court facts have already been compared independently. Keep equal
            // instance observations only to attribute the global force event.
            new.sessions = []
            new.actObservations = []
            new.complaintObservations = []
            var old = new
            if let prior = state.global {
                old.inForce = prior.inForce
                old.deadlines = prior.deadlines
            }
            let result = CaseEventDeriver.derive(
                old: state.global == nil ? nil : old, new: new, attempt: usable,
                observedAt: attempt.provenance.observedAt)
            events += result.events.filter { event in
                event.kind != .entryIntoForceRecorded
                    || !events.contains(where: { $0.kind == .entryIntoForceRecorded })
            }
            diagnostics += result.diagnostics
            state.global = CaseEventGlobalBaseline(inForce: new.inForce, deadlines: new.deadlines)
            state.globalConflict = false
        }
        if admittedCourts.isEmpty { diagnostics.append(.unusableSnapshot) }
        let savedState = journal.semanticBaselines == nil && state.courts.isEmpty && state.global == nil
            ? nil : state
        return (savedState, .init(events: events,
                            diagnostics: Array(Set(diagnostics)).sorted { $0.rawValue < $1.rawValue }))
    }

    /// A local user action confirms only the edited deadline. Other court and
    /// automatic deadline facts may still be waiting for a complete refresh.
    static func manualDeadline(journal: CaseEventJournal, before: CaseSnapshot,
                               after: CaseSnapshot, index: Int, observedAt: Date)
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        var old = before
        var new = old
        old.deadlines = [before.deadlines[index]]
        new.deadlines = [after.deadlines[index]]
        let result = CaseEventDeriver.derive(old: old, new: new, attempt: nil, observedAt: observedAt)
        var state = journal.semanticBaselines ?? CaseEventBaselines()
        if var global = state.global {
            let edited = after.deadlines[index]
            if let key = edited.occurrenceKey,
               let prior = global.deadlines.firstIndex(where: { $0.occurrenceKey == key }) {
                global.deadlines[prior] = edited
            } else if edited.occurrenceKey == nil,
                      let prior = global.deadlines.firstIndex(of: before.deadlines[index]) {
                global.deadlines[prior] = edited
            } else if !global.deadlines.contains(edited) {
                global.deadlines.append(edited)
            }
            state.global = global
        }
        return (journal.semanticBaselines == nil ? nil : state, result)
    }
}
