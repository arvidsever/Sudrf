import Foundation
import SudrfKit

struct HearingJournalFeedAlias: Equatable {
    let legacyID: String
    let eventID: String
}

enum HearingJournalFeedUnmappedReason: String, Equatable {
    case missingEventID
    case duplicateEventID
    case missingOccurrenceKey
    case missingSourceCardID
    case missingEvidenceDate
    case invalidEvidenceDate
    case missingEvidenceLevel
    case missingEvidenceEvent
    case rescheduledOccurrenceUnproven
    case missingCurrentSession
    case duplicateCurrentSession
    case currentSessionIsNotHearing
    case sourceConflict
    case missingCurrentObservation
    case duplicateCurrentObservation
    case missingCurrentOwner
    case ambiguousCurrentOwner
    case levelConflict
    case dateConflict
    case timeConflict
    case eventConflict
    case resultConflict
    case ambiguousEventForCurrentSession
    case missingLegacyHearing
    case ambiguousLegacyHearing
    case legacyIDMismatch
    case ambiguousAlias
    case noJournalHearingEvent
}

struct UnmappedLegacyHearingFeedRow: Equatable {
    let recordKey: String
    let legacyID: String
    let reason: HearingJournalFeedUnmappedReason
}

struct UnmappedHearingJournalEvent: Equatable {
    let recordKey: String
    let eventID: String
    let occurrenceKey: String?
    let reason: HearingJournalFeedUnmappedReason
}

struct HearingJournalFeedFieldMismatch: Equatable {
    let recordKey: String
    let legacyID: String
    let eventID: String
    let field: String
    let legacyValue: String?
    let shadowValue: String?
}

struct HearingJournalFeedProjectionResult {
    let entries: [FeedEntry]
    let aliases: [HearingJournalFeedAlias]
    let shadowReadIDs: Set<String>
    let shadowKnownIDs: Set<String>
    let unmappedLegacyHearings: [UnmappedLegacyHearingFeedRow]
    let unmappedEvents: [UnmappedHearingJournalEvent]
    let fieldMismatches: [HearingJournalFeedFieldMismatch]
}

/// A read-only shadow for persisted hearing events. The current legacy
/// projection is supplied only as the comparison oracle; current sessions,
/// source observations, and event evidence must independently agree.
enum HearingJournalFeedProjection {
    private struct OccurrenceKey: Hashable {
        let recordKey: String
        let value: String
    }

    private struct LegacyRowKey: Hashable {
        let recordKey: String
        let legacyID: String
    }

    private struct EventReference {
        let record: LegacyFeedRecordInput
        let event: CaseEvent
    }

    private struct ProjectedEvent {
        let record: LegacyFeedRecordInput
        let event: CaseEvent
        let occurrenceKey: OccurrenceKey
        let legacyID: String
        let entry: FeedEntry
    }

    private struct CandidateAlias {
        let alias: HearingJournalFeedAlias
        let legacy: FeedEntry
        let projected: ProjectedEvent
    }

    private struct ValidationFailure: Error {
        let reason: HearingJournalFeedUnmappedReason
    }

    static func project(
        records: [LegacyFeedRecordInput],
        journalsByRecordKey: [String: CaseEventJournal],
        today: Date,
        readIDs: Set<String>,
        knownIDs: Set<String>,
        legacyEntries: [FeedEntry]
    ) -> HearingJournalFeedProjectionResult {
        let legacyHearings = legacyEntries.filter { $0.kind == .hearing }
        // Feed identity intentionally omits the kind. Count every raw row,
        // including acts and movements, before any IDs are collapsed to sets.
        let rawLegacyIDCounts = Dictionary(grouping: legacyEntries, by: \.id)
        let references = records.flatMap { record in
            (journalsByRecordKey[record.recordKey]?.events ?? [])
                .filter {
                    $0.kind == .hearingScheduled || $0.kind == .hearingPostponed
                        || $0.kind == .hearingRescheduled
                }
                .map { EventReference(record: record, event: $0) }
        }
        let duplicateEventIDs = Set(Dictionary(grouping: references, by: { $0.event.id })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }.keys)
        let occurrencesWithMultiplePersistedEvents = Set(Dictionary(grouping: references.compactMap {
            reference -> OccurrenceKey? in
            guard reference.event.kind == .hearingScheduled
                    || reference.event.kind == .hearingPostponed,
                  let occurrence = reference.event.evidence.occurrenceKey,
                  hasCurrentInWindowOccurrence([occurrence],
                                                record: reference.record, today: today)
            else { return nil }
            return OccurrenceKey(recordKey: reference.record.recordKey, value: occurrence)
        }, by: { $0 }).filter { $0.value.count > 1 }.keys)

        var unmappedEvents = [UnmappedHearingJournalEvent]()
        var blockedLegacyReasons = [LegacyRowKey: HearingJournalFeedUnmappedReason]()
        var projected = [ProjectedEvent]()

