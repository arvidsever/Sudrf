import Foundation
import SudrfKit

struct ActJournalFeedAlias: Equatable {
    let legacyID: String
    let eventID: String
}

enum ActJournalFeedUnmappedReason: String, Equatable {
    case missingEventID
    case missingOccurrenceKey
    case missingSourceCardID
    case missingEvidenceDate
    case invalidEvidenceDate
    case missingEvidenceLevel
    case missingCurrentAct
    case duplicateCurrentAct
    case missingCurrentObservation
    case duplicateCurrentObservation
    case invalidCurrentDate
    case dateConflict
    case levelConflict
    case sourceConflict
    case missingCurrentOwner
    case ambiguousCurrentOwner
    case duplicateEventID
    case missingLegacyAct
    case ambiguousLegacyAct
    case ambiguousEventForLegacyAct
    case ambiguousAlias
    case legacyIDMismatch
    case missingLegacyActID
    case noPublishedEvent
}

struct UnmappedLegacyActFeedRow: Equatable {
    let recordKey: String
    let legacyID: String
    let actID: String?
    let reason: ActJournalFeedUnmappedReason
}

struct UnmappedActJournalEvent: Equatable {
    let recordKey: String
    let eventID: String
    let sourceActID: String?
    let reason: ActJournalFeedUnmappedReason
}

struct ActJournalFeedFieldMismatch: Equatable {
    let recordKey: String
    let legacyID: String
    let eventID: String
    let field: String
    let legacyValue: String?
    let shadowValue: String?
}

struct ActJournalFeedProjectionResult {
    let entries: [FeedEntry]
    let aliases: [ActJournalFeedAlias]
    let shadowReadIDs: Set<String>
    let shadowKnownIDs: Set<String>
    let unmappedLegacyActs: [UnmappedLegacyActFeedRow]
    let unmappedEvents: [UnmappedActJournalEvent]
    let fieldMismatches: [ActJournalFeedFieldMismatch]
}

/// A read-only journal projection for the published-act family. Legacy rows
/// are supplied only as the comparison oracle; event entries are built from
/// persisted event evidence and current, exactly matched act metadata.
enum ActJournalFeedProjection {
    private struct ActKey: Hashable {
        let recordKey: String
        let actID: String
    }

    private struct EventReference {
        let record: LegacyFeedRecordInput
        let event: CaseEvent
    }

    private struct ProjectedEvent {
        let recordKey: String
        let eventID: String
        let actID: String
        let expectedLegacyID: String
        var entry: FeedEntry

        var key: ActKey { ActKey(recordKey: recordKey, actID: actID) }
    }

    private struct ValidationFailure: Error {
        let reason: ActJournalFeedUnmappedReason
        let actID: String?
    }

