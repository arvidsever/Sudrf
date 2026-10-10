// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class MovementJournalFeedProjectionTests: XCTestCase {
    private let today = DateUtil.parse("10.06.2027")!

    func testAcceptedTextsUsePublishedValuesAndDetectionDateWithoutExtraLine() throws {
        let f = fixture()
        let events = [event(.judgeChanged, f, previous: "Иванов И.И.", value: "Петров П.П."),
                      event(.instanceDiscovered, f),
                      event(.resultChanged, f, previous: "Иск удовлетворён", value: "Иск удовлетворён частично")]
        let result = project(f, events)
        XCTAssertEqual(Set(result.entries.map(\.text)), [
            "Сменился судья: Иванов И.И. → Петров П.П.",
            "Новое производство: № 33-300/2026 · Тестовый областной суд",
            "Изменился результат: «Иск удовлетворён» → «Иск удовлетворён частично»"])
        XCTAssertTrue(result.entries.allSatisfy { $0.date == today && $0.time == "—" && $0.kind == .movement && $0.dayHead == nil && $0.actID == nil })
        XCTAssertTrue(result.unmappedEvents.isEmpty)
    }

    func testLaterOwnerValuesDoNotRewriteHistoricalPublishedTransition() {
        let f = fixture(judge: "Сидоров С.С.", result: "Дело прекращено")
        let result = project(f, [
            event(.judgeChanged, f, previous: "Иванов И.И.", value: "Петров П.П."),
            event(.resultChanged, f, previous: "Иск удовлетворён", value: "Иск удовлетворён частично")])
        XCTAssertEqual(Set(result.entries.map(\.text)), [
            "Сменился судья: Иванов И.И. → Петров П.П.",
            "Изменился результат: «Иск удовлетворён» → «Иск удовлетворён частично»"])
        XCTAssertTrue(result.unmappedEvents.isEmpty)
    }

    func testPublishedEvidenceDateDoesNotReplaceDetectionDateAndExisting7DayFilterApplies() {
        let f = fixture()
        let events = [-1, 0, 6, 7, 44, 45, 46].map { day in
            event(.judgeChanged, f, value: "Судья \(day)", daysAgo: day)
        }
        let result = project(f, events)
        XCTAssertEqual(Set(result.entries.map(\.id)), Set(events.filter {
            (0...45).contains(DateUtil.daysBetween(Date(timeIntervalSinceReferenceDate: $0.observedAtRef), today))
        }.map(\.id)))
        let recent = AppRouter.recentFeedEntries(result.entries, today: today, days: 7)
        XCTAssertEqual(Set(recent.map(\.text)), ["Сменился судья: Судья 0", "Сменился судья: Судья 6"])
        XCTAssertEqual(AppRouter.recentFeedEntries(result.entries, today: today, days: 45).count, 4)
    }

    func testMaterialUsesExistingSubtitleAndExactSourceNavigation() throws {
        let f = fixture(material: true)
        let row = try XCTUnwrap(project(f, [event(.instanceDiscovered, f)]).entries.first)
        XCTAssertEqual(row.secondaryLabel, "Материал № 13-300/2026")
        XCTAssertEqual(row.instanceLevel, .material)
        XCTAssertEqual(row.sourceCardID, f.source)
        XCTAssertEqual(row.sourceInstanceID, f.owner.id)
        XCTAssertEqual(row.caseNumber, f.input.caseNumber)
        XCTAssertEqual(row.text, "Новое производство: № 13-300/2026 · Тестовый областной суд")
    }

    func testMissingValuesAreNotInventedAndForeignSourcesFailClosed() {
        let f = fixture()
        XCTAssertTrue(project(f, [event(.judgeChanged, f), event(.resultChanged, f)]).entries.isEmpty)
        let single = project(f, [event(.resultChanged, f, value: "Оставлено без изменения")])
        XCTAssertEqual(single.entries.first?.text, "Изменился результат: «Оставлено без изменения»")
        let good = event(.instanceDiscovered, f)
        var evidence = good.evidence
        evidence.sourceCardID = "foreign-card"
        let foreign = CaseEvent(id: "foreign", kind: good.kind, observedAtRef: good.observedAtRef, evidence: evidence)
        XCTAssertTrue(project(f, [foreign]).entries.isEmpty)
        XCTAssertEqual(project(f, [foreign]).unmappedEvents, ["foreign"])
    }

    func testDuplicateIDsAndForeignOccurrenceDoNotBorrowOwners() {
        let f = fixture()
        let raw = event(.judgeChanged, f, previous: "А", value: "Б")
        XCTAssertTrue(project(f, [raw, raw]).entries.isEmpty)
        let foreign = CaseEventJournal().identifyingOccurrences([raw], originKey: "another-record")
        XCTAssertTrue(project(f, foreign).entries.isEmpty)
    }

    func testReadAndKnownMarksUseEventIDIndependentlyWithoutMutation() {
        let f = fixture()
        let event = event(.judgeChanged, f, previous: "А", value: "Б")
        for read in [false, true] {
            for known in [false, true] {
                let result = project(f, [event], read: read ? [event.id] : [], known: known ? [event.id] : [])
                XCTAssertEqual(result.entries.first?.isUnread, !read)
                XCTAssertEqual(result.knownIDs.contains(event.id), known)
            }
        }
    }

    func testProvenRetiredKeyKeepsImmutableOccurrenceAndMarksAfterReopen() throws {
        let f = fixture(aliases: ["retired-record"])
        let raw = event(.judgeChanged, f, previous: "А", value: "Б")
        let events = CaseEventJournal().identifyingOccurrences([raw], originKey: "retired-record")
        let journal = CaseEventJournal(events: events)
        let data = try JSONEncoder().encode(journal)
        let reopened = try JSONDecoder().decode(CaseEventJournal.self, from: data)
        let ids = Set(events.map(\.id))
        let result = project(f, reopened.events, read: ids, known: ids)
        XCTAssertEqual(result.entries.map(\.id), events.map(\.id))
        XCTAssertEqual(result.entries.first?.recordKey, f.input.recordKey)
        XCTAssertEqual(result.entries.first?.isUnread, false)
        XCTAssertEqual(result.knownIDs, ids)
        XCTAssertTrue(result.unmappedEvents.isEmpty)
        XCTAssertEqual(reopened, journal)
    }

    func testRetiredKeyWithTwoSurvivingOwnersIsNotBorrowed() {
        let f = fixture(aliases: ["retired-record"])
        let other = fixture(recordKey: "other-survivor", aliases: ["retired-record"])
        let raw = event(.judgeChanged, f, previous: "А", value: "Б")
        let events = CaseEventJournal().identifyingOccurrences([raw], originKey: "retired-record")
        let result = MovementJournalFeedProjection.project(records: [f.input, other.input],
            journalsByRecordKey: [f.input.recordKey: .init(events: events)], today: today,
            readIDs: [], knownIDs: [])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.unmappedEvents, events.map(\.id))
    }

    func testStillExistingOriginOwnerBlocksRetiredAlias() {
        let f = fixture(aliases: ["still-existing"])
        let other = fixture(recordKey: "still-existing")
        let events = CaseEventJournal().identifyingOccurrences(
            [event(.judgeChanged, f, previous: "А", value: "Б")], originKey: "still-existing")
        let result = MovementJournalFeedProjection.project(records: [f.input, other.input],
            journalsByRecordKey: [f.input.recordKey: .init(events: events)], today: today,
            readIDs: [], knownIDs: [])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.unmappedEvents, events.map(\.id))
    }

    func testUnvalidatedAliasCannotAdmitHistoryButStillBlocksAnotherOwner() {
        let f = fixture(aliases: ["retired-record"])
        let unvalidated = fixture(recordKey: "invalid-survivor", aliases: ["retired-record"],
                                  canUseAliases: false)
        let events = CaseEventJournal().identifyingOccurrences(
            [event(.judgeChanged, f, previous: "А", value: "Б")], originKey: "retired-record")
        XCTAssertTrue(project(unvalidated, events).entries.isEmpty)
        let result = MovementJournalFeedProjection.project(records: [f.input, unvalidated.input],
            journalsByRecordKey: [f.input.recordKey: .init(events: events)], today: today,
            readIDs: [], knownIDs: [])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.unmappedEvents, events.map(\.id))
    }

    func testRetiredKeyDoesNotOverrideExactSourceOrInferUnlistedKeys() {
        let f = fixture(aliases: ["retired-record"])
        let raw = event(.judgeChanged, f, previous: "А", value: "Б")
        let unlisted = CaseEventJournal().identifyingOccurrences([raw], originKey: "other-survivor")
        XCTAssertTrue(project(f, unlisted).entries.isEmpty)
        var evidence = raw.evidence
        evidence.sourceCardID = "another-source"
        let foreign = CaseEvent(id: raw.id, kind: raw.kind,
            observedAtRef: raw.observedAtRef, evidence: evidence)
        let retired = CaseEventJournal().identifyingOccurrences([foreign], originKey: "retired-record")
        XCTAssertTrue(project(f, retired).entries.isEmpty)
        XCTAssertEqual(project(f, retired).unmappedEvents, retired.map(\.id))
    }

    func testRepeatedTransitionDistinctIDsAndReadStateSurviveJournalFileReopen() throws {
        let f = fixture()
        var journal = CaseEventJournal()
        let first = event(.judgeChanged, f, previous: "А", value: "Б")
        let initial = journal.identifyingOccurrences([first], originKey: f.input.recordKey)
        XCTAssertEqual(initial, journal.identifyingOccurrences([first], originKey: f.input.recordKey))
        try journal.append(initial)
        let reverse = journal.identifyingOccurrences([event(.judgeChanged, f, previous: "Б", value: "А")], originKey: f.input.recordKey)
        try journal.append(reverse)
        let repeatChange = journal.identifyingOccurrences([first], originKey: f.input.recordKey)
        try journal.append(repeatChange)
        XCTAssertEqual(Set(journal.events.map(\.id)).count, 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("issue179-movement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url)
        let reopened = try JSONDecoder().decode(CaseEventJournal.self, from: Data(contentsOf: url))
        let read = Set(initial.map(\.id))
        let result = project(f, reopened.events, read: read, known: read)
        XCTAssertEqual(Set(result.entries.map(\.id)), Set(journal.events.map(\.id)))
        XCTAssertEqual(result.entries.filter { !$0.isUnread }.map(\.id), initial.map(\.id))
        XCTAssertEqual(result.knownIDs, read)
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(reopened, journal)
    }

    private struct Fixture {
        let input: LegacyFeedRecordInput
        let owner: CaseInstance
        let source: String
    }
    private func fixture(material: Bool = false, judge: String = "Петров П.П.",
                         result: String = "Иск удовлетворён частично", recordKey: String? = nil,
                         aliases: Set<String> = [], canUseAliases: Bool = true) -> Fixture {
        let context = MovementContext(branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Учебный городской суд", courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "district", caseNumber: "2-1/2026", caseID: "100")
        let owner = CaseInstance(level: material ? .material : .appeal,
            court: "Тестовый областной суд", caseNumber: material ? "13-300/2026" : "33-300/2026",
            judge: judge, domain: "komi.sudrf.ru", foundByUID: false,
            result: result, sessions: [],
            sourceURL: URL(string: "https://komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=300&delo_id=1540005"))
        let snapshot = CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
            leadCharges: nil, secondPartyLine: nil, stageRaw: "appeal", stageTag: "апелляция",
            statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "", nextChipRaw: "gray",
            steps: [], sessions: [], deadlines: [])
        let movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [owner], complaints: [:], acts: [])
        let input = LegacyFeedRecordInput(recordKey: recordKey ?? context.key, caseNumber: context.caseNumber,
            client: "Учебное дело", unreadByCase: true, snapshot: snapshot,
            movement: movement, context: context, enforcementRecords: [], recordKeyAliases: aliases,
            canUseRecordKeyAliases: canUseAliases)
        return Fixture(input: input, owner: owner,
            source: CaseSnapshotSourceIdentity.sourceCardID(for: owner, context: context)!)
    }
    private func event(_ kind: CaseEventKind, _ f: Fixture, previous: String? = nil,
                       value: String? = nil, daysAgo: Int = 0) -> CaseEvent {
        CaseEvent.make(kind: kind, occurrence: [f.source, previous ?? "", value ?? "", String(daysAgo)],
            observedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!,
            evidence: .init(sourceCardID: f.source, instanceLevelRaw: f.owner.level.rawValue,
                caseNumber: f.owner.caseNumber, dateRaw: "01.01.2020",
                previousValue: previous, value: value))
    }
    private func project(_ f: Fixture, _ events: [CaseEvent], read: Set<String> = [],
                         known: Set<String> = []) -> MovementJournalFeedProjection.Result {
        MovementJournalFeedProjection.project(records: [f.input],
            journalsByRecordKey: [f.input.recordKey: .init(events: events)], today: today,
            readIDs: read, knownIDs: known)
    }
}
