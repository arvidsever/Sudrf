//  WindowChrome.swift — Sudrf · v4.3
//  С .windowStyle(.hiddenTitleBar) светофор прижимается к самому углу окна и
//  налезает на скругление стеклянного сайдбара. Лечится пустым unified-тулбаром:
//  он увеличивает высоту тайтлбар-зоны, и системные кнопки встают с нормальным
//  отступом (~20×26) — на верх стеклянной панели, как в макете. Сам тулбар
//  прозрачный и ничего не рисует (fullSizeContentView + titlebarAppearsTransparent).

import SwiftUI
import AppKit

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        DispatchQueue.main.async { Self.configure(probe.window) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.configure(nsView.window) }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        if window.toolbar == nil {
            // Пустой тулбар — только ради высоты тайтлбар-зоны.
            window.toolbar = NSToolbar(identifier: "sudrf.titlebar.spacer")
        }
        window.toolbarStyle = .unified
    }
}
