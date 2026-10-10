// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import SudrfKit

/// Frozen presentation of a proved semantic event. Current snapshots are not
/// consulted again after its exact source-history binding has been committed.
struct JournalFeedPresentation: Codable, Equatable, Sendable {
    let dateRef: Double
    let time: String
    let kindRaw: String
    let text: String
    let actID: String?
    let instanceCaseNumber: String?
    let instanceLevelRaw: String
    let sourceCardID: String?
    let sourceInstanceID: String?
    let previousRegistrationNumber: String?

    init(_ entry: FeedEntry) {
        dateRef = entry.date.timeIntervalSinceReferenceDate
        time = entry.time
        kindRaw = entry.kind.rawValue
        text = entry.text
        actID = entry.actID
        instanceCaseNumber = entry.instanceCaseNumber
        instanceLevelRaw = entry.instanceLevel.rawValue
        sourceCardID = entry.sourceCardID
        sourceInstanceID = entry.sourceInstanceID
        previousRegistrationNumber = entry.previousRegistrationNumber
    }

    func entry(id: String, record: LegacyFeedRecordInput, read: Bool) -> FeedEntry? {
        guard dateRef.isFinite, let kind = FeedEntryKind(rawValue: kindRaw),
              let level = CaseInstance.Level(rawValue: instanceLevelRaw) else { return nil }
        return FeedEntry(id: id, dayHead: nil, date: Date(timeIntervalSinceReferenceDate: dateRef),
            time: time, recordKey: record.recordKey, caseNumber: record.caseNumber,
            client: record.client, kind: kind, text: text, actID: actID, isUnread: !read,
            instanceCaseNumber: instanceCaseNumber, instanceLevel: level,
            sourceCardID: sourceCardID, sourceInstanceID: sourceInstanceID,
            previousRegistrationNumber: previousRegistrationNumber)
    }
}

struct JournalFeedBinding: Codable, Equatable, Sendable {
    let eventID: String
    let historyEventIDs: [String]
    let legacyIDs: [String]
    let originRecordKeys: [String]
    let presentation: JournalFeedPresentation
}

/// Stored input is evidence of the one-time migration, never a replay command.
/// Later user mutations affect the authority sets and cannot be resurrected by it.
struct JournalFeedMarkReceipt: Codable, Equatable, Sendable {
    let originRecordKey: String
    let originalReadIDs: Set<String>
    let originalKnownIDs: Set<String>
}

struct JournalFeedState: Codable, Equatable, Sendable {
    var version = 1
    var bindings: [JournalFeedBinding] = []
    var receipts: [JournalFeedMarkReceipt] = []
    var readEventIDs: Set<String> = []
    var knownEventIDs: Set<String> = []
    var initializedEventIDs: Set<String> = []
    var materialMigrationState = MaterialFeedMigrationState()
    var materialResolvedHistoryIDs: Set<String> = []
    var materialHistoryReplacements: [String: String]?

    static func initial(recordKey: String, journal: CaseEventJournal,
                        legacyReadIDs: Set<String>, legacyKnownIDs: Set<String>,
                        recordKeyAliases: Set<String> = [], unreadByCase: Bool = true) -> Self {
        var state = Self()
        state.receipts = [JournalFeedMarkReceipt(originRecordKey: recordKey,
            originalReadIDs: legacyReadIDs, originalKnownIDs: legacyKnownIDs)]
        let events = journal.events
        for event in events {
            // Direct journal IDs are authoritative independently of any alias.
            let directIDs = Set([event.id] + (event.evidence.eventIDAliases ?? []))
            if !directIDs.isDisjoint(with: legacyReadIDs) { state.readEventIDs.insert(event.id) }
            if !directIDs.isDisjoint(with: legacyKnownIDs) { state.knownEventIDs.insert(event.id) }
            // The old read/known keys were flat IDs: all rows sharing that
            // exact ID had the same mark. Preserve that existing meaning,
            // without treating the mark as proof of semantic/source ownership.
            if let history = event.evidence.legacyFeedHistory {
                if legacyReadIDs.contains(history.legacyID) { state.readEventIDs.insert(event.id) }
                if legacyKnownIDs.contains(history.legacyID) { state.knownEventIDs.insert(event.id) }
            }
            if !unreadByCase && event.kind != .treasuryRSSPublished {
                state.readEventIDs.insert(event.id)
            }
            if event.kind == .treasuryRSSPublished {
                let legacyIDs = TreasuryEventJournal.legacyFeedIDs(recordKey: recordKey,
                    legacyKeys: Array(recordKeyAliases), event: event)
                if !legacyIDs.isDisjoint(with: legacyReadIDs) { state.readEventIDs.insert(event.id) }
                if !legacyIDs.isDisjoint(with: legacyKnownIDs) { state.knownEventIDs.insert(event.id) }
            }
            if event.kind == .legacyFeedImported
                || event.evidence.sourceRowBinding?.notificationEligible == false {
                state.knownEventIDs.insert(event.id)
            }
        }
        state.initializedEventIDs = Set(events.map(\.id))
        return state
    }

