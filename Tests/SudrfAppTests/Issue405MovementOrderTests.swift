import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue405MovementOrderTests: XCTestCase {
    private func instance(_ level: CaseInstance.Level, _ number: String,
                          _ date: String) -> CaseInstance {
        CaseInstance(level: level, court: "Синтетический суд", caseNumber: number,
                     judge: nil, domain: "fixture.sudrf.ru", foundByUID: false,
                     result: "Удовлетворено", sessions: date.isEmpty ? [] : [
                        CaseSession(date: date, event: "Рассмотрение", result: "Удовлетворено")])
    }

    private func movement(_ instances: [CaseInstance], number: String = "3/12-129/2022") -> CaseMovement {
        CaseMovement(uid: "", caseNumber: number, inForce: true,
                     instances: instances, complaints: [:], acts: [])
    }

    func testRootMaterialStartsExistingChainWithoutDuplication() {
        var root = instance(.material, "3/12-129/2022", "31.03.2022")
        root.sessions.append(CaseSession(date: "20.04.2022", event: "Материалы сданы"))
        let appeal = instance(.appeal, "22К-1467/2022", "10.06.2022")
        let cassation = instance(.cassation, "7У-5605/2022", "18.07.2022")
        for instances in [[root], [appeal, root], [cassation, root, appeal], [appeal, cassation, root]] {
            let value = movement(instances)
            let before = value
            let main = CaseMovementView.activeInstances(in: value)
            XCTAssertEqual(main.first?.id, root.id)
            XCTAssertEqual(main.map(\.id), [root, appeal, cassation].filter { candidate in
                instances.contains { $0.id == candidate.id }
            }.map(\.id))
            XCTAssertTrue(CaseMovementView.materialInstances(in: value).isEmpty)
            XCTAssertEqual(value, before)
            XCTAssertEqual(main.first?.level, .material)
        }
    }

    func testNestedAndAmbiguousMaterialsRemainSeparate() {
        let root = instance(.material, "3/12-129/2022", "31.03.2022")
        let nested = instance(.material, "3/12-130/2022", "01.04.2022")
        let appeal = instance(.appeal, "22К-1467/2022", "10.06.2022")
        let value = movement([appeal, nested, root])
        XCTAssertEqual(CaseMovementView.activeInstances(in: value).map(\.id), [root.id, appeal.id])
        XCTAssertEqual(CaseMovementView.materialInstances(in: value), [nested])

        var conflictingRoot = root
        conflictingRoot.domain = "other.sudrf.ru"
        let ambiguous = movement([appeal, root, conflictingRoot])
        XCTAssertEqual(CaseMovementView.activeInstances(in: ambiguous), [appeal])
        XCTAssertEqual(CaseMovementView.materialInstances(in: ambiguous).count, 2)

        let main = instance(.first, "1-129/2022", "01.03.2022")
        let ordinary = movement([appeal, root, main], number: main.caseNumber)
        XCTAssertEqual(CaseMovementView.activeInstances(in: ordinary).map(\.id), [main.id, appeal.id])
        XCTAssertEqual(CaseMovementView.materialInstances(in: ordinary), [root])
    }

    func testUndatedRootAndDatedNewRoundUseDistinctOrdering() {
        let undated = instance(.material, "3/12-129/2022", "")
        let appeal = instance(.appeal, "22К-1467/2022", "10.06.2022")
        XCTAssertEqual(CaseMovementView.activeInstances(in: movement([appeal, undated])), [undated, appeal])

        let earlier = instance(.material, "3/12-128/2022", "31.03.2022")
        var previous = earlier
        previous.note = "Предыдущая регистрация"
        var root = instance(.material, "3/12-129/2022", "01.07.2022")
        root.sessions.append(CaseSession(date: "01.12.2022", event: "Материалы сданы"))
        let cassation = instance(.cassation, "7У-5605/2022", "18.07.2022")
        XCTAssertEqual(CaseMovementView.activeInstances(in: movement([root, cassation, previous, appeal])),
                       [previous, appeal, root, cassation])
    }

    func testStoredMovementReopensWithSameSectionsAndUnchangedUserData() throws {
        let root = instance(.material, "3/12-129/2022", "31.03.2022")
        let appeal = instance(.appeal, "22К-1467/2022", "10.06.2022")
        let value = movement([appeal, root])
        var partial = value
        partial.instances = [appeal]
        partial.incompleteHigherCourtDomains = [root.domain]
        let merged = MovementCachePolicy.merge(fresh: partial, cached: value)
        XCTAssertEqual(CaseMovementView.activeInstances(in: merged).map(\.id), [root.id, appeal.id])
        XCTAssertEqual(merged.instances.first { $0.id == root.id }, root)
        XCTAssertTrue(CaseMovementView.materialInstances(in: merged).isEmpty)
        let context = MovementContext(branchRaw: CourtBranch.general.rawValue, region: "Синтетический регион",
            searchDomain: root.domain, displayDomain: root.domain, courtTitle: root.court,
            courtLevelRaw: CourtLevel.district.rawValue, cartotekaId: "m",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: root.caseNumber)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("issue405-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let today = DateUtil.parse("07.10.2026")!
        var key = ""
        var bytes = Data()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let store = try TrackedStore(container: SudrfModelContainerFactory.make(inMemory: false, storeURL: url), prepared: true)
            let record = try store.upsert(context: context,
                snapshot: MovementDerivation.snapshot(from: value, context: context, today: today),
                movement: value, collections: ["Синтетическая подборка"])
            record.seenAt = stamp
            record.movementFetchedAt = stamp
            try store.save()
            key = record.key
            bytes = try XCTUnwrap(record.movementData)
        }
        let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(inMemory: false, storeURL: url), prepared: true)
        let record = try XCTUnwrap(reopened.record(forKey: key))
        let cached = try XCTUnwrap(record.movement)
        for _ in 0..<2 {
            XCTAssertEqual(CaseMovementView.activeInstances(in: cached).map(\.id), [root.id, appeal.id])
            XCTAssertTrue(CaseMovementView.materialInstances(in: cached).isEmpty)
        }
        XCTAssertEqual(record.movementData, bytes)
        XCTAssertEqual(cached, value)
        XCTAssertEqual(record.seenAt, stamp)
        XCTAssertEqual(record.movementFetchedAt, stamp)
        XCTAssertEqual(record.collectionNames, ["Синтетическая подборка"])
        XCTAssertTrue(MovementDerivation.hasSameRefreshSource(cached, value))
    }
}
