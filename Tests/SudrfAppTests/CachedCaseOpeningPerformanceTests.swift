import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

/// Opt-in benchmark of the real opening route on synthetic data. The same
/// test runs against the parent commit and the fixed commit, without network.
@MainActor
final class CachedCaseOpeningPerformanceTests: XCTestCase {
    func testOpening500CachedCases() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SUDRF_OPENING_QA_OUTPUT"] else {
            throw XCTSkip("Set SUDRF_OPENING_QA_OUTPUT for the isolated opening benchmark.")
        }
        let defaults = UserDefaults.standard
        let preferenceKeys = ["myCollections", "overviewReadFeedIDs.v1", "notifiedFeedIDs.v1",
            "materialFeedConsumedLegacyIDs.v1", "materialFeedPendingCounts.v1"]
        let savedPreferences = preferenceKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedPreferences {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        defaults.set(["Проверка"], forKey: "myCollections")
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let container = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: output.appendingPathComponent("synthetic-" + UUID().uuidString + ".store"))
        let store = try TrackedStore(container: container, prepared: true)
        let today = DateUtil.today
        var keys: [String] = []
        for index in 1...500 {
            let number = "2-\(index)/2026"
            let context = MovementContext(
                branchRaw: "general", region: "Проверочный регион",
                searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru",
                courtTitle: "Проверочный районный суд", courtLevelRaw: "district",
                courtCode: "00RS0001", cartotekaId: "g1", cartotekaLevelRaw: "district",
                caseNumber: number, caseID: "synthetic-\(index)")
            let instances = (0..<3).map { round in
                let level: CaseInstance.Level = round == 0 ? .first : .appeal
                return CaseInstance(
                    level: level, court: round == 0 ? context.courtTitle : "Проверочный суд субъекта",
                    caseNumber: round == 0 ? number : "33-\(index + round * 1000)/2026",
                    judge: nil, domain: context.displayDomain, foundByUID: false,
                    result: round == 2 ? nil : "Решение оставлено без изменения",
                    sessions: (0..<6).map { event in
                        CaseSession(date: sourceDate(DateUtil.addDays(today, event - 5 + round)),
                            time: "10:00", event: "Судебное заседание",
                            result: event < 5 ? "Отложено" : nil)
                    })
            }
            let act = CaseAct(id: "act-\(index)", title: "Решение",
                date: sourceDate(DateUtil.addDays(today, -1)),
                courtShort: context.courtTitle, instanceLevel: .first)
            let movement = CaseMovement(uid: "", caseNumber: number, inForce: false,
                instances: instances, complaints: [:], acts: [act],
                actBodies: [act.id: "РЕШЕНИЕ\nПроверочный судебный акт по делу № \(number).\n"
                    + String(repeating: "Обезличенный текст для проверки открытия карточки.\n", count: 20)])
            let snapshot = MovementDerivation.snapshot(from: movement, context: context)
            let record = TrackedCaseRecord(key: context.key, collections: ["Проверка"],
                caseNumber: number, courtTitle: context.courtTitle,
                displayDomain: context.displayDomain,
                contextData: try JSONEncoder().encode(context),
                snapshotData: try JSONEncoder().encode(snapshot))
            record.movement = movement
            container.mainContext.insert(record)
            keys.append(record.key)
        }
        try store.save()
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        XCTAssertEqual(router.cases.count, 500)
        router.section = .cases
        var derivedPublications = 0
        let subscriptions = [
            router.$calendarHearings.dropFirst().sink { _ in derivedPublications += 1 },
            router.$hearings.dropFirst().sink { _ in derivedPublications += 1 },
            router.$deadlines.dropFirst().sink { _ in derivedPublications += 1 },
        ]
        var milliseconds: [Double] = []
        for key in keys.prefix(20) {
            let start = ContinuousClock.now
            router.openCase(key: key)
            let elapsed = start.duration(to: .now).components
            milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            XCTAssertEqual(router.openedCase, store.record(forKey: key)?.caseNumber)
            XCTAssertNotNil(router.liveMovement)
            XCTAssertFalse(router.loadingMovement)
        }
        let sorted = milliseconds.sorted()
        let result: [String: Any] = [
            "cases": 500, "instancesPerCase": 3, "sessionsPerInstance": 6,
            "openings": milliseconds.count, "milliseconds": milliseconds,
            "medianMilliseconds": sorted[sorted.count / 2],
            "p95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "derivedPublications": derivedPublications,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("opening.json"), options: .atomic)
        print("OPENING_BENCHMARK median_ms=\(sorted[sorted.count / 2]) p95_ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)]) derived_publications=\(derivedPublications)")
        _ = subscriptions

        if ProcessInfo.processInfo.environment["SUDRF_OPENING_NATIVE_QA"] == "1" {
            NSApplication.shared.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 1400, height: 850),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "СудРФ #385 — 500 синтетических дел, изолированная проверка"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MyCasesView().environmentObject(router))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(300))
            try capture(window, output: output.appendingPathComponent("cases.png"))
            router.closeCase()
            let clickStart = ContinuousClock.now
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                    location: NSPoint(x: 420, y: 670), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            let clickDuration = clickStart.duration(to: .now).components
            let clickMilliseconds = Double(clickDuration.seconds) * 1000
                + Double(clickDuration.attoseconds) / 1e15
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(router.openedCase, "2-500/2026", "real MyCasesView row must open")
            XCTAssertLessThan(clickMilliseconds, 500, "native click must not block for seconds")
            try JSONSerialization.data(withJSONObject: ["milliseconds": clickMilliseconds],
                options: [.prettyPrinted]).write(to: output.appendingPathComponent("native-click.json"))
            let movement = try XCTUnwrap(router.liveMovement)
            window.contentView = NSHostingView(rootView: HStack(spacing: 12) {
                CaseMovementView(movement: movement, expanded: .constant([]), onBack: {})
                LiveActsPane().frame(width: 400)
            }.environmentObject(router))
            try await Task.sleep(for: .milliseconds(300))
            try capture(window, output: output.appendingPathComponent("opened.png"))
            window.close()
        }
    }

    private func sourceDate(_ date: Date) -> String {
        let parts = DateUtil.cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%04d", parts.day!, parts.month!, parts.year!)
    }

    private func capture(_ window: NSWindow, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