    /// Late enrichment transfers the old flat mark policy, without asserting
    /// that unknown history belongs to a newly discovered native card.
    mutating func admitMaterialEnrichment(events: [CaseEvent], journal: CaseEventJournal) {
        let originalHistory = journal.events.filter {
            $0.kind == .legacyFeedImported
                && $0.evidence.legacyFeedHistory?.instanceLevelRaw == CaseInstance.Level.material.rawValue
        }
        let oldHistory = originalHistory.filter { $0.evidence.legacyFeedHistory?.sourceCardID == nil }
        var transitions = [String: Set<String>]()
        var eventByLegacy = [String: Set<String>]()
        var read = Set<String>()
        var known = Set<String>()
        var readEvents = Set<String>()
        var knownEvents = Set<String>()
        var resolvedByBase = [String: Set<String>]()
        var replacementsByBase = [String: [String: String]]()
        let candidates = events.compactMap { event -> (CaseEvent, CaseEvent)? in
            guard let origin = Self.materialEnrichmentOrigin(event, journal: journal) else { return nil }
            return (origin, event)
        }
        for event in events {
            guard event.kind == .sourceRowPublished,
                  event.evidence.sourceRowBinding != nil,
                  let history = event.evidence.legacyFeedHistory,
                  history.instanceLevelRaw == CaseInstance.Level.material.rawValue,
                  history.publishedAtRef.isFinite,
                  history.sourceCardID != nil else { continue }
            let flatText: String
            switch history.source {
            case .session: flatText = history.text
            case .act(let act): flatText = act.id
            }
            let base = AppRouter.feedID(recordKey: history.originRecordKey,
                date: Date(timeIntervalSinceReferenceDate: history.publishedAtRef),
                time: history.time, text: flatText)
            guard materialMigrationState.pendingUnresolvedCounts[base] != nil else { continue }
            let matches = candidates.filter { $0.1.id == event.id }
            guard matches.count == 1, let origin = matches.first?.0,
                  Set(candidates.filter { $0.0.id == origin.id }.map { $0.1.id }).count == 1,
                  materialHistoryReplacements?[origin.id].map({ $0 == event.id }) != false,
                  !(materialHistoryReplacements ?? [:]).contains(where: {
                      $0.key != origin.id && $0.value == event.id
                  }) else { continue }
            replacementsByBase[base, default: [:]][origin.id] = event.id
            resolvedByBase[base, default: []].insert(origin.id)
            transitions[base, default: []].insert(history.legacyID)
            eventByLegacy[history.legacyID, default: []].insert(event.id)
            if readEventIDs.contains(origin.id) { read.insert(base); readEvents.insert(event.id) }
            if knownEventIDs.contains(origin.id) { known.insert(base); knownEvents.insert(event.id) }
        }
        guard !transitions.isEmpty else { return }
        // Keep pending families outside this fresh admitted enrichment untouched.
        let otherPending = materialMigrationState.pendingUnresolvedCounts.filter { transitions[$0.key] == nil }
        // A missing/partial other court cannot consume its original occurrence.
        // Retain exact resolved-history IDs so a later admitted court completes
        // only its own part of a shared flat-ID family.
        var unresolved = [String: Int]()
        for base in transitions.keys {
            let resolved = materialResolvedHistoryIDs.union(resolvedByBase[base] ?? [])
            unresolved[base] = oldHistory.filter {
                $0.evidence.legacyFeedHistory?.legacyID == base && !resolved.contains($0.id)
            }.count
        }
        var scoped = MaterialFeedMigrationState(
            consumedLegacyIDs: materialMigrationState.consumedLegacyIDs,
            pendingUnresolvedCounts: materialMigrationState.pendingUnresolvedCounts.filter { transitions[$0.key] != nil })
        let selected = AppRouter.materialFeedTransitionsToMigrate(transitions: transitions,
            unresolvedCounts: unresolved, readIDs: read, knownIDs: known, state: &scoped)
        materialMigrationState.consumedLegacyIDs = scoped.consumedLegacyIDs
        materialMigrationState.pendingUnresolvedCounts = otherPending.merging(scoped.pendingUnresolvedCounts) { _, value in value }
        for (base, ids) in selected {
            let eventIDs = ids.reduce(into: Set<String>()) { $0.formUnion(eventByLegacy[$1] ?? []) }
            readEventIDs.formUnion(eventIDs.intersection(readEvents))
            knownEventIDs.formUnion(eventIDs.intersection(knownEvents))
            materialResolvedHistoryIDs.formUnion(resolvedByBase[base] ?? [])
            if materialHistoryReplacements == nil { materialHistoryReplacements = [:] }
            for (original, publication) in replacementsByBase[base] ?? [:] {
                materialHistoryReplacements?[original] = publication
            }
        }
    }

