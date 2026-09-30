import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class VSRFMovementPresentationTests: XCTestCase {
    func makeMovement() throws -> CaseMovement {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("SudrfKitTests/Fixtures/vsrf_current_card_340.html")
        let card = try VSRFCardParser.parse(html: String(contentsOf: fixture, encoding: .utf8))
        let production = try XCTUnwrap(card.caseProduction)
        let base = CaseInstance(level: .first, court: "Тестовый суд субъекта", caseNumber: "3а-85/2025",
            judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "В иске отказано", sessions: [CaseSession(date: "28.07.2025", event: "Решение", result: "В иске отказано")])
        let appeal = CaseInstance(level: .appeal, court: "Тестовый апелляционный суд", caseNumber: "66а-514/2025",
            judge: nil, domain: "2ap.sudrf.ru", foundByUID: true,
            result: "Оставлено без изменения", sessions: [CaseSession(date: "20.08.2025", event: "Рассмотрено", result: "Оставлено без изменения")])
        return CaseMovement(uid: production.uid ?? "", caseNumber: base.caseNumber, inForce: true,
            instances: [base, appeal, MovementService.mapProduction(production)], complaints: [:], acts: [])
    }

    func context() -> MovementContext {
        MovementContext(branchRaw: "general", region: "Республика Коми", searchDomain: "vs--komi.sudrf.ru",
            displayDomain: "vs.komi.sudrf.ru", courtTitle: "Тестовый суд субъекта", courtLevelRaw: "subject",
            courtCode: "11OS0000", cartotekaId: "adm1", cartotekaLevelRaw: "subject", caseNumber: "3а-85/2025")
    }

    func testHistoricalHydrationKeepsCompletedStageAndDoesNotNotify() throws {
        let movement = try makeMovement()
        let now = try XCTUnwrap(DateUtil.parse("30.09.2026"))
        var summary = movement
        summary.instances[2].sessions = [CaseSession(date: "15.10.2025", event: movement.instances[2].result!)]
        let before = MovementDerivation.snapshot(from: summary, context: context(), today: now)
        let after = MovementDerivation.snapshot(from: movement, context: context(), today: now)
        XCTAssertEqual(after.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(after.stageRaw, before.stageRaw)
        XCTAssertEqual(after.deadlines, before.deadlines)
        let hearings = MovementDerivation.calendarHearings(after.sessions).filter { $0.level == .vsCassation }
        XCTAssertEqual(hearings.map(\.dateRaw), ["15.10.2025"])
        XCTAssertNil(hearings.first?.time)
        XCTAssertTrue(MovementDerivation.futureHearings(after.sessions, today: now).isEmpty)
        let attempt = SourceOutcomeClassifier.attempt(for: movement, sourceFamily: "sudrf", host: "vs.komi.sudrf.ru", observedAt: now)
        XCTAssertTrue(CaseEventDeriver.derive(old: before, new: after, attempt: attempt, observedAt: now).events.isEmpty)
        XCTAssertTrue(CaseEventDeriver.derive(old: after, new: after, attempt: attempt, observedAt: now).events.isEmpty)
        XCTAssertEqual(CaseMovementView.activeInstances(in: movement).last?.sessions.count, 3)
    }

    func testIsolatedStoreReopenRetainsFullMovementAndCollections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sudrf-340-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let movement = try makeMovement()
        let ctx = context()
        let snapshot = MovementDerivation.snapshot(from: movement, context: ctx, today: DateUtil.parse("30.09.2026")!)
        func save() throws {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true, projectionSynchronizer: { _, _ in })
            _ = try store.upsert(context: ctx, snapshot: snapshot, movement: movement, collections: ["Тестовая подборка"])
        }
        try save()
        let reopened = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let store = try TrackedStore(container: reopened, prepared: true, projectionSynchronizer: { _, _ in })
        let saved = try XCTUnwrap(store.record(forKey: ctx.key))
        XCTAssertEqual(saved.movement, movement)
        XCTAssertEqual(saved.collectionNames, ["Тестовая подборка"])
        XCTAssertEqual(saved.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        let again = MovementCachePolicy.merge(fresh: movement, cached: saved.movement)
        XCTAssertEqual(again, movement)
        XCTAssertEqual(again.instances.last?.sessions.count, 3)
    }

    func testUniqueVSRFHearingAndResultDisplayInOneRowWithoutChangingSource() throws {
        let source = try XCTUnwrap(makeMovement().instances.last)
        let rows = InstanceBlock.displaySessions(in: source)
        XCTAssertEqual(source.sessions.count, 3)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last?.event, "Судебное заседание")
        XCTAssertEqual(rows.last?.date, "15.10.2025")
        XCTAssertNil(rows.last?.time)
        XCTAssertTrue(rows.last?.result?.contains("оставлена без удовлетворения") == true)
        XCTAssertTrue(rows.last?.result?.contains("16.09.2025 16:24") == true)
        var ambiguous = source
        ambiguous.sessions.append(source.sessions[1])
        XCTAssertEqual(InstanceBlock.displaySessions(in: ambiguous), ambiguous.sessions)
        var otherCourt = source
        otherCourt.domain = "3kas.sudrf.ru"
        XCTAssertEqual(InstanceBlock.displaySessions(in: otherCourt), source.sessions)
    }

    func testRealMovementViewRendersPublishedTimeline() throws {
        let movement = try makeMovement()
        let content = CaseMovementView(movement: movement, expanded: .constant([]), onBack: {})
            .frame(width: 1120, height: 660).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["SUDRF_VSRF340_VISUAL_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertFalse(data.isEmpty)
    }
}
