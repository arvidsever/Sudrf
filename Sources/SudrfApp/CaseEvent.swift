import CryptoKit
import Foundation
import SudrfKit

/// Shadow-only semantic vocabulary. User-facing feed projections deliberately
/// continue to use their existing model until #179.
enum CaseEventKind: String, Codable, CaseIterable, Sendable {
    case instanceDiscovered
    case hearingScheduled
    case hearingPostponed
    case hearingRescheduled
    case judgeChanged
    case resultChanged
    case judicialActPublished
    case entryIntoForceRecorded
    case complaintRegistered
    case transferRegistered
    case deadlineProposed
    case deadlineConfirmed
    case deadlineChanged
    case deadlineExpired
    case deadlineSuperseded
}

struct CaseEventEvidence: Codable, Equatable, Sendable {
    var sourceCardID: String? = nil
    var instanceLevelRaw: String? = nil
    var caseNumber: String? = nil
    var dateRaw: String? = nil
    var time: String? = nil
    var previousDateRaw: String? = nil
    var previousTime: String? = nil
    var event: String? = nil
    var previousValue: String? = nil
    var value: String? = nil
    var ruleID: String? = nil
    var occurrenceKey: String? = nil
    var relatedOccurrenceKey: String? = nil
}

struct CaseEvent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: CaseEventKind
    let observedAtRef: Double
    let evidence: CaseEventEvidence

    static func make(kind: CaseEventKind, occurrence: [String], observedAt: Date,
                     evidence: CaseEventEvidence) -> CaseEvent {
        let components = ["case-event-v1", kind.rawValue] + occurrence
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined()
        let id = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CaseEvent(id: id, kind: kind,
                         observedAtRef: observedAt.timeIntervalSinceReferenceDate,
                         evidence: evidence)
    }
}

enum CaseEventJournalError: Error, Equatable {
    case conflictingEventID(String)
}

struct CaseEventJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentDerivationVersion = 1

    var schemaVersion: Int
    var derivationVersion: Int
    var events: [CaseEvent]

    init(schemaVersion: Int = Self.currentSchemaVersion,
         derivationVersion: Int = Self.currentDerivationVersion,
         events: [CaseEvent] = []) {
        self.schemaVersion = schemaVersion
        self.derivationVersion = derivationVersion
        self.events = events
    }

    mutating func append(_ additions: [CaseEvent]) throws {
        var byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for event in additions {
            if let prior = byID[event.id] {
                guard prior == event else {
                    throw CaseEventJournalError.conflictingEventID(event.id)
                }
                continue
            }
            events.append(event)
            byID[event.id] = event
        }
    }

    static func merged(_ journals: [CaseEventJournal]) throws -> CaseEventJournal {
        var merged = CaseEventJournal()
        for journal in journals {
            try merged.append(journal.events)
        }
        return merged
    }
}

enum CaseEventDiagnosticReason: String, Codable, Equatable, Sendable {
    case baseline
    case derivationVersionChanged
    case unusableSnapshot
    case missingSourceIdentity
    case ambiguousHearingRewrite
}

struct CaseEventDerivationResult: Equatable, Sendable {
    var events: [CaseEvent]
    var diagnostics: [CaseEventDiagnosticReason]
}

struct StoredInstanceObservation: Codable, Equatable, Sendable {
    var sourceCardID: String?
    var levelRaw: String
    var court: String
    var caseNumber: String
    var judge: String?
    var result: String?
}

struct StoredActObservation: Codable, Equatable, Sendable {
    var sourceCardID: String?
    var sourceActID: String
    var title: String
    var dateRaw: String
    var court: String
    var levelRaw: String
}

struct StoredComplaintObservation: Codable, Equatable, Sendable {
    var sourceCardID: String?
    var sourceComplaintID: String
    var label: String
    var court: String
    var caseNumber: String
}

