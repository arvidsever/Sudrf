import AppKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

/// Opt-in acceptance screen using two synthetic dossiers and the real views.
@MainActor
final class PrivateComplaintVisualTests: XCTestCase {
    func testPrivateComplaintDatesInOverviewAndCalendar() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_DEADLINE125_QA_OUTPUT"] else {
            throw XCTSkip("Set SUDRF_DEADLINE125_QA_OUTPUT for isolated visual acceptance.")
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
        for (number, cartoteka, trigger, due, category, result) in [
            ("9-1251/2026", "g1", "11.09.2026", "02.10.2026", "Споры из договоров",
             "Исковое заявление возвращено заявителю"),
            ("9а-1252/2026", "p", "28.09.2026", "03.10.2026",
             "О защите избирательных прав и права на участие в референдуме (гл. 24 КАС РФ)",
             "Отказано в принятии административного искового заявления"),
        ] {
            let context = MovementContext(branchRaw: "general", region: "Проверочный регион",
                searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru",
                courtTitle: firstCourt, courtLevelRaw: "district", courtCode: "00RS0001",
                cartotekaId: cartoteka, cartotekaLevelRaw: "district", caseNumber: number)
            let first = CaseInstance(level: .first, court: firstCourt, caseNumber: number,
                judge: nil, domain: context.displayDomain, foundByUID: false,
                result: result, sessions: [CaseSession(date: trigger,
                    event: "Решение вопроса о принятии к производству", result: result)])
            let movement = CaseMovement(uid: "", caseNumber: number, inForce: false,
                instances: [first], complaints: [:], acts: [], category: category)
            let snapshot = MovementDerivation.snapshot(from: movement, context: context,
                                                       today: DateUtil.parse("01.10.2026")!)
            XCTAssertEqual(snapshot.deadlines.filter(\.isActive).count, 1)
            XCTAssertEqual(snapshot.deadlines.filter(\.isActive).first?.date, DateUtil.parse(due))
            XCTAssertEqual(snapshot.deadlines.first?.what, "Частная жалоба")
            _ = try store.reconcileAndUpsert(context: context, snapshot: snapshot,
                movement: movement, collections: ["Проверка"])
            try store.save()
        }
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let registry = try LegalDeadlineRegistry.load()
        for deadline in router.deadlines.filter({ $0.lifecycle == .active }) {
            let info = DeadlineInfoProjection(deadline: deadline, registry: registry)
            XCTAssertTrue(info.hasProvenance)
            XCTAssertTrue(info.formula.contains("15 рабочих дней") || info.formula.contains("5 календарных дней"))
        }
        XCTAssertEqual(router.deadlines.filter { $0.lifecycle == .active }.count, 2)
        NSApplication.shared.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 1400, height: 850),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "СудРФ #125 — синтетические сроки, изолированная проверка"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: OverviewView().environmentObject(router))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(500))
        try capture(window, to: output.appendingPathComponent("overview.png"))
        router.openCalendar(date: DateUtil.parse("02.10.2026"))
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
