import Foundation
import CoreImage
import CoreML
import Vision

/// Стратегия распознавания на основе CoreML-модели, обученной на
/// размеченном корпусе captcha-изображений. Заменяет/дополняет
/// `VisionOCRStrategy` для captcha-стилей, на которых Vision даёт
/// conf=0.00 (rotated/struck-through digits у `1kas`,
/// `oblsud--mo.sudrf.ru`, `sankt-peterburgsky--spb.sudrf.ru`).
///
/// Архитектура (по описанию друга в
/// `Docs/branch-changelogs/captcha-auto-solver/v0.38.8.md`):
///   вход 100×30 RGB → бинарная маска «чернил» (порог по цвету
///   ~(2, 103, 154)) → downsample 100×30 → 64×20 (box-averaging)
///   → `MLMultiArray` формы `[1, 64, 20]`
///   → 5 softmax-голов по 10 цифр каждая
///   → argmax по каждой голове → 5 цифр
///
/// Контракт:
///   - `init(modelURL:kind:)` загружает `compiledMLModel`. Если
///     файл отсутствует или повреждён — `init` бросает
///     `CoreMLCaptchaStrategyError.modelLoadFailed`. `AppModel`/
///     `SearchModel` оборачивают инициализацию в `try?` и
///     при неудаче откатываются на `VisionOCRStrategy`.
///   - `solve(pngData:kind:host:)` возвращает `CaptchaAttempt` с
///     value = 5 цифр, confidence = min(softmax по 5 головам).
///   - `topCandidates(...)` возвращает топ-N 5-значных строк по
///     уверенности, для diagnostics.
///
/// **Эта реализация — каркас (v0.38.8).** Реальный `.mlmodelc`
/// должен быть обучен и положен в
/// `Tests/CaptchaSolverTests/Fixtures/model-captcha-numeric.mlmodelc/`
/// (для тестов) или в `~/Library/Application Support/Sudrf/`
/// (для рантайма). Обучение — `Scripts/train-coreml-captcha.swift`.
public struct CoreMLCaptchaStrategy: CaptchaSolvingProvider {

    public let modelURL: URL
    public let kind: CaptchaKind
    private let compiledModel: MLModel
    private let inputName: String
    private let outputNames: [String]

    /// Загружает модель из `modelURL`. Бросает
    /// `CoreMLCaptchaStrategyError.modelLoadFailed` при ошибке.
    public init(modelURL: URL,
                kind: CaptchaKind,
                inputName: String = "inkMask",
                outputNames: [String] = ["digit0", "digit1", "digit2", "digit3", "digit4"]) throws {
        self.modelURL = modelURL
        self.kind = kind
        self.inputName = inputName
        self.outputNames = outputNames
        do {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            self.compiledModel = try MLModel(contentsOf: modelURL, configuration: cfg)
        } catch {
            throw CoreMLCaptchaStrategyError.modelLoadFailed(
                url: modelURL, underlying: error
            )
        }
    }

    public func solve(pngData: Data, kind: CaptchaKind, host: String?) async throws -> CaptchaAttempt {
        guard kind == self.kind else { return .empty }
        let started = Date()
        let mask = try Self.binarizeAndDownsample(pngData: pngData)
        let input = try Self.makeInput(name: inputName, mask: mask)
        let output: MLFeatureProvider
        do {
            output = try await compiledModel.prediction(from: input)
        } catch {
            throw CaptchaSolverError.visionFailed("coreml prediction: \(error.localizedDescription)")
        }
        let (digits, minProb) = try Self.decodeFiveHeads(
            output: output, outputNames: outputNames
        )
        return CaptchaAttempt(
            value: digits,
            confidence: Double(minProb),
            duration: Date().timeIntervalSince(started)
        )
    }

