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
        await store.flushManifest()

        let reopened = CorpusStore(baseDir: tmpDir)
        let manifest = await reopened.manifest

        XCTAssertEqual(manifest.numericLastTrainedCount, 3)
        XCTAssertEqual(manifest.numericPendingSinceLastTrain, 0)
        XCTAssertNotNil(manifest.numericLastTrainedAt)
        XCTAssertEqual(manifest.textLastTrainedCount, 2)
        XCTAssertEqual(manifest.textPendingSinceLastTrain, 0)
        XCTAssertNotNil(manifest.textLastTrainedAt)
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
}
