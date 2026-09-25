import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class AppRouterOpenRefreshTests: XCTestCase {
    private func context(_ number: String) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, caseID: "test-id-\(number)",
            caseUID: "test-guid-\(number)")
    }

    func testOpeningCachedCaseDoesNotRefreshButFirstLoadStillStarts() async throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let cachedContext = context("2-1/2026")
        let movement = CaseMovement(
            uid: "", caseNumber: cachedContext.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: cachedContext.courtTitle,
                caseNumber: cachedContext.caseNumber, judge: nil,
                domain: cachedContext.searchDomain, foundByUID: false,
                result: nil, sessions: [])],
            complaints: [:], acts: [])
        let cached = try store.upsert(
            context: cachedContext,
            snapshot: MovementDerivation.snapshot(from: movement, context: cachedContext),
            movement: movement, collections: [])
        let uncached = try store.upsert(
            context: context("2-2/2026"), snapshot: nil, movement: nil,
            collections: [])
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)
        router.refreshCenter.repairBeforeRefresh = { _ in throw CancellationError() }

        router.openCase(key: cached.key)
        XCTAssertEqual(router.liveMovement?.caseNumber, cachedContext.caseNumber)
        XCTAssertFalse(router.refreshCenter.isRefreshing(cached.key))

        router.openCase(key: uncached.key)
        XCTAssertTrue(router.loadingMovement)
        XCTAssertTrue(router.refreshCenter.isRefreshing(uncached.key))
        _ = await router.refreshCenter.refresh(key: uncached.key)?.value
    }
}
