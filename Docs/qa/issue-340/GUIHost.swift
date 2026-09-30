// Runs only the fixture-backed movement view; no production bootstrap or data store.
@MainActor final class VSRFQADelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var hosted: NSHostingView<AnyView>?
    @objc func runChecks() {
        let suite = XCTestSuite(forTestCaseClass: VSRFMovementPresentationTests.self)
        suite.run()
        let failures = suite.testRun?.failureCount ?? 1
        let report = "GUI tests: \(suite.testRun?.executionCount ?? 0), failures: \(failures), skips: \(suite.testRun?.skipCount ?? 0)\n"
        try? report.write(toFile: "/private/tmp/sudrf-340-gui-result.txt", atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            do {
                let movement = try VSRFMovementPresentationTests().makeMovement()
                let content = CaseMovementView(movement: movement, expanded: .constant([]), onBack: {})
                    .environment(\.colorScheme, .light)
                let hosted = NSHostingView(rootView: AnyView(content))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 660),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Sudrf — ВС РФ #340, изолированные данные"
                window.contentView = hosted
                window.appearance = NSAppearance(named: .aqua)
                window.center()
                window.makeKeyAndOrderFront(nil)
                self.window = window; self.hosted = hosted
                let menu = NSMenu()
                let top = NSMenuItem(title: "VSRF QA", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let run = NSMenuItem(title: "Run checks", action: #selector(self.runChecks), keyEquivalent: "r")
                run.target = self; sub.addItem(run); top.submenu = sub; menu.addItem(top)
                NSApp.mainMenu = menu
            } catch { print(error); exit(1) }
        }
    }
}
@main struct VSRFQABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        let delegate = VSRFQADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
