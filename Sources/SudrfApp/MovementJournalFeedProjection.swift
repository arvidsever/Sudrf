// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import SudrfKit

/// Pure shadow for new undated events. No live feed or mark migration.
enum MovementJournalFeedProjection {
    struct Result {
        let entries: [FeedEntry]
        let knownIDs: Set<String>
        let unmappedEvents: [String]
    }

    static func project(records: [LegacyFeedRecordInput],
                        journalsByRecordKey: [String: CaseEventJournal], today: Date,
                        readIDs: Set<String>, knownIDs: Set<String>) -> Result {
        let kinds: Set<CaseEventKind> = [.judgeChanged, .instanceDiscovered, .resultChanged]
        let references = records.flatMap { record in
            (journalsByRecordKey[record.recordKey]?.events ?? [])
                .filter { kinds.contains($0.kind) }.map { (record, $0) }
        }
        let counts = Dictionary(grouping: references, by: { $0.1.id })
        let originOwners = Dictionary(grouping: records.flatMap { record in
            record.recordKeyAliases.union([record.recordKey]).map { ($0, record.recordKey) }
        }, by: { $0.0 })
        var entries = [FeedEntry]()
        var unmapped = [String]()
        for (record, event) in references {
            guard event.observedAtRef.isFinite else { unmapped.append(event.id); continue }
            let date = Date(timeIntervalSinceReferenceDate: event.observedAtRef)
            guard (0...45).contains(DateUtil.daysBetween(date, today)) else { continue }
            let evidence = event.evidence
            let ownsOrigin = event.occurrence.map {
                ($0.originRecordKey == record.recordKey || record.canUseRecordKeyAliases
                    && record.recordKeyAliases.contains($0.originRecordKey))
                    && originOwners[$0.originRecordKey]?.map(\.1) == [record.recordKey]
            } ?? true
            guard !event.id.isEmpty, counts[event.id]?.count == 1,
                  ownsOrigin,
                  let context = record.context, let source = evidence.sourceCardID,
                  let levelRaw = evidence.instanceLevelRaw,
                  let level = CaseInstance.Level(rawValue: levelRaw) else {
                unmapped.append(event.id); continue
            }
            let owners = record.instances.filter {
                CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context) == source
            }
            guard owners.count == 1, let owner = owners.first, owner.level == level,
                  let number = evidence.caseNumber,
                  CaseNumberPresentation.primary(number) == CaseNumberPresentation.primary(owner.caseNumber),
                  let text = text(event, owner: owner) else {
                unmapped.append(event.id); continue
            }
            entries.append(FeedEntry(id: event.id, dayHead: nil, date: date, time: "—",
                recordKey: record.recordKey, caseNumber: record.caseNumber, client: record.client,
                kind: .movement, text: text, actID: nil,
                isUnread: record.unreadByCase && !readIDs.contains(event.id),
                instanceCaseNumber: number, instanceLevel: level, sourceCardID: source,
                sourceInstanceID: level == .material ? owner.id : nil))
        }
        entries.sort { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        return Result(entries: entries, knownIDs: knownIDs.intersection(entries.map(\.id)),
                      unmappedEvents: unmapped.sorted())
    }

    private static func text(_ event: CaseEvent, owner: CaseInstance) -> String? {
        func published(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        switch event.kind {
        case .judgeChanged:
            guard let value = published(event.evidence.value) else { return nil }
            let change = published(event.evidence.previousValue).map { "\($0) → \(value)" } ?? value
            return "Сменился судья: \(change)"
        case .resultChanged:
            guard let value = published(event.evidence.value) else { return nil }
            let change = published(event.evidence.previousValue).map { "«\($0)» → «\(value)»" } ?? "«\(value)»"
            return "Изменился результат: \(change)"
        case .instanceDiscovered:
            let parts = [published(event.evidence.caseNumber).map { "№ \($0)" }, published(owner.court)].compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            return "Новое производство: " + parts.joined(separator: " · ")
        default: return nil
        }
    }
}
