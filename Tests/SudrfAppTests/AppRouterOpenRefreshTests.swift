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

    private func repairDiagnostic() -> CaseRepairDiagnostic {
        CaseRepairDiagnostic(
            phase: .uidSearch,
            attempt: SourceAttempt(
                kind: .transportFailure,
                provenance: SourceProvenance(
                    operation: .discovery, sourceFamily: "mosgorsud",
                    host: "mos-gorsud.ru", httpStatus: 502)))
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
        router.refreshCenter.repairBeforeRefresh = { _, _ in throw CancellationError() }

        router.openCase(key: cached.key)
        XCTAssertEqual(router.liveMovement?.caseNumber, cachedContext.caseNumber)
        XCTAssertFalse(router.refreshCenter.isRefreshing(cached.key))

        router.openCase(key: uncached.key)
        XCTAssertTrue(router.loadingMovement)
        XCTAssertTrue(router.refreshCenter.isRefreshing(uncached.key))
        _ = await router.refreshCenter.refresh(key: uncached.key)?.value
    }

    func testRepairDiagnosticStaysSeparateAcrossEmptyPreflightRemapAndSuccess() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let context = context("2-336/2026")
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
                judge: nil, domain: context.searchDomain, foundByUID: false,
                result: nil, sessions: [])], complaints: [:], acts: [])
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context),
            movement: movement, collections: [])
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)
        router.openCase(key: record.key)
        router.refreshNote = "Движение обновляется частично."

        let diagnostic = repairDiagnostic()
        var failed = CaseRepairSummary()
        failed.recordSourceFailure(diagnostic, for: record.key)
        router.consumeRepairDiagnostics(failed)
        XCTAssertEqual(router.refreshNote, "Движение обновляется частично.")
        XCTAssertEqual(router.repairNote, diagnostic.message)
        let view = CaseMovementView(
            movement: movement, expanded: .constant([]), onBack: {},
            refreshNote: router.refreshNote, repairNote: router.repairNote)
        XCTAssertEqual(view.refreshNote, router.refreshNote)
        XCTAssertEqual(view.repairNote, router.repairNote)

        var notifications = 0
        let subscription = router.objectWillChange.sink { _ in notifications += 1 }
        router.consumeRepairDiagnostics(CaseRepairSummary())
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(router.repairNote, diagnostic.message)

        let remappedKey = "canonical-\(record.key)"
        var remapped = CaseRepairSummary()
        remapped.keyRemaps = [record.key: remappedKey]
        router.consumeRepairDiagnostics(remapped)
        XCTAssertNil(router.repairDiagnostics[record.key])
        XCTAssertEqual(router.repairDiagnostics[remappedKey], diagnostic)

        var resolved = CaseRepairSummary()
        resolved.keyRemaps = [record.key: remappedKey]
        resolved.markResolved(record.key)
        router.consumeRepairDiagnostics(resolved)
        XCTAssertNil(router.repairDiagnostics[remappedKey])
        XCTAssertNil(router.repairNote)
        _ = subscription
    }
}