    static func project(
        records: [LegacyFeedRecordInput],
        journalsByRecordKey: [String: CaseEventJournal],
        today: Date,
        readIDs: Set<String>,
        knownIDs: Set<String>,
        legacyEntries: [FeedEntry]
    ) -> ActJournalFeedProjectionResult {
        let legacyActs = legacyEntries.filter { $0.kind == .act }
        let rawLegacyIDCounts = Dictionary(grouping: legacyEntries, by: \.id)
        var legacyByKey = [ActKey: [FeedEntry]]()
        for row in legacyActs {
            guard let actID = row.actID else { continue }
            legacyByKey[ActKey(recordKey: row.recordKey, actID: actID), default: []]
                .append(row)
        }

        let eventReferences = records.flatMap { record in
            (journalsByRecordKey[record.recordKey]?.events ?? [])
                .filter { $0.kind == .judicialActPublished }
                .map { EventReference(record: record, event: $0) }
        }
        let duplicateEventIDs = Set(Dictionary(grouping: eventReferences, by: { $0.event.id })
            .filter { $0.value.count > 1 }.keys)

        var unmappedEvents = [UnmappedActJournalEvent]()
        var blockedLegacyReasons = [ActKey: ActJournalFeedUnmappedReason]()
        var projected = [ProjectedEvent]()

        for reference in eventReferences {
            let record = reference.record
            let event = reference.event
            let sourceActID = event.evidence.occurrenceKey

            if event.id.isEmpty {
                recordFailure(.missingEventID, sourceActID)
                continue
            }
            if duplicateEventIDs.contains(event.id) {
                recordFailure(.duplicateEventID, sourceActID)
                continue
            }

            do {
                guard let sourceActID, !sourceActID.isEmpty else {
                    throw ValidationFailure(reason: .missingOccurrenceKey, actID: nil)
                }
                guard let sourceCardID = event.evidence.sourceCardID,
                      !sourceCardID.isEmpty else {
                    throw ValidationFailure(reason: .missingSourceCardID, actID: sourceActID)
                }
                guard let rawDate = event.evidence.dateRaw,
                      !rawDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationFailure(reason: .missingEvidenceDate, actID: sourceActID)
                }
                guard let evidenceDate = DateUtil.parse(rawDate) else {
                    throw ValidationFailure(reason: .invalidEvidenceDate, actID: sourceActID)
                }
                guard let evidenceLevel = event.evidence.instanceLevelRaw,
                      !evidenceLevel.isEmpty else {
                    throw ValidationFailure(reason: .missingEvidenceLevel, actID: sourceActID)
                }

                let matchingActs = record.acts.filter { $0.id == sourceActID }
                if matchingActs.count == 1, let currentDate = DateUtil.parse(matchingActs[0].date),
                   currentDate != evidenceDate {
                    throw ValidationFailure(reason: .dateConflict, actID: sourceActID)
                }
                let observedActs = record.snapshot?.actObservations?.filter {
                    $0.sourceActID == sourceActID
                } ?? []
                if observedActs.count == 1,
                   let observationDate = DateUtil.parse(observedActs[0].dateRaw),
                   observationDate != evidenceDate {
                    throw ValidationFailure(reason: .dateConflict, actID: sourceActID)
                }

                let diff = DateUtil.daysBetween(evidenceDate, today)
                guard diff >= 0 && diff <= 45 else { continue }

                guard matchingActs.count == 1, let act = matchingActs.first else {
                    throw ValidationFailure(
                        reason: matchingActs.isEmpty ? .missingCurrentAct : .duplicateCurrentAct,
                        actID: sourceActID)
                }
                guard let currentDate = DateUtil.parse(act.date) else {
                    throw ValidationFailure(reason: .invalidCurrentDate, actID: sourceActID)
                }
                guard currentDate == evidenceDate else {
                    throw ValidationFailure(reason: .dateConflict, actID: sourceActID)
                }

                let observations = record.snapshot?.actObservations?.filter {
                    $0.sourceActID == sourceActID
                } ?? []
                guard observations.count == 1, let observation = observations.first else {
                    throw ValidationFailure(
                        reason: observations.isEmpty ? .missingCurrentObservation
                            : .duplicateCurrentObservation,
                        actID: sourceActID)
                }
                guard let observationDate = DateUtil.parse(observation.dateRaw),
                      observationDate == evidenceDate else {
                    throw ValidationFailure(reason: .dateConflict, actID: sourceActID)
                }
                guard observation.levelRaw == evidenceLevel else {
                    throw ValidationFailure(reason: .levelConflict, actID: sourceActID)
                }
                guard observation.sourceCardID == sourceCardID else {
                    throw ValidationFailure(reason: .sourceConflict, actID: sourceActID)
                }

                let linkedOwners = record.instances.filter { $0.linkedActIDs.contains(act.id) }
                let ownerCandidates = linkedOwners.isEmpty && act.instanceLevel != .material
                    ? record.instances.filter { $0.level == act.instanceLevel }
                    : linkedOwners
                guard ownerCandidates.count == 1, let owner = ownerCandidates.first else {
                    throw ValidationFailure(
                        reason: ownerCandidates.isEmpty ? .missingCurrentOwner
                            : .ambiguousCurrentOwner,
                        actID: sourceActID)
                }
                guard owner.level.rawValue == evidenceLevel else {
                    throw ValidationFailure(reason: .levelConflict, actID: sourceActID)
                }
                guard let context = record.context,
                      let currentSourceID = CaseSnapshotSourceIdentity.sourceCardID(
                        for: owner, context: context) else {
                    throw ValidationFailure(reason: .missingCurrentOwner, actID: sourceActID)
                }
                guard currentSourceID == sourceCardID else {
                    throw ValidationFailure(reason: .sourceConflict, actID: sourceActID)
                }

                let exactOwner = linkedOwners.count == 1 ? linkedOwners[0] : nil
                let legacyID = AppRouter.feedID(
                    recordKey: record.recordKey, date: evidenceDate, time: "—", text: act.id)
                let sourceLevel = exactOwner?.level ?? act.instanceLevel
                let legacySourceCardID = exactOwner.flatMap { instance -> String? in
                    guard instance.level == .material,
                          let context = record.context,
                          let sourceID = CaseSnapshotSourceIdentity.sourceCardID(
                            for: instance, context: context),
                          record.materialInstance(forSourceCardID: sourceID) != nil else {
                        return nil
                    }
                    return sourceID
                }
                let expectedLegacyID = sourceLevel == .material
                    ? legacySourceCardID.map {
                        AppRouter.materialFeedID(legacyID: legacyID, sourceCardID: $0)
                    } ?? legacyID
                    : legacyID
                let previousRegistrationNumber = exactOwner.flatMap { instance -> String? in
                    guard instance.note == "Предыдущая регистрация" else { return nil }
                    return CaseNumberPresentation.secondary(
                        instance.caseNumber, distinctFrom: record.caseNumber)
                }
                let material = owner.level == .material
                    ? record.materialInstance(forSourceCardID: sourceCardID) : nil
                let instanceCaseNumber = previousRegistrationNumber
                    ?? (owner.level == .material
                        ? material.flatMap(MovementDerivation.materialNumber)
                        : AppRouter.actReviewNumber(
                            for: act, instances: record.instances,
                            baseCaseNumber: record.caseNumber))
                let entry = FeedEntry(
                    id: event.id, dayHead: nil, date: evidenceDate, time: "—",
                    recordKey: record.recordKey, caseNumber: record.caseNumber,
                    client: record.client, kind: .act,
                    text: "Опубликован судебный акт: \(act.title)", actID: sourceActID,
                    isUnread: record.unreadByCase,
                    instanceCaseNumber: instanceCaseNumber,
                    instanceLevel: sourceLevel,
                    sourceCardID: sourceLevel == .material ? legacySourceCardID : nil,
                    sourceInstanceID: exactOwner?.id ?? material?.id,
                    previousRegistrationNumber: previousRegistrationNumber)
                projected.append(ProjectedEvent(
                    recordKey: record.recordKey, eventID: event.id, actID: sourceActID,
                    expectedLegacyID: expectedLegacyID, entry: entry))
            } catch let failure as ValidationFailure {
                recordFailure(failure.reason, failure.actID)
            } catch {
                recordFailure(.missingCurrentAct, sourceActID)
            }

            func recordFailure(_ reason: ActJournalFeedUnmappedReason, _ actID: String?) {
                unmappedEvents.append(UnmappedActJournalEvent(
                    recordKey: record.recordKey, eventID: event.id,
                    sourceActID: actID, reason: reason))
                if let actID {
                    let key = ActKey(recordKey: record.recordKey, actID: actID)
                    blockedLegacyReasons[key] = reason
                }
            }
        }

