import Foundation
import CoreImage
import Vision

/// Стратегия распознавания на основе Vision framework (`VNRecognizeTextRequest`).
///
/// Поток: `pngData` → опционально `Preprocessor.process` (grayscale +
/// 2x scale, см. `CaptchaConfiguration.preprocessingEnabled`) →
/// `VNRecognizeTextRequest` с `usesLanguageCorrection = false`,
/// `minimumTextHeight = 0.2` (понижен с 0.3 в v0.38.4 — на 100×30
/// PNG текст может быть 20–25% высоты, и 0.3 не даёт Vision даже
/// пытаться) → пост-фильтр по регулярному выражению, специфичному
/// для `CaptchaKind`.
///
/// Возвращает `CaptchaAttempt.empty` (нулевая уверенность), если ни
/// один кандидат не прошёл фильтр. Это нормальный исход — вызывающая
/// сторона решает, что делать дальше.
public struct VisionOCRStrategy: CaptchaSolvingProvider {

    public var preprocessingEnabled: Bool
    public var preprocessorHosts: Set<String>

    /// Опциональный live-источник флага preprocess. Если задан, читается
    /// при каждом вызове `solve` — позволяет пользователю переключать
    /// preprocess в меню без пересоздания солвера. Если `nil`,
    /// используется фиксированное `preprocessingEnabled` из инициализатора.
    public var preprocessingProvider: (() -> Bool)?

    /// Возвращает топ-N кандидатов, прошедших регулярку `kind.regex`,
    /// отсортированных по (длина ↓, уверенность ↓). Используется для
    /// диагностики: `AutoCaptchaSolver` логирует эти данные в файл,
    /// чтобы при ручной разборке видеть «что ещё увидел Vision».
    /// Второй элемент кортежа — был ли применён preprocess.
    public func topCandidates(pngData: Data, kind: CaptchaKind, host: String?, n: Int = 3) async throws -> (candidates: [(text: String, confidence: Double)], preprocessed: Bool) {
        let (effectiveData, preprocessed) = resolveEffectiveData(pngData: pngData, host: host)
        let observations = try await performVision(data: effectiveData, kind: kind)
        let tuples = observations.flatMap { obs -> [(String, Float)] in
            obs.topCandidates(n).map { ($0.string, $0.confidence) }
        }
        let regex = kind.regex
        let matches = tuples.compactMap { t -> (String, Double)? in
            let cleaned = t.0.replacingOccurrences(of: " ", with: "")
            let nsRange = NSRange(location: 0, length: cleaned.utf16.count)
            guard regex.firstMatch(in: cleaned, options: [], range: nsRange) != nil else {
                return nil
            }
            return (cleaned, Double(t.1))
        }
        let sorted = matches.sorted { lhs, rhs in
            if lhs.0.count != rhs.0.count { return lhs.0.count > rhs.0.count }
            return lhs.1 > rhs.1
        }
        return (Array(sorted.prefix(n)), preprocessed)
    }

    public init(preprocessingEnabled: Bool = false,
                preprocessorHosts: Set<String> = [],
                preprocessingProvider: (() -> Bool)? = nil) {
        self.preprocessingEnabled = preprocessingEnabled
        self.preprocessorHosts = preprocessorHosts
        self.preprocessingProvider = preprocessingProvider
    }

    public func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        // Предобработка решает per-host. По умолчанию выключена —
        // на captcha sudrf без сильных искажений Vision с прямым PNG
        // даёт conf=1.00, а предобработка вносит артефакты
        // (например, читает «667» как «49»). Включать стоит только
        // для хостов с rotated/struck-through captcha, на которых
        // Vision возвращает conf=0.00 на сырых данных.
        //
        // Логика:
        //   - live provider (если задан) → читаем `preprocessorEnabled`
        //     из `CaptchaSettings` на каждом вызове (для тоггла в меню).
        //   - иначе фиксированный `preprocessingEnabled`:
        //       - false  → preprocess выключен глобально.
        //       - true + preprocessorHosts = ∅   → preprocess для всех.
        //       - true + preprocessorHosts = {...} → только эти хосты.
        let liveFlag = preprocessingProvider?() ?? preprocessingEnabled
        let shouldPreprocess: Bool = {
            guard liveFlag else { return false }
            guard !preprocessorHosts.isEmpty else { return true }
            guard let host = host?.lowercased() else { return false }
            return preprocessorHosts.contains { $0.lowercased() == host }
        }()

