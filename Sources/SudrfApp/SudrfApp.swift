//  SudrfApp.swift — Sudrf · v2
//  Главное окно + WindowGroup для отдельных окон с текстом акта.
//  AppDelegate сохранён из вашей версии: без него SwiftPM-исполняемый файл
//  стартует как «фоновый», окно не получает фокус клавиатуры.

import SwiftUI
import AppKit

extension Notification.Name {
    /// Команда меню «Файл → Импортировать дела из CSV…»: сцена команд не имеет
    /// доступа к environment-роутеру окна, поэтому — через NotificationCenter;
    /// слушает RootView (там живут роутер и панель выбора файла).
    static let sudrfImportCases = Notification.Name("sudrfImportCases")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Нативные уведомления о новых событиях ленты + бейдж дока.
        FeedNotifier.shared.configure()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SudrfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var captchaSettings = CaptchaSettings.shared
    @State private var captchaStatusTick = Date()

    var body: some Scene {
        WindowGroup("СудРФ — поиск дел ОСЮ") {
            RootView()
        }
        // Без тайтлбара: светофор ложится на верх стеклянного сайдбара,
        // как в макете (FilterPane оставляет под него отступ сверху).
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Импортировать дела из CSV…") {
                    NotificationCenter.default.post(name: .sudrfImportCases, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            // Отдельный блок «Captcha» в системном меню — toggle
            // авто-солвера + статус. ⌃⌘A — стандарт для app-wide
            // boolean toggles.
            CommandMenu("Captcha") {
                CaptchaMenuContent(settings: captchaSettings)
            }
        }

        // Отдельное окно «текст акта»: openWindow(value: ActWindowPayload(…)).
        // Повторный вызов с тем же payload поднимает уже открытое окно.
        WindowGroup("Текст акта", for: ActWindowPayload.self) { $payload in
            if let payload {
                ActWindowView(payload: payload)
            }
        }
    }
}
