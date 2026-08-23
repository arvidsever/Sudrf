import CryptoKit
import Foundation

/// Подтверждённые пользователем CAPTCHA ФССП для последующего обучения
/// отдельной локальной модели. В корпус попадают только пары, после которых
/// сервер перестал требовать CAPTCHA.
actor FSSPCaptchaCorpus {
    static let shared = FSSPCaptchaCorpus()

    private let directory: URL
    private let fileManager = FileManager.default

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            directory = baseDirectory.appendingPathComponent("solved-fssp", isDirectory: true)
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            directory = support
                .appendingPathComponent("Sudrf/captcha-training/solved-fssp", isDirectory: true)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    func addAccepted(png: Data, code: String) -> URL? {
        guard !png.isEmpty,
              code.count == 5,
              code.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("\(code)_\(digest).png")
        if fileManager.fileExists(atPath: url.path) { return url }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func count() -> Int {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { $0.pathExtension.lowercased() == "png" }.count
    }
}
