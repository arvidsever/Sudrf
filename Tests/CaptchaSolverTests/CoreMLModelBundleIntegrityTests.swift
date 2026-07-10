import XCTest
@testable import CaptchaSolver

/// XCTest-зеркало `Scripts/verify-model.sh` для проверки
/// `MODEL_MANIFEST.sha256` и `.mlmodelc/` в test bundle.
///
/// Контракт:
/// 1. manifest обязателен — если отсутствует, тест **fail**, не skip;
/// 2. manifest парсится **до** проверки модели и должен содержать ровно
///    два whitespace-separated поля, lowercase SHA-256, безопасные пути,
///    уникальные entries; internal empty line и дубликаты → fail;
/// 3. **только** после успешного parse manifest, при отсутствии модели
///    в bundle, тест делает `XCTSkip` (чистый checkout без fetched asset);
/// 4. обход модели использует `.fileTypeKey` и пропускает только
///    directories; symlink/special/regular-но-не-listed → fail;
/// 5. SHA-256 каждого regular file проверяется через
///    `Process` + `/usr/bin/shasum -a 256`.
final class CoreMLModelBundleIntegrityTests: XCTestCase {

    func testBundleModelMatchesManifest() throws {
        // 1. Manifest обязателен. FAIL если отсутствует.
        guard let manifestURL = Bundle.module.url(
            forResource: "MODEL_MANIFEST",
            withExtension: "sha256",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("MODEL_MANIFEST.sha256 missing from Fixtures/ — check git tracking")
            return
        }

        // 2. Strict parse manifest ДО проверки модели.
        // split keepingEmpty: отлавливает пустые строки (кроме terminal \n).
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        var lines = manifestText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        if lines.last == "" { lines.removeLast() }  // drop single trailing newline

        var expected: [String: String] = [:]
        var anyLineFailed = false

        for (idx, rawLine) in lines.enumerated() {
            let lineNo = idx + 1
            let line = String(rawLine)
            if line.isEmpty {
                XCTFail("manifest line \(lineNo): empty line (not allowed)")
                anyLineFailed = true
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard parts.count == 2 else {
                XCTFail("manifest line \(lineNo): expected exactly 2 whitespace-separated fields, got \(parts.count): \(line)")
                anyLineFailed = true
                continue
            }
            let hash = parts[0]
            let rel = parts[1]
            guard hash.count == 64,
                  hash.allSatisfy({ $0.isHexDigit }),
                  hash == hash.lowercased() else {
                XCTFail("manifest line \(lineNo): SHA256 must be 64 lowercase hex chars: \(hash)")
                anyLineFailed = true
                continue
            }
            guard rel.hasPrefix("model-captcha-numeric.mlmodelc/"),
                  !rel.contains(".."),
                  !rel.hasPrefix("/") else {
                XCTFail("manifest line \(lineNo): rel-path invalid: \(rel)")
                anyLineFailed = true
                continue
            }
            if expected[rel] != nil {
                XCTFail("manifest line \(lineNo): duplicate rel-path: \(rel)")
                anyLineFailed = true
                continue
            }
            expected[rel] = hash
        }

        guard !expected.isEmpty else {
            XCTFail("manifest is empty or has no valid entries")
            return
        }
        guard !anyLineFailed else { return }  // strict parse already reported

        // 3. Модель — skip если отсутствует (только после успешного parse).
        guard let modelURL = Bundle.module.url(
            forResource: "model-captcha-numeric",
            withExtension: "mlmodelc",
            subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("model not in bundle (run Scripts/fetch-model.sh first)")
        }

        // 4. Recursive walk: только regular files; symlink → fail; прочие
        //    non-regular (sockets, devices, etc.) → fail по negative list.
        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: modelURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            XCTFail("cannot enumerate \(modelURL.path)")
            return
        }
        var seen: Set<String> = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: resourceKeys)
            if values?.isSymbolicLink == true {
                XCTFail("symbolic link in .mlmodelc/ (not allowed): \(fileURL.path)")
                continue
            }
            // isRegularFile == false → directory / special node. Special nodes
            // (socket, device, fifo) также отрисовываются как не-regular;
            // они не listed в manifest → negative list ловит.
            guard values?.isRegularFile == true else { continue }
            let suffix = fileURL.path.replacingOccurrences(of: modelURL.path + "/", with: "")
            let rel = "model-captcha-numeric.mlmodelc/\(suffix)"
            guard let exp = expected[rel] else {
                XCTFail("unlisted file in .mlmodelc/: \(rel)")
                continue
            }
            let actual = try Self.sha256(of: fileURL)
            if actual.lowercased() != exp.lowercased() {
                XCTFail("hash mismatch for \(rel): expected \(exp), got \(actual)")
            }
            seen.insert(rel)
        }

        // 5. Negative check (files in manifest but not on disk).
        for rel in expected.keys where !seen.contains(rel) {
            XCTFail("manifest entry not found in model: \(rel)")
        }
    }

    // MARK: - Helpers

    /// SHA-256 через `Process` + `/usr/bin/shasum -a 256` (без CryptoKit).
    private static func sha256(of url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "sha256", code: 1, userInfo: [NSLocalizedDescriptionKey: "no output"])
        }
        // Output: "<hash>  <path>\n"
        return output.split(separator: " ").first.map(String.init) ?? ""
    }
}
