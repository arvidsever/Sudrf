import AppKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue372VisualTests: XCTestCase {
    struct Example: Decodable { let id: String; let movement: CaseMovement }
    var selectedMovement: CaseMovement?
    var selectedContext: MovementContext?
    static var cardMovement: CaseMovement?
    static var cardContext: MovementContext?

    func screen() throws -> (NSWindow, AppRouter) {
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set(false, forKey: "spotlight.systemIndexEnabled")
        UserDefaults.standard.set(true, forKey: "spotlight.systemIndexDisclosure.v1")
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let today = DateUtil.parse("02.10.2026")!
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/issue372_movement_examples.json")
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: fixture))
        for (index, example) in examples.enumerated() {
            let movement = example.movement
            let administrative = movement.caseNumber.hasPrefix("2а-") || movement.caseNumber.hasPrefix("3а-")
            let level = movement.caseNumber.hasPrefix("3а-") ? "subject" : "district"
            let context = MovementContext(branchRaw: "general", region: "Проверочный регион",
                searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru",
                courtTitle: movement.instances.first?.court ?? "Проверочный суд", courtLevelRaw: level,
                courtCode: "00RS0001", cartotekaId: administrative ? "p1" : "g1",
                cartotekaLevelRaw: level, caseNumber: movement.caseNumber,
                caseID: "qa372-\(index)", caseUID: "qa372-card-\(index)")
            var snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
            snapshot.deadlines = []
            snapshot.deadlineAssessments = [DeadlineRuleAssessment(ruleID: "KAS-CASSATION-KSOYU",
                kind: "cassation", statusRaw: DeadlineAssessmentStatus.needsLegalReview.rawValue)]
            let record = try store.reconcileAndUpsert(context: context, snapshot: snapshot,
                movement: movement, collections: ["Изолированная проверка #372"], movementFetchedAt: today)
            record.snapshot = snapshot
            if example.id == "historical-gpk" { selectedMovement = movement; selectedContext = context; Self.cardMovement = movement; Self.cardContext = context }
        }
        try store.save()
        _ = try TrackedStorePreparation.prepare(context: container.mainContext, today: today)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1440, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "СудРФ #372 — изолированные санитизированные примеры"
        window.isReleasedWhenClosed = false
        show(AnyView(MyCasesView().environmentObject(router)), in: window)
        return (window, router)
    }

    func testPreparedCasesOverviewCalendarAndCard() throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_DEADLINE372_QA_OUTPUT"] else {
            throw XCTSkip("Use Docs/qa/issue-372/run.sh for isolated native acceptance")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (window, router) = try screen()
        defer { window.close() }
        XCTAssertEqual(router.cases.count, 7)
        XCTAssertTrue(router.deadlines.isEmpty, "Preparation must not admit new terms")
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        try capture(window, to: output.appendingPathComponent("cases.png"))
        show(AnyView(OverviewView().environmentObject(router)), in: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        try capture(window, to: output.appendingPathComponent("overview.png"))
        router.openCalendar(date: DateUtil.parse("02.10.2026")!)
        show(AnyView(CalendarScreen().environmentObject(router)), in: window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        try capture(window, to: output.appendingPathComponent("calendar.png"))
        let movement = try XCTUnwrap(selectedMovement)
        let context = try XCTUnwrap(selectedContext)
        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: DateUtil.parse("02.10.2026")!)
        XCTAssertTrue(snapshot.deadlineAssessments?.contains(where: \.isIndeterminate) == true)
        // The actual scroll view is inspected and captured through the native QA host.

    }

    private func show(_ view: AnyView, in window: NSWindow, dark: Bool = false) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: AnyView(view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 1440, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))))
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
