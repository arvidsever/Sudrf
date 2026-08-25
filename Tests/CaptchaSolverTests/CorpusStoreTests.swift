import XCTest
@testable import CaptchaSolver

/// Тесты для `CorpusStore` (v0.38.9). Используют временный
/// каталог (через `init(baseDir:)`), чтобы не трогать реальный
/// `~/Library/Application Support/Sudrf/captcha-training/`.
final class CorpusStoreTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CorpusStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    /// `add` пишет PNG в `solved-numeric/<code>_<host>_<ts>_<uuid>.png`
    /// для `.sudrfToken` и в `solved-text/...` для `.kcaptcha`.
    func testAddWritesToCorrectSubdir() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        // Numeric.
        let n = await store.add(
            png: Data([0x00, 0x01, 0x02]),
            code: "12345",
            host: "ramenskoe--mo.sudrf.ru",
            kind: .sudrfToken
        )
        let n2 = try XCTUnwrap(n)
        XCTAssertTrue(n2.path.contains("/solved-numeric/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: n2.path))
        // Text.
        let t = await store.add(
            png: Data([0x00]),
            code: "abcde",
            host: "msudrf.ru",
            kind: .kcaptcha
        )
        let t2 = try XCTUnwrap(t)
        XCTAssertTrue(t2.path.contains("/solved-text/"))
    }

    /// FIFO-eviction: после превышения потолка самые старые файлы
    /// удаляются, пока count не вернётся в лимит.
    func testFIFOEvictsOldestAtCeiling() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        // Override ceiling to 5 for fast test.
        await store._setCeilingForTesting(5, kind: .sudrfToken)
        // Add 7 captchas, each with a small sleep so mtime differs.
        for i in 0..<7 {
            _ = await store.add(
                png: Data([UInt8(i)]),
                code: String(format: "%05d", 10000 + i),
                host: "court-\(i).sudrf.ru",
                kind: .sudrfToken
            )
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        let count = await store.currentCount(kind: .sudrfToken)
        XCTAssertEqual(count, 5, "ceiling=5, after 7 adds should be exactly 5")
    }

    /// `markTrained` сбрасывает `pendingSinceLastTrain` и обновляет
    /// `lastTrainedCount`.
    func testMarkTrainedResetsPendingCount() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        for i in 0..<3 {
            _ = await store.add(
                png: Data([UInt8(i)]),
                code: String(format: "%05d", 20000 + i),
                host: "h\(i).sudrf.ru",
                kind: .sudrfToken
            )
        }
        let before = await store.pendingSinceLastTrain(kind: .sudrfToken)
        XCTAssertEqual(before, 3)
        await store.markTrained(kind: .sudrfToken, count: 3)
        let after = await store.pendingSinceLastTrain(kind: .sudrfToken)
        XCTAssertEqual(after, 0)
    }

    func testManifestReopenPreservesTrainedMetadata() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        await store.markTrained(kind: .sudrfToken, count: 3)
        await store.markTrained(kind: .kcaptcha, count: 2)
        await store.markTrained(kind: .fsspDigits, count: 7)
        await store.flushManifest()

        let reopened = CorpusStore(baseDir: tmpDir)
        let manifest = await reopened.manifest

        XCTAssertEqual(manifest.numericLastTrainedCount, 3)
        XCTAssertEqual(manifest.numericPendingSinceLastTrain, 0)
        XCTAssertNotNil(manifest.numericLastTrainedAt)
        XCTAssertEqual(manifest.textLastTrainedCount, 2)
        XCTAssertEqual(manifest.textPendingSinceLastTrain, 0)
        XCTAssertNotNil(manifest.textLastTrainedAt)
        XCTAssertEqual(manifest.fsspLastTrainedCount, 7)
        XCTAssertEqual(manifest.fsspPendingSinceLastTrain, 0)
        XCTAssertNotNil(manifest.fsspLastTrainedAt)
    }

    /// Text-captcha length distribution трекается в manifest. Сейчас
    /// мы не делаем активную нормализацию, просто пишем в словарь.
    func testTextLengthDistributionTracksInManifest() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        _ = await store.add(png: Data([0]), code: "abcde", host: "msudrf.ru", kind: .kcaptcha)
        _ = await store.add(png: Data([0]), code: "abcde", host: "msudrf.ru", kind: .kcaptcha)
        _ = await store.add(png: Data([0]), code: "abcdef", host: "msudrf.ru", kind: .kcaptcha)
        let distribution = await store.manifest.textLengthDistribution
        XCTAssertEqual(distribution[5], 2)
        XCTAssertEqual(distribution[6], 1)
    }

    /// `currentCount` возвращает точное число PNG в `solved-<kind>/`.
    func testCurrentCountMatchesFilesOnDisk() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        for i in 0..<4 {
            _ = await store.add(
                png: Data([UInt8(i)]),
                code: String(format: "%05d", 30000 + i),
                host: "h\(i).sudrf.ru",
                kind: .sudrfToken
            )
        }
        let n = await store.currentCount(kind: .sudrfToken)
        XCTAssertEqual(n, 4)
        let t = await store.currentCount(kind: .kcaptcha)
        XCTAssertEqual(t, 0)
    }

    /// `ceiling(for:)` возвращает правильное значение для каждого kind.
    func testCeilingForKind() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        let numeric = await store.ceiling(for: .sudrfToken)
        let text = await store.ceiling(for: .kcaptcha)
        XCTAssertEqual(numeric, 5000)
        XCTAssertEqual(text, 5000)
    }

    func testFSSPCorpusRequiresFiveDigitsAndDeduplicatesBySHA256() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        let png = Data([1, 2, 3])
        let invalid = await store.add(
            png: png, code: "1234", host: "fssp.gov.ru", kind: .fsspDigits)
        XCTAssertNil(invalid)

        let firstAdded = await store.add(
            png: png, code: "58872", host: "fssp.gov.ru", kind: .fsspDigits)
        let duplicateAdded = await store.add(
            png: png, code: "58872", host: "fssp.gov.ru", kind: .fsspDigits)
        let conflictingAdded = await store.add(
            png: png, code: "70120", host: "fssp.gov.ru", kind: .fsspDigits)
        let first = try XCTUnwrap(firstAdded)
        let duplicate = try XCTUnwrap(duplicateAdded)
        XCTAssertEqual(first, duplicate)
        XCTAssertNil(conflictingAdded)
        XCTAssertTrue(first.path.contains("/solved-fssp/58872_"))
        let count = await store.currentCount(kind: .fsspDigits)
        let pending = await store.pendingSinceLastTrain(kind: .fsspDigits)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(pending, 1)
    }

    func testNumericCorpusDeduplicatesServerConfirmedImageBySHA256() async throws {
        let store = CorpusStore(baseDir: tmpDir)
        let png = Data([4, 5, 6])

        let firstAdded = await store.add(
            png: png, code: "12345", host: "court.sudrf.ru", kind: .sudrfToken)
        let duplicateAdded = await store.add(
            png: png, code: "12345", host: "court.sudrf.ru", kind: .sudrfToken)
        let conflictingAdded = await store.add(
            png: png, code: "54321", host: "court.sudrf.ru", kind: .sudrfToken)

        XCTAssertEqual(try XCTUnwrap(firstAdded), try XCTUnwrap(duplicateAdded))
        XCTAssertNil(conflictingAdded)
        let count = await store.currentCount(kind: .sudrfToken)
        let pending = await store.pendingSinceLastTrain(kind: .sudrfToken)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(pending, 1)
    }

    func testOldManifestDecodesWithEmptyFSSPMetadata() throws {
        let old = Data(#"{"version":1,"numericCeiling":5000,"textCeiling":5000,"numericLastTrainedCount":1,"numericPendingSinceLastTrain":0,"textLastTrainedCount":2,"textPendingSinceLastTrain":0,"fifoPolicy":"oldestFirst","textLengthDistribution":{}}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(CorpusStore.Manifest.self, from: old)
        XCTAssertEqual(manifest.fsspCeiling, 5000)
        XCTAssertEqual(manifest.fsspLastTrainedCount, 0)
        XCTAssertEqual(manifest.fsspPendingSinceLastTrain, 0)
    }
}