enum CaseEventDeriver {
    /// Identity reconciliation can collapse several records during the same
    /// refresh. Compare the final survivor with the union of facts that were
    /// already present anywhere in that merge group, so the merge itself can
    /// never masquerade as a newly discovered court event.
    static func conservativeBaseline(_ snapshots: [CaseSnapshot],
                                     comparedTo latest: CaseSnapshot) -> CaseSnapshot? {
        guard var result = snapshots.first else { return nil }
        result.semanticProjectionVersion = snapshots.allSatisfy {
            $0.semanticProjectionVersion == CaseEventJournal.currentDerivationVersion
        } ? CaseEventJournal.currentDerivationVersion : nil
        if snapshots.contains(where: { $0.inForce == latest.inForce }) {
            result.inForce = latest.inForce
        }
        result.sessions = deduplicated(snapshots.flatMap(\.sessions))
        result.instanceObservations = mergedInstances(
            snapshots.flatMap { $0.instanceObservations ?? [] },
            latest: latest.instanceObservations ?? [])
        result.actObservations = mergedByID(
            snapshots.flatMap { $0.actObservations ?? [] },
            latest: latest.actObservations ?? [], id: \.sourceActID)
        result.complaintObservations = mergedByID(
            snapshots.flatMap { $0.complaintObservations ?? [] },
            latest: latest.complaintObservations ?? [], id: \.sourceComplaintID)
        result.deadlines = mergedByID(
            snapshots.flatMap(\.deadlines), latest: latest.deadlines,
            id: { $0.occurrenceKey ?? "legacy:\($0.kind):\($0.dateRef)" })
        return result
    }