    /// Топ-N полных 5-значных строк, отсортированных по min softmax
    /// (т.е. наименьшей вероятности среди 5 голов — мера «уверенности»
    /// модели). Используется для candidates diagnostic.
    public func topCandidates(pngData: Data, kind: CaptchaKind, host: String?, n: Int = 3) async throws -> (candidates: [(text: String, confidence: Double)], preprocessed: Bool) {
        guard kind == self.kind else { return ([], false) }
        let mask = try Self.binarizeAndDownsample(pngData: pngData)
        let input = try Self.makeInput(name: inputName, mask: mask)
        let output = try await compiledModel.prediction(from: input)
        let all = try Self.allFiveDigitStrings(output: output, outputNames: outputNames, n: n * 4)
        let sorted = all.sorted { $0.confidence > $1.confidence }
        let picked = Array(sorted.prefix(n))
        return (picked, false)
    }

    // MARK: - Preprocessing

    /// 100×30 RGB → бинарная маска «чернил» (порог по RGB-расстоянию
    /// от судрфовского teal (2, 103, 154)) → downsample 100×30 → 64×20
    /// (box-averaging) → плоский массив `Float` длины 1280.
    static func binarizeAndDownsample(pngData: Data) throws -> [Float] {
        guard let ciImage = CIImage(data: pngData) else {
            throw CaptchaSolverError.imageDecodeFailed
        }
        // 1) Render to 100×30 RGB pixels (force the exact size).
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: 100, height: 30), format: .RGBA8, colorSpace: cs) else {
            throw CaptchaSolverError.coreImageContextUnavailable
        }
        let width = 100, height = 30
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let csRef = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: csRef,
            bitmapInfo: info
        ) else {
            throw CaptchaSolverError.coreImageContextUnavailable
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 2) Binarize: pixel is "ink" iff RGB close to (2, 103, 154).
        //    Distance threshold ~ 80 (covers anti-aliased edges).
        let targetR: Float = 2, targetG: Float = 103, targetB: Float = 154
        let thresholdSq: Float = 80 * 80
        var mask100 = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Float(pixels[i * 4 + 0])
            let g = Float(pixels[i * 4 + 1])
            let b = Float(pixels[i * 4 + 2])
            let dr = r - targetR, dg = g - targetG, db = b - targetB
            let distSq = dr * dr + dg * dg + db * db
            mask100[i] = distSq < thresholdSq ? 1.0 : 0.0
        }

        // 3) Downsample 100×30 → 64×20 by box-averaging. Each output
        //    cell covers a region of (100/64) × (30/20) = 1.5625 × 1.5
        //    input pixels. Use simple area-weighted averaging.
        let outW = 64, outH = 20
        var mask64 = [Float](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let y0 = oy * height / outH
            let y1 = (oy + 1) * height / outH
            for ox in 0..<outW {
                let x0 = ox * width / outW
                let x1 = (ox + 1) * width / outW
                var sum: Float = 0
                var count: Float = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        sum += mask100[y * width + x]
                        count += 1
                    }
                }
                mask64[oy * outW + ox] = count > 0 ? sum / count : 0
            }
        }
        return mask64
    }

    /// Собирает `MLFeatureProvider` для входа модели. По умолчанию
    /// модель ожидает 1-D `MLMultiArray` длины 1280 (= 64×20).
    static func makeInput(name: String, mask: [Float]) throws -> MLFeatureProvider {
        let arr = try MLMultiArray(shape: [1, 20, 64], dataType: .float32)
        // Note: CoreML conv layers typically expect `[1, H, W, C]` for
        // image-style inputs. We use `[1, 20, 64]` (channel-first) as a
        // default; specific models may override inputName + shape.
        for i in 0..<mask.count {
            arr[i] = NSNumber(value: mask[i])
        }
        return try MLDictionaryFeatureProvider(dictionary: [name: arr])
    }

    /// Декодирует выход модели: 5 softmax-голов по 10 классов каждая
    /// → argmax → 5 цифр. Возвращает (digits, minProb) где minProb —
    /// минимум из 5 вероятностей argmax (мера уверенности).
    static func decodeFiveHeads(output: MLFeatureProvider, outputNames: [String]) throws -> (String, Float) {
        var digits: [String] = []
        var minProb: Float = 1.0
        for name in outputNames {
            guard let feature = output.featureValue(for: name),
                  let arr = feature.multiArrayValue else {
                throw CaptchaSolverError.visionFailed("coreml output missing: \(name)")
            }
            let (d, p) = try argmax(arr)
            digits.append(String(d))
            minProb = min(minProb, p)
        }
        return (digits.joined(), minProb)
    }

    /// Возвращает топ-N 5-значных строк, отсортированных по min
    /// softmax-вероятности. Перебирает все комбинации топ-3 цифр
    /// в каждой голове (3^5 = 243 вариантов) и возвращает лучшие.
    static func allFiveDigitStrings(output: MLFeatureProvider,
                                    outputNames: [String],
                                    n: Int) throws -> [(text: String, confidence: Double)] {
        // Get top-3 per head.
        var perHead: [[(digit: Int, prob: Float)]] = []
        for name in outputNames {
            guard let feature = output.featureValue(for: name),
                  let arr = feature.multiArrayValue else {
                throw CaptchaSolverError.visionFailed("coreml output missing: \(name)")
            }
            perHead.append(try topK(arr, k: 3))
        }
        // Generate all 3^5 = 243 combinations.
        var candidates: [(text: String, minProb: Float)] = []
        for i0 in perHead[0] {
            for i1 in perHead[1] {
                for i2 in perHead[2] {
                    for i3 in perHead[3] {
                        for i4 in perHead[4] {
                            let text = "\(i0.digit)\(i1.digit)\(i2.digit)\(i3.digit)\(i4.digit)"
                            let minP = min(min(i0.prob, i1.prob), min(min(i2.prob, i3.prob), i4.prob))
                            candidates.append((text, minP))
                        }
                    }
                }
            }
        }
        // Sort by minProb descending, return top N.
        let sorted = candidates.sorted { $0.minProb > $1.minProb }
        return sorted.prefix(n).map { ($0.text, Double($0.minProb)) }
    }
}