        let projectedByKey = Dictionary(grouping: projected, by: \.key)
        var candidateAliases = [ActJournalFeedAlias]()
        var aliasFailureByKey = [ActKey: ActJournalFeedUnmappedReason]()

        for value in projected {
            let matchingEvents = projectedByKey[value.key] ?? []
            let matchingLegacy = legacyByKey[value.key] ?? []
            guard matchingEvents.count == 1 else {
                aliasFailureByKey[value.key] = .ambiguousEventForLegacyAct
                continue
            }
            guard matchingLegacy.count == 1, let legacy = matchingLegacy.first else {
                aliasFailureByKey[value.key] = matchingLegacy.isEmpty
                    ? .missingLegacyAct : .ambiguousLegacyAct
                continue
            }
            guard legacy.id == value.expectedLegacyID else {
                aliasFailureByKey[value.key] = .legacyIDMismatch
                continue
            }
            candidateAliases.append(.init(legacyID: legacy.id, eventID: value.eventID))
        }

        let candidateLegacyIDCounts = Dictionary(grouping: candidateAliases, by: \.legacyID)
        let eventIDCounts = Dictionary(grouping: candidateAliases, by: \.eventID)
        let aliases = candidateAliases.filter {
            rawLegacyIDCounts[$0.legacyID]?.count == 1
                && candidateLegacyIDCounts[$0.legacyID]?.count == 1
                && eventIDCounts[$0.eventID]?.count == 1
        }
        let acceptedEventIDs = Set(aliases.map(\.eventID))
        let acceptedLegacyIDs = Set(aliases.map(\.legacyID))
        let rejectedAliasKeys = Set(candidateAliases.filter {
            rawLegacyIDCounts[$0.legacyID]?.count != 1
                || candidateLegacyIDCounts[$0.legacyID]?.count != 1
                || eventIDCounts[$0.eventID]?.count != 1
        }.compactMap { alias in
            projected.first(where: { $0.eventID == alias.eventID })?.key
        })
        for key in rejectedAliasKeys { aliasFailureByKey[key] = .ambiguousAlias }

