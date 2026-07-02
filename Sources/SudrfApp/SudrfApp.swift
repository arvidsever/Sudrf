//  SudrfApp.swift — Sudrf · v2
//  Главное окно + WindowGroup для отдельных окон с текстом акта.
//  AppDelegate сохранён из вашей версии: без него SwiftPM-исполняемый файл
//  стартует как «фоновый», окно не получает фокус клавиатуры.

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SudrfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("СудРФ — поиск дел ОСЮ") {
            RootView()
        }
        // Без тайтлбара: светофор ложится на верх стеклянного сайдбара,
        // как в макете (FilterPane оставляет под него отступ сверху).
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)

        // Отдельное окно «текст акта»: openWindow(value: ActWindowPayload(…)).
        // Повторный вызов с тем же payload поднимает уже открытое окно.
        WindowGroup("Текст акта", for: ActWindowPayload.self) { $payload in
            if let payload {
                ActWindowView(payload: payload)
            }
        }
    }
}
