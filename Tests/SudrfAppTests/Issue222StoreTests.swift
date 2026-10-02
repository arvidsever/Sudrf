import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue222StoreTests: XCTestCase {
    private let today = DateUtil.parse("02.10.2026")!

    private func fixture() throws -> (MovementContext, CaseMovement) {
        let movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let first = try XCTUnwrap(movement.instances.first { $0.level == .first })
        let sourceURL = try XCTUnwrap(first.sourceURL)
        let query = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let context = MovementContext(branchRaw: "general", region: "Проверочный регион",
            searchDomain: first.domain, displayDomain: first.domain.replacingOccurrences(of: "--", with: "."),
            courtTitle: first.court, courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "district", caseNumber: movement.caseNumber,
            caseID: query.first { $0.name == "case_id" }?.value,
            caseUID: query.first { $0.name == "case_uid" }?.value,
            cardURLString: sourceURL.absoluteString, judicialUID: movement.uid)
        return (context, movement)
    }

    func testOwnedMaterialDeadlineKeepsItsSourceIdentityThroughPreparationAndDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue222-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracked.store")
        let (context, movement) = try fixture()
        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        let expected = try XCTUnwrap(snapshot.deadlines.first {
            MovementDerivation.deadlineScopeKey($0) != nil
        })
        let sourceCardID = try XCTUnwrap(MovementDerivation.deadlineScopeKey(expected))

        var recordKey = ""
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.reconcileAndUpsert(context: context, snapshot: snapshot,
                movement: movement, collections: ["Проверка #222"], movementFetchedAt: today)
            recordKey = record.key
            record.snapshot = snapshot
            try store.save()
            _ = try TrackedStorePreparation.prepare(context: container.mainContext, today: today)
            let prepared = try XCTUnwrap(store.record(forKey: record.key)?.snapshot)
            let stored = try XCTUnwrap(prepared.deadlines.first {
                MovementDerivation.deadlineScopeKey($0) == sourceCardID
            })

            XCTAssertEqual(stored.date, DateUtil.parse("05.11.2026"))
            XCTAssertEqual(stored.occurrenceKey, expected.occurrenceKey)
            XCTAssertEqual(store.record(forKey: record.key)?.collectionNames, ["Проверка #222"])
        }

        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        _ = try TrackedStorePreparation.prepare(context: reopenedContainer.mainContext, today: today)
        let record = try XCTUnwrap(reopened.record(forKey: recordKey))
        let stored = try XCTUnwrap(record.snapshot?.deadlines.first {
            MovementDerivation.deadlineScopeKey($0) == sourceCardID
        })

        XCTAssertEqual(stored.date, DateUtil.parse("05.11.2026"))
        XCTAssertEqual(stored.occurrenceKey, expected.occurrenceKey)
        XCTAssertEqual(record.collectionNames, ["Проверка #222"])
        XCTAssertEqual(record.movement?.instances.first { $0.caseNumber == "13-630/2026" }?.sessions.last?.result,
                       "Удовлетворено частично")
    }
    func testPreparationDoesNotAdmitNewVSRouteAndRefreshKeepsJournalAndSourceData() throws {
        let (context, movement) = try fixture()
        let fresh = MovementDerivation.snapshot(from: movement, context: context, today: today)
        let store = TrackedStore(inMemory: true)
        var old = fresh
        old.deadlines = []
        let record = try store.reconcileAndUpsert(context: context, snapshot: old,
            movement: movement, collections: ["Проверка #222"], movementFetchedAt: today)
        record.snapshot = old
        try store.save()
        let journal = record.eventJournal
        let fetchedAt = record.movementFetchedAt
        for _ in 0..<2 {
            _ = try TrackedStorePreparation.prepare(context: store.container.mainContext, today: today)
            XCTAssertTrue(record.snapshot?.deadlines.isEmpty == true)
            XCTAssertEqual(record.eventJournal, journal)
            XCTAssertEqual(record.movementFetchedAt, fetchedAt)
        }
        _ = try store.reconcileAndUpsert(context: context, snapshot: fresh,
            movement: movement, collections: ["Проверка #222"], movementFetchedAt: today)
        XCTAssertTrue(record.snapshot?.deadlines.contains { $0.date == DateUtil.parse("05.11.2026") } == true)
        XCTAssertEqual(record.eventJournal, journal)
        XCTAssertEqual(record.movement, movement)
        XCTAssertEqual(record.collectionNames, ["Проверка #222"])
    }

}