    private static func materialEnrichmentOrigin(_ fresh: CaseEvent, journal: CaseEventJournal) -> CaseEvent? {
        let matching = journal.events.filter { materialPayloadMatches($0, fresh) }
        // Qualified occurrences reserve the already handled ordinal prefix.
        let origins = matching.filter { $0.evidence.legacyFeedHistory?.sourceCardID != nil }
            + matching.filter { $0.evidence.legacyFeedHistory?.sourceCardID == nil }
        guard let ordinal = fresh.evidence.sourceRowBinding?.ordinal,
              origins.indices.contains(ordinal),
              origins[ordinal].evidence.legacyFeedHistory?.sourceCardID == nil else { return nil }
        return origins[ordinal]
    }

    /// The stored pair proves display replacement; the original archive stays intact.
    static func materialPayloadMatches(_ old: CaseEvent, _ fresh: CaseEvent) -> Bool {
        guard old.kind == .legacyFeedImported, fresh.kind == .sourceRowPublished,
              let payload = old.evidence.legacyFeedHistory,
              let history = fresh.evidence.legacyFeedHistory,
              payload.instanceLevelRaw == CaseInstance.Level.material.rawValue,
              history.instanceLevelRaw == CaseInstance.Level.material.rawValue,
              payload.publishedAtRef.isFinite, history.publishedAtRef.isFinite,
              let sourceID = history.sourceCardID, !sourceID.isEmpty,
              let binding = fresh.evidence.sourceRowBinding,
              !binding.nativeCardID.isEmpty, !binding.courtScope.isEmpty,
              binding.sourceCardID == sourceID, fresh.evidence.sourceCardID == sourceID,
              payload.originRecordKey == history.originRecordKey,
              payload.sourceCardID == nil || payload.sourceCardID == sourceID else { return false }
        let flatText: String
        switch history.source {
        case .session: flatText = history.text
        case .act(let act): flatText = act.id
        }
        let base = AppRouter.feedID(recordKey: history.originRecordKey,
            date: Date(timeIntervalSinceReferenceDate: history.publishedAtRef),
            time: history.time, text: flatText)
        guard (payload.legacyID == base || payload.legacyID == history.legacyID),
              history.legacyID == AppRouter.materialFeedID(legacyID: base, sourceCardID: sourceID) else { return false }
        switch (payload.source, history.source) {
        case (.session(let oldSource), .session(let newSource)):
            return newSource.sourceCardID == sourceID
                && oldSource.court == newSource.court && oldSource.caseNumber == newSource.caseNumber
                && SourceRowPublication.sessionPublication(oldSource)
                    == SourceRowPublication.sessionPublication(newSource)
        case (.act(let oldAct), .act(let newAct)):
            return oldAct.id == newAct.id && oldAct.title == newAct.title && oldAct.date == newAct.date
                && old.evidence.sourceCardID == sourceID
        default: return false
        }
    }

