// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import CryptoKit
import Foundation
import SudrfKit

/// An immutable exact binding to the published source row, including multiplicity.
/// The legacy row ID and original source payload remain in legacyFeedHistory.
struct SourceRowBinding: Codable, Equatable, Sendable {
    let courtScope: String
    let nativeCardID: String
    let sourceCardID: String
    let fingerprint: String
    let ordinal: Int
    let notificationEligible: Bool
}

enum SourceRowPublication {
    static func events(rows: [LegacyFeedProjection.RawRow], snapshot: CaseSnapshot,
                       fresh: CaseEventCourtBaseline, old: CaseEventCourtBaseline?,
                       scope: String, journal: CaseEventJournal, logicalCaseID: UUID,
                       observedAt: Date) -> [CaseEvent] {
        // The first confirmed response also retains immutable history, quietly.
        // Cached/partial display rows never participate in this comparison.
        var old = old
        old?.reidentifyActs(using: fresh)
        var counts = [String: Int]()
        var additions = [CaseEvent]()
        let persisted = Set(journal.events.compactMap { $0.evidence.sourceRowBinding })
        for row in rows {
            guard let source = row.source else { continue }
            let owners: Set<String>
            let publication: [String]
            let priorCount: (String) -> Int
            switch source {
            case .session(let session):
                owners = Set([session.sourceCardID].compactMap { $0 })
                publication = sessionPublication(session)
                priorCount = { id in (old?.sessions ?? []).filter {
                    $0.sourceCardID == id && sessionPublication($0) == publication
                }.count }
            case .act(let act):
                owners = Set((snapshot.actObservations ?? []).filter {
                    $0.sourceActID == act.id
                }.compactMap(\.sourceCardID))
                publication = ["act", act.id, act.title, act.date]
                priorCount = { id in (old?.acts ?? []).filter {
                    $0.sourceCardID == id && $0.sourceActID == act.id
                        && $0.title == act.title && $0.dateRaw == act.date
                }.count }
            }
            guard owners.count == 1, let sourceID = owners.first else { continue }
            let nativeOwners = fresh.cards.filter { $0.value == sourceID }
            guard nativeOwners.count == 1, let nativeID = nativeOwners.first?.key else { continue }
            // A previously unprocessed card inside a merged dossier was seeded
            // by the baseline transition. No alert is inferred from that seed.
            let fingerprint = hash(publication)
            let countKey = nativeID + "|" + fingerprint
            let ordinal = counts[countKey, default: 0]
            counts[countKey] = ordinal + 1
            var alreadyHandled = priorCount(sourceID)
            if old == nil {
                // Initial history can replace only a proven same-origin/source
                // publication. A date/text collision alone is not a binding.
                alreadyHandled = journal.events.filter { event in
                    guard event.kind == .legacyFeedImported,
                          let history = event.evidence.legacyFeedHistory,
                          history.originRecordKey == row.entry.recordKey,
                          (history.sourceCardID ?? event.evidence.sourceCardID) == sourceID else { return false }
                    switch history.source {
                    case .session(let session): return sessionPublication(session) == publication
                    case .act(let act): return ["act", act.id, act.title, act.date] == publication
                    }
                }.count
            }
            guard ordinal >= alreadyHandled else { continue }
            let binding = SourceRowBinding(courtScope: scope, nativeCardID: nativeID,
                sourceCardID: sourceID, fingerprint: fingerprint, ordinal: ordinal,
                notificationEligible: old != nil)
            guard !persisted.contains(where: {
                canonicalNative($0.nativeCardID, aliases: journal.sourceRowContinuities ?? [:])
                    == canonicalNative(nativeID, aliases: journal.sourceRowContinuities ?? [:])
                    && $0.fingerprint == fingerprint && $0.ordinal == ordinal
            }) else { continue }
            var evidence = CaseEventEvidence()
            evidence.sourceCardID = sourceID
            evidence.sourceRowBinding = binding
            evidence.legacyFeedHistory = LegacyFeedHistoryEvidence(row.entry, source: source)
            additions.append(CaseEvent.make(kind: .sourceRowPublished,
                occurrence: ["source-row-v1", logicalCaseID.uuidString.lowercased(),
                             scope, nativeID, fingerprint, String(ordinal)],
                observedAt: observedAt, evidence: evidence))
        }
        return additions
    }

    static func mergingContinuities(_ values: [[String: String]]) throws -> [String: String] {
        var result = [String: String]()
        for value in values {
            for (old, new) in value where old != new {
                if let existing = result[old], existing != new {
                    throw CaseEventJournalError.conflictingEventID("source-row-continuity:" + old)
                }
                result[old] = new
            }
        }
        for key in result.keys {
            var visited = Set<String>()
            var current = key
            while let next = result[current] {
                guard visited.insert(current).inserted else {
                    throw CaseEventJournalError.conflictingEventID("source-row-continuity-cycle:" + key)
                }
                current = next
            }
        }
        return result
    }

    static func canonicalNative(_ id: String, aliases: [String: String]) -> String {
        var current = id
        var visited = Set<String>()
        while let next = aliases[current], visited.insert(current).inserted { current = next }
        return current
    }

    static func sessionPublication(_ session: StoredSession) -> [String] {
        ["session", session.dateRaw, session.time ?? "—",
         AppRouter.feedKind(for: session).rawValue, session.result ?? session.event,
         session.levelRaw, session.caseNumber ?? ""]
    }

    private static func hash(_ fields: [String]) -> String {
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension SourceRowBinding: Hashable {}