/// Ошибки CoreML-стратегии, которые нельзя интерпретировать как
/// «я не уверен» — настоящие сбои инициализации модели.
public enum CoreMLCaptchaStrategyError: Error, Sendable {
    /// `MLModel(contentsOf:)` бросил — файл отсутствует, не
    /// скомпилирован, повреждён, или не совпадает с архитектурой.
    case modelLoadFailed(url: URL, underlying: Error)
}

// MARK: - Argmax helpers

/// Argmax по 1-D `MLMultiArray`. Возвращает (digit, probability).
private func argmax(_ arr: MLMultiArray) throws -> (Int, Float) {
    guard arr.shape.count == 1 else {
        throw CaptchaSolverError.visionFailed("expected 1-D logits, got shape \(arr.shape)")
    }
    let count = arr.shape[0].intValue
    var bestIdx = 0
    var bestVal: Float = -.infinity
    for i in 0..<count {
        let v = arr[i].floatValue
        if v > bestVal { bestVal = v; bestIdx = i }
    }
    // Softmax the result for the best class only (rough).
    var sumExp: Float = 0
    for i in 0..<count {
        sumExp += exp(arr[i].floatValue - bestVal)
    }
    let prob = 1.0 / sumExp
    return (bestIdx, prob)
}

/// Топ-K (digit, prob) по 1-D `MLMultiArray` (softmax-нормализованные
/// вероятности). Используется для candidates diagnostic.
private func topK(_ arr: MLMultiArray, k: Int) throws -> [(Int, Float)] {
    let count = arr.shape[0].intValue
    // Softmax over the full array first.
    var maxVal: Float = -.infinity
    for i in 0..<count { maxVal = max(maxVal, arr[i].floatValue) }
    var probs = [Float](repeating: 0, count: count)
    var sumExp: Float = 0
    for i in 0..<count {
        let e = exp(arr[i].floatValue - maxVal)
        probs[i] = e
        sumExp += e
    }
    for i in 0..<count { probs[i] /= sumExp }
    // Top-K by sorting indices.
    let indexed = probs.enumerated().sorted { $0.element > $1.element }
    return Array(indexed.prefix(k))
}
