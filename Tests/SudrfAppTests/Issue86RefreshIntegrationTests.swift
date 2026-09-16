import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue86Movements: MovementProviding {
    private var values: [CaseMovement]
    private(set) var requestedNumbers: [String] = []

    init(_ values: [CaseMovement]) { self.values = values }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        requestedNumbers.append(base.caseNumber)
        return values.removeFirst()
    }

    func requests() -> [String] { requestedNumbers }
}

@MainActor
final class Issue86RefreshIntegrationTests: XCTestCase {
    func testEffectiveKoAPForceSurvivesPartialRefreshAndDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-86-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = try context()

        let cached = movement(terminal: false)
        var legacySnapshot = MovementDerivation.snapshot(from: cached, context: context)
        legacySnapshot.semanticProjectionVersion = 2
        let record = try store.upsert(
            context: context, snapshot: legacySnapshot,
            movement: cached, collections: ["КоАП"])
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-86-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(derivationVersion: 2, events: [seed])
        try store.save()

        let full = movement(terminal: true)
        var partial = CaseMovement(
            uid: full.uid, caseNumber: full.caseNumber, inForce: false,
            instances: [full.instances[0]], complaints: [:], acts: [])
        partial.incompleteHigherCourtDomains = ["vs--komi.sudrf.ru"]
        let service = Issue86Movements([full, partial])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })

        let first = await center.refresh(key: record.key)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        let refreshed = try XCTUnwrap(store.record(forKey: record.key))
        XCTAssertTrue(try XCTUnwrap(refreshed.snapshot).inForce)
        XCTAssertEqual(refreshed.snapshot?.statusText, "Оставлено без изменения")
        XCTAssertEqual(refreshed.eventJournal?.derivationVersion,
                       CaseEventJournal.currentDerivationVersion)
        XCTAssertEqual(refreshed.eventJournal?.events, [seed])
        XCTAssertEqual(refreshed.collectionNames, ["КоАП"])

        let second = await center.refresh(key: record.key)?.value
        guard case .partial = second?.outcome else {
            return XCTFail("ожидался partial refresh")
        }
        let afterPartial = try XCTUnwrap(store.record(forKey: record.key))
        XCTAssertTrue(try XCTUnwrap(afterPartial.snapshot).inForce)
        XCTAssertNotNil(afterPartial.movement?.instances.first {
            $0.caseNumber == "12-77/2026"
        })
        XCTAssertEqual(afterPartial.eventJournal?.events, [seed])
        let requests = await service.requests()
        XCTAssertEqual(requests, ["5-469/2026", "5-469/2026"])

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: record.key))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertTrue(try XCTUnwrap(persisted.snapshot).inForce)
        XCTAssertEqual(persisted.snapshot?.statusText, "Оставлено без изменения")
        XCTAssertEqual(persisted.eventJournal?.events, [seed])
        XCTAssertEqual(persisted.collectionNames, ["КоАП"])
    }

    private func context() throws -> MovementContext {
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "adm"))
        let url = try XCTUnwrap(URL(string:
            "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=35768698&case_uid=46a9b300-ffc6-44b6-b478-df808b52281b"
                + "&delo_id=\(cartoteka.deloID)&new=\(cartoteka.new)"))
        return MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд Республики Коми",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "adm", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "5-469/2026", caseID: "35768698",
            caseUID: "46a9b300-ffc6-44b6-b478-df808b52281b",
            cardURLString: url.absoluteString,
            judicialUID: "11RS0001-01-2026-005022-94")
    }

    private func movement(terminal: Bool) -> CaseMovement {
        let first = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд Республики Коми",
            caseNumber: "5-469/2026", judge: nil, domain: "syktsud--komi.sudrf.ru",
            foundByUID: false,
            result: "Вынесено постановление о назначении административного наказания",
            sessions: [CaseSession(
                date: "20.05.2026", event: "Рассмотрение дела по существу",
                result: "Вынесено постановление о назначении административного наказания")])
        let result = terminal ? "Оставлено без изменения" : nil
        let appeal = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми",
            caseNumber: "12-77/2026", judge: nil, domain: "vs--komi.sudrf.ru",
            foundByUID: true, result: result,
            sessions: [CaseSession(
                date: terminal ? "24.06.2026" : "08.06.2026",
                event: terminal ? "Судебное заседание" : "Материалы переданы судье",
                result: result)])
        return CaseMovement(
            uid: "11RS0001-01-2026-005022-94", caseNumber: "5-469/2026",
            inForce: false, instances: [first, appeal], complaints: [:], acts: [])
    }
}
