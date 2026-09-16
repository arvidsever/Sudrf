import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue309Movements: MovementProviding {
    let full: CaseMovement
    let partial: CaseMovement
    private var calls = 0

    init(full: CaseMovement, partial: CaseMovement) {
        self.full = full
        self.partial = partial
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        calls += 1
        return calls == 2 ? partial : full
    }
}

@MainActor
final class Issue309RefreshIntegrationTests: XCTestCase {
    private let today = DateUtil.today
    private let uid = "11RS0001-01-2025-009990-15"
    private let baseNumber = "2-6719/2025"
    private let reviewNumber = "88-16139/2026"

    func testActiveCassationSurvivesFullPartialRepeatedRefreshAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-309-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = try context()
        let full = movement()
        var partial = full
        partial.instances.removeAll { $0.level == .cassation }
        partial.incompleteHigherCourtDomains = ["3kas.sudrf.ru"]

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        var stale = MovementDerivation.snapshot(from: full, context: context, today: today)
        stale.stageRaw = CaseStageKind.first.rawValue
        stale.stageTag = "Первая инстанция"
        stale.statusText = "В производстве"
        stale.steps = ["active", "done", "done", "todo"]
        let record = try store.upsert(
            context: context, snapshot: stale, movement: full,
            collections: ["Регрессия #309"])
        let stableKey = record.key
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-309-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let sequence = Issue309Movements(full: full, partial: partial)
        let center = RefreshCenter(
            store: store, client: SudrfClient(),
            serviceBuilder: { _ in sequence })

        let refreshed = await center.refresh(key: stableKey)?.value
        XCTAssertEqual(refreshed?.outcome, .refreshed)
        try assertCassation(in: store, container: container, key: stableKey, seed: seed)