    static func derive(old: CaseSnapshot?, new: CaseSnapshot,
                       attempt: SourceAttempt?, observedAt: Date) -> CaseEventDerivationResult {
        if let attempt, attempt.kind != .usableSnapshot {
            return .init(events: [], diagnostics: [.unusableSnapshot])
        }
        guard let old else {
            return .init(events: [], diagnostics: [.baseline])
        }
        guard old.semanticProjectionVersion == CaseEventJournal.currentDerivationVersion,
              new.semanticProjectionVersion == CaseEventJournal.currentDerivationVersion else {
            if attempt == nil {
                var events: [CaseEvent] = []
                var diagnostics: [CaseEventDiagnosticReason] = [.derivationVersionChanged]
                deriveDeadlines(old: old.deadlines, new: new.deadlines,
                                observedAt: observedAt, events: &events,
                                diagnostics: &diagnostics)
                return .init(events: unique(events.sorted(by: eventOrder)),
                             diagnostics: Array(Set(diagnostics)).sorted {
                                 $0.rawValue < $1.rawValue
                             })
            }
            return .init(events: [], diagnostics: [.derivationVersionChanged])
        }

        var events: [CaseEvent] = []
        var diagnostics: [CaseEventDiagnosticReason] = []
        let oldInstances = keyed(old.instanceObservations ?? [])
        let newInstances = keyed(new.instanceObservations ?? [])

        for key in newInstances.keys.sorted() where oldInstances[key] == nil {
            guard let value = newInstances[key], let source = value.sourceCardID else {
                diagnostics.append(.missingSourceIdentity); continue
            }
            events.append(make(.instanceDiscovered, source: source,
                               occurrence: [source], observedAt: observedAt,
                               evidence: instanceEvidence(value)))
        }

        for key in Set(oldInstances.keys).intersection(newInstances.keys).sorted() {
            guard let before = oldInstances[key], let after = newInstances[key],
                  let source = after.sourceCardID else { continue }
            if normalized(before.judge) != normalized(after.judge),
               !normalized(after.judge).isEmpty {
                var evidence = instanceEvidence(after)
                evidence.previousValue = before.judge
                evidence.value = after.judge
                events.append(make(.judgeChanged, source: source,
                                   occurrence: [source, normalized(after.judge)],
                                   observedAt: observedAt, evidence: evidence))
            }
            if let beforeDisposition = CaseLifecycleResolver.semanticDisposition(
                result: before.result),
               let afterDisposition = CaseLifecycleResolver.semanticDisposition(
                result: after.result),
               beforeDisposition != afterDisposition {
                var evidence = instanceEvidence(after)
                evidence.previousValue = before.result
                evidence.value = after.result
                events.append(make(.resultChanged, source: source,
                                   occurrence: [source, beforeDisposition, afterDisposition],
                                   observedAt: observedAt, evidence: evidence))
            }
            if !CaseLifecycleResolver.hasLegalForceEvidence(event: "", result: before.result),
               CaseLifecycleResolver.hasLegalForceEvidence(event: "", result: after.result) {
                events.append(make(.entryIntoForceRecorded, source: source,
                                   occurrence: [source, "legal-force"], observedAt: observedAt,
                                   evidence: instanceEvidence(after)))
            }
            if CaseLifecycleResolver.semanticDisposition(result: before.result)?.hasPrefix(
                "remand:") != true,
               CaseLifecycleResolver.semanticDisposition(result: after.result)?.hasPrefix(
                "remand:") == true {
                events.append(make(.transferRegistered, source: source,
                                   occurrence: [source, normalized(after.result)],
                                   observedAt: observedAt,
                                   evidence: instanceEvidence(after)))
            }
        }

        if !old.inForce, new.inForce,
           !events.contains(where: { $0.kind == .entryIntoForceRecorded }),
           let observation = (new.instanceObservations ?? []).first(where: {
               $0.sourceCardID != nil
           }), let source = observation.sourceCardID {
            events.append(make(.entryIntoForceRecorded, source: source,
                               occurrence: [source, "snapshot-in-force"],
                               observedAt: observedAt,
                               evidence: instanceEvidence(observation)))
        }

        deriveHearings(old: old.sessions, new: new.sessions, observedAt: observedAt,
                       events: &events, diagnostics: &diagnostics)
        deriveActs(old: old.actObservations ?? [], new: new.actObservations ?? [],
                   observedAt: observedAt, events: &events, diagnostics: &diagnostics)
        deriveComplaints(old: old.complaintObservations ?? [],
                         new: new.complaintObservations ?? [], observedAt: observedAt,
                         events: &events, diagnostics: &diagnostics)
        deriveDeadlines(old: old.deadlines, new: new.deadlines,
                        observedAt: observedAt, events: &events,
                        diagnostics: &diagnostics)

        let uniqueDiagnostics = Array(Set(diagnostics)).sorted { $0.rawValue < $1.rawValue }
        return .init(events: unique(events.sorted(by: eventOrder)),
                     diagnostics: uniqueDiagnostics)
    }

