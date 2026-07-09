import XCTest
@testable import SudrfKit

/// Тесты для `SearchDiagnostics`. Используют temp-dir чтобы не
/// загрязнять реальный `~/Library/Application Support/Sudrf/diagnostics/`.
final class SearchDiagnosticsTests: XCTestCase {

    private var tmpDir: URL!
    private var originalDir: URL!
    private var originalEnabled: Bool!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SearchDiagnosticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        originalDir = SearchDiagnostics.setDirForTesting(tmpDir)
        originalEnabled = SearchDiagnostics.enabled
        SearchDiagnostics.enabled = true
    }

    override func tearDownWithError() throws {
        SearchDiagnostics.enabled = originalEnabled
        SearchDiagnostics.setDirForTesting(originalDir)
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    func testDumpVariantWritesFile() {
        let html = "<html><body>Unrecognized content from sudrf server.</body></html>"
        SearchDiagnostics.dumpVariant(html: html, host: "example.sudrf.ru")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(files.count, 1)
        // Имя файла: `<host>_<timestamp>_<kind>.html`. Хост сохраняется
        // as-is (с точками), чтобы можно было прочитать. Тест проверяет,
        // что хост и kind присутствуют в имени.
        XCTAssertTrue(files[0].lastPathComponent.hasPrefix("example.sudrf.ru_"))
        XCTAssertTrue(files[0].lastPathComponent.contains("_variant"))
        XCTAssertTrue(files[0].lastPathComponent.hasSuffix(".html"))
        let saved = (try? String(contentsOf: files[0], encoding: .utf8)) ?? ""
        XCTAssertEqual(saved, html)
    }

    func testDumpFormCheckWritesFile() {
        let html = "<html><body>Form with no captcha marker we recognize.</body></html>"
        SearchDiagnostics.dumpFormCheck(html: html, host: "msk--sudrf.ru")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].lastPathComponent.hasPrefix("msk--sudrf.ru_"))
        XCTAssertTrue(files[0].lastPathComponent.contains("_form"))
    }

    func testDumpSolverMismatchWritesBothFiles() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let html = "<html><body>Server rejected our captcha answer.</body></html>"
        SearchDiagnostics.dumpSolverMismatch(png: Data(png), html: html, host: "fail.sudrf.ru")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(files.count, 2)
        let hasHTML = files.contains(where: { $0.pathExtension == "html" })
        let hasPNG = files.contains(where: { $0.pathExtension == "png" })
        XCTAssertTrue(hasHTML)
        XCTAssertTrue(hasPNG)
    }

    func testToggleDisables() {
        SearchDiagnostics.enabled = false
        SearchDiagnostics.dumpVariant(html: "<html>x</html>", host: "x.sudrf.ru")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(files.count, 0, "no files should be written when disabled")
    }

    func testFifoEvictionAt50Files() {
        // 51-я запись должна вытеснить самую старую.
        for i in 0..<51 {
            let url = tmpDir.appendingPathComponent("test-\(String(format: "%03d", i)).html")
            try? "old-\(i)".data(using: .utf8)?.write(to: url)
            // Принудительно ставим разные даты — старые с меньшим индексом.
            let date = Date().addingTimeInterval(TimeInterval(i))
            try? FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url.path
            )
        }
        SearchDiagnostics.dumpVariant(html: "<html>51st</html>", host: "evict.sudrf.ru")

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(entries.count, 50, "after eviction at 51, should be exactly 50")
        XCTAssertFalse(
            entries.contains(where: { $0.lastPathComponent == "test-000.html" }),
            "oldest file should have been evicted"
        )
    }
}