        var shadowReadIDs = Set<String>()
        var shadowKnownIDs = Set<String>()
        for alias in aliases {
            if readIDs.contains(alias.legacyID) { shadowReadIDs.insert(alias.eventID) }
            if knownIDs.contains(alias.legacyID) { shadowKnownIDs.insert(alias.eventID) }
        }

        var entries = projected.map(\.entry)
        for index in entries.indices where shadowReadIDs.contains(entries[index].id) {
            entries[index].isUnread = false
        }

        var fieldMismatches = [ActJournalFeedFieldMismatch]()
        for value in projected where acceptedEventIDs.contains(value.eventID) {
            guard let legacy = legacyByKey[value.key]?.first else { continue }
            guard let shadow = entries.first(where: { $0.id == value.eventID }) else { continue }
            fieldMismatches += JournalFeedComparison.mismatches(legacy, shadow)
                .map { field, legacyValue, shadowValue in
                    ActJournalFeedFieldMismatch(
                        recordKey: value.recordKey, legacyID: legacy.id,
                        eventID: value.eventID, field: field,
                        legacyValue: legacyValue, shadowValue: shadowValue)
                }
        }

        var unmappedLegacyActs = [UnmappedLegacyActFeedRow]()
        for legacy in legacyActs where !acceptedLegacyIDs.contains(legacy.id) {
            let reason: ActJournalFeedUnmappedReason
            if let actID = legacy.actID {
                let key = ActKey(recordKey: legacy.recordKey, actID: actID)
                if let blocked = blockedLegacyReasons[key] {
                    reason = blocked
                } else if rawLegacyIDCounts[legacy.id]?.count ?? 0 > 1 {
                    reason = .ambiguousAlias
                } else if let aliasFailure = aliasFailureByKey[key] {
                    reason = aliasFailure
                } else if (legacyByKey[key]?.count ?? 0) > 1 {
                    reason = .ambiguousLegacyAct
                } else {
                    reason = .noPublishedEvent
                }
            } else {
                reason = .missingLegacyActID
            }
            unmappedLegacyActs.append(UnmappedLegacyActFeedRow(
                recordKey: legacy.recordKey, legacyID: legacy.id,
                actID: legacy.actID, reason: reason))
        }

        for value in projected where !acceptedEventIDs.contains(value.eventID)
            && !unmappedEvents.contains(where: { $0.eventID == value.eventID }) {
            let reason = aliasFailureByKey[value.key] ?? .missingLegacyAct
            unmappedEvents.append(UnmappedActJournalEvent(
                recordKey: value.recordKey, eventID: value.eventID,
                sourceActID: value.actID, reason: reason))
        }

        return ActJournalFeedProjectionResult(
            entries: entries, aliases: aliases,
            shadowReadIDs: shadowReadIDs, shadowKnownIDs: shadowKnownIDs,
            unmappedLegacyActs: unmappedLegacyActs, unmappedEvents: unmappedEvents,
            fieldMismatches: fieldMismatches)
    }

}