    private static func deriveHearings(old: [StoredSession], new: [StoredSession],
                                       observedAt: Date, events: inout [CaseEvent],
                                       diagnostics: inout [CaseEventDiagnosticReason]) {
        let oldHearings = old.filter { CaseLifecycleResolver.isHearingEvent(event: $0.event) }
        let newHearings = new.filter { CaseLifecycleResolver.isHearingEvent(event: $0.event) }
        var matchedNew = Set<Int>()
        var postponed: [(StoredSession, StoredSession)] = []
        var ambiguousSources = Set<String>()

        for before in oldHearings {
            let exact = newHearings.indices.filter {
                sameHearingOccurrence(before, newHearings[$0])
            }
            if exact.count == 1 {
                matchedNew.insert(exact[0])
                let after = newHearings[exact[0]]
                if !isPostponed(before), isPostponed(after) { postponed.append((before, after)) }
                continue
            }
            let sameShape = newHearings.indices.filter {
                !matchedNew.contains($0) && sameHearingShape(before, newHearings[$0])
            }
            if sameShape.count == 1 {
                // A date-only rewrite is not proof that a hearing was moved.
                diagnostics.append(.ambiguousHearingRewrite)
                if let source = before.sourceCardID { ambiguousSources.insert(source) }
            } else if sameShape.count > 1 || exact.count > 1 {
                diagnostics.append(.ambiguousHearingRewrite)
                if let source = before.sourceCardID { ambiguousSources.insert(source) }
            } else {
                // A vanished source row is never treated as cancellation.
                diagnostics.append(.ambiguousHearingRewrite)
                if let source = before.sourceCardID { ambiguousSources.insert(source) }
            }
        }

        var consumed = Set<Int>()
        for (before, after) in postponed {
            guard let source = after.sourceCardID else {
                diagnostics.append(.missingSourceIdentity); continue
            }
            let candidates = newHearings.indices.filter {
                !matchedNew.contains($0) && !consumed.contains($0)
                    && newHearings[$0].sourceCardID == source
                    && normalized(newHearings[$0].event) == normalized(after.event)
                    && dateKey(newHearings[$0]) > dateKey(after)
            }
            if candidates.count == 1 {
                let next = newHearings[candidates[0]]
                consumed.insert(candidates[0])
                var evidence = sessionEvidence(after)
                evidence.previousDateRaw = before.dateRaw
                evidence.previousTime = before.time
                evidence.dateRaw = next.dateRaw
                evidence.time = next.time
                evidence.relatedOccurrenceKey = hearingKey(next)
                events.append(make(.hearingRescheduled, source: source,
                                   occurrence: [hearingKey(after), hearingKey(next)],
                                   observedAt: observedAt, evidence: evidence))
            } else if candidates.isEmpty {
                events.append(make(.hearingPostponed, source: source,
                                   occurrence: [hearingKey(after), "postponed"],
                                   observedAt: observedAt, evidence: sessionEvidence(after)))
            } else {
                diagnostics.append(.ambiguousHearingRewrite)
                ambiguousSources.insert(source)
            }
        }

        let today = Calendar.current.startOfDay(for: observedAt)
        for index in newHearings.indices where !matchedNew.contains(index)
            && !consumed.contains(index) {
            let value = newHearings[index]
            guard let date = value.date, date >= today else { continue }
            guard let source = value.sourceCardID else {
                diagnostics.append(.missingSourceIdentity); continue
            }
            guard !ambiguousSources.contains(source) else { continue }
            events.append(make(.hearingScheduled, source: source,
                               occurrence: [hearingKey(value)], observedAt: observedAt,
                               evidence: sessionEvidence(value)))
        }
    }

    private static func deriveActs(old: [StoredActObservation], new: [StoredActObservation],
                                   observedAt: Date, events: inout [CaseEvent],
                                   diagnostics: inout [CaseEventDiagnosticReason]) {
        let oldIDs = Set(old.map { $0.sourceActID })
        for value in new.filter({ !oldIDs.contains($0.sourceActID) }) {
            guard let source = value.sourceCardID else {
                diagnostics.append(.missingSourceIdentity); continue
            }
            let evidence = CaseEventEvidence(
                sourceCardID: source, instanceLevelRaw: value.levelRaw,
                caseNumber: nil, dateRaw: value.dateRaw, time: nil,
                previousDateRaw: nil, previousTime: nil, event: value.title,
                previousValue: nil, value: value.court, ruleID: nil,
                occurrenceKey: value.sourceActID, relatedOccurrenceKey: nil)
            events.append(make(.judicialActPublished, source: source,
                               occurrence: [source, value.sourceActID],
                               observedAt: observedAt, evidence: evidence))
        }
    }