        for reference in references {
            let record = reference.record
            let event = reference.event
            let evidence = event.evidence
            let currentOccurrenceInWindow = evidence.occurrenceKey.map {
                hasCurrentInWindowOccurrence([$0], record: record, today: today)
            } ?? false

            func recordFailure(_ reason: HearingJournalFeedUnmappedReason,
                               session: StoredSession? = nil) {
                unmappedEvents.append(UnmappedHearingJournalEvent(
                    recordKey: record.recordKey, eventID: event.id,
                    occurrenceKey: evidence.occurrenceKey, reason: reason))
                if let session,
                   let legacyID = HearingJournalFeedProjection.legacyID(
                    recordKey: record.recordKey, session: session) {
                    blockedLegacyReasons[LegacyRowKey(
                        recordKey: record.recordKey, legacyID: legacyID)] = reason
                }
            }

            if event.kind == .hearingRescheduled {
                let relevantDates = [evidence.previousDateRaw, evidence.dateRaw]
                    .compactMap { $0.flatMap(DateUtil.parse) }
                let affectedKeys = [evidence.occurrenceKey,
                                    evidence.relatedOccurrenceKey].compactMap { $0 }
                guard relevantDates.contains(where: { isInWindow($0, today: today) })
                        || hasCurrentInWindowOccurrence(affectedKeys,
                                                        record: record, today: today) else {
                    continue
                }
                guard !event.id.isEmpty else {
                    recordFailure(.missingEventID)
                    continue
                }
                guard !duplicateEventIDs.contains(event.id) else {
                    recordFailure(.duplicateEventID)
                    continue
                }
                recordFailure(.rescheduledOccurrenceUnproven)
                let affectedKeySet = Set(affectedKeys)
                for session in record.snapshot?.sessions ?? []
                    where affectedKeySet.contains(CaseEventDeriver.hearingKey(session)) {
                    if let legacyID = HearingJournalFeedProjection.legacyID(
                        recordKey: record.recordKey, session: session) {
                        blockedLegacyReasons[LegacyRowKey(
                            recordKey: record.recordKey, legacyID: legacyID)] =
                            .rescheduledOccurrenceUnproven
                    }
                }
                continue
            }

            guard let rawDate = evidence.dateRaw,
                  !rawDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                recordFailure(.missingEvidenceDate)
                continue
            }
            guard let evidenceDate = DateUtil.parse(rawDate) else {
                recordFailure(.invalidEvidenceDate)
                continue
            }
            // History scope follows the process date and the same inclusive
            // window as LegacyFeedProjection; observedAt never controls it.
            // An in-window current occurrence stays relevant even when its
            // persisted date conflicts, so invalid evidence cannot hide it.
            guard isInWindow(evidenceDate, today: today) || currentOccurrenceInWindow else {
                continue
            }

            guard !event.id.isEmpty else {
                recordFailure(.missingEventID)
                continue
            }
            guard !duplicateEventIDs.contains(event.id) else {
                recordFailure(.duplicateEventID)
                continue
            }
            guard let occurrence = evidence.occurrenceKey, !occurrence.isEmpty else {
                recordFailure(.missingOccurrenceKey)
                continue
            }
            guard let sourceCardID = evidence.sourceCardID, !sourceCardID.isEmpty else {
                recordFailure(.missingSourceCardID)
                continue
            }
            guard let evidenceLevel = evidence.instanceLevelRaw, !evidenceLevel.isEmpty else {
                recordFailure(.missingEvidenceLevel)
                continue
            }
            guard let evidenceEvent = evidence.event else {
                recordFailure(.missingEvidenceEvent)
                continue
            }

            let matchingSessions = record.snapshot?.sessions.filter {
                CaseEventDeriver.hearingKey($0) == occurrence
            } ?? []
            guard !matchingSessions.isEmpty else {
                recordFailure(.missingCurrentSession)
                continue
            }
            guard matchingSessions.count == 1, let session = matchingSessions.first else {
                recordFailure(.duplicateCurrentSession)
                continue
            }
            let key = OccurrenceKey(recordKey: record.recordKey, value: occurrence)
            guard !occurrencesWithMultiplePersistedEvents.contains(key) else {
                recordFailure(.ambiguousEventForCurrentSession, session: session)
                continue
            }

