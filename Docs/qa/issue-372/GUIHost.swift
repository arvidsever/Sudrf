// Isolated native host: no SudrfApp bootstrap or production store.
@MainActor final class DeadlineQADelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var router: AppRouter?
    @objc func runChecks() {
        window?.close()
        let suite = XCTestSuite(forTestCaseClass: Issue372VisualTests.self)
        suite.run()
        let failures = suite.testRun?.failureCount ?? 1
        let report = "GUI tests: \(suite.testRun?.executionCount ?? 0), failures: \(failures), skips: \(suite.testRun?.skipCount ?? 0)\n"
        try? report.write(toFile: "/private/tmp/sudrf-372-gui-result.txt", atomically: true, encoding: .utf8)
        exit(failures == 0 && suite.testRun?.executionCount == 1
            && suite.testRun?.skipCount == 0 ? 0 : 1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let screen = try Issue372VisualTests().screen()
            window = screen.0; router = screen.1
            if ProcessInfo.processInfo.environment["SUDRF_DEADLINE372_QA_SCREEN"] == "cases" {
                screen.1.stageFilter = .first
                screen.1.myView = .stages
                screen.0.contentView = NSHostingView(rootView: MyCasesView()
                    .environmentObject(screen.1).environment(\.colorScheme, .light)
                    .frame(width: 1440, height: 900))
            }
            if ProcessInfo.processInfo.environment["SUDRF_DEADLINE372_QA_SCREEN"] == "card", let movement = Issue372VisualTests.cardMovement, let context = Issue372VisualTests.cardContext {
                let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: DateUtil.parse("02.10.2026")!)
                screen.0.contentView = NSHostingView(rootView: CaseMovementView(movement: movement, expanded: .constant([]), onBack: {}, sourceContext: context, savedDeadlineAssessments: snapshot.deadlineAssessments).frame(width: 1440, height: 900))
            }
            screen.0.makeKeyAndOrderFront(nil)
            let menu = NSMenu()
            let top = NSMenuItem(title: "Deadline QA", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let run = NSMenuItem(title: "Run checks", action: #selector(runChecks), keyEquivalent: "r")
            run.target = self; sub.addItem(run); top.submenu = sub; menu.addItem(top)
            NSApp.mainMenu = menu
            if ProcessInfo.processInfo.environment["SUDRF_DEADLINE372_QA_AUTORUN"] == "1" {
                DispatchQueue.main.async { self.runChecks() }
            }
        } catch { print(error); exit(1) }
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