    private static func deriveComplaints(old: [StoredComplaintObservation],
                                         new: [StoredComplaintObservation], observedAt: Date,
                                         events: inout [CaseEvent],
                                         diagnostics: inout [CaseEventDiagnosticReason]) {
        let oldIDs = Set(old.map { $0.sourceComplaintID })
        for value in new.filter({ !oldIDs.contains($0.sourceComplaintID) }) {
            guard let source = value.sourceCardID else {
                diagnostics.append(.missingSourceIdentity); continue
            }
            let evidence = CaseEventEvidence(
                sourceCardID: source, instanceLevelRaw: nil,
                caseNumber: value.caseNumber, dateRaw: nil, time: nil,
                previousDateRaw: nil, previousTime: nil, event: value.label,
                previousValue: nil, value: value.court, ruleID: nil,
                occurrenceKey: value.sourceComplaintID, relatedOccurrenceKey: nil)
            events.append(make(.complaintRegistered, source: source,
                               occurrence: [source, value.sourceComplaintID],
                               observedAt: observedAt, evidence: evidence))
        }
    }

    private static func deriveDeadlines(old: [StoredDeadline], new: [StoredDeadline],
                                        observedAt: Date, events: inout [CaseEvent],
                                        diagnostics: inout [CaseEventDiagnosticReason]) {
        let oldByKey = old.reduce(into: [String: StoredDeadline]()) { result, value in
            if let key = value.occurrenceKey { result[key] = value }
        }
        for value in new {
            guard let occurrence = value.occurrenceKey else { continue }
            guard let ruleID = value.provenance?.ruleID, !ruleID.isEmpty else {
                diagnostics.append(.missingSourceIdentity)
                continue
            }
            var evidence = deadlineEvidence(value)
            if let prior = oldByKey[occurrence] {
                if prior.status != value.status {
                    evidence.previousValue = prior.statusRaw
                    let kind: CaseEventKind = value.status == .confirmed
                        ? .deadlineConfirmed : .deadlineChanged
                    events.append(make(kind, source: ruleID,
                                       occurrence: [ruleID, occurrence, value.statusRaw],
                                       observedAt: observedAt, evidence: evidence))
                } else if prior.dateRef != value.dateRef {
                    evidence.previousValue = String(prior.dateRef)
                    events.append(make(.deadlineChanged, source: ruleID,
                                       occurrence: [ruleID, occurrence, String(value.dateRef)],
                                       observedAt: observedAt, evidence: evidence))
                }
                if prior.lifecycle != value.lifecycle {
                    let kind: CaseEventKind? = value.lifecycle == .expiredUnconfirmed
                        ? .deadlineExpired
                        : value.lifecycle == .superseded ? .deadlineSuperseded : nil
                    if let kind {
                        events.append(make(kind, source: ruleID,
                                           occurrence: [ruleID, occurrence, value.lifecycleRaw ?? "active"],
                                           observedAt: observedAt, evidence: evidence))
                    }
                }
            } else if value.lifecycle == .active {
                events.append(make(.deadlineProposed, source: ruleID,
                                   occurrence: [ruleID, occurrence], observedAt: observedAt,
                                   evidence: evidence))
            }
        }
    }

    private static func unique(_ events: [CaseEvent]) -> [CaseEvent] {
        var seen = [String: CaseEvent]()
        return events.filter { event in
            guard let prior = seen[event.id] else {
                seen[event.id] = event
                return true
            }
            return prior != event
        }
    }

    private static func deduplicated<T: Equatable>(_ values: [T]) -> [T] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    private static func mergedByID<T: Equatable, ID: Hashable>(
        _ values: [T], latest: [T], id: (T) -> ID
    ) -> [T] {
        Dictionary(grouping: values, by: id).keys.sorted {
            String(describing: $0) < String(describing: $1)
        }.compactMap { key in
            let candidates = values.filter { id($0) == key }
            guard let current = latest.first(where: { id($0) == key }) else {
                return candidates.first
            }
            return candidates.contains(current) ? current : candidates.first
        }
    }