            do {
                guard CaseLifecycleResolver.isHearingEvent(event: session.event) else {
                    throw ValidationFailure(reason: .currentSessionIsNotHearing)
                }
                guard sourceCardID == session.sourceCardID else {
                    throw ValidationFailure(reason: .sourceConflict)
                }
                guard evidenceLevel == session.levelRaw else {
                    throw ValidationFailure(reason: .levelConflict)
                }
                guard evidenceDate == session.date else {
                    throw ValidationFailure(reason: .dateConflict)
                }
                guard evidence.time == session.time else {
                    throw ValidationFailure(reason: .timeConflict)
                }
                guard evidenceEvent == session.event else {
                    throw ValidationFailure(reason: .eventConflict)
                }
                guard evidence.value == session.result else {
                    throw ValidationFailure(reason: .resultConflict)
                }

                let observations = record.snapshot?.instanceObservations?.filter {
                    $0.sourceCardID == sourceCardID
                } ?? []
                guard !observations.isEmpty else {
                    throw ValidationFailure(reason: .missingCurrentObservation)
                }
                guard observations.count == 1, let observation = observations.first else {
                    throw ValidationFailure(reason: .duplicateCurrentObservation)
                }
                guard observation.levelRaw == evidenceLevel else {
                    throw ValidationFailure(reason: .levelConflict)
                }
                guard let context = record.context else {
                    throw ValidationFailure(reason: .missingCurrentOwner)
                }
                let owners = record.instances.filter {
                    CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context)
                        == sourceCardID
                }
                guard !owners.isEmpty else {
                    throw ValidationFailure(reason: .missingCurrentOwner)
                }
                guard owners.count == 1, let owner = owners.first else {
                    throw ValidationFailure(reason: .ambiguousCurrentOwner)
                }
                guard owner.level.rawValue == evidenceLevel else {
                    throw ValidationFailure(reason: .levelConflict)
                }

