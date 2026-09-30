import AppKit
import CryptoKit
import PDFKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class PublishedActViewTests: XCTestCase {
    func testActualPaneAndWindowOnIsolatedData() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_PDF_VISUAL_OUTPUT"] else {
            throw XCTSkip("Run with SUDRF_PDF_VISUAL_OUTPUT for native window QA.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let cacheDirectory = output.appendingPathComponent("isolated-cache")
        let text = "ВЕРХОВНЫЙ СУД РОССИЙСКОЙ ФЕДЕРАЦИИ\n3-ИКАД25-3-А2\nКАССАЦИОННОЕ ОПРЕДЕЛЕНИЕ\n15 октября 2025 года\n\nПроверочный обезличенный судебный акт.\nРешение оставлено без изменения."
        let data = try XCTUnwrap(ActPDFExporter.renderData(text: text))
        let source = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000001")!
        let provenance = PublishedActProvenance(sourceURL: source, finalURL: source, format: .pdf,
            contentType: "application/pdf", contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count, fetchedAt: .now, extractorVersion: 1)
        let file = PublishedActFile(text: text, provenance: provenance, data: data)
        let cache = ActFileCache(directory: cacheDirectory)
        let selection = PublishedActSelection(cache: cache) { _, _ in
            try await Task.sleep(for: .milliseconds(500))
            return file
        }
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true, projectionSynchronizer: { _, _ in })
        let context = MovementContext(branchRaw: "general", region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Проверочный суд субъекта", courtLevelRaw: "subject",
            courtCode: "11OS0000", cartotekaId: "adm1", cartotekaLevelRaw: "subject", caseNumber: "3а-85/2025")
        let first = CaseAct(id: "lower", title: "Решение", date: "28.07.2025", courtShort: "Суд субъекта", instanceLevel: .first)
        let act = CaseAct(id: "vs-pdf", title: "Кассационное определение", date: "15.10.2025",
            courtShort: "ВС РФ", instanceLevel: .vsCassation, sourceFileURL: source, productionNumber: "3-ИКАД25-3-А2")
        let instances = [CaseInstance(level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: true, result: "Отказано", sessions: [], actID: first.id),
            CaseInstance(level: .vsCassation, court: "Верховный Суд РФ", caseNumber: "3-ИКАД25-3-А2",
            judge: nil, domain: "vsrf.ru", foundByUID: true, result: "Оставлено без изменения", sessions: [], actID: act.id)]
        let movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: true,
            instances: instances, complaints: [:], acts: [first, act], actBodies: [first.id: "РЕШЕНИЕ\nОбезличенное решение первой инстанции."])
        let record = try store.upsert(context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context), movement: movement, collections: ["Проверка PDF"])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true,
            selectedPublishedAct: selection, trackedStoreProjectionSynchronizer: { _, _ in })
        router.openCase(key: record.key)
        let window = host(AnyView(LiveActsPane().environmentObject(router)), title: "СудРФ #345 — проверка PDF")
        defer { window.close() }
        router.selectAct(act.id)
        await settle()
        try snapshot(window, name: "loading", output: output)
        for _ in 0..<100 where selection.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(router.selectedActText, text)
        XCTAssertNotNil(selection.fileURL)
        let exportURL = output.appendingPathComponent("exported-original.pdf")
        try ActPDFExporter.write(to: exportURL, text: text, originalPDF: data)
        XCTAssertEqual(try Data(contentsOf: exportURL), data)
        await settle()
        try snapshot(window, name: "text", output: output)
        XCTAssertTrue(press("Оригинал PDF", in: window.contentView!))
        await settle()
        XCTAssertTrue(hasPDFView(window.contentView!))
        try snapshot(window, name: "original", output: output)
        XCTAssertTrue(press("Текст", in: window.contentView!))
        await settle()

        let payload = ActWindowPayload(caseNumber: act.productionNumber!, actText: text,
            pdfFileURL: selection.fileURL, pdfProvenance: selection.provenance)
        let separate = host(AnyView(ActWindowView(payload: payload)), title: "СудРФ #345 — отдельный акт")
        await settle()
        try snapshot(separate, name: "separate-window", output: output)
        separate.close()
        let searchSelection = PublishedActSelection(cache: cache) { _, _ in
            XCTFail("The search pane must reuse the verified file")
            throw URLError(.notConnectedToInternet)
        }
        let search = SearchModel(selectedPublishedAct: searchSelection)
        let court = SearchModel.CourtOption(domain: context.displayDomain, title: context.courtTitle, level: .district)
        let result = CaseSearchResult(caseNumber: context.caseNumber)
        let searchKey = MovementContext.identityKey(displayDomain: court.domain, courtCode: nil, caseNumber: result.caseNumber)
        MovementMemoryCache.shared.put(searchKey, try XCTUnwrap(router.liveMovement))
        defer { MovementMemoryCache.shared.remove(searchKey) }
        search.tier = .district
        search.courts = [court]
        search.selectedCourtID = court.id
        search.cartotekaId = "g1"
        search.results = [result]
        await search.openMovement(result)
        XCTAssertNotNil(search.movement, search.status)
        search.selectAct(act.id)
        let searchWindow = host(AnyView(SearchQAPane(model: search)), title: "СудРФ #345 — поиск")
        for _ in 0..<100 where searchSelection.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(searchSelection.data, data)
        await settle()
        try snapshot(searchWindow, name: "search", output: output)
        searchWindow.close()
        router.selectAct(first.id)
        XCTAssertNil(selection.data)
        XCTAssertEqual(router.selectedActText, movement.actBodies[first.id])
        router.selectAct(act.id)
        await settle()
        XCTAssertEqual(selection.data, data)
        if let seconds = ProcessInfo.processInfo.environment["SUDRF_PDF_VISUAL_HOLD"].flatMap(Double.init) {
            try await Task.sleep(for: .seconds(min(seconds, 55)))
        }

        let textDocument = try XCTUnwrap(PDFDocument(data: data))
        let scanData = try XCTUnwrap(textDocument.page(at: 0)?.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox))
        let scanDocument = PDFDocument()
        scanDocument.insert(try XCTUnwrap(PDFPage(image: scanData)), at: 0)
        let scan = try XCTUnwrap(scanDocument.dataRepresentation())
        XCTAssertTrue(scanDocument.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let scanWindow = host(AnyView(CourtActContent(text: nil, pdfData: scan, isPublishedFile: true)), title: "СудРФ #345 — скан без текста")
        await settle()
        try snapshot(scanWindow, name: "scan", output: output)
        if let seconds = ProcessInfo.processInfo.environment["SUDRF_PDF_SCAN_HOLD"].flatMap(Double.init) {
            try await Task.sleep(for: .seconds(min(seconds, 55)))
        }
        XCTAssertTrue(hasPDFView(scanWindow.contentView!))
        scanWindow.close()
        var retries = 0
        let errorWindow = host(AnyView(CourtActContent(text: nil, pdfData: nil, isPublishedFile: true,
            error: "Суд временно недоступен", retry: { retries += 1 })), title: "СудРФ #345 — ошибка PDF")
        await settle()
        try snapshot(errorWindow, name: "error", output: output)
        click(errorWindow, at: NSPoint(x: 340, y: 718))
        await settle()
        XCTAssertEqual(retries, 1)
        errorWindow.close()
    }

    private func host(_ root: AnyView, title: String) -> NSWindow {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 540, height: 740),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root.environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.makeKeyAndOrderFront(nil)
        return window
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(120)) }
    private func snapshot(_ window: NSWindow, name: String, output: URL) throws {
        if ProcessInfo.processInfo.environment["SUDRF_PDF_NATIVE_SCREENSHOTS"] == "1" {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber),
                                 output.appendingPathComponent(name + ".png").path]
            try capture.run()
            capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
            return
        }
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
    private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }
    private func press(_ label: String, in object: Any, depth: Int = 0) -> Bool {
        guard depth < 30 else { return false }
        if let segments = object as? NSSegmentedControl {
            for index in 0..<segments.segmentCount where segments.label(forSegment: index) == label {
                segments.selectedSegment = index
                return segments.sendAction(segments.action, to: segments.target)
            }
        }
        if let button = object as? NSButton, button.title == label {
            button.performClick(nil)
            return true
        }
        if let view = object as? NSView {
            for child in view.subviews where press(label, in: child, depth: depth + 1) { return true }
        }
        guard let element = object as? NSAccessibilityProtocol else { return false }
        if element.accessibilityLabel() == label || element.accessibilityTitle() == label, element.accessibilityPerformPress() { return true }
        for child in element.accessibilityChildren() ?? [] {
            if press(label, in: child, depth: depth + 1) { return true }
        }
        return false
    }
    private func hasPDFView(_ view: NSView) -> Bool {
        view is PDFView || view.subviews.contains(where: hasPDFView)
    }
}

private struct SearchQAPane: View {
    @ObservedObject var model: SearchModel
    @Environment(\.openWindow) private var openWindow
    var body: some View { ActSwitcherPane(model: model, openWindow: openWindow) }
}
