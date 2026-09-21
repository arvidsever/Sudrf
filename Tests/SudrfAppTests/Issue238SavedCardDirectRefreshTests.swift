import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue238MovementSequence: MovementProviding {
    let movement: CaseMovement

    init(_ movement: CaseMovement) {
        self.movement = movement
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        movement
    }
}

@MainActor
final class Issue238SavedCardDirectRefreshTests: XCTestCase {
    func testSavedCardLinksFeedRepeatedPartialRefreshAndDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-238-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = makeContext()
        let movement = makePartialMovement()
        let oldSuccess = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context),
            movement: movement,
            collections: ["Регрессия #238"])
        record.movementFetchedAt = oldSuccess
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-238-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        var captured: [MovementContext] = []
        let provider = Issue238MovementSequence(movement)
        let center = RefreshCenter(
            store: store, client: SudrfClient(),
            serviceBuilder: { context in
                captured.append(context)
                return provider
            })

        for _ in 0..<2 {
            let execution = await center.refresh(key: record.key)?.value
            guard case .partial = execution?.outcome else {
                return XCTFail("недоступная карточка должна сохранить partial outcome")
            }
            try assertState(store: store, key: record.key, oldSuccess: oldSuccess, seed: seed)
        }
        XCTAssertEqual(captured.count, 2)
        for context in captured { try assertEnrichedContext(context) }

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertState(store: reopened, key: record.key, oldSuccess: oldSuccess, seed: seed)

        var reopenedContext: MovementContext?
        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { context in
                reopenedContext = context
                return Issue238MovementSequence(movement)
            })
        let repeated = await reopenedCenter.refresh(key: record.key)?.value

        guard case .partial = repeated?.outcome else {
            return XCTFail("после перезапуска partial-семантика должна сохраниться")
        }
        try assertEnrichedContext(try XCTUnwrap(reopenedContext))
        try assertState(store: reopened, key: record.key, oldSuccess: oldSuccess, seed: seed)
    }

    private func assertEnrichedContext(_ context: MovementContext) throws {
        let cards = try XCTUnwrap(context.knownCards)
        XCTAssertEqual(cards.count, 2, "одинаковый номер другого суда не должен схлопываться")

        let appeal = try XCTUnwrap(cards.first {
            SudrfHost.moduleHost($0.domain) == "vs--komi.sudrf.ru"
        })
        XCTAssertEqual(appeal.caseID, "")
        XCTAssertEqual(appeal.caseUID, "appeal-guid")
        XCTAssertEqual(appeal.level, .appeal)
        XCTAssertEqual(appeal.courtTitle, "Верховный суд Республики Коми")
        XCTAssertEqual(appeal.sourceURL?.host, "vs.komi.sudrf.ru")
        XCTAssertNil(URLComponents(
            url: try XCTUnwrap(appeal.sourceURL), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "utm_source" })

        let cassation = try XCTUnwrap(cards.first { $0.domain == "3kas.sudrf.ru" })
        XCTAssertEqual(cassation.caseID, "cassation-card")
        XCTAssertEqual(cassation.caseUID, "")
        XCTAssertEqual(cassation.level, .cassation)
        XCTAssertEqual(cassation.caseNumber, "33-238/2026")
        XCTAssertNotNil(cassation.sourceURL)
        XCTAssertFalse(cards.contains { $0.domain == "4kas.sudrf.ru" })
    }

    private func assertState(store: TrackedStore, key: String, oldSuccess: Date,
                             seed: CaseEvent) throws {
        let saved = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(saved.movementFetchedAt, oldSuccess)
        XCTAssertEqual(saved.sourceRefreshAttempt?.kind, .partial)
        XCTAssertEqual(saved.eventJournal?.events, [seed])
        XCTAssertEqual(saved.collectionNames, ["Регрессия #238"])
        XCTAssertEqual(saved.context?.knownCards?.count, 1,
                       "обогащение рабочего контекста не требует миграции хранилища")
        XCTAssertEqual(saved.movement?.instances.filter {
            $0.caseNumber == "33-238/2026"
        }.count, 4)
        XCTAssertEqual(saved.movement?.instances.filter {
            $0.sourceURL != nil
        }.count, 5)
    }

    private func makeContext() -> MovementContext {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-238/2026",
            caseID: "base-card",
            caseUID: "base-guid",
            judicialUID: "11RS0001-01-2026-000238-10")
        context.knownCards = [KnownCard(
            domain: "vs--komi.sudrf.ru",
            courtTitle: "Верховный суд Республики Коми",
            caseID: "", caseUID: "appeal-guid", deloID: "5", new: "5",
            caseNumber: "33-238/2026", levelRaw: CaseInstance.Level.appeal.rawValue,
            cartotekaID: "g2")]
        return context
    }

    private func makePartialMovement() -> CaseMovement {
        let appealURL = URL(string:
            "https://vs.komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_uid=appeal-guid&delo_id=5&new=5&utm_source=test")!
        let cassationURL = URL(string:
            "https://3kas.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=cassation-card&delo_id=2800001&new=2800001")!
        let mismatchedURL = URL(string:
            "https://5kas.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=foreign-card&delo_id=2800001&new=2800001")!
        let malformedURL = URL(string: "https://4kas.sudrf.ru/not-a-card")!
        let instances = [
            CaseInstance(
                level: .first, court: "Сыктывкарский городской суд",
                caseNumber: "2-238/2026", judge: nil,
                domain: "syktsud--komi.sudrf.ru", foundByUID: false,
                result: "Решено", sessions: [],
                sourceURL: URL(string:
                    "https://syktsud.komi.sudrf.ru/modules.php?name=sud_delo"
                    + "&name_op=case&case_id=base-card&case_uid=base-guid"
                    + "&delo_id=1540005&new=0")),
            CaseInstance(
                level: .appeal, court: "Верховный суд Республики Коми",
                caseNumber: "33-238/2026", judge: nil,
                domain: "vs--komi.sudrf.ru", foundByUID: true,
                result: "Оставлено без изменения", sessions: [], sourceURL: appealURL,
                sourceEvidence: .init(cartotekaID: "g2")),
            CaseInstance(
                level: .cassation, court: "Третий кассационный суд общей юрисдикции",
                caseNumber: "33-238/2026", judge: nil,
                domain: "3kas.sudrf.ru", foundByUID: true,
                result: nil, sessions: [], sourceURL: cassationURL),
            CaseInstance(
                level: .cassation, court: "Четвёртый кассационный суд общей юрисдикции",
                caseNumber: "33-238/2026", judge: nil,
                domain: "4kas.sudrf.ru", foundByUID: true,
                result: nil, sessions: [], sourceURL: mismatchedURL),
            CaseInstance(
                level: .cassation, court: "Четвёртый кассационный суд общей юрисдикции",
                caseNumber: "33-238/2026", judge: nil,
                domain: "4kas.sudrf.ru", foundByUID: true,
                result: nil, sessions: [], sourceURL: malformedURL),
        ]
        return CaseMovement(
            uid: "11RS0001-01-2026-000238-10", caseNumber: "2-238/2026",
            inForce: false, instances: instances, complaints: [:], acts: [],
            incompleteHigherCourtDomains: ["3kas.sudrf.ru"])
    }
}
