// Developer-only visual QA host. It uses a fresh temporary disk store and
// never starts production bootstrap, refresh, Spotlight, or network work.
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
private final class Issue431QADelegate: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow?
    private(set) var router: AppRouter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("sudrf-431-calendar-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let storeURL = directory.appendingPathComponent("qa-only.store")
            let container = try SudrfModelContainerFactory.make(
                inMemory: false, storeURL: storeURL)
            try seedSyntheticCases(in: container.mainContext)
            let corpus = CorpusStore(baseDir: directory.appendingPathComponent(
                "captcha-training", isDirectory: true))
            let router = try AppRouter(modelContainer: container,
                                       modelContainerIsPrepared: true,
                                       captchaCorpus: corpus)
            let hearingDate = DateUtil.parse("21.10.2026")!
            router.calMode = .month
            router.calMonth = DateUtil.startOfMonth(hearingDate)
            router.calWeekStart = DateUtil.startOfWeek(hearingDate)
            router.calSelectedDate = DateUtil.startOfDay(hearingDate)
            router.reload(today: DateUtil.parse("01.10.2026")!)
            self.router = router

            let window = NSWindow(
                contentRect: NSRect(x: 50, y: 50, width: 1580, height: 920),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered, defer: false)
            window.title = "СудРФ #431 — синтетическая QA-сборка"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(
                rootView: CalendarScreen().environmentObject(router))
            self.window = window
            installMenu()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fputs("ISSUE431_QA_ERROR: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "QA #431", action: nil, keyEquivalent: "")
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

    private func seedSyntheticCases(in context: ModelContext) throws {
        let date = "21.10.2026"
        let target = makeContext(
            number: "2-4461/2026", court: "Сыктывкарский городской суд Республики Коми",
            domain: "syktsud.komi.sudrf.ru", searchDomain: "syktsud--komi.sudrf.ru",
            code: "11RS0001", nativeID: "synthetic-431-base")
        let targetMovement = CaseMovement(
            uid: "synthetic-issue-431-target", caseNumber: target.caseNumber,
            inForce: false,
            instances: [
                CaseInstance(level: .first, court: target.courtTitle,
                    caseNumber: target.caseNumber, judge: nil, domain: target.displayDomain,
                    foundByUID: false, result: nil, sessions: []),
                CaseInstance(level: .appeal, court: "OBLSUD--MO",
                    caseNumber: "33-42895/2026", judge: nil,
                    domain: "OBLSUD--MO.SUDRF.RU", foundByUID: true, result: nil,
                    sessions: [CaseSession(date: date, time: "12:05",
                                           event: "Судебное заседание")]),
            ], complaints: [:], acts: [],
            parties: CaseParties(plaintiffs: ["Сторона А (синтетическая)"],
                                 defendants: ["Сторона Б (синтетическая)"]))
        try insert(context: target, movement: targetMovement, in: context,
                   collections: ["Синтетическая проверка #431"], oldSnapshot: true)

        let companion = makeContext(
            number: "2-731/2026", court: "Усть-Вымский районный суд Республики Коми",
            domain: "uwsud.komi.sudrf.ru", searchDomain: "uwsud--komi.sudrf.ru",
            code: "11RS0020", nativeID: "synthetic-431-companion")
        let companionMovement = CaseMovement(
            uid: "synthetic-issue-431-companion", caseNumber: companion.caseNumber,
            inForce: false,
            instances: [
                CaseInstance(level: .first, court: companion.courtTitle,
                    caseNumber: companion.caseNumber, judge: nil,
                    domain: companion.displayDomain, foundByUID: false,
                    result: nil, sessions: []),
                CaseInstance(level: .appeal, court: "Верховный Суд Республики Коми",
                    caseNumber: "33-731/2026", judge: nil, domain: "vs--komi.sudrf.ru",
                    foundByUID: true, result: nil,
                    sessions: [CaseSession(date: date, time: "12:05",
                                           event: "Судебное заседание")]),
            ], complaints: [:], acts: [],
            parties: CaseParties(plaintiffs: ["Сторона В (синтетическая)"],
                                 defendants: ["Сторона Г (синтетическая)"]))
        try insert(context: companion, movement: companionMovement, in: context,
                   collections: ["Синтетическая проверка #431"])
        try context.save()
    }

    private func insert(context movementContext: MovementContext,
                        movement: CaseMovement, in modelContext: ModelContext,
                        collections: [String], oldSnapshot: Bool = false) throws {
        var snapshot = MovementDerivation.snapshot(
            from: movement, context: movementContext,
            today: DateUtil.parse("01.10.2026")!)
        if oldSnapshot {
            snapshot.sessions = snapshot.sessions.map { value in
                var value = value
                value.sourceCardID = nil
                return value
            }
        }
        var snapshotData = try JSONEncoder().encode(snapshot)
        if oldSnapshot {
            guard var object = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any],
                  var sessions = object["sessions"] as? [[String: Any]] else {
                throw NSError(domain: "Issue431QA", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "Synthetic snapshot has an unexpected JSON shape"])
            }
            for index in sessions.indices { sessions[index].removeValue(forKey: "sourceCardID") }
            object["sessions"] = sessions
            snapshotData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let record = TrackedCaseRecord(
            key: movementContext.key, collections: collections,
            caseNumber: movementContext.caseNumber, courtTitle: movementContext.courtTitle,
            displayDomain: movementContext.displayDomain,
            contextData: try JSONEncoder().encode(movementContext), snapshotData: snapshotData)
        record.movement = movement
        record.movementFetchedAt = Date(timeIntervalSince1970: 1_797_000_000)
        modelContext.insert(record)
    }

    private func makeContext(number: String, court: String,
                             domain: String, searchDomain: String,
                             code: String, nativeID: String) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: searchDomain, displayDomain: domain, courtTitle: court,
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: code,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, caseID: nativeID, caseUID: "synthetic-link-\(nativeID)")
    }
}

@main
struct Issue431QABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Issue431QADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
