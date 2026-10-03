import AppKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class DeadlineExistingUITests: XCTestCase {
    private let today = DateUtil.parse("03.10.2026")!

    func testClosestEventCombinesMainAndMaterialEvents() throws {
        let (movement, context, snapshot, materials, ids) = try syntheticCase()
        var value = snapshot
        let mainDeadline = StoredDeadline(kind: "appeal", what: "Апелляционная жалоба",
            basis: "QA", calLabel: "апелл.", dateRef: day("22.10.2026").timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue)
        let firstMaterialDeadline = materialDeadline(materials[0], sourceID: ids[0], date: "28.10.2026")
        let secondMaterialDeadline = materialDeadline(materials[1], sourceID: ids[1], date: "05.11.2026")
        var opaque = mainDeadline
        opaque.occurrenceKey = "unknown|not-a-valid-material-key"
        opaque.dateRef = day("10.10.2026").timeIntervalSinceReferenceDate
        value.deadlines = [mainDeadline, firstMaterialDeadline, secondMaterialDeadline, opaque]
        value.sessions = [hearing("24.10.2026", level: .first, number: movement.caseNumber)]

        var result = present(movement, context, value)
        XCTAssertEqual(result.nextEventDate, day("22.10.2026"))
        XCTAssertTrue(result.nextEvent.hasPrefix("срок апелляции:"),
                      "An opaque occurrence must not be treated as a main-case deadline")

        value.deadlines[0].dateRef = day("12.11.2026").timeIntervalSinceReferenceDate
        result = present(movement, context, value)
        XCTAssertEqual(result.nextEventDate, day("24.10.2026"))
        XCTAssertTrue(result.nextEvent.hasPrefix("заседание 24.10"))

        value.sessions = [hearing("28.10.2026", level: .material,
                                  number: materials[0].caseNumber, sourceID: ids[0])]
        result = present(movement, context, value)
        XCTAssertEqual(result.nextEventDate, day("28.10.2026"))
        XCTAssertTrue(result.nextEvent.contains("материал № \(materials[0].caseNumber)"),
                      "A hearing wins a same-day tie and names its material")

        value.sessions = []
        value.deadlines = [firstMaterialDeadline, secondMaterialDeadline]
        result = present(movement, context, value)
        XCTAssertEqual(result.nextEventDate, day("28.10.2026"))
        XCTAssertTrue(result.nextEvent.contains("материал № \(materials[0].caseNumber)"),
                      "The earliest of several material deadlines is selected")
    }

    func testCompletedMainShowsFutureHearingOwnedByMaterial() throws {
        var movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let context = context(for: movement)
        let scope = try XCTUnwrap(MaterialDeadlineScope.proven(in: movement, context: context)
            .first { $0.movement.caseNumber == "13-630/2026" })
        let review = try XCTUnwrap(scope.movement.instances.first { $0.level == .cassation })
        let index = try XCTUnwrap(movement.instances.firstIndex { $0.id == review.id })
        movement.instances[index].result = nil
        movement.instances[index].sessions = [CaseSession(
            date: "05.11.2026", event: "Судебное заседание")]

        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        let result = present(movement, context, snapshot)
        XCTAssertEqual(result.stage, .done)
        XCTAssertTrue(result.nextEvent.hasPrefix("заседание 05.11"))
        XCTAssertTrue(result.nextEvent.contains("материал № 13-630/2026"))
    }

    func testTerminalMaterialHearingDoesNotReplaceItsDeadline() throws {
        let movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let context = context(for: movement)
        var snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        let deadline = try XCTUnwrap(snapshot.deadlines.first {
            MovementDerivation.deadlineScopeKey($0) != nil && $0.date == day("05.11.2026")
        })
        let sourceID = try XCTUnwrap(MovementDerivation.deadlineScopeKey(deadline))
        snapshot.sessions.append(StoredSession(dateRaw: "04.11.2026", time: nil, room: nil,
            event: "Судебное заседание", result: nil, court: "QA court",
            levelRaw: CaseInstance.Level.material.rawValue, caseNumber: "13-630/2026",
            sourceCardID: sourceID))

        let result = present(movement, context, snapshot)
        XCTAssertTrue(result.nextEvent.hasPrefix("срок ВС РФ: 05.11"))
        XCTAssertEqual(result.nextEventDate, day("05.11.2026"))
    }

    func testMissingMaterialCalculationKeepsNumberedFullDiagnostic() throws {
        var movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let context = context(for: movement)
        let scope = try XCTUnwrap(MaterialDeadlineScope.proven(in: movement, context: context)
            .first { $0.movement.caseNumber == "13-630/2026" })
        let ownedReviews = Set(scope.movement.instances.filter { $0.level == .cassation }.map(\.caseNumber))
        let ownedActIDs = Set(scope.movement.instances.filter { $0.level == .cassation }.flatMap(\.linkedActIDs))
        for index in movement.instances.indices where ownedReviews.contains(movement.instances[index].caseNumber) {
            movement.instances[index].sessions.removeAll {
                $0.event.localizedCaseInsensitiveContains("окончательной форме")
            }
            movement.instances[index].sourceEvidence?.decisionDate = nil
        }
        movement.acts.removeAll { ownedActIDs.contains($0.id) }
        movement.actBodies = movement.actBodies.filter { !ownedActIDs.contains($0.key) }

        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        let result = present(movement, context, snapshot)
        let help = try XCTUnwrap(result.nextEventHelp)
        XCTAssertNil(snapshot.deadlines.first { MovementDerivation.deadlineScopeKey($0) == scope.sourceCardID })
        XCTAssertFalse(result.nextEvent.isEmpty)
        XCTAssertTrue(help.contains("Материал № 13-630/2026"))
        XCTAssertTrue(help.contains("GPK-CASSATION-SUPREME-COURT"))
    }

    func testUserChangedMaterialDateRemainsTheNextEvent() throws {
        let movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let context = context(for: movement)
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        let record = try store.reconcileAndUpsert(context: context, snapshot: snapshot,
            movement: movement, collections: [], movementFetchedAt: today)
        record.snapshot = snapshot
        try store.save()
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: today)
        let deadline = try XCTUnwrap(router.deadlines.first {
            $0.displayNumber == "13-630/2026" && $0.date == day("05.11.2026")
        })
        let savedDate = day("12.11.2026")
        router.beginEdit(deadline.id)
        router.draftDate = savedDate
        router.save(deadline.id)
        router.reload(today: today)

        let updated = try XCTUnwrap(router.deadlines.first { $0.id == deadline.id })
        let tracked = try XCTUnwrap(router.cases.first { $0.caseNumber.contains("2-4869/2025") })
        XCTAssertEqual(updated.status, .overridden)
        XCTAssertEqual(updated.date, savedDate)
        XCTAssertEqual(tracked.stage, .done)
        XCTAssertEqual(tracked.nextEventDate, savedDate)
        XCTAssertTrue(tracked.next.contains("материал № 13-630/2026"))
    }

    func testCompletedRootMaterialSuppressesItsStaleFutureHearing() throws {
        let number = "13-900/2026"
        let material = CaseInstance(level: .material, court: "Проверочный суд", caseNumber: number,
            judge: nil, domain: "qa.sudrf.ru", foundByUID: false, result: "Удовлетворено",
            sessions: [CaseSession(date: "01.10.2026", event: "Судебное заседание", result: "Удовлетворено")])
        let movement = CaseMovement(uid: "qa-root-material", caseNumber: number,
            inForce: true, instances: [material], complaints: [:], acts: [])
        var context = MovementContext(branchRaw: "general", region: "QA",
            searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru", courtTitle: "Проверочный суд",
            courtLevelRaw: "district", cartotekaId: "m", cartotekaLevelRaw: "district",
            caseNumber: number)
        context.baseInstanceLevelRaw = CaseInstance.Level.material.rawValue
        var snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        snapshot.sessions.append(hearing("10.10.2026", level: .material, number: number))
        let result = present(movement, context, snapshot)
        XCTAssertEqual(result.stage, .done)
        XCTAssertFalse(result.nextEvent.hasPrefix("заседание"))
    }

    func testNativeExistingScreensAndCardWithoutAddedDeadlineDropdowns() throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_DEADLINE_EXISTING_UI_OUTPUT"] else {
            throw XCTSkip("Use Docs/qa/deadlines-existing-ui/run.sh for isolated native screenshots")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (window, router) = try Issue222VisualTests().screen()
        defer { window.close() }
        router.reload(today: today)
        XCTAssertEqual(router.cases.count, 7)
        XCTAssertTrue(router.deadlines.contains {
            $0.displayNumber == "13-630/2026" && $0.date == day("05.11.2026")
        })
        let tracked = try XCTUnwrap(router.cases.first { $0.caseNumber.contains("2-4869/2025") })
        XCTAssertEqual(tracked.stage, .done)
        XCTAssertEqual(tracked.nextEventDate, day("05.11.2026"))
        XCTAssertTrue(tracked.next.contains("материал № 13-630/2026"))
        router.myView = .list
        router.sortBy = .nextEvent
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        try capture(window, to: output.appendingPathComponent("cases.png"))

        show(AnyView(OverviewView().environmentObject(router)), in: window)
        try capture(window, to: output.appendingPathComponent("overview.png"))

        let movement = try XCTUnwrap(Issue222VisualTests.cardMovement)
        let context = try XCTUnwrap(Issue222VisualTests.cardContext)
        show(AnyView(CaseMovementView(movement: movement, expanded: .constant([]),
            onBack: {}, sourceContext: context)), in: window)
        // Layer-backed scroll content is inspected and captured through the native app surface.
    }

    private func syntheticCase() throws
        -> (CaseMovement, MovementContext, CaseSnapshot, [CaseInstance], [String]) {
        let number = "2-990/2026"
        let root = CaseInstance(level: .first, court: "Проверочный суд", caseNumber: number,
            judge: nil, domain: "qa.sudrf.ru", foundByUID: false, result: nil, sessions: [])
        let materials = (0..<2).map { index in
            CaseInstance(level: .material, court: "Проверочный суд", caseNumber: "13-\(991 + index)/2026",
                judge: nil, domain: "qa.sudrf.ru", foundByUID: false, result: nil, sessions: [],
                sourceURL: URL(string: "https://qa.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=m\(index)&delo_id=1610001&new=1"))
        }
        let movement = CaseMovement(uid: "00RS0001-01-2026-009990-11", caseNumber: number, inForce: false,
            instances: [root] + materials, complaints: [:], acts: [], category: "Споры из договоров")
        let context = MovementContext(branchRaw: "general", region: "QA",
            searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru", courtTitle: root.court,
            courtLevelRaw: "district", courtCode: "00RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: "district", caseNumber: number)
        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        let ids = try materials.map { try XCTUnwrap(CaseSnapshotSourceIdentity.sourceCardID(for: $0, context: context)) }
        return (movement, context, snapshot, materials, ids)
    }

    private func materialDeadline(_ material: CaseInstance, sourceID: String,
                                  date: String) -> StoredDeadline {
        let fields = ["qa-round", CaseInstance.Level.material.rawValue, material.caseNumber,
            "01.10.2026", "Определение суда", "", sourceID]
        let key = "GPK-CASSATION-SUPREME-COURT|" + Data(fields.joined(separator: "\u{1F}").utf8).base64EncodedString()
        return StoredDeadline(kind: "cassation", what: "Обращение в ВС РФ", basis: "QA",
            calLabel: "ВС РФ", dateRef: day(date).timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.proposed.rawValue, occurrenceKey: key)
    }

    private func hearing(_ date: String, level: CaseInstance.Level,
                         number: String, sourceID: String? = nil) -> StoredSession {
        StoredSession(dateRaw: date, time: nil, room: nil, event: "Судебное заседание",
            result: nil, court: "Проверочный суд", levelRaw: level.rawValue,
            caseNumber: number, sourceCardID: sourceID)
    }

    private func present(_ movement: CaseMovement, _ context: MovementContext,
                         _ snapshot: CaseSnapshot) -> CaseLifecyclePresentation {
        MovementDerivation.lifecyclePresentation(from: movement, snapshot: snapshot,
            context: context, today: today)
    }

    private func context(for movement: CaseMovement) -> MovementContext {
        let first = movement.instances.first { $0.level == .first }
        let level = movement.caseNumber.hasPrefix("3а-") ? "subject" : "district"
        let administrative = movement.caseNumber.hasPrefix("2а-") || movement.caseNumber.hasPrefix("3а-")
        let domain = first?.domain ?? "qa.sudrf.ru"
        return MovementContext(branchRaw: "general", region: "QA",
            searchDomain: domain, displayDomain: domain.replacingOccurrences(of: "--", with: "."),
            courtTitle: first?.court ?? "Проверочный суд", courtLevelRaw: level,
            courtCode: "00RS0001", cartotekaId: administrative ? "p1" : "g1",
            cartotekaLevelRaw: level, caseNumber: movement.caseNumber,
            cardURLString: first?.sourceURL?.absoluteString)
    }

    private func day(_ value: String) -> Date { DateUtil.parse(value)! }

    private func show(_ view: AnyView, in window: NSWindow) {
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: view.environment(\.colorScheme, .light)
            .frame(width: 1440, height: 900).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    }

    private func capture(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 10_000)
        try data.write(to: url, options: .atomic)
    }
}
