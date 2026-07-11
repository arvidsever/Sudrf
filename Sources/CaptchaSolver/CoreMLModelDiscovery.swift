import Foundation

/// Ищет скомпилированную CoreML-модель для числовой sudrf captcha.
/// Порядок поиска:
///   1. `~/Library/Application Support/Sudrf/model-captcha-numeric.mlmodelc/`
///      — позволяет пользователю переопределить модель без перебилда.
///   2. `Bundle.main.url(forResource: "model-captcha-numeric",
///      withExtension: "mlmodelc")` — модель, зашитая в app bundle.
/// Возвращает `nil`, если ни там, ни там модель не найдена —
/// `CoreMLCaptchaStrategy` не инициализируется, и солвер работает
/// на `VisionOCRStrategy` (текущее поведение до v0.38.8).
public enum CoreMLModelDiscovery {

    public static func discoverURL() -> URL? {
        let fm = FileManager.default
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let userPath = support
                .appendingPathComponent("Sudrf", isDirectory: true)
                .appendingPathComponent("model-captcha-numeric.mlmodelc", isDirectory: true)
            if fm.fileExists(atPath: userPath.path) { return userPath }
        }
        return Bundle.main.url(forResource: "model-captcha-numeric", withExtension: "mlmodelc")
    }
}
