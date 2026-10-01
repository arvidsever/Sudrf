import AppKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

/// Own native host and in-memory store; never opens the production database.
@MainActor
final class Issue128DeadlineVisualTests: XCTestCase {
    func screen() throws -> (NSWindow, AppRouter) {
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.set(false, forKey: "spotlight.systemIndexEnabled")
        UserDefaults.standard.set(true, forKey: "spotlight.systemIndexDisclosure.v1")
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let today = DateUtil.parse("01.10.2026")!
        for (index, example) in [
            ("2-6027/2026", "g1", "27.08.2026", "Судебное заседание", "Заседание отложено", "21.09.2026"),
            ("2а-5090/2026", "p1", "26.08.2026", "Судебное заседание", "Отложено", "05.10.2026"),
            ("2-3685/2026", "g1", "27.08.2026", "Решение вопроса о принятии иска к рассмотрению", "Иск принят к производству", ""),
        ].enumerated() {
            let (number, cartoteka, date, event, result, next) = example
            let court = "Проверочный районный суд"
            let context = MovementContext(branchRaw: "general", region: "Проверочный регион",
                searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru", courtTitle: court,
                courtLevelRaw: "district", courtCode: "00RS0001", cartotekaId: cartoteka,
                cartotekaLevelRaw: "district", caseNumber: number, caseID: "qa-128-\(index)", caseUID: "qa-card-128-\(index)")
            let first = CaseInstance(level: .first, court: court, caseNumber: number,
                judge: nil, domain: context.displayDomain, foundByUID: false,
                result: result, sessions: [CaseSession(date: date, time: "11:00", event: event, result: result),
                    CaseSession(date: next, time: "14:00", event: "Судебное заседание")].filter { !$0.date.isEmpty })
            let movement = CaseMovement(uid: "00RS0001-01-2026-00012\(index)-11",
                caseNumber: number, inForce: false, instances: [first], complaints: [:], acts: [],
                category: cartoteka == "p1" ? "Оспаривание решения органа" : "Споры из договоров")
            var snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
            if number == "2-6027/2026" {
                snapshot.deadlines = [StoredDeadline(kind: "appeal", what: "Апелляционная жалоба",
                    basis: "1 месяц со дня решения (27.08) — расчётный, проверьте",
                    calLabel: "апел. жалоба 2-6027/2026",
                    dateRef: DateUtil.parse("26.09.2026")!.timeIntervalSinceReferenceDate,
                    statusRaw: DeadlineStatus.confirmed.rawValue)]
            }
            let record = try store.reconcileAndUpsert(context: context, snapshot: snapshot,
                movement: movement, collections: ["Проверка #128"])
            record.snapshot = snapshot
            record.movementFetchedAt = today
            try store.save()
        }
        _ = try TrackedStorePreparation.prepare(context: container.mainContext, today: today)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1440, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "СудРФ #128 — синтетические дела, изолированная проверка"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        show(AnyView(OverviewView().environmentObject(router)), in: window)
        return (window, router)
    }

    func testOverviewActiveCasesAndHistoricalDeadline() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_DEADLINE128_QA_OUTPUT"] else {
            throw XCTSkip("Use Docs/qa/issue-128/run.sh for isolated native acceptance")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let (window, router) = try screen()
        defer { window.close() }
        XCTAssertTrue(router.deadlines.isEmpty)
        XCTAssertEqual(router.cases.count, 3)
        XCTAssertTrue(router.cases.allSatisfy { $0.stage == .first })
        let historical = try XCTUnwrap(router.inactiveDeadlines.first)
        XCTAssertEqual(historical.lifecycle, .superseded)
        XCTAssertEqual(historical.status, .confirmed)
        XCTAssertEqual(historical.date, DateUtil.parse("26.09.2026"))
        XCTAssertEqual(DeadlineInfoProjection(deadline: historical,
            registry: try LegalDeadlineRegistry.load()).lifecycle, "Не действует")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(400))
        try capture(window, to: output.appendingPathComponent("overview.png"))
        router.stageFilter = .first
        router.myView = .stages
        XCTAssertEqual(router.filteredCases().count, 3)
        show(AnyView(MyCasesView().environmentObject(router)), in: window)
        try await Task.sleep(for: .milliseconds(400))
        try capture(window, to: output.appendingPathComponent("active-cases.png"))
        router.openCalendar(date: historical.date)
        show(AnyView(CalendarScreen().environmentObject(router)), in: window)
        try await Task.sleep(for: .milliseconds(400))
        try capture(window, to: output.appendingPathComponent("calendar-history.png"))
    }

    private func show(_ view: AnyView, in window: NSWindow) {
        window.contentView = NSHostingView(rootView: AnyView(ZStack {
            Color(nsColor: .windowBackgroundColor)
            view
            }.environment(\.colorScheme, .light)
            .frame(width: 1440, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))))
    }

    private func capture(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window.appearance?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 10_000, "Native screen must contain rendered content")
        try data.write(to: url, options: .atomic)
    }
}
