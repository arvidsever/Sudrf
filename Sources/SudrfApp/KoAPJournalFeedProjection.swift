// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import SudrfKit

/// Diagnostic only: no feed, read/known mark or delivery migration.
enum KoAPJournalFeedProjection {
    struct Alias: Equatable {
        let recordKey: String
        let legacyID: String
        let eventID: String
    }
    struct Mismatch: Equatable {
        let alias: Alias
        let field: String
        let legacyValue: String?
        let shadowValue: String?
    }
    struct Result {
        let entries: [FeedEntry]
        let aliases: [Alias]
        let unmappedEvents: [String]
        let unmappedLegacyIDs: [String]
        let fieldMismatches: [Mismatch]
    }

    static func project(records: [LegacyFeedRecordInput],
                        journalsByRecordKey: [String: CaseEventJournal], today: Date,
                        readIDs: Set<String>, legacyEntries: [FeedEntry]) -> Result {
        let kinds: Set<CaseEventKind> = [.caseFileRequested, .requestedCaseReceived, .complaintReviewResult]
        let references = records.flatMap { record in
            (journalsByRecordKey[record.recordKey]?.events ?? []).filter { kinds.contains($0.kind) }
                .map { (record, $0) }
        }
        let eventCounts = Dictionary(grouping: references, by: { $0.1.id })
        // Invalid or stale persisted competitors still make ownership ambiguous.
        var occurrenceCounts = [String: [String: Int]]()
        for (record, event) in references {
            if let key = event.evidence.occurrenceKey, !key.isEmpty {
                occurrenceCounts[record.recordKey, default: [:]][key, default: 0] += 1
            }
        }
        // Count the entire raw feed before applying this family's date window.
        let legacyCounts = Dictionary(grouping: legacyEntries, by: \.id)
        var candidates: [(Alias, FeedEntry, FeedEntry)] = []
        var unmappedEvents = [String]()
        var currentLegacyIDs = Set<String>()
        for record in records {
            for session in record.snapshot?.sessions ?? [] {
                if CaseEventDeriver.complaintTimelineCandidate(session) != nil,
                   let date = session.date, inWindow(date, today),
                   let id = legacyID(record.recordKey, session) { currentLegacyIDs.insert(id) }
            }
        }
        for (record, event) in references {
            let evidence = event.evidence
            guard let date = evidence.dateRaw.flatMap(DateUtil.parse) else {
                unmappedEvents.append(event.id); continue
            }
            let currentInWindow = record.snapshot?.sessions.contains { session in
                CaseEventDeriver.complaintTimelineCandidate(session)?.key == evidence.occurrenceKey
                    && session.date.map { inWindow($0, today) } == true
            } == true
            guard inWindow(date, today) || currentInWindow else { continue }
            if let key = evidence.occurrenceKey, !key.isEmpty,
               occurrenceCounts[record.recordKey]?[key] != 1 {
                unmappedEvents.append(event.id); continue
            }
            guard !event.id.isEmpty, eventCounts[event.id]?.count == 1,
                  event.occurrence == nil || event.occurrence?.originRecordKey == record.recordKey,
                  let source = evidence.sourceCardID, let occurrence = evidence.occurrenceKey else {
                unmappedEvents.append(event.id); continue
            }
            let sessions = record.snapshot?.sessions ?? []
            let matching = sessions.filter {
                guard let candidate = CaseEventDeriver.complaintTimelineCandidate($0) else { return false }
                return candidate.key == occurrence && candidate.kind == event.kind
            }
            guard matching.count == 1, let session = matching.first,
                  evidence.sourceCardID == session.sourceCardID,
                  evidence.instanceLevelRaw == session.levelRaw,
                  evidence.caseNumber == session.caseNumber,
                  evidence.dateRaw == session.dateRaw, evidence.time == session.time,
                  evidence.event == session.event, evidence.value == session.result,
                  let candidate = CaseEventDeriver.complaintTimelineCandidate(session),
                  !sessions.contains(where: { other in
                      guard let value = CaseEventDeriver.complaintTimelineCandidate(other) else { return false }
                      return value.source == candidate.source && value.kind == candidate.kind
                          && value.dateKey == candidate.dateKey && value.resultKey != candidate.resultKey
                  }),
                  let context = record.context else {
                unmappedEvents.append(event.id); continue
            }
            let observations = record.snapshot?.instanceObservations?.filter { $0.sourceCardID == source } ?? []
            let owners = record.instances.filter {
                CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context) == source
            }
            guard observations.count == 1, let observation = observations.first,
                  owners.count == 1, let owner = owners.first,
                  owner.sourceURL.map({ url in
                      CartotekaRegistry.find(level: .cassation, id: "adm3").flatMap {
                          SourceNativeCardLocator.sudrf(url: url, cartoteka: $0)
                      }?.identity.id == source
                  }) != false,
                  !(session.caseNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  observation.levelRaw == session.levelRaw, owner.level == session.level,
                  SudrfHost.moduleHost(owner.domain.lowercased()) == source.split(separator: "|").dropFirst().first.map(String.init),
                  CaseNumberPresentation.primary(observation.caseNumber) == CaseNumberPresentation.primary(session.caseNumber ?? ""),
                  CaseNumberPresentation.primary(owner.caseNumber) == CaseNumberPresentation.primary(session.caseNumber ?? ""),
                  let id = legacyID(record.recordKey, session),
                  legacyCounts[id]?.count == 1, let legacy = legacyCounts[id]?.first,
                  legacy.recordKey == record.recordKey, legacy.sourceCardID == source,
                  legacy.instanceLevel == session.level, legacy.kind == AppRouter.feedKind(for: session),
                  legacy.actID == nil else {
                unmappedEvents.append(event.id); continue
            }
            let previous = record.previousRegistrationSource(session)
            let shadow = FeedEntry(id: event.id, dayHead: nil, date: date,
                time: session.time ?? "—", recordKey: record.recordKey,
                caseNumber: record.caseNumber, client: record.client,
                kind: AppRouter.feedKind(for: session), text: session.result ?? session.event,
                actID: nil, isUnread: record.unreadByCase && !readIDs.contains(id),
                instanceCaseNumber: previous?.number ?? session.caseNumber,
                instanceLevel: session.level, sourceCardID: source,
                sourceInstanceID: previous?.instance.id, previousRegistrationNumber: previous?.number)
            candidates.append((Alias(recordKey: record.recordKey, legacyID: id, eventID: event.id), legacy, shadow))
        }
        let aliasesByID = Dictionary(grouping: candidates, by: { $0.0.legacyID })
        let accepted = candidates.filter { aliasesByID[$0.0.legacyID]?.count == 1 }
        unmappedEvents += candidates.filter { aliasesByID[$0.0.legacyID]?.count != 1 }.map { $0.0.eventID }
        let acceptedIDs = Set(accepted.map { $0.0.legacyID })
        let mismatches = accepted.flatMap { alias, legacy, shadow in
            JournalFeedComparison.mismatches(legacy, shadow).map {
                Mismatch(alias: alias, field: $0.0, legacyValue: $0.1, shadowValue: $0.2)
            }
        }
        return Result(entries: accepted.map { $0.2 }, aliases: accepted.map { $0.0 },
                      unmappedEvents: unmappedEvents.sorted(),
                      unmappedLegacyIDs: currentLegacyIDs.subtracting(acceptedIDs).sorted(),
                      fieldMismatches: mismatches)
    }

    private static func inWindow(_ date: Date, _ today: Date) -> Bool {
        (0...45).contains(DateUtil.daysBetween(date, today))
    }
    private static func legacyID(_ recordKey: String, _ session: StoredSession) -> String? {
        guard let date = session.date else { return nil }
        return AppRouter.feedID(recordKey: recordKey, date: date,
                                time: session.time ?? "—", text: session.result ?? session.event)
    }
}
