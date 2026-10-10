// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import SudrfKit

enum TreasuryEventJournal {
    static func additions(records: [EnforcementRecord], logicalCaseID: UUID,
                          journal: CaseEventJournal) -> [CaseEvent] {
        var known = Set(journal.events.compactMap(guid))
        var events: [CaseEvent] = []
        for record in records where record.source == .treasury {
            for item in record.events {
                guard let guid = clean(item.guid), known.insert(guid).inserted else { continue }
                events.append(CaseEvent.make(
                    kind: .treasuryRSSPublished,
                    occurrence: [logicalCaseID.uuidString.lowercased(), guid],
                    observedAt: record.lastSuccessAt ?? record.lastAttemptAt ?? item.date ?? .distantPast,
                    evidence: .init(dateRaw: item.dateRaw, event: item.text,
                                    rssGUID: guid,
                                    rssPublishedAtRef: item.date?.timeIntervalSinceReferenceDate)))
            }
        }
        return events
    }

    /// A proven dossier merge preserves one prior binding and every retired ID.
    static func merged(_ journals: [CaseEventJournal],
                       preferred: CaseEventJournal) throws -> CaseEventJournal {
        let grouped = Dictionary(grouping: journals.flatMap(\.events).filter { guid($0) != nil },
                                 by: { guid($0)! })
        let preferredIDs = Set(preferred.events.map(\.id))
        var combined = try CaseEventJournal.merged(journals.map { journal in
            var courtJournal = journal
            courtJournal.events.removeAll { guid($0) != nil }
            return courtJournal
        })
        for key in grouped.keys.sorted() {
            let candidates = grouped[key]!.sorted { left, right in
                if preferredIDs.contains(left.id) != preferredIDs.contains(right.id) {
                    return preferredIDs.contains(left.id)
                }
                if left.observedAtRef != right.observedAtRef {
                    return left.observedAtRef < right.observedAtRef
                }
                return left.id < right.id
            }
            let selected = candidates[0]
            var evidence = selected.evidence
            let aliases = Set(candidates.flatMap { [$0.id] + ($0.evidence.eventIDAliases ?? []) })
                .subtracting([selected.id]).sorted()
            evidence.eventIDAliases = aliases.isEmpty ? nil : aliases
            try combined.append([CaseEvent(id: selected.id, kind: selected.kind,
                observedAtRef: selected.observedAtRef, evidence: evidence,
                occurrence: selected.occurrence)])
        }
        return combined
    }

    static func legacyFeedIDs(recordKey: String, legacyKeys: [String],
                              event: CaseEvent) -> Set<String> {
        guard let guid = guid(event) else { return [] }
        return Set(([recordKey] + legacyKeys).map {
            AppRouter.enforcementFeedID(recordKey: $0, guid: guid)
        })
    }

    private static func guid(_ event: CaseEvent) -> String? {
        event.kind == .treasuryRSSPublished ? clean(event.evidence.rssGUID) : nil
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
