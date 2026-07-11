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

    /// Главный тест для v0.38.6: сырые байты пишутся в файл
    /// **verbatim** (без перекодирования). Берем настоящий cp1251
    /// байт-секвенс для «Россия» (`D0 CF E0 E2 E5 F0`), и проверяем
    /// что в файле лежат ровно эти байты. Если бы код декодировал
    /// строку и записывал её как UTF-8, мы бы получили другую
    /// последовательность (cp1251 «Р» = `D0` интерпретируется как
    /// первый байт UTF-8 multi-byte sequence и порождает разный
    /// результат).
    func testDumpVariantPreservesRawBytes() {
        // "Россия" в windows-1251: D0 CF E0 E2 E5 F0
        let cp1251Russia: [UInt8] = [0xD0, 0xCF, 0xE0, 0xE2, 0xE5, 0xF0]
        let data = Data(cp1251Russia)
        SearchDiagnostics.dumpVariant(data: data, host: "test.cp1251.sudrf.ru")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(files.count, 1)
        let savedData = (try? Data(contentsOf: files[0])) ?? Data()
        XCTAssertEqual(savedData, data,
                       "file should contain EXACTLY the bytes we passed — no re-encoding")
    }

    /// Аналогично для dumpFormCheck — сырые байты формы сохраняются
    /// без изменений. Это и есть основной фикс v0.38.6: раньше код
    /// декодировал в String и писал как UTF-8 → браузер показывал
    /// mojibake. Теперь байты лежат в исходной кодировке.
    func testDumpFormCheckPreservesRawBytes() {
        // «Форма поиска» в windows-1251: реальные байты.
        let cp1251Form: [UInt8] = [
            0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E,  // <html>
            0xD4, 0xEE, 0xF0, 0xEC, 0xE0, 0x20, 0xEF, 0xEE, 0xE8, 0xF1, 0xEA, 0xE0,  // Форма поиска
            0x3C, 0x2F, 0x68, 0x74, 0x6D, 0x6C, 0x3E  // </html>
        ]
        let data = Data(cp1251Form)
        SearchDiagnostics.dumpFormCheck(data: data, host: "spbkirov.sudrf.ru")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(files.count, 1)
        let savedData = (try? Data(contentsOf: files[0])) ?? Data()
        XCTAssertEqual(savedData, data)
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
        let responseBytes: [UInt8] = [0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E, 0xD1, 0xEE, 0xE1, 0xE2, 0x3C, 0x2F, 0x68, 0x74, 0x6D, 0x6C, 0x3E]  // <html>Нет</html> in cp1251
        SearchDiagnostics.dumpSolverMismatch(
            png: Data(png),
            responseData: Data(responseBytes),
            host: "fail.sudrf.ru"
        )

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
        SearchDiagnostics.dumpVariant(data: Data([0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E]),
                                 host: "x.sudrf.ru")
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
        SearchDiagnostics.dumpVariant(data: Data("<html>51st</html>".utf8),
                                 host: "evict.sudrf.ru")

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
