// Developer-only Xcode entry point. Never uses the production bootstrap/store.
import AppKit
import SwiftUI
import SudrfKit

// These names normally live next to the excluded production entry point.
extension Notification.Name {
    static let sudrfImportCases = Notification.Name("sudrfImportCases")
    static let sudrfSpotlightPreferenceChanged = Notification.Name("sudrfSpotlightPreferenceChanged")
}

@MainActor final class Issue414QADelegate: NSObject, NSApplicationDelegate {
    struct Entry: Decodable { var movement: CaseMovement; var context: MovementContext }
    struct Fixture: Decodable { var entries: [Entry] }
    var window: NSWindow?
    var router: AppRouter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let url = Bundle.main.url(forResource: "issue414_ezhva_appeals", withExtension: "json")!
            let entries = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).entries
            let container = try SudrfModelContainerFactory.make(inMemory: true)
            let store = try TrackedStore(container: container, prepared: true)
            let today = DateUtil.parse("06.10.2026")!
            for entry in entries {
                _ = try store.upsert(context: entry.context,
                    snapshot: MovementDerivation.snapshot(from: entry.movement, context: entry.context, today: today),
                    movement: entry.movement, collections: ["Проверка #414"])
            }
            // Synthetic active control; unrelated to the observed appeals.
            var control = entries.last!
            control.context.caseNumber = "2а-41400/2026"
            control.context.caseID = "41400"
            control.context.caseUID = "41400-control"
            control.context.judicialUID = "11RS0010-01-2026-041400-00"
            control.context.cardURLString = nil
            control.context.sourceKnownCard = nil
            control.context.resultText = nil
            control.context.decisionDate = nil
            control.movement.caseNumber = control.context.caseNumber
            control.movement.uid = control.context.judicialUID!
            control.movement.instances = [CaseInstance(
                level: .first, court: control.context.courtTitle,
                caseNumber: control.context.caseNumber, judge: nil,
                domain: control.context.searchDomain, foundByUID: false, result: nil,
                sessions: [CaseSession(date: "01.10.2026", event: "Административное исковое заявление принято к производству"),
                           CaseSession(date: "01.11.2026", time: "10:00", event: "Судебное заседание")])]
            control.movement.inForce = false
            _ = try store.upsert(context: control.context,
                snapshot: MovementDerivation.snapshot(from: control.movement, context: control.context, today: today),
                movement: control.movement, collections: ["Проверка #414"])
            let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
            router.reload(today: today)
            router.myView = .list
            self.router = router
            precondition(router.cases.count == 4)
            precondition(router.cases.filter { $0.stage == .done }.count == 3)
            precondition(router.cases.filter { $0.stage == .first }.count == 1)
            let window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1480, height: 900),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "СудРФ #414 — изолированные данные"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: MyCasesView().environmentObject(router)
                .buttonBorderShape(.capsule))
            self.window = window
            let menu = NSMenu()
            let item = NSMenuItem(title: "QA", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let capture = NSMenuItem(title: "Сохранить снимок QA", action: #selector(captureScreen), keyEquivalent: "s")
            capture.target = self
            submenu.addItem(capture)
            item.submenu = submenu
            menu.addItem(item)
            NSApp.mainMenu = menu
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch { print("ISSUE414_QA_ERROR: \(error)"); exit(1) }
    }
    @objc func captureScreen() {
        do {
            guard let view = window?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.layoutSubtreeIfNeeded()
            window?.appearance?.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            let data = bitmap.representation(using: .png, properties: [:])!
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("sudrf-414-screenshots", isDirectory: true)
            let name = router?.stageFilter?.rawValue ?? "all"
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("cases-" + name + ".png"), options: .atomic)
            print("ISSUE414_QA_CAPTURE: " + output.appendingPathComponent("cases-" + name + ".png").path)
        } catch { print("ISSUE414_QA_CAPTURE_ERROR: \(error)") }
    }
}

@main struct Issue414QABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Issue414QADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
