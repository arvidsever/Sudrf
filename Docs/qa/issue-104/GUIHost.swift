import AppKit
import SwiftUI
import Foundation
@testable import SudrfKit
@testable import SudrfApp

private final class DenyNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@MainActor private final class DiskMovementDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var store: TrackedStore?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let manifestURL = URL(fileURLWithPath: "/private/tmp/sudrf-104-refresh-native-evidence/persisted-store.json")
            let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifestURL))
            guard let path = manifest["storePath"], path.hasPrefix("/private/tmp/sudrf-104-refresh-native-evidence/"),
                  let key = manifest["recordKey"] else { throw URLError(.badURL) }
            let store = try TrackedStore(container: SudrfModelContainerFactory.make(
                inMemory: false, storeURL: URL(fileURLWithPath: path)), prepared: true)
            guard let movement = store.record(forKey: key)?.movement else { throw URLError(.cannotDecodeContentData) }
            self.store = store
            let content = CaseMovementView(movement: movement, expanded: .constant([]), onBack: {})
                .environment(\.colorScheme, .light)
                .environment(\.openURL, OpenURLAction { _ in .discarded })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Sudrf — #104, сохранённое изолированное движение"
            window.contentView = NSHostingView(rootView: content)
            window.center(); window.makeKeyAndOrderFront(nil)
            self.window = window
            let menu = NSMenu()
            let appMenu = NSMenuItem(title: "QA", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.addItem(withTitle: "Завершить QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appMenu.submenu = submenu; menu.addItem(appMenu); NSApp.mainMenu = menu
        } catch { exit(1) }
    }
}

@main struct DiskMovementBoot {
    @MainActor static func main() {
        guard Bundle.main.bundleIdentifier == "ru.sudrf.qa.vsrf104.disk" else { exit(2) }
        // Standalone host: no AppRouter, refresh, publication, shared cookie session or application bootstrap.
        URLProtocol.registerClass(DenyNetwork.self)
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.regular)
        let delegate = DiskMovementDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
