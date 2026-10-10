// © 2026 Воробьёв Виктор Викторович. SPDX-License-Identifier: CC-BY-NC-ND-4.0
import XCTest
@testable import SudrfApp

/// Compatibility oracles distinguish new semantic transitions from quietly retained
/// published history. Full-journal/byte equality after import remains a separate oracle.
func semanticJournalEvents(_ journal: CaseEventJournal?,
                           file: StaticString = #filePath, line: UInt = #line) -> [CaseEvent]? {
    guard let journal else { return nil }
    let history = journal.events.filter { $0.kind == .legacyFeedImported }
    if !history.isEmpty {
        XCTAssertEqual(journal.legacyFeedImportVersion, 1, "quiet history has an import receipt", file: file, line: line)
        XCTAssertEqual(Set(history.map(\.id)).count, history.count, "quiet history has distinct persistent IDs", file: file, line: line)
        for event in history {
            guard let evidence = event.evidence.legacyFeedHistory else {
                XCTFail("quiet history must retain its original published source", file: file, line: line)
                continue
            }
            XCTAssertFalse(evidence.originRecordKey.isEmpty, file: file, line: line)
            XCTAssertFalse(evidence.legacyID.isEmpty, file: file, line: line)
            XCTAssertFalse(evidence.text.isEmpty, file: file, line: line)
            XCTAssertNil(event.occurrence, "import is not a newly observed semantic occurrence", file: file, line: line)
            switch evidence.source {
            case .act(let act):
                XCTAssertEqual(evidence.actID, act.id, file: file, line: line)
            case .session:
                XCTAssertNil(evidence.actID, file: file, line: line)
            }
        }
    }
    return journal.events.filter { $0.kind != .legacyFeedImported }
}

func assertSemanticJournalEqual(_ actual: CaseEventJournal?, _ expected: CaseEventJournal?,
                                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(semanticJournalEvents(actual, file: file, line: line),
                   expected?.events, file: file, line: line)
    XCTAssertEqual(actual?.schemaVersion, expected?.schemaVersion, file: file, line: line)
    XCTAssertEqual(actual?.derivationVersion, expected?.derivationVersion, file: file, line: line)
    XCTAssertEqual(actual?.semanticBaselines, expected?.semanticBaselines, file: file, line: line)
}
