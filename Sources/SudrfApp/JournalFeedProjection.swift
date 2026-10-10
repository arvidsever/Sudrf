// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import SudrfKit

/// Projection from immutable publication history and once-proved semantic bindings.
/// Display windows are applied after durable binding/mark state has been formed.
enum JournalFeedProjection {
    static func synchronize(record: LegacyFeedRecordInput, journal: CaseEventJournal,
                            legacyReadIDs: Set<String>, legacyKnownIDs: Set<String>,
                            materialMigrationState: MaterialFeedMigrationState = .init(),
                            migrationDay: Date = DateUtil.today) throws -> JournalFeedState {
        var state: JournalFeedState
        if let existing = journal.feedState {
            state = existing
        } else {
            // Reuse the exact old renderer's one-time mark policy before cutover.
            // This transfers flat marks; it proves no source ownership or collapse.
            let old = LegacyFeedProjection.project(records: [record], today: migrationDay,
                readIDs: legacyReadIDs, knownIDs: legacyKnownIDs,
                migrationState: materialMigrationState)
            state = JournalFeedState.initial(recordKey: record.recordKey, journal: journal,
                legacyReadIDs: old.migratedReadIDs, legacyKnownIDs: old.migratedKnownIDs,
                recordKeyAliases: record.recordKeyAliases, unreadByCase: record.unreadByCase)
            state.receipts = [JournalFeedMarkReceipt(originRecordKey: record.recordKey,
                originalReadIDs: legacyReadIDs, originalKnownIDs: legacyKnownIDs)]
            state.materialMigrationState = old.migrationState
        }
        for event in journal.events where !state.initializedEventIDs.contains(event.id)
            && (event.kind == .legacyFeedImported
                || event.evidence.sourceRowBinding?.notificationEligible == false) {
            state.knownEventIDs.insert(event.id)
        }
        state.initializedEventIDs.formUnion(journal.events.map(\.id))
        let histories = journal.events.filter { $0.evidence.legacyFeedHistory != nil }
        let historyRows = histories.compactMap { event -> (CaseEvent, FeedEntry)? in
            guard let history = event.evidence.legacyFeedHistory,
                  history.originRecordKey == record.recordKey
                    || record.canUseRecordKeyAliases && record.recordKeyAliases.contains(history.originRecordKey),
                  var entry = historyEntry(event, record: record, read: false) else { return nil }
            entry.id = history.legacyID
            if history.originRecordKey != record.recordKey {
                entry.id = AppRouter.remappedFeedID(entry.id,
                    keyRemaps: [history.originRecordKey: record.recordKey])
            }
            return (event, entry)
        }
        let bound = Set(state.bindings.map(\.eventID))
        var pending = journal
        pending.events.removeAll { bound.contains($0.id) }
        let journals = [record.recordKey: pending]
        for event in pending.events {
            let datedKinds: Set<CaseEventKind> = [.judicialActPublished, .hearingScheduled,
                .hearingPostponed, .hearingRescheduled, .caseFileRequested,
                .requestedCaseReceived, .complaintReviewResult]
            let undatedKinds: Set<CaseEventKind> = [.judgeChanged, .instanceDiscovered, .resultChanged]
            guard datedKinds.contains(event.kind) || undatedKinds.contains(event.kind) else { continue }
            let observedDay = Date(timeIntervalSinceReferenceDate: event.observedAtRef)
            let proofDay = undatedKinds.contains(event.kind) ? observedDay
                : event.evidence.dateRaw.flatMap(DateUtil.parse) ?? observedDay
            guard proofDay.timeIntervalSinceReferenceDate.isFinite else { continue }
            let legacyEntries = historyRows.map(\.1)
            let entries: [FeedEntry]
            let aliases: [String]
            switch event.kind {
            case .judicialActPublished:
                let projected = ActJournalFeedProjection.project(records: [record],
                    journalsByRecordKey: journals, today: proofDay, readIDs: [], knownIDs: [],
                    legacyEntries: legacyEntries)
                entries = projected.entries.filter { $0.id == event.id }
                aliases = projected.aliases.filter { $0.eventID == event.id }.map(\.legacyID)
            case .hearingScheduled, .hearingPostponed, .hearingRescheduled:
                let projected = HearingJournalFeedProjection.project(records: [record],
                    journalsByRecordKey: journals, today: proofDay, readIDs: [], knownIDs: [],
                    legacyEntries: legacyEntries)
                entries = projected.entries.filter { $0.id == event.id }
                aliases = projected.aliases.filter { $0.eventID == event.id }.map(\.legacyID)
            case .caseFileRequested, .requestedCaseReceived, .complaintReviewResult:
                let projected = KoAPJournalFeedProjection.project(records: [record],
                    journalsByRecordKey: journals, today: proofDay, readIDs: [], legacyEntries: legacyEntries)
                entries = projected.entries.filter { $0.id == event.id }
                aliases = projected.aliases.filter { $0.eventID == event.id }.map(\.legacyID)
            default:
                entries = MovementJournalFeedProjection.project(records: [record],
                    journalsByRecordKey: journals, today: proofDay, readIDs: [], knownIDs: []).entries
                    .filter { $0.id == event.id }
                aliases = []
            }
            guard entries.count == 1, let entry = entries.first else { continue }
            if datedKinds.contains(event.kind) {
                let expected = event.kind == .hearingRescheduled ? 2 : 1
                guard Set(aliases).count == expected else { continue }
            }
            var matched = [CaseEvent]()
            var proved = true
            for alias in aliases {
                let candidates = historyRows.filter { $0.1.id == alias }
                guard candidates.count == 1, let candidate = candidates.first,
                      historySourceMatches(candidate.0, semantic: event, record: record, journal: journal),
                      !state.bindings.contains(where: { $0.historyEventIDs.contains(candidate.0.id) }) else {
                    proved = false; break
                }
                matched.append(candidate.0)
            }
            guard proved else { continue }
            let binding = JournalFeedBinding(eventID: event.id,
                historyEventIDs: matched.map(\.id),
                legacyIDs: matched.compactMap { $0.evidence.legacyFeedHistory?.legacyID },
                originRecordKeys: Set(matched.compactMap { $0.evidence.legacyFeedHistory?.originRecordKey }
                    + [event.occurrence?.originRecordKey ?? record.recordKey]).sorted(),
                presentation: JournalFeedPresentation(entry))
            try state.bind(binding, rescheduled: event.kind == .hearingRescheduled)
        }
        return state
    }