    private static func mergedInstances(_ values: [StoredInstanceObservation],
                                        latest: [StoredInstanceObservation])
        -> [StoredInstanceObservation] {
        Dictionary(grouping: values, by: { $0.sourceCardID ?? "" }).keys.sorted()
            .compactMap { source in
                let candidates = values.filter { ($0.sourceCardID ?? "") == source }
                guard var merged = candidates.first else { return nil }
                if let current = latest.first(where: { ($0.sourceCardID ?? "") == source }) {
                    if candidates.contains(where: {
                        normalized($0.judge) == normalized(current.judge)
                    }) { merged.judge = current.judge }
                    if candidates.contains(where: {
                        normalized($0.result) == normalized(current.result)
                    }) { merged.result = current.result }
                }
                return merged
            }
    }

    private static func keyed(_ values: [StoredInstanceObservation])
        -> [String: StoredInstanceObservation] {
        values.reduce(into: [String: StoredInstanceObservation]()) { result, value in
            if let key = value.sourceCardID { result[key] = value }
        }
    }

    private static func make(_ kind: CaseEventKind, source: String,
                             occurrence: [String], observedAt: Date,
                             evidence: CaseEventEvidence) -> CaseEvent {
        CaseEvent.make(kind: kind, occurrence: [source] + occurrence,
                       observedAt: observedAt, evidence: evidence)
    }

    private static func instanceEvidence(_ value: StoredInstanceObservation) -> CaseEventEvidence {
        CaseEventEvidence(sourceCardID: value.sourceCardID,
                          instanceLevelRaw: value.levelRaw,
                          caseNumber: value.caseNumber, dateRaw: nil, time: nil,
                          previousDateRaw: nil, previousTime: nil, event: nil,
                          previousValue: nil, value: value.result, ruleID: nil,
                          occurrenceKey: value.sourceCardID, relatedOccurrenceKey: nil)
    }

    private static func sessionEvidence(_ value: StoredSession) -> CaseEventEvidence {
        CaseEventEvidence(sourceCardID: value.sourceCardID,
                          instanceLevelRaw: value.levelRaw,
                          caseNumber: value.caseNumber, dateRaw: value.dateRaw,
                          time: value.time, previousDateRaw: nil, previousTime: nil,
                          event: value.event, previousValue: nil, value: value.result,
                          ruleID: nil, occurrenceKey: hearingKey(value),
                          relatedOccurrenceKey: nil)
    }

    private static func deadlineEvidence(_ value: StoredDeadline) -> CaseEventEvidence {
        CaseEventEvidence(sourceCardID: nil, instanceLevelRaw: nil, caseNumber: nil,
                          dateRaw: isoDate(value.date), time: nil,
                          previousDateRaw: nil, previousTime: nil, event: value.what,
                          previousValue: nil, value: value.statusRaw,
                          ruleID: value.provenance?.ruleID,
                          occurrenceKey: value.occurrenceKey, relatedOccurrenceKey: nil)
    }

    private static func hearingKey(_ value: StoredSession) -> String {
        [value.sourceCardID ?? "", normalized(value.event), normalizedDate(value.dateRaw),
         normalizedTime(value.time)].joined(separator: "|")
    }

    private static func sameHearingOccurrence(_ lhs: StoredSession,
                                              _ rhs: StoredSession) -> Bool {
        hearingKey(lhs) == hearingKey(rhs)
    }

    private static func sameHearingShape(_ lhs: StoredSession,
                                         _ rhs: StoredSession) -> Bool {
        lhs.sourceCardID == rhs.sourceCardID
            && normalized(lhs.event) == normalized(rhs.event)
            && normalized(lhs.room) == normalized(rhs.room)
    }

