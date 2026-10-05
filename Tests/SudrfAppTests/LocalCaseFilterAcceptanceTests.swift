import AppKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class LocalCaseFilterAcceptanceTests: XCTestCase {
    func testThousandSavedCasesTypingBenchmark() throws {
        guard ProcessInfo.processInfo.environment["SUDRF_FILTER403_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in isolated 1000-case benchmark")
        }
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        _ = try LocalFilter403Fixture.seed(container, count: 1000, participants: 200)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let queries = ["Е", "Ер", "Ермаков", "Ермаков проверочный", "33-40001/2026", "Скрытый участник 199", "11RS0001-01-2026-000001-01", "несуществующий"]
        var elapsed: [Double] = []
        for _ in 0..<4 {
            for query in queries {
                router.query = query
                let start = ProcessInfo.processInfo.systemUptime
                let rows = router.filteredCases()
                for row in rows.prefix(20) {
                    _ = LocalCaseFilter.explanation(for: row, query: query)
                }
                let sample = (ProcessInfo.processInfo.systemUptime - start) * 1000
                elapsed.append(sample)
                print("FILTER403_SAMPLE query=\(query) ms=\(sample)")
                if query == "33-40001/2026" { XCTAssertEqual(rows.count, 1) }
                if query == "несуществующий" { XCTAssertTrue(rows.isEmpty) }
            }
        }
        elapsed.sort()
        let p95 = elapsed[Int(Double(elapsed.count - 1) * 0.95)]
        print("FILTER403_BENCHMARK cases=1000 participantsPerCase=200 samples=\(elapsed.count) medianMs=\(elapsed[elapsed.count / 2]) p95Ms=\(p95)")
        XCTAssertLessThan(p95, 100)
    }

    func testNativeScreensOnIsolatedData() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["SUDRF_FILTER403_QA_OUTPUT"] else {
            throw XCTSkip("Set SUDRF_FILTER403_QA_OUTPUT for isolated native screenshots")
        }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        _ = try LocalFilter403Fixture.seed(container, count: 3)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.query = "Ермаков"
        router.cases[2].production = nil
        router.collections = [("Все дела", 3), ("Жешарт", 1), ("Проверка", 1)]
        XCTAssertEqual(router.filteredCases().count, 3)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1320, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "СудРФ #403 — синтетические данные"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for (mode, dark, width) in [(MyCasesMode.list, false, 1320.0), (.stages, false, 1320.0), (.prods, true, 1320.0), (.clients, false, 950.0)] {
            router.myView = mode
            try capture(router, window: window, size: CGSize(width: width, height: 800), dark: dark,
                to: output.appendingPathComponent("\(mode.rawValue)-\(dark ? "dark" : "light").png"))
            XCTAssertFalse(LocalCaseFilter.explanation(for: router.filteredCases()[0], query: router.query)?.isEmpty ?? true)
        }
        router.query = "нет такого реквизита"
        try capture(router, window: window, size: CGSize(width: 950, height: 800), dark: false,
            to: output.appendingPathComponent("empty.png"))
        router.query = ""
        router.myView = .list
        XCTAssertEqual(router.filteredCases().count, 3)
    }

    private func capture(_ router: AppRouter, window: NSWindow, size: CGSize, dark: Bool, to url: URL) throws {
        window.setContentSize(size)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: MyCasesView().environmentObject(router)
            .buttonBorderShape(.capsule)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        window.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        try png.write(to: url, options: .atomic)
    }
}
