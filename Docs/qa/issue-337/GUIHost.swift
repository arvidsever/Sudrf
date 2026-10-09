// Build-only visual QA host. It uses an in-memory store and synthetic hearings.
// It does not run production bootstrap, background refresh, or Spotlight sync.
import AppKit
import SwiftData
import SwiftUI
import CaptchaSolver
import SudrfKit

extension Notification.Name {
    static let sudrfImportCases = Notification.Name("sudrfImportCases")
    static let sudrfSpotlightPreferenceChanged = Notification.Name(
        "sudrfSpotlightPreferenceChanged")
}

@MainActor
private final class Issue337QADelegate: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: true)
            let qaDirectory = URL(fileURLWithPath: "/private/tmp/sudrf-337",
                                  isDirectory: true)
            try FileManager.default.createDirectory(
                at: qaDirectory, withIntermediateDirectories: true)
            let corpus = CorpusStore(baseDir: qaDirectory.appendingPathComponent(
                "captcha-corpus", isDirectory: true))
            let router = try AppRouter(modelContainer: container,
                                       modelContainerIsPrepared: true,
                                       captchaCorpus: corpus)

            let wednesday = DateUtil.parse("21.10.2026")!
            let thursday = DateUtil.parse("22.10.2026")!
            router.calMode = .week
            router.calMonth = DateUtil.startOfMonth(wednesday)
            router.calWeekStart = DateUtil.startOfWeek(wednesday)
            router.calSelectedDate = nil
            router.calendarHearings = [
                hearing(recordKey: "synthetic-337-oblast",
                        date: wednesday, time: "11:00",
                        caseNumber: "2-4461/2026", instanceNumber: "33-1234567890/2026",
                        courtIdentity: "OBLSUD--MO.SUDRF.RU",
                        courtLabel: "Московский областной суд", room: "Зал 4",
                        level: .appeal),
                hearing(recordKey: "synthetic-337-komi",
                        date: wednesday, time: "11:00",
                        caseNumber: "2-519/2026", instanceNumber: "33-731/2026",
                        courtIdentity: "vs--komi.sudrf.ru",
                        courtLabel: "Верховный суд Республики Коми", room: "Зал 3",
                        level: .appeal),
                hearing(recordKey: "synthetic-337-third",
                        date: wednesday, time: "11:00",
                        caseNumber: "2-1003/2026", instanceNumber: "33-1003/2026",
                        courtIdentity: "OBLSUD--MO.SUDRF.RU",
                        courtLabel: "Московский областной суд", room: "Зал 5",
                        level: .appeal),
                hearing(recordKey: "synthetic-337-fourth",
                        date: wednesday, time: "11:00",
                        caseNumber: "2-1004/2026", instanceNumber: "33-1004/2026",
                        courtIdentity: "vs--komi.sudrf.ru",
                        courtLabel: "Верховный суд Республики Коми", room: "Зал 6",
                        level: .appeal),
                hearing(recordKey: "synthetic-337-fifth",
                        date: wednesday, time: "11:00",
                        caseNumber: "2-1005/2026", instanceNumber: "33-1005/2026",
                        courtIdentity: "OBLSUD--MO.SUDRF.RU",
                        courtLabel: "Московский областной суд", room: "Зал 7",
                        level: .appeal),
                hearing(recordKey: "synthetic-337-material",
                        date: wednesday, time: "12:00",
                        caseNumber: "2-9143/2025", instanceNumber: "13-3241/2026",
                        courtIdentity: "syktsud--komi.sudrf.ru",
                        courtLabel: "Сыктывкарский городской суд Республики Коми",
                        room: "Зал 7", level: .material),
                hearing(recordKey: "synthetic-337-single",
                        date: thursday, time: "11:30",
                        caseNumber: "2-817/2026", instanceNumber: nil,
                        courtIdentity: "uwsud--komi.sudrf.ru",
                        courtLabel: "Усть-Вымский районный суд Республики Коми",
                        room: "Зал 2", level: .first),
            ]

            let window = NSWindow(
                contentRect: NSRect(x: 50, y: 50, width: 1380, height: 820),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "СудРФ #337 — синтетическая QA-сборка"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(
                rootView: CalendarScreen().environmentObject(router))
            self.window = window
            installMenu()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fputs("ISSUE337_QA_ERROR: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func hearing(recordKey: String, date: Date, time: String,
                         caseNumber: String, instanceNumber: String?,
                         courtIdentity: String, courtLabel: String, room: String,
                         level: CaseInstance.Level) -> TrackedHearing {
        TrackedHearing(
            recordKey: recordKey, date: date, time: time, caseNumber: caseNumber,
            parties: "Сторона А · сторона Б (синтетически)",
            court: courtIdentity, displayCourt: courtLabel,
            room: room, dateLabel: DateUtil.dateLabel(date), judge: "Судья А. А.",
            identitySuffix: "issue337-\(recordKey)", instanceCaseNumber: instanceNumber,
            instanceLevel: level)
    }

    private func installMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "QA #337", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, action, key) in [
            ("Светлая тема", #selector(useLightAppearance), "l"),
            ("Тёмная тема", #selector(useDarkAppearance), "d"),
            ("Закрыть QA", #selector(quitQA), "q"),
        ] {
            let option = NSMenuItem(title: title, action: action, keyEquivalent: key)
            option.target = self
            submenu.addItem(option)
        }
        item.submenu = submenu
        menu.addItem(item)
        NSApp.mainMenu = menu
    }

    @objc private func useLightAppearance() {
        window?.appearance = NSAppearance(named: .aqua)
    }

    @objc private func useDarkAppearance() {
        window?.appearance = NSAppearance(named: .darkAqua)
    }

    @objc private func quitQA() {
        NSApp.terminate(nil)
    }
}

@main
struct Issue337QABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Issue337QADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
