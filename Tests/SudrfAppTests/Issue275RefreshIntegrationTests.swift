import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue275FixtureClient: CaseProviding {
    let html: String
    let responseURL: URL

    init(html: String, responseURL: URL) {
        self.html = html
        self.responseURL = responseURL
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        []
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        try CaseCardParser.parse(html: html, cardURL: responseURL)
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        try CaseCardParser.parse(html: html, cardURL: responseURL)
    }
}

private actor Issue275Movements: MovementProviding {
    let parsed: MovementService
    private(set) var requestedNumbers: [String] = []

    init(parsed: MovementService) { self.parsed = parsed }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        requestedNumbers.append(base.caseNumber)
        if requestedNumbers.count == 3 {
            throw SudrfError.caseCardTemporarilyUnavailable
        }
        var movement = try await parsed.movement(
            for: base, court: court, cartoteka: cartoteka)
        if requestedNumbers.count == 2 {
            movement.incompleteHigherCourtDomains = ["unrelated.sudrf.ru"]
        }
        return movement
    }

    func requests() -> [String] { requestedNumbers }
}

@MainActor
final class Issue275RefreshIntegrationTests: XCTestCase {
    private let result = "возвращено - кассационные жалоба, представление поданы с нарушением "
        + "правил подсудности, установленных ст.377 настоящего Кодекса"

    func testReturnedComplaintRefreshIsCompletedWithoutFalseEventAndSurvivesFailuresAndReopen()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-275-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = try context()
        let parsed = try fixtureService(context: context)
        let full = try await parsed.movement(
            for: context.baseResult, court: context.searchCourt,
            cartoteka: try XCTUnwrap(context.cartoteka))

        XCTAssertEqual(full.uid, "")
        XCTAssertEqual(full.instances.first?.sessions.map(\.date), [
            "09.10.2019", "09.10.2019", "10.10.2019", "15.10.2019",
        ])
        XCTAssertEqual(full.instances.first?.sessions.last?.result, result)

        var stale = MovementDerivation.snapshot(from: full, context: context)
        stale.stageRaw = CaseStageKind.cassation.rawValue
        stale.stageTag = "Кассация"
        stale.statusText = "В производстве"
        stale.steps = ["todo", "todo", "active", "todo"]
        let record = try store.upsert(
            context: context, snapshot: stale, movement: full, collections: ["Гражданские"])
        let seenAt = Date(timeIntervalSinceReferenceDate: 2)
        record.seenAt = seenAt
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-275-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let service = Issue275Movements(parsed: try fixtureService(context: context))
        let center = RefreshCenter(
            store: store, client: SudrfClient(), serviceBuilder: { _ in service })

        let refreshed = await center.refresh(key: record.key)?.value
        XCTAssertEqual(refreshed?.outcome, .refreshed)
        let completed = try XCTUnwrap(store.record(forKey: record.key))
        let completedMovement = completed.movement
        let completedSnapshot = completed.snapshot
        let completedFetchedAt = completed.movementFetchedAt
        XCTAssertEqual(completedSnapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(completedSnapshot?.statusText, result)
        XCTAssertFalse(try XCTUnwrap(completedSnapshot).inForce)
        XCTAssertEqual(completedMovement?.instances.first?.sessions.last?.result, result)
        XCTAssertEqual(completed.eventJournal?.events, [seed])
        XCTAssertEqual(completed.seenAt, seenAt)
        XCTAssertEqual(completed.collectionNames, ["Гражданские"])

        let partial = await center.refresh(key: record.key)?.value
        guard case .partial = partial?.outcome else {
            return XCTFail("ожидался partial refresh")
        }
        let afterPartial = try XCTUnwrap(store.record(forKey: record.key))
        XCTAssertEqual(afterPartial.movement, completedMovement)
        XCTAssertEqual(afterPartial.snapshot, completedSnapshot)
        XCTAssertEqual(afterPartial.movementFetchedAt, completedFetchedAt)
        XCTAssertEqual(afterPartial.eventJournal?.events, [seed])

        let unavailable = await center.refresh(key: record.key)?.value
        guard case .failed = unavailable?.outcome else {
            return XCTFail("временная недоступность должна быть отдельной ошибкой")
        }
        let afterFailure = try XCTUnwrap(store.record(forKey: record.key))
        XCTAssertEqual(afterFailure.movement, completedMovement)
        XCTAssertEqual(afterFailure.snapshot, completedSnapshot)
        XCTAssertEqual(afterFailure.eventJournal?.events, [seed])
        let requests = await service.requests()
        XCTAssertEqual(requests, [
            "8Г-162/2019", "8Г-162/2019", "8Г-162/2019",
        ])

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: record.key))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(persisted.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(persisted.snapshot?.statusText, result)
        XCTAssertFalse(try XCTUnwrap(persisted.snapshot).inForce)
        XCTAssertEqual(persisted.eventJournal?.events, [seed])

        let router = try AppRouter(
            modelContainer: reopenedContainer, modelContainerIsPrepared: true)
        router.reload(today: try XCTUnwrap(DateUtil.parse("20.10.2019")))
        XCTAssertEqual(router.cases.count, 1)
        XCTAssertEqual(router.cases.first?.stage, .done)
        XCTAssertEqual(router.cases.first?.statusText, result)
        XCTAssertNil(router.cases.first?.courtTier)
        XCTAssertFalse(router.stageCounts.contains { $0.0 == .cassation })
        XCTAssertEqual(router.stageCounts.first { $0.0 == .done }?.1, 1)
        router.stageFilter = .cassation
        XCTAssertTrue(router.filteredCases().isEmpty)
        router.stageFilter = .done
        XCTAssertEqual(router.filteredCases().count, 1)
        router.stageFilter = nil
        router.noActiveProductionFilter = true
        XCTAssertEqual(router.filteredCases().count, 1)
    }

    private func context() throws -> MovementContext {
        let url = try XCTUnwrap(URL(string:
            "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case"
                + "&case_id=11929251&case_uid=3ec699b1-bad6-4927-b00a-b18f140ccb0c"
                + "&new=2800001&delo_id=2800001"))
        return MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Санкт-Петербург",
            searchDomain: "3kas.sudrf.ru", displayDomain: "3kas.sudrf.ru",
            courtTitle: "Третий кассационный суд общей юрисдикции",
            courtLevelRaw: CourtLevel.cassation.rawValue, courtCode: nil,
            cartotekaId: "g3", cartotekaLevelRaw: CourtLevel.cassation.rawValue,
            caseNumber: "8Г-162/2019", caseID: "11929251",
            caseUID: "3ec699b1-bad6-4927-b00a-b18f140ccb0c",
            cardURLString: url.absoluteString, judicialUID: nil,
            baseInstanceLevelRaw: CaseInstance.Level.cassation.rawValue)
    }

    private func fixtureService(context: MovementContext) throws -> MovementService {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = tests.appendingPathComponent(
            "SudrfKitTests/Fixtures/ksoyu_civil_returned_wrong_jurisdiction.html")
        let html = try String(contentsOf: fixture, encoding: .utf8)
        let responseURL = try XCTUnwrap(URL(string: context.cardURLString!))
        return context.makeService(client: Issue275FixtureClient(
            html: html, responseURL: responseURL))
    }
}