        let partialResult = await center.refresh(key: stableKey)?.value
        guard case .partial = partialResult?.outcome else {
            return XCTFail("неполный ответ КСОЮ должен сохранять последнюю подтверждённую кассацию")
        }
        let afterPartial = try XCTUnwrap(store.record(forKey: stableKey))
        XCTAssertEqual(afterPartial.movement?.instances.filter {
            $0.caseNumber == reviewNumber
        }.count, 1)
        XCTAssertEqual(afterPartial.movement?.instances.filter {
            $0.caseNumber == "88-1234/2026"
        }.count, 1)
        try assertCassation(in: store, container: container, key: stableKey, seed: seed)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        XCTAssertEqual(reopened.all().count, 1)
        try assertCassation(
            in: reopened, container: reopenedContainer, key: stableKey, seed: seed)

        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { _ in Issue309Movements(full: full, partial: partial) })
        let afterReopen = await reopenedCenter.refresh(key: stableKey)?.value
        XCTAssertEqual(afterReopen?.outcome, .refreshed)
        XCTAssertEqual(reopened.all().count, 1)
        try assertCassation(
            in: reopened, container: reopenedContainer, key: stableKey, seed: seed)
    }

    private func assertCassation(
        in store: TrackedStore, container: ModelContainer,
        key: String, seed: CaseEvent
    ) throws {
        let record = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(record.snapshot?.stageRaw, CaseStageKind.cassation.rawValue)
        XCTAssertEqual(record.snapshot?.statusText, "Назначено заседание")
        XCTAssertEqual(record.eventJournal?.events, [seed])
        XCTAssertEqual(record.collectionNames, ["Регрессия #309"])
        XCTAssertEqual(record.movement?.instances.filter {
            $0.caseNumber == reviewNumber
        }.count, 1)

        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: today)
        let tracked = try XCTUnwrap(router.cases.first)
        XCTAssertEqual(router.cases.count, 1)
        XCTAssertEqual(tracked.stage, .cassation)
        XCTAssertEqual(tracked.currentReviewNumber, reviewNumber)
        XCTAssertEqual(tracked.courtTier, .cassation)
        XCTAssertEqual(tracked.court, "Третий кассационный суд общей юрисдикции")
        XCTAssertEqual(tracked.statusText, "Назначено заседание")
        XCTAssertEqual(tracked.next,
                       "заседание \(DateUtil.shortDM(hearingDate)), 12:05")
        XCTAssertEqual(router.stageCounts.first { $0.0 == .cassation }?.1, 1)
        XCTAssertFalse(router.stageCounts.contains { $0.0 == .first || $0.0 == .done })
        XCTAssertEqual(router.tierCounts.first { $0.0 == .cassation }?.1, 1)

        router.stageFilter = .cassation
        XCTAssertEqual(router.filteredCases().count, 1)
        router.stageFilter = .first
        XCTAssertTrue(router.filteredCases().isEmpty)
        router.stageFilter = .done
        XCTAssertTrue(router.filteredCases().isEmpty)
        router.stageFilter = nil
        router.tierFilter = .cassation
        XCTAssertEqual(router.filteredCases().count, 1)
    }

    private func context() throws -> MovementContext {
        let url = try XCTUnwrap(URL(string:
            "https://syktsud.komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=30626186"
                + "&case_uid=1f4345b6-d348-4130-9d19-0c34adef4bc7"
                + "&delo_id=1540005"))
        return MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: baseNumber, caseID: "30626186",
            caseUID: "1f4345b6-d348-4130-9d19-0c34adef4bc7",
            cardURLString: url.absoluteString, judicialUID: uid,
            baseInstanceLevelRaw: CaseInstance.Level.first.rawValue)
    }

    private func movement() -> CaseMovement {
        let first = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд",
            caseNumber: baseNumber, judge: nil,
            domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: nil, sessions: [
                CaseSession(date: "12.09.2025", event: "Судебное заседание",
                            result: "Иск удовлетворён"),
                CaseSession(date: "05.03.2026", event: "Дело принято к производству"),
                CaseSession(date: "20.03.2026", event: "Судебное заседание",
                            result: "Иск удовлетворён"),
            ], sourceEvidence: .init(
                appealKinds: ["Апелляционная жалоба", "Частная жалоба"]))
        let historicalAppeal = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми",
            caseNumber: "33-4096/2025", judge: nil,
            domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Оставлено без изменения", sessions: [
                CaseSession(date: "10.11.2025", event: "Судебное заседание",
                            result: "Оставлено без изменения"),
            ], sourceEvidence: .init(decisionDate: "10.11.2025"))
        let remand = CaseInstance(
            level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "88-1234/2026", judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Отменить судебное решение полностью и направить дело на новое рассмотрение",
            sessions: [
                CaseSession(date: "25.02.2026", event: "Судебное заседание",
                            result: "Отменить судебное решение полностью и направить дело на новое рассмотрение"),
            ])
        let currentAppeal = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми",
            caseNumber: "33-4096/2026", judge: nil,
            domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Решение изменено без направления на новое рассмотрение",
            sessions: [
                CaseSession(date: "27.04.2026", event: "Судебное заседание",
                            result: "Решение изменено без направления на новое рассмотрение"),
            ], sourceEvidence: .init(decisionDate: "27.04.2026"))
        let currentCassation = CaseInstance(
            level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: reviewNumber, judge: nil,
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: nil, sessions: [
                CaseSession(date: "28.07.2026", event: "Регистрация жалобы"),
                CaseSession(date: sourceDate(hearingDate), time: "12:05",
                            event: "Судебное заседание"),
            ])
        return CaseMovement(
            uid: uid, caseNumber: baseNumber, inForce: false,
            instances: [first, historicalAppeal, remand, currentAppeal, currentCassation],
            complaints: [:], acts: [])
    }

    private var hearingDate: Date { DateUtil.addDays(today, 11) }

    private func sourceDate(_ date: Date) -> String {
        let parts = DateUtil.cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%04d", parts.day!, parts.month!, parts.year!)
    }
}