    /// Old material display collapsed exact qualified duplicates. Preserve
    /// their immutable events and use current authority for the whole group.
    static func replacedHistoryIDs(journal: CaseEventJournal) -> Set<String> {
        var ids = Set((journal.feedState?.bindings ?? []).flatMap(\.historyEventIDs))
        for (original, publication) in journal.feedState?.materialHistoryReplacements ?? [:] {
            guard original != publication,
                  let old = journal.events.first(where: { $0.id == original }),
                  let fresh = journal.events.first(where: { $0.id == publication }),
                  old.evidence.legacyFeedHistory?.sourceCardID == nil,
                  JournalFeedState.materialPayloadMatches(old, fresh) else { continue }
            ids.insert(original)
        }
        return ids
    }

    static func historyDisplayGroups(journal: CaseEventJournal) -> [[CaseEvent]] {
        let replaced = replacedHistoryIDs(journal: journal)
        var groups = [[CaseEvent]]()
        for event in journal.events where !replaced.contains(event.id) {
            guard let history = event.evidence.legacyFeedHistory else { continue }
            if history.instanceLevelRaw == CaseInstance.Level.material.rawValue,
               history.sourceCardID != nil,
               let index = groups.firstIndex(where: { $0.first?.evidence.legacyFeedHistory == history }) {
                groups[index].append(event)
            } else { groups.append([event]) }
        }
        return groups
    }

    static func displayMemberIDs(_ ids: Set<String>, journal: CaseEventJournal) -> Set<String> {
        var result = ids
        for group in historyDisplayGroups(journal: journal) {
            let members = Set(group.map(\.id))
            if !members.isDisjoint(with: ids) { result.formUnion(members) }
        }
        return result
    }

    static func entries(record: LegacyFeedRecordInput, journal: CaseEventJournal, today: Date) -> [FeedEntry] {
        guard let state = journal.feedState else { return [] }
        var rows = historyDisplayGroups(journal: journal).compactMap { group -> FeedEntry? in
            guard let event = group.first else { return nil }
            return historyEntry(event, record: record,
                read: group.allSatisfy { state.readEventIDs.contains($0.id) })
        }
        rows += journal.events.filter { $0.kind == .treasuryRSSPublished }.compactMap { event in
            guard let text = event.evidence.event,
                  let date = event.evidence.rssPublishedAtRef.map(Date.init(timeIntervalSinceReferenceDate:))
                    ?? event.evidence.dateRaw.flatMap(DateUtil.parse),
                  date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return FeedEntry(id: event.id, dayHead: nil, date: date, time: "—",
                recordKey: record.recordKey, caseNumber: record.caseNumber, client: record.client,
                kind: .enforcement, text: text, actID: nil,
                isUnread: !state.readEventIDs.contains(event.id))
        }
        rows += state.bindings.compactMap {
            $0.presentation.entry(id: $0.eventID, record: record,
                read: state.readEventIDs.contains($0.eventID))
        }
        return rows.filter { (0...45).contains(DateUtil.daysBetween($0.date, today)) }
    }

    private static func historyEntry(_ event: CaseEvent, record: LegacyFeedRecordInput,
                                     read: Bool) -> FeedEntry? {
        guard let history = event.evidence.legacyFeedHistory,
              history.publishedAtRef.isFinite, let kind = FeedEntryKind(rawValue: history.kindRaw),
              let level = CaseInstance.Level(rawValue: history.instanceLevelRaw) else { return nil }
        return FeedEntry(id: event.id, dayHead: nil,
            date: Date(timeIntervalSinceReferenceDate: history.publishedAtRef), time: history.time,
            recordKey: record.recordKey, caseNumber: record.caseNumber, client: record.client,
            kind: kind, text: history.text, actID: history.actID, isUnread: !read,
            instanceCaseNumber: history.instanceCaseNumber, instanceLevel: level,
            sourceCardID: history.sourceCardID, sourceInstanceID: history.sourceInstanceID,
            previousRegistrationNumber: history.previousRegistrationNumber)
    }

    private static func historySourceMatches(_ historyEvent: CaseEvent, semantic: CaseEvent,
                                            record: LegacyFeedRecordInput, journal: CaseEventJournal) -> Bool {
        guard let history = historyEvent.evidence.legacyFeedHistory,
              let target = semantic.evidence.sourceCardID else { return false }
        if (history.sourceCardID ?? historyEvent.evidence.sourceCardID) == target { return true }
        guard let binding = historyEvent.evidence.sourceRowBinding, let context = record.context else { return false }
        let owners = record.instances.filter {
            CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context) == target
        }
        guard owners.count == 1, let owner = owners.first,
              let native = CaseEventSourceAdmission.nativeCardIdentity(for: owner, context: context) else { return false }
        return SourceRowPublication.canonicalNative(binding.nativeCardID,
            aliases: journal.sourceRowContinuities ?? [:]) == native.id
    }
}
