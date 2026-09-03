import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class FalliblePersistenceInteractionTests: XCTestCase {
    private final class ProjectionGate {
        var isFailing = false
    }

    private struct ForcedProjectionFailure: LocalizedError {
        var errorDescription: String? { "forced projection failure" }
    }

    private func context(number: String = "2-100/2026") -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number)
    }

    private func router(using gate: ProjectionGate) throws -> AppRouter {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        return try AppRouter(
            modelContainer: container,
            modelContainerIsPrepared: true,
            trackedStoreProjectionSynchronizer: { context, scope in
                if gate.isFailing { throw ForcedProjectionFailure() }
                try CourtActProjectionSynchronizer.synchronize(context: context, scope: scope)
            })
    }

    private func movement(for context: MovementContext) -> CaseMovement {
        let session = CaseSession(date: "01.08.2026", event: "Судебное заседание",
                                  result: "Иск удовлетворён; решение принято в окончательной форме")
        let instance = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: "Иск удовлетворён", sessions: [session])
        return CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                            instances: [instance], complaints: [:], acts: [],
                            category: "Споры из договоров")
    }

    func testFailedTrackRestoresPublishedCasesAndShowsCommonAlert() throws {
        let gate = ProjectionGate()
        let router = try router(using: gate)
        gate.isFailing = true

        router.track(context: context(), movement: nil)

        XCTAssertTrue(router.cases.isEmpty)
        XCTAssertEqual(router.persistenceError, "Изменения не сохранены. Повторите попытку.")
    }

    func testFreshFSSPResultOrErrorRequiresSameOpenCaseAndRequest() {
        let request = UUID()
        XCTAssertTrue(AppRouter.acceptsFreshFSSPStep(
            activeRequestID: request, requestID: request,
            openedKey: "case", caseKey: "case"))
        XCTAssertFalse(AppRouter.acceptsFreshFSSPStep(
            activeRequestID: UUID(), requestID: request,
            openedKey: "case", caseKey: "case"))
        XCTAssertFalse(AppRouter.acceptsFreshFSSPStep(
            activeRequestID: request, requestID: request,
            openedKey: nil, caseKey: "case"))
        XCTAssertFalse(AppRouter.acceptsFreshFSSPStep(
            activeRequestID: request, requestID: request,
            openedKey: "replacement", caseKey: "case"))
    }

    func testDeadlineSaveFailureKeepsEditorDraftAndStoredDate() throws {
        let gate = ProjectionGate()
        let router = try router(using: gate)
        let value = context()
        router.track(context: value, movement: movement(for: value))
        let deadline = try XCTUnwrap(router.deadlines.first)
        router.beginEdit(deadline.id)
        router.step(1)
        let draft = try XCTUnwrap(router.draftDate)
        gate.isFailing = true

        router.save(deadline.id)

        XCTAssertEqual(router.editingDeadline, deadline.id)
        XCTAssertEqual(router.draftDate, draft)
        XCTAssertEqual(router.deadline(deadline.id)?.date, deadline.date)
        XCTAssertEqual(router.persistenceError, "Изменения не сохранены. Повторите попытку.")
        let store = try TrackedStore(container: router.modelContainer)
        let key = try XCTUnwrap(router.cases.first?.recordKey)
        XCTAssertTrue(store.record(forKey: key)?.eventJournal?.events.isEmpty == true)
    }

    func testDeadlineConfirmationAndOverrideAppendJournalOnce() throws {
        let gate = ProjectionGate()
        let router = try router(using: gate)
        let value = context()
        router.track(context: value, movement: movement(for: value))
        let deadline = try XCTUnwrap(router.deadlines.first)
        let key = try XCTUnwrap(router.cases.first?.recordKey)
        let store = try TrackedStore(container: router.modelContainer)

        router.confirm(deadline.id)
        router.confirm(deadline.id)
        XCTAssertEqual(store.record(forKey: key)?.eventJournal?.events.map(\.kind),
                       [.deadlineConfirmed])

        router.beginEdit(deadline.id)
        router.step(1)
        router.save(deadline.id)
        XCTAssertEqual(store.record(forKey: key)?.eventJournal?.events.map(\.kind),
                       [.deadlineConfirmed, .deadlineChanged])
    }

    func testCollectionIntentRethrowsCommitFailureWithoutMembershipSuccess() throws {
        let gate = ProjectionGate()
        let router = try router(using: gate)
        let value = context()
        router.track(context: value, movement: nil)
        let key = try XCTUnwrap(router.cases.first?.recordKey)
        gate.isFailing = true

        XCTAssertThrowsError(try router.intentAddCase(key: key, collection: "Доверитель")) { error in
            guard case .projectionSynchronization = error as? TrackedStoreCommitError else {
                return XCTFail("Expected projection failure, got \(error)")
            }
        }

        XCTAssertFalse(router.cases.first?.collections.contains("Доверитель") ?? true)
        XCTAssertFalse(router.collections.contains { $0.0 == "Доверитель" })
    }

    func testFailedUntrackKeepsCaseOpenForRetryAndShowsCommonAlert() throws {
        let gate = ProjectionGate()
        let router = try router(using: gate)
        let value = context()
        router.track(context: value, movement: nil)
        let key = try XCTUnwrap(router.cases.first?.recordKey)
        router.openCase(key: key)
        gate.isFailing = true

        router.untrack(recordKey: key)

        XCTAssertEqual(router.cases.map(\.recordKey), [key])
        XCTAssertEqual(router.openedCase, value.caseNumber)
        XCTAssertEqual(router.persistenceError, "Изменения не сохранены. Повторите попытку.")
    }

    func testImportBatchProjectionFailureRollsBackEveryPlannedRecord() throws {
        let gate = ProjectionGate()
        let router = try router(using: gate)
        let existing = context(number: "2-90/2026")
        router.track(context: existing, movement: nil)
        let existingKey = try XCTUnwrap(router.cases.first?.recordKey)
        let planned = ["2-101/2026", "2-102/2026"].map {
            CaseImporter.PlannedRecord(context: context(number: $0), isMaterial: false)
        }
        gate.isFailing = true

        XCTAssertThrowsError(try router.commitImport(
            records: planned, collection: "Импорт 29.08.2026"
        )) { error in
            guard case .projectionSynchronization = error as? TrackedStoreCommitError else {
                return XCTFail("Expected projection failure, got \(error)")
            }
        }
        router.reload()

        XCTAssertEqual(router.cases.map(\.recordKey), [existingKey])
        XCTAssertTrue(router.cases.first?.collections.isEmpty == true)
    }
}
