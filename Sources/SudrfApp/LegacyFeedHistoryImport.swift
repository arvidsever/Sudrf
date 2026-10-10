// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import CryptoKit
import Foundation
import SudrfKit

enum LegacyFeedHistorySource: Codable, Equatable, Sendable {
    case session(StoredSession)
    case act(CaseAct)
}

/// Published history, not a reconstructed semantic transition or delivery receipt.
struct LegacyFeedHistoryEvidence: Codable, Equatable, Sendable {
    let originRecordKey: String
    let legacyID: String
    let publishedAtRef: Double
    let time: String
    let kindRaw: String
    let text: String
    let actID: String?
    let instanceCaseNumber: String?
    let instanceLevelRaw: String
    let sourceCardID: String?
    let sourceInstanceID: String?
    let previousRegistrationNumber: String?
    let source: LegacyFeedHistorySource

    init(_ entry: FeedEntry, source: LegacyFeedHistorySource) {
        originRecordKey = entry.recordKey
        legacyID = entry.id
        publishedAtRef = entry.date.timeIntervalSinceReferenceDate
        time = entry.time
        kindRaw = entry.kind.rawValue
        text = entry.text
        actID = entry.actID
        instanceCaseNumber = entry.instanceCaseNumber
        instanceLevelRaw = entry.instanceLevel.rawValue
        sourceCardID = entry.sourceCardID
        sourceInstanceID = entry.sourceInstanceID
        previousRegistrationNumber = entry.previousRegistrationNumber
        self.source = source
    }
}

enum LegacyFeedHistoryImportError: Error {
    case incompleteOriginHistory
    case missingSource
}

enum LegacyFeedHistoryImport {
    static let currentVersion = 1

    static func journal(record: LegacyFeedRecordInput, logicalCaseID: UUID,
                        existing: CaseEventJournal, importedAt: Date) throws -> CaseEventJournal {
        guard existing.legacyFeedImportVersion == nil else { return existing }
        guard !existing.events.contains(where: { $0.kind == .legacyFeedImported }) else {
            // A mixed merged journal cannot recover the original unimported records.
            throw LegacyFeedHistoryImportError.incompleteOriginHistory
        }
        var journal = existing
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var duplicateCounts = [String: Int]()
        let additions = try LegacyFeedProjection.rawRows(records: [record], readIDs: [])
            .filter { $0.entry.kind != .enforcement }
            .map { row in
                guard let source = row.source else { throw LegacyFeedHistoryImportError.missingSource }
                let history = LegacyFeedHistoryEvidence(row.entry, source: source)
                let fingerprint = SHA256.hash(data: try encoder.encode(history))
                    .map { String(format: "%02x", $0) }.joined()
                let ordinal = duplicateCounts[fingerprint, default: 0]
                duplicateCounts[fingerprint] = ordinal + 1
                var evidence = CaseEventEvidence()
                evidence.legacyFeedHistory = history
                // Distinct payloads and repeated rows survive legacy-ID collisions.
                return CaseEvent.make(kind: .legacyFeedImported,
                    occurrence: ["legacy-feed-import-v1", logicalCaseID.uuidString.lowercased(),
                                 record.recordKey, row.entry.id, fingerprint, String(ordinal)],
                    observedAt: importedAt, evidence: evidence)
            }
        try journal.append(additions)
        journal.legacyFeedImportVersion = currentVersion
        return journal
    }
}
