import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue284RefreshIntegrationTests: XCTestCase {
    private struct FixedOriginResolver: CaseOriginResolving {
        let origin: ResolvedCaseOrigin

        func resolve(anchorContext: MovementContext,
                     anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
            throw CaseOriginResolutionError.noReference
        }

        func resolveMainCase(anchorContext: MovementContext,
                             anchorCard: CaseCard) async throws -> ResolvedCaseOrigin { origin }
    }

    private actor RecordedMovements: MovementProviding {
        private var values: [CaseMovement]
        private(set) var requestedNumbers: [String] = []

        init(_ values: [CaseMovement]) { self.values = values }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            requestedNumbers.append(base.caseNumber)
            return values.removeFirst()
        }
    }

    func testRefreshPreflightKeepsPromotedNumberAndExistingJournalAndAct() async throws {
        let store = TrackedStore(inMemory: true)
        let uid = "11RS0001-01-2026-000664-00"
        let old = context(number: "9а-664/2026", caseID: "old-9a", caseUID: "old-guid",
                          server: "2", judicialUID: uid)
        var current = old
        current.caseNumber = "3а-684/2026"
        current.caseID = "current-3a"
        current.caseUID = "current-guid"
        current.cardURLString = cardURL(caseID: current.caseID!, caseUID: current.caseUID!, server: "1")

        let oldAct = "act_vs--komi.sudrf.ru#old"
        var cached = movement(number: old.caseNumber, sourceActID: oldAct,
                              result: "Отказано в принятии")
        cached.instances[0].sourceURL = try XCTUnwrap(old.cardURLString.flatMap(URL.init(string:)))
        let record = try store.upsert(context: old,
                                      snapshot: MovementDerivation.snapshot(from: cached, context: old),
                                      movement: cached, collections: [])
        try store.save(projection: .cases([record.key]))

        let accepted = CaseCard(rawText: "", actText: nil, sessions: [],
                                result: "Принято к производству", uid: uid,
                                caseNumber: current.caseNumber)
        let origin = ResolvedCaseOrigin(
            court: current.searchCourt, branch: .general, region: current.region,
            courtCode: current.courtCode,
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "p1")),
            result: CaseSearchResult(caseNumber: current.caseNumber, caseID: current.caseID,
                                     caseUID: current.caseUID), card: accepted)
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: FixedOriginResolver(origin: origin),
            defaults: UserDefaults(suiteName: "Issue284RefreshIntegrationTests.\(UUID().uuidString)")!,
            anchorCardFetcher: { _ in
                CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: old.caseNumber)
            })

        var refreshed = movement(number: current.caseNumber, sourceActID: "act-current",
                                 result: "Принято к производству")
        refreshed.instances[0].sessions = [CaseSession(
            date: "01.09.2026", event: "Принято к производству")]
        var previousInstance = cached.instances[0]
        previousInstance.note = "Предыдущая регистрация"
        refreshed.instances.append(previousInstance)
        refreshed.acts.append(cached.acts[0])
        refreshed.actBodies[oldAct] = cached.actBodies[oldAct]
        // A later partial answer is still rooted in the accepted current card;
        // the missing higher-court domain must not erase cached history.
        var stalePartial = refreshed
        stalePartial.incompleteHigherCourtDomains = ["3kas.sudrf.ru"]
        let service = RecordedMovements([refreshed, stalePartial])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })
        center.repairBeforeRefresh = { key in
            try await coordinator.repairIfNeeded(key: key).effectiveKey
        }

        let firstResult = await center.refresh(key: record.key)?.value
        let first = try XCTUnwrap(firstResult)
        let promoted = try XCTUnwrap(store.record(forKey: record.key))
        let journalIDs = Set(try XCTUnwrap(promoted.eventJournal).events.map(\.id))
        let firstMovement = try XCTUnwrap(promoted.movement)
        let firstPrevious = try XCTUnwrap(firstMovement.instances.first {
            $0.caseNumber == old.caseNumber && $0.note == "Предыдущая регистрация"
        })
        let firstRequestedNumbers = await service.requestedNumbers

        XCTAssertEqual(first.effectiveKey, record.key)
        XCTAssertEqual(first.outcome, .refreshed)
        XCTAssertEqual(promoted.context?.caseNumber, current.caseNumber)
        XCTAssertEqual(firstMovement.caseNumber, current.caseNumber)
        XCTAssertEqual(firstRequestedNumbers, [current.caseNumber])
        XCTAssertEqual(firstPrevious.sourceURL,
                       try XCTUnwrap(old.cardURLString.flatMap(URL.init(string:))))
        XCTAssertTrue(firstMovement.acts.contains { $0.id == oldAct })
        XCTAssertEqual(firstMovement.actBodies[oldAct], "Отказано в принятии")
        XCTAssertFalse(journalIDs.isEmpty, "accepted court event must be recorded")
        let firstFetchedAt = promoted.movementFetchedAt

        let secondResult = await center.refresh(key: record.key)?.value
        let second = try XCTUnwrap(secondResult)
        let afterPartial = try XCTUnwrap(store.record(forKey: record.key))
        let afterIDs = Set(try XCTUnwrap(afterPartial.eventJournal).events.map(\.id))
        let partialMovement = try XCTUnwrap(afterPartial.movement)
        let partialPrevious = try XCTUnwrap(partialMovement.instances.first {
            $0.caseNumber == old.caseNumber && $0.note == "Предыдущая регистрация"
        })
        let secondRequestedNumbers = await service.requestedNumbers

        XCTAssertEqual(second.effectiveKey, record.key)
        XCTAssertEqual(second.outcome, .partial(
            "Не обновился источник 3kas.sudrf.ru; сохранены последние успешные данные."))
        XCTAssertEqual(afterPartial.context?.caseNumber, current.caseNumber)
        XCTAssertEqual(partialMovement.caseNumber, current.caseNumber)
        XCTAssertEqual(secondRequestedNumbers, [current.caseNumber, current.caseNumber])
        XCTAssertEqual(afterIDs, journalIDs)
        XCTAssertEqual(afterPartial.movementFetchedAt, firstFetchedAt)
        XCTAssertEqual(partialPrevious.sourceURL, firstPrevious.sourceURL)
        XCTAssertTrue(partialMovement.acts.contains { $0.id == oldAct })
        XCTAssertEqual(partialMovement.actBodies[oldAct], "Отказано в принятии")
    }

    private func context(number: String, caseID: String, caseUID: String,
                         server: String, judicialUID: String) -> MovementContext {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный Суд Республики Коми", courtLevelRaw: CourtLevel.subject.rawValue,
            courtCode: "11RS0001", cartotekaId: "p1", cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: number, caseID: caseID, caseUID: caseUID,
            cardURLString: cardURL(caseID: caseID, caseUID: caseUID, server: server))
        context.judicialUID = judicialUID
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        return context
    }

    private func cardURL(caseID: String, caseUID: String, server: String) -> String {
        "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=\(caseID)&case_uid=\(caseUID)&delo_id=41&new=0&srv_num=\(server)"
    }

    private func movement(number: String, sourceActID: String, result: String) -> CaseMovement {
        let act = CaseAct(id: sourceActID, title: "Определение", date: "01.06.2026",
                          courtShort: "Верховный Суд Республики Коми", instanceLevel: .first)
        return CaseMovement(
            uid: "11RS0001-01-2026-000664-00", caseNumber: number, inForce: false,
            instances: [CaseInstance(level: .first, court: "Верховный Суд Республики Коми",
                                     caseNumber: number, judge: nil, domain: "vs--komi.sudrf.ru",
                                     foundByUID: false, result: result, sessions: [], actID: sourceActID)],
            complaints: [:], acts: [act], actBodies: [sourceActID: result])
    }
}
