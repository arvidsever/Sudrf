// Synthetic GUI host for CalendarMonthViewTests; no production bootstrap.
extension CalendarMonthViewTests {
    func captureHostedScreens() throws {
        let fixture = try makeFixture()
        let configurations: [(String, NSAppearance.Name, CGSize, Date?)] = [
            ("01.09.2026", .aqua, CGSize(width: 1280, height: 760), nil),
            ("01.09.2026", .darkAqua, CGSize(width: 1280, height: 760), nil),
            ("01.10.2026", .aqua, CGSize(width: 1280, height: 760), nil),
            ("01.10.2026", .darkAqua, CGSize(width: 1280, height: 760), nil),
            ("01.02.2026", .aqua, CGSize(width: 760, height: 660), nil),
            ("01.10.2026", .aqua, CGSize(width: 1180, height: 720), fixture.september28),
            ("01.02.2026", .aqua, CGSize(width: 1180, height: 720), fixture.march1)
        ]
        for (index, configuration) in configurations.enumerated() {
            let (month, appearance, size, selected) = configuration
            fixture.router.calMonth = DateUtil.startOfMonth(try XCTUnwrap(DateUtil.parse(month)))
            fixture.router.calSelectedDate = selected
            NSApp.appearance = NSAppearance(named: appearance)
            let hosted = host(fixture.router, size: size)
            hosted.window.appearance = NSAppearance(named: appearance)
            hosted.view.rootView = AnyView(CalendarScreen().environmentObject(fixture.router)
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                .frame(width: size.width, height: size.height))
            hosted.window.makeKeyAndOrderFront(nil)
            settle(hosted.view)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            let bitmap = try XCTUnwrap(hosted.view.bitmapImageRepForCachingDisplay(in: hosted.view.bounds))
            hosted.view.cacheDisplay(in: hosted.view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try save(png, name: "hosted-\(index).png", to: "/private/tmp/sudrf-351-hosted")
            hosted.window.close()
        }
    }
}

extension CalendarMonthViewTests {
    func showInteractiveFixture() throws -> (NSWindow, NSHostingView<AnyView>, AppRouter) {
        let fixture = try makeFixture()
        fixture.router.calMonth = DateUtil.startOfMonth(fixture.september28)
        let hosted = host(fixture.router, size: CGSize(width: 1180, height: 720))
        hosted.window.title = "Sudrf — календарь #351, синтетические данные"
        return (hosted.window, hosted.view, fixture.router)
    }
}
@MainActor final class CalendarQADelegate: NSObject, NSApplicationDelegate {
    var fixture: (NSWindow, NSHostingView<AnyView>, AppRouter)?
    @objc func runChecks() {
        fixture?.0.close()
        let suite = XCTestSuite(forTestCaseClass: CalendarMonthViewTests.self)
        suite.run()
        var failures = suite.testRun?.failureCount ?? 1
        do { try CalendarMonthViewTests().captureHostedScreens() } catch {
            print(error)
            failures += 1
        }
        let report = "GUI tests: \(suite.testRun?.executionCount ?? 0), failures: \(failures), skips: \(suite.testRun?.skipCount ?? 0)\n"
        try? report.write(toFile: "/private/tmp/sudrf-351-gui-result.txt", atomically: true, encoding: .utf8)
        exit(failures == 0 && suite.testRun?.skipCount == 0 ? 0 : 1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            do {
                self.fixture = try CalendarMonthViewTests().showInteractiveFixture()
                let menu = NSMenu()
                let top = NSMenuItem(title: "Calendar QA", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let run = NSMenuItem(title: "Run GUI checks", action: #selector(self.runChecks), keyEquivalent: "r")
                run.target = self
                sub.addItem(run)
                top.submenu = sub
                menu.addItem(top)
                NSApp.mainMenu = menu
            } catch { print(error); exit(1) }
        }
    }
}
@main struct CalendarQABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        let delegate = CalendarQADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
