import Foundation
import CoreImage
import Vision

/// Стратегия распознавания на основе Vision framework (`VNRecognizeTextRequest`).
///
/// Поток: `pngData` → `ImagePreprocessor.process` (Оцу, бордер, паддинг) →
/// `VNRecognizeTextRequest` с `usesLanguageCorrection = false` →
/// пост-фильтр по регулярному выражению, специфичному для `CaptchaKind`.
///
/// Возвращает `CaptchaAttempt.empty` (нулевая уверенность), если ни один
/// кандидат не прошёл фильтр. Это нормальный исход — вызывающая сторона
/// решает, что делать дальше.
public struct VisionOCRStrategy: CaptchaSolvingProvider {

    public init() {}

    public func solve(pngData: Data, kind: CaptchaKind) async throws -> CaptchaAttempt {
        // Без предобработки: прямой PNG → Vision. Предобработка (Оцу,
        // паддинг) ухудшала точность из-за особенностей CIImage-координат
        // (bottom-up) — Vision на сырой картинке sudrf уверенно читает
        // цифры (например, '667' с conf=1.00). Если точность на
        // сложных капчах (nsk, msudrf) окажется ниже порога, добавим
        // точечные стратегии с другой нормализацией.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.3
        switch kind {
        case .sudrfToken:
            request.recognitionLanguages = ["en-US"]
        case .kcaptcha:
            request.recognitionLanguages = ["ru-RU", "en-US"]
        }

        let handler: VNImageRequestHandler
        do {
            handler = try VNImageRequestHandler(data: pngData, options: [:])
        } catch {
            throw CaptchaSolverError.visionFailed("handler init: \(error.localizedDescription)")
        }
        do {
            try handler.perform([request])
        } catch {
            throw CaptchaSolverError.visionFailed("perform: \(error.localizedDescription)")
        }

        let observations = request.results ?? []
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        return Self.pick(tuples: candidates.map { ($0.string, $0.confidence) }, kind: kind)
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
