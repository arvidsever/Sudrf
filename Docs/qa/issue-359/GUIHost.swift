// Isolated native host: no SudrfApp bootstrap, production store or Spotlight writer.
@MainActor final class HeadingQADelegate: NSObject, NSApplicationDelegate {
    var views: [(NSWindow, NSHostingView<AnyView>)] = []
    @objc func runChecks() {
        let suite = XCTestSuite(forTestCaseClass: ActHeadingVisualTests.self)
        suite.run()
        let failures = suite.testRun?.failureCount ?? 1
        let report = "GUI tests: \(suite.testRun?.executionCount ?? 0), failures: \(failures), skips: \(suite.testRun?.skipCount ?? 0)\n"
        try? report.write(toFile: "/private/tmp/sudrf-359-gui-result.txt", atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            views = try ActHeadingVisualTests().windows()
            for (index, item) in views.enumerated() {
                item.0.setFrameOrigin(NSPoint(x: 70 + index * 670, y: 150))
                item.0.makeKeyAndOrderFront(nil)
            }
            let menu = NSMenu()
            let top = NSMenuItem(title: "Heading QA", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let run = NSMenuItem(title: "Run checks", action: #selector(runChecks), keyEquivalent: "r")
            run.target = self; sub.addItem(run); top.submenu = sub; menu.addItem(top)
            NSApp.mainMenu = menu
        } catch { print(error); exit(1) }
    }
}
@main struct HeadingQABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        let delegate = HeadingQADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