    private static func isPostponed(_ value: StoredSession) -> Bool {
        let text = normalized((value.result ?? "") + " " + value.event)
        return text.contains("заседани") && text.contains("отлож")
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDate(_ value: String) -> String {
        DateUtil.parse(value).map(isoDate) ?? normalized(value)
    }

    private static func normalizedTime(_ value: String?) -> String {
        let key = CaseLifecycleResolver.hearingTimeKey(value)
        return key == Int.max ? normalized(value) : String(format: "%04d", key)
    }

    private static func dateKey(_ value: StoredSession) -> Double {
        value.date?.timeIntervalSinceReferenceDate ?? -.infinity
    }

    private static func eventOrder(_ lhs: CaseEvent, _ rhs: CaseEvent) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id < rhs.id
    }

    private static func isoDate(_ date: Date) -> String {
        let components = DateUtil.cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0,
                      components.month ?? 0, components.day ?? 0)
    }
}

enum CaseSnapshotSourceIdentity {
    static func sourceCardID(for instance: CaseInstance,
                             context: MovementContext) -> String? {
        let candidates = [context.sourceKnownCard].compactMap { $0 }
            + (context.knownCards ?? [])
        let matchingKnownCards = candidates.filter { value in
            sameHost(value.domain, instance.domain)
                && (value.caseNumber == nil || sameNumber(value.caseNumber, instance.caseNumber))
                && value.level == instance.level
        }
        let matchingIdentities = Dictionary(grouping: matchingKnownCards.map {
            identity(for: $0, context: context)
        }, by: \.id)
        if matchingIdentities.count == 1, let known = matchingKnownCards.first {
            return identity(for: known, context: context).id
        }
        if sameHost(context.searchDomain, instance.domain),
           instance.level == context.baseInstanceLevel,
           let id = context.caseID {
            return SourceNativeCardIdentity(
                sourceFamily: family(context.searchDomain),
                courtKey: context.courtCode ?? SudrfHost.moduleHost(context.searchDomain),
                cartotekaKey: context.cartotekaId, sourceNativeID: id).id
        }
        guard let url = instance.sourceURL,
              let caseID = query(["case_id", "_id"], url),
              let deloID = query(["delo_id", "_deloId"], url),
              let host = url.host else { return nil }
        let cartoteka = CartotekaRegistry.resolve(
            level: level(for: instance), deloID: deloID,
            new: query(["new", "_new"], url), caseNumber: instance.caseNumber)?.id
            ?? deloID
        return SourceNativeCardIdentity(
            sourceFamily: family(host), courtKey: SudrfHost.moduleHost(host),
            cartotekaKey: cartoteka, sourceNativeID: caseID).id
    }

    private static func identity(for value: KnownCard,
                                 context: MovementContext) -> SourceNativeCardIdentity {
        SourceNativeCardIdentity(
            sourceFamily: family(value.domain),
            courtKey: sameHost(value.domain, context.searchDomain) && context.courtCode != nil
                ? context.courtCode! : SudrfHost.moduleHost(value.domain),
            cartotekaKey: value.cartotekaID ?? value.deloID,
            sourceNativeID: value.caseID)
    }

    private static func query(_ names: [String], _ url: URL) -> String? {
        let values = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { names.contains($0.name) ? $0.value : nil }
            .filter { !$0.isEmpty }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        SudrfHost.moduleHost(lhs) == SudrfHost.moduleHost(rhs)
    }

    private static func sameNumber(_ lhs: String?, _ rhs: String) -> Bool {
        normalizedNumber(lhs ?? "") == normalizedNumber(rhs)
    }

    private static func normalizedNumber(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "ё", with: "е")
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func family(_ host: String) -> String {
        let value = host.lowercased()
        if value.contains("msudrf") { return "msudrf" }
        if value.contains("mos-gorsud") { return "mosgorsud" }
        if value.contains("vsrf") { return "vsrf" }
        return "sudrf"
    }

    private static func level(for instance: CaseInstance) -> CourtLevel {
        switch instance.level {
        case .first, .material: return .district
        case .appeal: return .subject
        case .cassation: return .cassation
        case .vsCassation, .supervisory: return .cassation
        }
    }
}
