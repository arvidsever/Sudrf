// Isolated native host: no SudrfApp bootstrap or production store.
@MainActor final class DeadlineQADelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var router: AppRouter?
    @objc func runChecks() {
        let suite = XCTestSuite(forTestCaseClass: DeadlineExistingUITests.self)
        suite.run()
        let failures = suite.testRun?.failureCount ?? 1
        let report = "GUI tests: \(suite.testRun?.executionCount ?? 0), failures: \(failures), skips: \(suite.testRun?.skipCount ?? 0)\n"
        try? report.write(toFile: "/private/tmp/sudrf-existing-ui-gui-result.txt", atomically: true, encoding: .utf8)
        exit(failures == 0 && (suite.testRun?.executionCount ?? 0) > 0
            && suite.testRun?.skipCount == 0 ? 0 : 1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let screenName = ProcessInfo.processInfo.environment["SUDRF_DEADLINE_EXISTING_UI_SCREEN"] {
            do {
                let screen = try Issue222VisualTests().screen()
                window = screen.0; router = screen.1
                screen.1.reload(today: DateUtil.parse("03.10.2026")!)
                screen.1.myView = .list; screen.1.sortBy = .nextEvent
                if screenName == "card", let movement = Issue222VisualTests.cardMovement,
                   let context = Issue222VisualTests.cardContext {
                    screen.0.contentView = NSHostingView(rootView: CaseMovementView(
                        movement: movement, expanded: .constant([]), onBack: {}, sourceContext: context)
                        .environment(\.colorScheme, .light).frame(width: 1440, height: 900))
                } else if screenName == "overview" {
                    screen.0.contentView = NSHostingView(rootView: OverviewView()
                        .environmentObject(screen.1).environment(\.colorScheme, .light)
                        .frame(width: 1440, height: 900))
                }
                screen.0.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch { print(error); exit(1) }
        } else {
            DispatchQueue.main.async { self.runChecks() }
        }
    }

}
@main struct DeadlineQABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        let delegate = DeadlineQADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
