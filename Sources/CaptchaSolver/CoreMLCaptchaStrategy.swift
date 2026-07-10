import Foundation
import CoreImage
import CoreML
import Vision

/// Стратегия распознавания на основе CoreML-модели, обученной на
/// размеченном корпусе captcha-изображений. Заменяет/дополняет
/// `VisionOCRStrategy` для captcha-стилей, на которых Vision даёт
/// низкую точность (rotated/struck-through digits у `1kas`,
/// `oblsud--mo.sudrf.ru`, `sankt-peterburgsky--spb.sudrf.ru` и
/// `sovetsky--nsk.sudrf.ru`: Vision на них пропускает цифры или
/// возвращает пусто).
///
/// Архитектура (см. `Scripts/train-coreml-captcha-helper.py`):
///   вход 100×30 RGB → бинарная маска «чернил» (порог по цвету
///   ~(2, 103, 154)) → downsample 100×30 → 64×20 (box-averaging)
///   → `MLMultiArray` формы `[1, 1, 20, 64]` (NCHW)
///   → 5 softmax-голов по 10 цифр каждая
///   → единственный выход `digits` формы `[1, 5, 10]`
///   → argmax по последней оси → 5 цифр
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
/// **A4 regression marker:** на rotated/struck-through captcha spb/nsk
/// модель in-distribution и выдаёт корректные 5-значные ответы
/// (verified человеком с PNG; см. `testLocalSudrfFixturesAccuracy`
/// в `Tests/CaptchaSolverTests/CoreMLCaptchaStrategyTests.swift` —
/// regression marker на наших 3 уникальных captcha spb/nsk).
/// Раньше `labels.csv` содержал Vision-ошибки (667/1909/UNREADABLE)
/// как «expected», что стало основой FIXPLAN A4. В действительности
/// captcha всегда 5-значная, а Vision просто не справляется с
/// rotated/struck-through стилями.
public struct CoreMLCaptchaStrategy: CaptchaSolvingProvider {

    public let modelURL: URL
    public let kind: CaptchaKind
    private let compiledModel: MLModel
    private let inputName: String
    private let outputName: String

    /// Контракт числовой модели: ровно пять ASCII-цифр.
    /// Используется диспетчером A4b, прежде чем принять ответ CoreML.
    public static func isCompatibleOutput(_ value: String) -> Bool {
        value.utf8.count == 5 && value.utf8.allSatisfy { byte in
            byte >= 48 && byte <= 57
        }
    }

    /// Загружает модель из `modelURL`. Бросает
    /// `CoreMLCaptchaStrategyError.modelLoadFailed` при ошибке.
    public init(modelURL: URL,
                kind: CaptchaKind,
                inputName: String = "inkMask",
                outputName: String = "digits") throws {
        self.modelURL = modelURL
        self.kind = kind
        self.inputName = inputName
        self.outputName = outputName
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
        let (digits, minProb) = try Self.decodeDigits(
            output: output, outputName: outputName
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
        let all = try Self.allFiveDigitStrings(output: output, outputName: outputName, n: n * 4)
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

        // 3) Downsample 100×30 → 64×20 by box-averaging.
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

    /// Собирает `MLFeatureProvider` для входа модели. Модель
    /// (см. `train-coreml-captcha-helper.py`) ожидает
    /// `MLMultiArray` формы `[1, 1, 20, 64]` (NCHW, channel=1).
    static func makeInput(name: String, mask: [Float]) throws -> MLFeatureProvider {
        let arr = try MLMultiArray(shape: [1, 1, 20, 64], dataType: .float32)
        for i in 0..<mask.count {
            // Layout в `[1, 1, 20, 64]`: индекс = c*1*20*64 + h*64 + w
            // = h * 64 + w (c=0). В mask[i] i = h*64 + w. Прямое
            // соответствие.
            arr[i] = NSNumber(value: mask[i])
        }
        return try MLDictionaryFeatureProvider(dictionary: [name: arr])
    }

    /// Декодирует выход модели: один тензор `digits` формы
    /// `[1, 5, 10]` → argmax по последней оси → 5 цифр.
    /// Возвращает (digits, minProb) где minProb — минимум из 5
    /// softmax-вероятностей argmax (мера уверенности).
    static func decodeDigits(output: MLFeatureProvider, outputName: String) throws -> (String, Float) {
        guard let feature = output.featureValue(for: outputName),
              let arr = feature.multiArrayValue else {
            throw CaptchaSolverError.visionFailed("coreml output missing: \(outputName)")
        }
        // Ожидаемая форма: [1, 5, 10]. PyTorch stack склеил головы
        // по оси 1, классы — по оси 2. CoreML в Swift видит
        // `MLMultiArray` с shape [1, 5, 10].
        let shape = arr.shape.map { $0.intValue }
        guard shape.count == 3, shape[0] == 1, shape[1] == 5, shape[2] == 10 else {
            throw CaptchaSolverError.visionFailed(
                "expected digits shape [1, 5, 10], got \(shape)"
            )
        }
        var digits: [String] = []
        var minProb: Float = 1.0
        for k in 0..<5 {
            let (d, p) = softmaxArgmax(arr: arr, headIdx: k)
            digits.append(String(d))
            minProb = min(minProb, p)
        }
        return (digits.joined(), minProb)
    }

    /// Возвращает топ-N 5-значных строк, отсортированных по min
    /// softmax-вероятности. Перебирает все комбинации топ-3 цифр
    /// в каждой голове (3^5 = 243 вариантов) и возвращает лучшие.
    static func allFiveDigitStrings(output: MLFeatureProvider,
                                    outputName: String,
                                    n: Int) throws -> [(text: String, confidence: Double)] {
        guard let feature = output.featureValue(for: outputName),
              let arr = feature.multiArrayValue else {
            throw CaptchaSolverError.visionFailed("coreml output missing: \(outputName)")
        }
        // Get top-3 per head.
        var perHead: [[(digit: Int, prob: Float)]] = []
        for k in 0..<5 {
            perHead.append(softmaxTopK(arr: arr, headIdx: k, k: 3))
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

// MARK: - Head helpers

/// В тензоре [1, 5, 10], при `headIdx = k`, классы 0..9 лежат по
/// смещению `k * 10 + j` (row-major C-order). Возвращает
/// (argmaxDigit, softmaxProbability).
private func softmaxArgmax(arr: MLMultiArray, headIdx: Int) -> (Int, Float) {
    let base = headIdx * 10
    var bestIdx = 0
    var bestVal: Float = -.infinity
    for j in 0..<10 {
        let v = arr[base + j].floatValue
        if v > bestVal { bestVal = v; bestIdx = j }
    }
    var sumExp: Float = 0
    for j in 0..<10 {
        sumExp += exp(arr[base + j].floatValue - bestVal)
    }
    return (bestIdx, 1.0 / sumExp)
}

/// Top-K (digit, softmaxProb) для одной головы в тензоре [1, 5, 10].
private func softmaxTopK(arr: MLMultiArray, headIdx: Int, k: Int) -> [(Int, Float)] {
    let base = headIdx * 10
    var probs = [Float](repeating: 0, count: 10)
    var maxVal: Float = -.infinity
    for j in 0..<10 {
        maxVal = max(maxVal, arr[base + j].floatValue)
    }
    var sumExp: Float = 0
    for j in 0..<10 {
        let e = exp(arr[base + j].floatValue - maxVal)
        probs[j] = e
        sumExp += e
    }
    for j in 0..<10 { probs[j] /= sumExp }
    let indexed = probs.enumerated().sorted { $0.element > $1.element }
    return Array(indexed.prefix(k))
}
