import AppKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

/// Opt-in acceptance screen using two synthetic dossiers and the real views.
@MainActor
final class CalendarDeadlineVisualTests: XCTestCase {
    func testRepairedMonthDatesInOverviewAndCalendar() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_DEADLINE129_QA_OUTPUT"] else {
            throw XCTSkip("Set SUDRF_DEADLINE129_QA_OUTPUT for isolated visual acceptance.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let keys = ["myCollections", "overviewReadFeedIDs.v1", "notifiedFeedIDs.v1",
                    "materialFeedConsumedLegacyIDs.v1", "materialFeedPendingCounts.v1"]
        let preferences = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in preferences {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set(["Проверка"], forKey: "myCollections")
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let firstCourt = "Проверочный районный суд"
        let appealCourt = "Проверочный суд субъекта"
        for (number, trigger, due, count) in [
            ("2-1291/2026", "18.08.2026", "18.09.2026", 30),
            ("2-1292/2026", "30.06.2026", "30.09.2026", 90),
        ] {
            let context = MovementContext(branchRaw: "general", region: "Проверочный регион",
                searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru",
                courtTitle: firstCourt, courtLevelRaw: "district", courtCode: "00RS0001",
                cartotekaId: "g1", cartotekaLevelRaw: "district", caseNumber: number)
            let first = CaseInstance(level: .first, court: firstCourt, caseNumber: number,
                judge: nil, domain: context.displayDomain, foundByUID: false,
                result: "Иск удовлетворён", sessions: [CaseSession(
                    date: count == 30 ? trigger : "20.05.2026", event: "Судебное заседание",
                    result: "Иск удовлетворён; решение принято в окончательной форме")])
            let appeal = CaseInstance(level: .appeal, court: appealCourt,
                caseNumber: "33-1292/2026", judge: nil, domain: "qa-appeal.sudrf.ru",
                foundByUID: false, result: "Решение оставлено без изменения", sessions: [
                    CaseSession(date: trigger, event: "Судебное заседание",
                                result: "Решение оставлено без изменения"),
                    CaseSession(date: trigger,
                        event: "Составлено мотивированное апелляционное определение в окончательной форме")])
            let movement = CaseMovement(uid: "", caseNumber: number, inForce: count == 90,
                instances: count == 30 ? [first] : [first, appeal], complaints: [:], acts: [],
                category: "Споры из договоров")
            var snapshot = MovementDerivation.snapshot(from: movement, context: context,
                                                       today: DateUtil.parse("01.07.2026")!)
            let index = try XCTUnwrap(snapshot.deadlines.firstIndex { $0.kind == (count == 30 ? "appeal" : "cassation") })
            snapshot.deadlines[index].dateRef = DateUtil.addDays(DateUtil.parse(trigger)!, count)
                .timeIntervalSinceReferenceDate
            snapshot.deadlines[index].occurrenceKey = nil
            snapshot.deadlines[index].provenance = nil
            snapshot.deadlines = [snapshot.deadlines[index]]
            let record = try store.reconcileAndUpsert(context: context, snapshot: snapshot,
                movement: movement, collections: ["Проверка"])
            try store.save()
            _ = try TrackedStorePreparation.prepare(context: container.mainContext,
                                                   today: DateUtil.parse("01.09.2026")!)
            XCTAssertEqual(record.snapshot?.deadlines.filter(\.isActive).first?.date, DateUtil.parse(due))
        }
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let registry = try LegalDeadlineRegistry.load()
        for deadline in router.deadlines.filter({ $0.lifecycle == .active }) {
            let info = DeadlineInfoProjection(deadline: deadline, registry: registry)
            XCTAssertTrue(info.hasProvenance)
            XCTAssertTrue(info.formula.contains("месяц"))
        }
        XCTAssertEqual(router.deadlines.filter { $0.lifecycle == .active }.count, 2)
        NSApplication.shared.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 1400, height: 850),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "СудРФ #129 — синтетические сроки, изолированная проверка"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: OverviewView().environmentObject(router))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(500))
        try capture(window, to: output.appendingPathComponent("overview.png"))
        router.openCalendar(date: DateUtil.parse("30.09.2026"))
        window.contentView = NSHostingView(rootView: CalendarScreen().environmentObject(router))
        try await Task.sleep(for: .milliseconds(500))
        try capture(window, to: output.appendingPathComponent("calendar.png"))
    }

    private func capture(_ window: NSWindow, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
