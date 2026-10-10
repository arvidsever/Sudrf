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
    _ = assertSourceRowPublications(journal, file: file, line: line)
    return journal.events.filter {
        $0.kind != .legacyFeedImported && $0.kind != .sourceRowPublished
    }
}

/// Publication carriers prove admission of the raw source row without turning
/// that archived row into a semantic transition.
@discardableResult
func assertSourceRowPublications(
    _ journal: CaseEventJournal?, expectedCount: Int? = nil,
    notificationEligible: Bool? = nil,
    file: StaticString = #filePath, line: UInt = #line
) -> [CaseEvent]? {
    guard let journal else { return nil }
    let events = journal.events.filter { $0.kind == .sourceRowPublished }
    if let expectedCount {
        XCTAssertEqual(events.count, expectedCount, file: file, line: line)
    }
    for event in events {
        guard let binding = event.evidence.sourceRowBinding,
              let history = event.evidence.legacyFeedHistory else {
            XCTFail("source-row publication must retain its raw binding and source history",
                    file: file, line: line)
            continue
        }
        if let notificationEligible {
            XCTAssertEqual(binding.notificationEligible, notificationEligible, file: file, line: line)
        }
        XCTAssertFalse(binding.courtScope.isEmpty, file: file, line: line)
        XCTAssertFalse(binding.nativeCardID.isEmpty, file: file, line: line)
        XCTAssertFalse(binding.sourceCardID.isEmpty, file: file, line: line)
        XCTAssertFalse(binding.fingerprint.isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(binding.ordinal, 0, file: file, line: line)
        XCTAssertEqual(event.evidence.sourceCardID, binding.sourceCardID, file: file, line: line)
        if let historySourceCardID = history.sourceCardID {
            XCTAssertEqual(historySourceCardID, binding.sourceCardID, file: file, line: line)
        }
        XCTAssertFalse(history.originRecordKey.isEmpty, file: file, line: line)
        XCTAssertFalse(history.legacyID.isEmpty, file: file, line: line)
        XCTAssertFalse(history.text.isEmpty, file: file, line: line)
        switch history.source {
        case .session(let session):
            XCTAssertEqual(session.sourceCardID, binding.sourceCardID, file: file, line: line)
        case .act(let act):
            XCTAssertEqual(history.actID, act.id, file: file, line: line)
        }
    }
    return events
}

/// Initial publication carriers are retained quietly and keep their raw proof.
@discardableResult
func assertQuietSourceRowPublications(
    _ journal: CaseEventJournal?, expectedCount: Int? = nil,
    file: StaticString = #filePath, line: UInt = #line
) -> [CaseEvent]? {
    assertSourceRowPublications(journal, expectedCount: expectedCount,
                                notificationEligible: false, file: file, line: line)
}

func assertSemanticJournalEqual(_ actual: CaseEventJournal?, _ expected: CaseEventJournal?,
                                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(semanticJournalEvents(actual, file: file, line: line),
                   expected?.events, file: file, line: line)
    XCTAssertEqual(actual?.schemaVersion, expected?.schemaVersion, file: file, line: line)
    XCTAssertEqual(actual?.derivationVersion, expected?.derivationVersion, file: file, line: line)
    XCTAssertEqual(actual?.semanticBaselines, expected?.semanticBaselines, file: file, line: line)
}
