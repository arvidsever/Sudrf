import XCTest
@testable import CaptchaSolver

/// Тесты для `CaptchaSolverLog`. Используют временный каталог
/// (через `URL(fileURLWithPath:)` в `NSTemporaryDirectory()`), чтобы
/// не трогать реальный `~/Library/Application Support/Sudrf/`.
final class CaptchaSolverLogTests: XCTestCase {

    private var tmpDir: URL!
    private var logFile: URL!
    private var failuresDir: URL!
    private var log: CaptchaSolverLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptchaSolverLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        logFile = tmpDir.appendingPathComponent("captcha-solve.log")
        failuresDir = tmpDir.appendingPathComponent("captcha-failures")
        try FileManager.default.createDirectory(at: failuresDir, withIntermediateDirectories: true)
        log = CaptchaSolverLog(fileURL: logFile, failuresDir: failuresDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    /// Главный регресс: каждая запись `logSkip`/`logAttempt` ДОЛЖНА
    /// попадать в файл как отдельная строка. До фикса (v0.38.3) handle
    /// открывался на offset 0 и каждая запись затирала предыдущую —
    /// в логе оставалась только последняя строка. Этот тест ловит
    /// регрессию в одну строку.
    func testAppendAccumulatesAllLines() {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test-write-queue")
        let log = self.log!

        for i in 0..<5 {
            group.enter()
            queue.async {
                log.logSkip(host: "court-\(i).sudrf.ru", kind: .sudrfToken,
                            reason: "low confidence on attempt \(i)")
                group.leave()
            }
        }
        group.wait()
        // `logSkip` пишет в собственный serial queue, дождёмся
        // её завершения отдельным опросом.
        waitForFileLines(expected: 5)

        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: true).count
        XCTAssertEqual(lineCount, 5, "log file should have 5 distinct lines, got \(lineCount)")
        for i in 0..<5 {
            XCTAssertTrue(content.contains("court-\(i).sudrf.ru"),
                          "line for court-\(i) missing from log")
        }
    }

    /// Записи разных типов (SKIP / ERROR / logAttempt) корректно
    /// разделяются переводами строк. До фикса всё сливалось в одну
    /// длинную строку с потерей переносов.
    func testMixedEntriesAreLineSeparated() {
        log.logAttempt(host: "h1", kind: .sudrfToken,
                       attempt: CaptchaAttempt(value: "12345", confidence: 0.9, duration: 0.01))
        log.logSkip(host: "h1", kind: .sudrfToken, reason: "low conf")
        log.logError(host: "h1", kind: .sudrfToken, error: NSError(domain: "t", code: 1))
        waitForFileLines(expected: 3)

        let content = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines.contains(where: { $0.contains("\th1\t") && $0.contains("value=12345") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("\th1\t") && $0.contains("\tSKIP\t") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("\th1\t") && $0.contains("\tERROR\t") }))
    }

    /// `logFailedImage` создаёт PNG-файл и возвращает путь.
    func testLogFailedImageWritesFile() {
        // Минимальный валидный PNG: 1×1 прозрачный.
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,  // signature
            0x00, 0x00, 0x00, 0x0D,                            // IHDR length
            0x49, 0x48, 0x44, 0x52,                            // "IHDR"
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,  // 1x1
            0x08, 0x06, 0x00, 0x00, 0x00,                    // 8-bit RGBA
            0x1F, 0x15, 0xC4, 0x89,                            // CRC
            0x00, 0x00, 0x00, 0x0D,                            // IDAT length
            0x49, 0x44, 0x41, 0x54,                            // "IDAT"
            0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, 0x05,
            0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
            0x00, 0x00, 0x00, 0x00,                            // CRC
            0x49, 0x45, 0x4E, 0x44,                            // "IEND"
            0xAE, 0x42, 0x60, 0x82
        ]
        let url = log.logFailedImage(png: Data(png),
                                      host: "test.sudrf.ru",
                                      kind: .sudrfToken)
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path),
                      "failure PNG should be on disk")
        let savedData = try? Data(contentsOf: url!)
        XCTAssertEqual(savedData, Data(png))
    }

    /// FIFO-eviction: при превышении `maxFailureImages` (50) самые
    /// старые удаляются. Создаём 52 файла с разной датой модификации,
    /// ожидаем 50 самых свежих на диске.
    func testEvictionAtMaxFailureImages() {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for i in 0..<52 {
            let url = failuresDir.appendingPathComponent("test-\(String(format: "%03d", i)).png")
            try? Data(png).write(to: url)
            // Принудительно ставим разные даты — старые с меньшим индексом.
            let date = Date().addingTimeInterval(TimeInterval(i))
            try? FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: url.path
            )
        }
        // 51-я запись должна вытеснить самый старый (i=0).
        let savedURL = log.logFailedImage(png: Data(png),
                                          host: "test.sudrf.ru",
                                          kind: .sudrfToken)
        XCTAssertNotNil(savedURL)

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: failuresDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        XCTAssertEqual(entries.count, 50, "after eviction at 51, should be exactly 50")
        // Самый старый (test-000.png) должен быть удалён.
        XCTAssertFalse(
            entries.contains(where: { $0.lastPathComponent == "test-000.png" }),
            "oldest file should have been evicted"
        )
    }

    func testFourthRotationKeepsBoundedGenerations() {
        let oversizedReason = String(repeating: "x", count: 1_100_000)
        for i in 0..<4 {
            log.logSkip(host: "rotation.sudrf.ru", kind: .sudrfToken,
                        reason: oversizedReason)
            log.logSkip(host: "rotation.sudrf.ru", kind: .sudrfToken,
                        reason: "rotation-\(i)")
        }
        waitForFileText("rotation-3")

        let names = ((try? FileManager.default.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).map(\.lastPathComponent)
        XCTAssertLessThanOrEqual(names.filter { $0 == "captcha-solve.log" ||
            $0.hasPrefix("captcha-solve.log.") }.count, 4)
        XCTAssertTrue(names.contains("captcha-solve.log"))
    }

    func testSolvedCountTodayCountsSuccessButNotYesterday() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let yesterdayLine = "\(formatter.string(from: yesterday))\tyesterday.sudrf.ru\tsudrfToken\tvalue=00000\tconf=1.00\tdur_ms=1\n"
        try yesterdayLine.write(to: logFile, atomically: true, encoding: .utf8)

        log.logAttempt(
            host: "today.sudrf.ru",
            kind: .sudrfToken,
            attempt: CaptchaAttempt(value: "12345", confidence: 0.9, duration: 0.01)
        )
        waitForFileLines(expected: 2)

        XCTAssertEqual(log.solvedCountToday(), 1)
    }

    /// Спит пока в файле не окажется ровно `expected` строк, до 3 секунд.
    private func waitForFileLines(expected: Int) {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let content = try? String(contentsOf: logFile, encoding: .utf8) {
                let n = content.split(separator: "\n", omittingEmptySubsequences: true).count
                if n >= expected { return }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func waitForFileText(_ text: String) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let content = try? String(contentsOf: logFile, encoding: .utf8),
               content.contains(text) {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("timed out waiting for \(text) in log")
    }
}