    mutating func bind(_ binding: JournalFeedBinding, rescheduled: Bool) throws {
        if let existing = bindings.first(where: { $0.eventID == binding.eventID }) {
            guard existing == binding else {
                throw CaseEventJournalError.conflictingEventID("feed-binding:" + binding.eventID)
            }
            return
        }
        // A reschedule may replace only the complete two-row occurrence.
        guard !rescheduled || binding.historyEventIDs.count == 2 && binding.legacyIDs.count == 2 else {
            throw CaseEventJournalError.conflictingEventID("incomplete-feed-reschedule:" + binding.eventID)
        }
        if !binding.historyEventIDs.isEmpty,
           binding.historyEventIDs.allSatisfy(readEventIDs.contains) {
            readEventIDs.insert(binding.eventID)
        }
        if binding.historyEventIDs.contains(where: knownEventIDs.contains) {
            knownEventIDs.insert(binding.eventID)
        }
        bindings.append(binding)
    }

    static func merged(_ values: [Self], events: [CaseEvent]) throws -> Self? {
        guard !values.isEmpty else { return nil }
        var result = Self()
        var canonicalIDs = [String: String]()
        for event in events {
            for alias in event.evidence.eventIDAliases ?? [] {
                if let prior = canonicalIDs[alias], prior != event.id {
                    throw CaseEventJournalError.conflictingEventID("feed-alias:" + alias)
                }
                canonicalIDs[alias] = event.id
            }
        }
        func canonical(_ id: String) -> String { canonicalIDs[id] ?? id }
        for value in values {
            guard value.version == 1 else {
                throw CaseEventJournalError.conflictingEventID("feed-state-version")
            }
            result.readEventIDs.formUnion(value.readEventIDs.map(canonical))
            result.knownEventIDs.formUnion(value.knownEventIDs.map(canonical))
            result.initializedEventIDs.formUnion(value.initializedEventIDs.map(canonical))
            result.materialResolvedHistoryIDs.formUnion(value.materialResolvedHistoryIDs.map(canonical))
            for (original, publication) in value.materialHistoryReplacements ?? [:] {
                let oldID = canonical(original), newID = canonical(publication)
                guard oldID != newID,
                      result.materialHistoryReplacements?[oldID].map({ $0 == newID }) != false,
                      !(result.materialHistoryReplacements ?? [:]).contains(where: {
                          $0.key != oldID && $0.value == newID
                      }) else {
                    throw CaseEventJournalError.conflictingEventID("material-feed-replacement:" + oldID)
                }
                if result.materialHistoryReplacements == nil { result.materialHistoryReplacements = [:] }
                result.materialHistoryReplacements?[oldID] = newID
            }
            result.materialMigrationState.consumedLegacyIDs.formUnion(
                value.materialMigrationState.consumedLegacyIDs)
            for (id, count) in value.materialMigrationState.pendingUnresolvedCounts {
                result.materialMigrationState.pendingUnresolvedCounts[id] = max(
                    result.materialMigrationState.pendingUnresolvedCounts[id] ?? 0, count)
            }
            for receipt in value.receipts where !result.receipts.contains(receipt) {
                result.receipts.append(receipt)
            }
            for binding in value.bindings {
                let mapped = JournalFeedBinding(eventID: canonical(binding.eventID),
                    historyEventIDs: binding.historyEventIDs.map(canonical),
                    legacyIDs: binding.legacyIDs, originRecordKeys: binding.originRecordKeys,
                    presentation: binding.presentation)
                if let prior = result.bindings.first(where: { $0.eventID == mapped.eventID }) {
                    guard prior == mapped else {
                        throw CaseEventJournalError.conflictingEventID("feed-binding:" + mapped.eventID)
                    }
                } else { result.bindings.append(mapped) }
            }
        }
        for id in result.materialMigrationState.consumedLegacyIDs {
            result.materialMigrationState.pendingUnresolvedCounts.removeValue(forKey: id)
        }
        return result
    }
}