                let text = session.result ?? session.event
                let legacyID = HearingJournalFeedProjection.legacyID(
                    recordKey: record.recordKey, session: session)
                    ?? AppRouter.feedID(recordKey: record.recordKey, date: evidenceDate,
                                        time: session.time ?? "—", text: text)
                let material = record.materialSource(session)
                let previousRegistration = record.previousRegistrationSource(session)
                let entry = FeedEntry(
                    id: event.id, dayHead: nil, date: evidenceDate,
                    time: session.time ?? "—", recordKey: record.recordKey,
                    caseNumber: record.caseNumber, client: record.client,
                    kind: AppRouter.feedKind(for: session), text: text, actID: nil,
                    isUnread: record.unreadByCase,
                    instanceCaseNumber: previousRegistration?.number
                        ?? (session.level == .material ? material.number : session.caseNumber),
                    instanceLevel: session.level, sourceCardID: session.sourceCardID,
                    sourceInstanceID: previousRegistration?.instance.id ?? material.instance?.id,
                    previousRegistrationNumber: previousRegistration?.number)
                projected.append(ProjectedEvent(
                    record: record, event: event,
                    occurrenceKey: key, legacyID: legacyID, entry: entry))
            } catch let failure as ValidationFailure {
                recordFailure(failure.reason, session: session)
            } catch {
                recordFailure(.missingCurrentOwner, session: session)
            }

        }

        var candidateAliases = [CandidateAlias]()
        for value in projected {
            let identityRows = legacyHearings.filter {
                $0.recordKey == value.record.recordKey
                    && $0.date == value.entry.date
                    && $0.time == value.entry.time
                    && $0.text == value.entry.text
                    && $0.instanceLevel == value.entry.instanceLevel
                    && $0.sourceCardID == value.entry.sourceCardID
            }
            let exactRows = legacyHearings.filter {
                $0.recordKey == value.record.recordKey && $0.id == value.legacyID
            }
            let matchingRows = exactRows.isEmpty ? identityRows : exactRows
            guard !matchingRows.isEmpty else {
                unmappedEvents.append(UnmappedHearingJournalEvent(
                    recordKey: value.record.recordKey, eventID: value.event.id,
                    occurrenceKey: value.event.evidence.occurrenceKey,
                    reason: .missingLegacyHearing))
                blockedLegacyReasons[LegacyRowKey(
                    recordKey: value.record.recordKey, legacyID: value.legacyID)] =
                    .missingLegacyHearing
                continue
            }
            guard matchingRows.count == 1, let legacy = matchingRows.first else {
                unmappedEvents.append(UnmappedHearingJournalEvent(
                    recordKey: value.record.recordKey, eventID: value.event.id,
                    occurrenceKey: value.event.evidence.occurrenceKey,
                    reason: .ambiguousLegacyHearing))
                blockedLegacyReasons[LegacyRowKey(
                    recordKey: value.record.recordKey, legacyID: value.legacyID)] =
                    .ambiguousLegacyHearing
                continue
            }
            guard legacy.id == value.legacyID else {
                unmappedEvents.append(UnmappedHearingJournalEvent(
                    recordKey: value.record.recordKey, eventID: value.event.id,
                    occurrenceKey: value.event.evidence.occurrenceKey,
                    reason: .legacyIDMismatch))
                blockedLegacyReasons[LegacyRowKey(
                    recordKey: legacy.recordKey, legacyID: legacy.id)] = .legacyIDMismatch
                continue
            }
            candidateAliases.append(CandidateAlias(
                alias: HearingJournalFeedAlias(legacyID: legacy.id, eventID: value.event.id),
                legacy: legacy, projected: value))
        }

        let candidateLegacyIDCounts = Dictionary(grouping: candidateAliases, by: { $0.alias.legacyID })
        let candidateEventIDCounts = Dictionary(grouping: candidateAliases, by: { $0.alias.eventID })
        let aliases = candidateAliases.filter {
            rawLegacyIDCounts[$0.alias.legacyID]?.count == 1
                && candidateLegacyIDCounts[$0.alias.legacyID]?.count == 1
                && candidateEventIDCounts[$0.alias.eventID]?.count == 1
        }
        let acceptedEventIDs = Set(aliases.map { $0.alias.eventID })
        let acceptedLegacyIDs = Set(aliases.map { $0.alias.legacyID })
        for candidate in candidateAliases where !acceptedEventIDs.contains(candidate.alias.eventID) {
            unmappedEvents.append(UnmappedHearingJournalEvent(
                recordKey: candidate.projected.record.recordKey,
                eventID: candidate.alias.eventID,
                occurrenceKey: candidate.projected.event.evidence.occurrenceKey,
                reason: .ambiguousAlias))
            blockedLegacyReasons[LegacyRowKey(
                recordKey: candidate.legacy.recordKey, legacyID: candidate.legacy.id)] = .ambiguousAlias
        }

        var shadowReadIDs = Set<String>()
        var shadowKnownIDs = Set<String>()
        var fieldMismatches = [HearingJournalFeedFieldMismatch]()
        var entries = projected.map(\.entry)
        for candidate in aliases {
            if readIDs.contains(candidate.alias.legacyID) {
                shadowReadIDs.insert(candidate.alias.eventID)
            }
            if knownIDs.contains(candidate.alias.legacyID) {
                shadowKnownIDs.insert(candidate.alias.eventID)
            }
        }
        for index in entries.indices where shadowReadIDs.contains(entries[index].id) {
            entries[index].isUnread = false
        }
        for candidate in aliases {
            guard let shadow = entries.first(where: { $0.id == candidate.alias.eventID }) else {
                continue
            }
            fieldMismatches += JournalFeedComparison.mismatches(candidate.legacy, shadow)
                .map { field, legacyValue, shadowValue in
                    HearingJournalFeedFieldMismatch(
                        recordKey: candidate.projected.record.recordKey,
                        legacyID: candidate.alias.legacyID,
                        eventID: candidate.alias.eventID,
                        field: field, legacyValue: legacyValue, shadowValue: shadowValue)
                }
        }

        let unmappedLegacy = legacyHearings.filter {
            !acceptedLegacyIDs.contains($0.id)
        }.map { legacy in
            let rowKey = LegacyRowKey(recordKey: legacy.recordKey, legacyID: legacy.id)
            let reason = rawLegacyIDCounts[legacy.id]?.count != 1
                ? HearingJournalFeedUnmappedReason.ambiguousAlias
                : blockedLegacyReasons[rowKey] ?? .noJournalHearingEvent
            return UnmappedLegacyHearingFeedRow(
                recordKey: legacy.recordKey, legacyID: legacy.id, reason: reason)
        }

        return HearingJournalFeedProjectionResult(
            entries: entries, aliases: aliases.map(\.alias),
            shadowReadIDs: shadowReadIDs, shadowKnownIDs: shadowKnownIDs,
            unmappedLegacyHearings: unmappedLegacy, unmappedEvents: unmappedEvents,
            fieldMismatches: fieldMismatches)
    }

    private static func isInWindow(_ date: Date, today: Date) -> Bool {
        let diff = DateUtil.daysBetween(date, today)
        return diff >= 0 && diff <= 45
    }

    private static func hasCurrentInWindowOccurrence(_ occurrenceKeys: [String],
                                                     record: LegacyFeedRecordInput,
                                                     today: Date) -> Bool {
        let keys = Set(occurrenceKeys)
        guard !keys.isEmpty else { return false }
        return record.snapshot?.sessions.contains {
            keys.contains(CaseEventDeriver.hearingKey($0))
                && $0.date.map { isInWindow($0, today: today) } == true
        } ?? false
    }

    private static func legacyID(recordKey: String, session: StoredSession) -> String? {
        guard let date = session.date else { return nil }
        let baseID = AppRouter.feedID(
            recordKey: recordKey, date: date,
            time: session.time ?? "—", text: session.result ?? session.event)
        guard session.level == .material, let sourceCardID = session.sourceCardID else {
            return baseID
        }
        return AppRouter.materialFeedID(legacyID: baseID, sourceCardID: sourceCardID)
    }

}
