// Developer-only entry point. It does not run production bootstrap or background work.
import AppKit
import SwiftData
import SwiftUI
import SudrfKit

extension Notification.Name {
    static let sudrfImportCases = Notification.Name("sudrfImportCases")
    static let sudrfSpotlightPreferenceChanged = Notification.Name("sudrfSpotlightPreferenceChanged")
}

@MainActor final class Issue324QADelegate: NSObject, NSApplicationDelegate {
    private(set) var window: NSWindow?
    private(set) var router: AppRouter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("sudrf-324-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let storeURL = temp.appendingPathComponent("qa-only.store")
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: false)
            try seedSyntheticCases(in: store)
            try store.save()

            let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
            router.myView = .list
            router.productionFilters = [.civil, .kas]
            router.stageFilters = [.first, .appeal]
            router.tierFilters = [.district, .subject]
            self.router = router
            precondition(router.cases.count == 3, "The temporary store should contain three synthetic rows.")
            precondition(router.cases.filter { $0.stage == .done }.count == 1)
            precondition(router.cases.contains { $0.filterStage == .first && $0.filterTier == .district })
            precondition(router.cases.contains { $0.filterStage == .appeal && $0.filterTier == .subject })

            let window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 1480, height: 900),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "СудРФ #324 — синтетическая QA-сборка"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: MyCasesView().environmentObject(router)
                .buttonBorderShape(.capsule))
            self.window = window

            let menu = NSMenu()
            let item = NSMenuItem(title: "QA #324", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, action, key) in [
                ("Светлая тема", #selector(useLightAppearance), "l"),
                ("Тёмная тема", #selector(useDarkAppearance), "d"),
            ] {
                let option = NSMenuItem(title: title, action: action, keyEquivalent: key)
                option.target = self
                submenu.addItem(option)
            }
            item.submenu = submenu
            menu.addItem(item)
            NSApp.mainMenu = menu
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            print("ISSUE324_QA_ERROR: \(error)")
            exit(1)
        }
    }

    @objc private func useLightAppearance() {
        window?.appearance = NSAppearance(named: .aqua)
    }

    @objc private func useDarkAppearance() {
        window?.appearance = NSAppearance(named: .darkAqua)
    }

    private func seedSyntheticCases(in store: TrackedStore) throws {
        let scenarios: [(String, String, CourtLevel, String, CaseStageKind, String)] = [
            ("2-32401/2026", "g1", .district, "district", .first, "Синтетическое гражданское дело"),
            ("2а-32402/2026", "p2", .subject, "subject", .appeal, "Синтетическое дело КАС"),
            ("2-32403/2025", "g1", .district, "district", .done, "Синтетическое завершённое дело"),
        ]
        for (index, scenario) in scenarios.enumerated() {
            let (number, cartoteka, courtLevel, hostPrefix, stage, subject) = scenario
            let domain = "qa-\(hostPrefix).sudrf.ru"
            let key = "issue324-\(index + 1)"
            let cardURL = "https://\(domain)/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=324\(index + 1)&case_uid=\(key)&delo_id=1540005"
            var context = MovementContext(
                branchRaw: CourtBranch.general.rawValue, region: "Синтетический регион",
                searchDomain: domain, displayDomain: domain, courtTitle: "Проверочный суд",
                courtLevelRaw: courtLevel.rawValue, courtCode: "00RS0324",
                cartotekaId: cartoteka, cartotekaLevelRaw: courtLevel.rawValue,
                caseNumber: number, caseID: "324\(index + 1)", caseUID: key,
                essence: subject, cardURLString: cardURL)
            context.baseInstanceLevelRaw = (stage == .appeal ? "appeal" : "first")
            let snapshot = CaseSnapshot(
                uid: key, inForce: false, category: cartoteka == "p2" ? "КАС РФ" : "ГПК РФ",
                partiesShort: "Сторона А — Сторона Б (синтетические данные)", leadCharges: nil,
                secondPartyLine: nil, stageRaw: stage.rawValue, stageTag: stage.label,
                statusText: stage == .done ? "Завершено · синтетический пример" : "Синтетическое производство",
                statusChipRaw: stage == .done ? Palette.Chip.gray.rawValue : Palette.Chip.blue.rawValue,
                lastEvent: "01.10.2026 · Синтетическое событие", nextEvent: "—",
                nextChipRaw: Palette.Chip.gray.rawValue,
                steps: stage == .done ? ["done", "done", "done", "done"] : ["active", "todo", "todo", "todo"],
                sessions: [], deadlines: [], actsFingerprint: nil)
            _ = try store.upsert(context: context, snapshot: snapshot,
                                 collections: ["Синтетическая проверка #324"])
        }
    }
}

@main struct Issue324QABoot {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Issue324QADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