        let effectiveData: Data
        if shouldPreprocess, let preprocessed = Preprocessor.process(pngData: pngData) {
            effectiveData = preprocessed
        } else {
            effectiveData = pngData
        }

        let observations = try await performVision(data: effectiveData, kind: kind)
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        return Self.pick(tuples: candidates.map { ($0.string, $0.confidence) }, kind: kind)
    }

    /// Применяет preprocess по тем же правилам, что и `solve`, и
    /// возвращает (effectiveData, didPreprocess). Используется
    /// `topCandidates` для диагностики, чтобы файл-лог отражал то же
    /// изображение, что и распознавание.
    func resolveEffectiveData(pngData: Data, host: String?) -> (Data, Bool) {
        let liveFlag = preprocessingProvider?() ?? preprocessingEnabled
        let shouldPreprocess: Bool = {
            guard liveFlag else { return false }
            guard !preprocessorHosts.isEmpty else { return true }
            guard let host = host?.lowercased() else { return false }
            return preprocessorHosts.contains { $0.lowercased() == host }
        }()
        if shouldPreprocess, let preprocessed = Preprocessor.process(pngData: pngData) {
            return (preprocessed, true)
        }
        return (pngData, false)
    }

    /// Прогоняет PNG через `VNRecognizeTextRequest` с настройками под
    /// `kind`. Возвращает массив observations для последующего извлечения
    /// кандидатов. Бросает `CaptchaSolverError.visionFailed` при сбое
    /// инициализации/перформанса. Используется и `solve`, и `topCandidates`.
    func performVision(data: Data, kind: CaptchaKind) async throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // 0.2 — проходит нижнюю границу для 100×30 captcha, где
        // высота символов ~20% от изображения. 0.3 (предыдущее
        // значение) не давал Vision даже пытаться для таких случаев
        // → conf=0.00 на spb-капчах с rotated digits.
        request.minimumTextHeight = 0.2
        switch kind {
        case .sudrfToken:
            request.recognitionLanguages = ["en-US"]
        case .kcaptcha:
            request.recognitionLanguages = ["ru-RU", "en-US"]
        }
        let handler: VNImageRequestHandler
        do {
            handler = try VNImageRequestHandler(data: data, options: [:])
        } catch {
            throw CaptchaSolverError.visionFailed("handler init: \(error.localizedDescription)")
        }
        do {
            try handler.perform([request])
        } catch {
            throw CaptchaSolverError.visionFailed("perform: \(error.localizedDescription)")
        }
        return request.results ?? []
    }

    /// Выбирает лучшего кандидата: применяет регулярку, специфичную для
    /// `kind`; среди прошедших берёт самого длинного с наивысшей уверенностью.
    func pick(candidates: [VNRecognizedText], kind: CaptchaKind) -> CaptchaAttempt {
        let tuples = candidates.map { ($0.string, $0.confidence) }
        return Self.pick(tuples: tuples, kind: kind)
    }

    /// Чистая функция отбора, тестируемая без Vision.
    static func pick(tuples: [(text: String, confidence: Float)], kind: CaptchaKind) -> CaptchaAttempt {
        let regex = kind.regex
        let matches = tuples.compactMap { t -> (text: String, confidence: Float)? in
            let cleaned = t.text.replacingOccurrences(of: " ", with: "")
            guard regex.firstMatch(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.utf16.count)) != nil else {
                return nil
            }
            return (cleaned, t.confidence)
        }
        guard let top = matches.max(by: {
            if $0.text.count != $1.text.count { return $0.text.count < $1.text.count }
            return $0.confidence < $1.confidence
        }) else {
            return .empty
        }
        return CaptchaAttempt(value: top.text, confidence: Double(top.confidence), duration: 0)
    }
}

private extension CaptchaKind {
    var regex: NSRegularExpression {
        switch self {
        case .sudrfToken:
            return try! NSRegularExpression(pattern: "^[0-9]{3,6}$")
        case .kcaptcha:
            return try! NSRegularExpression(pattern: "^[0-9A-Za-zА-Яа-я]{3,6}$")
        }
    }
}
