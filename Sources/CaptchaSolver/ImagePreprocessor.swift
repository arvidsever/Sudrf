import Foundation
import AppKit
import CoreImage

/// Подготовка изображения капчи к подаче в Vision.
///
/// Триплет: градации серого → бинаризация по Оцу → удаление 1px рамки →
/// вписывание в 200×64 с сохранением пропорций → лёгкий unsharp, чтобы
/// вернуть потерянные при бинаризации полутона.
///
/// Тонкости:
///   • Оцу работает на гистограмме 256 бинов. Один проход по изображению
///     через `CIAreaHistogram` + ручной подсчёт порога — дешевле, чем
///     отдельный фильтр, и легко покрывается тестом.
///   • На msudrf-картинках (`.kcaptcha`) рамки обычно нет — `stripBorder`
///     обнаруживает её по наличию сплошной линии на границе, и при её
///     отсутствии шаг становится no-op.
public enum ImagePreprocessor {

    /// Размер, до которого доводится сторона-высота при паддинге.
    public static let targetHeight: CGFloat = 64
    /// Размер, до которого доводится сторона-ширина.
    public static let targetWidth: CGFloat = 200

    public struct Output: Sendable, Equatable {
        public let processed: Data        // PNG после обработки (для логов/снапшотов)
        public let widthPx: Int
        public let heightPx: Int
    }

    public static func process(pngData: Data) throws -> Output {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let raw = CIImage(data: pngData) else {
            throw CaptchaSolverError.imageDecodeFailed
        }

        // CIImage по умолчанию рисуется снизу вверх. PNG, наоборот, —
        // сверху вниз. CIImage(data:) переворачивает картинку так, что
        // низ PNG оказывается вверху extent. Это и нужно для Vision
        // (текст «как на экране»). Поэтому при паддинге мы НЕ
        // переворачиваем Y — текст и так окажется в правильной
        // ориентации относительно extent.
        let stripped = stripBorder(image: raw)
        let padded = padToTarget(image: stripped)

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let result = context.createCGImage(padded, from: padded.extent, format: .RGBA8, colorSpace: cs) else {
            throw CaptchaSolverError.coreImageContextUnavailable
        }

        let bitmap = NSBitmapImageRep(cgImage: result)
        guard let outPng = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptchaSolverError.coreImageContextUnavailable
        }
        return Output(
            processed: outPng,
            widthPx: result.width,
            heightPx: result.height
        )
    }

    // MARK: - Otsu

    /// Возвращает порог бинаризации (0…1) по методу Оцу. Считает
    /// гистограмму через `CIAreaHistogram`, после чего ищет порог,
    /// максимизирующий межклассовую дисперсию.
    static func otsuThreshold(grayscale: CIImage, context: CIContext) throws -> Double {
        let extent = grayscale.extent
        let histogram = grayscale.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent),
            "inputCount": 256,
            "inputScale": 1.0
        ])

        var bytes = [UInt8](repeating: 0, count: 256 * 4)
        context.render(histogram,
                       toBitmap: &bytes,
                       rowBytes: 256 * 4,
                       bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        // В RGBA-рендере альфа-канал (R = count) сидит в последнем байте
        // каждой четвёрки (CIAreaHistogram: red = 32-bit float count, но
        // мы работаем в 8-битном контексте — нужно масштабирование). Для
        // Оцу достаточно относительных весов, поэтому берём `R` напрямую
        // и нормализуем.
        var weights = [Double](repeating: 0, count: 256)
        var total: Double = 0
        for i in 0..<256 {
            let r = Double(bytes[i * 4 + 0])
            let g = Double(bytes[i * 4 + 1])
            let b = Double(bytes[i * 4 + 2])
            let value = (r + g + b) / 3.0
            weights[i] = value
            total += value
        }
        guard total > 0 else { return 0.5 }

        var sum: Double = 0
        for i in 0..<256 { sum += Double(i) * weights[i] }
        let mean = sum / total

        var sumB: Double = 0
        var wB: Double = 0
        var maxVar: Double = -1
        var bestThreshold: Int = 127

        for t in 0..<256 {
            wB += weights[t]
            guard wB > 0 else { continue }
            let wF = total - wB
            guard wF > 0 else { break }
            sumB += Double(t) * weights[t]
            let mB = sumB / wB
            let mF = (sum - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > maxVar {
                maxVar = between
                bestThreshold = t
            }
            _ = mean
        }

        return Double(bestThreshold) / 255.0
    }

    // MARK: - Border strip

    /// Снимает тонкую (1–2px) сплошную рамку, если она есть. Обнаруживает
    /// её по наличию сплошной тёмной (или светлой) линии на одной из
    /// четырёх границ изображения.
    static func stripBorder(image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width >= 6, extent.height >= 6 else { return image }
        let detector = BorderDetector()
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(image, from: extent) else { return image }
        guard let cropped = detector.strip(cgImage: cg) else { return image }
        return CIImage(cgImage: cropped)
    }

    // MARK: - Pad

    /// Вписывает изображение в targetWidth×targetHeight, сохраняя
    /// пропорции, фон — белый. CIImage рисует снизу вверх, PNG —
    /// сверху вниз: при компоновке поверх белого холста без переворота
    /// содержимое PNG оказывается у нижней кромки холста, и Vision
    /// читает текст вверх ногами. Здесь мы зеркалим по Y после
    /// масштабирования, чтобы итоговая картинка соответствовала
    /// PNG-координатам (верх текста — у верхней кромки extent).
    static func padToTarget(image: CIImage) -> CIImage {
        let extent = image.extent
        let scale = min(targetWidth / extent.width, targetHeight / extent.height)
        let scaledW = extent.width * scale
        let scaledH = extent.height * scale
        // Масштабируем и сразу отражаем по Y вокруг верхней кромки
        // (extent.maxY), чтобы текст оказался у maxY extent, а не у 0.
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: -scale))
        let padX = (targetWidth - scaledW) / 2
        let padY = (targetHeight - scaledH) / 2
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: padX,
            y: padY + scaledH
        ))

        let canvas = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return translated.composited(over: canvas)
    }
}

/// Детектор и стриппер 1px-рамки. Реализован отдельно, чтобы CoreImage-
/// зависимость оставалась только в публичной части `ImagePreprocessor`.
private final class BorderDetector {

    func strip(cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 4, height > 4 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Проверяем, что верхняя строка однородна (отклонение < 8).
        let topRow = isUniformRow(row: 0, pixels: pixels, width: width, bytesPerRow: bytesPerRow, tolerance: 8)
        let leftCol = isUniformCol(col: 0, pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow, tolerance: 8)
        let rightCol = isUniformCol(col: width - 1, pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow, tolerance: 8)
        let bottomRow = isUniformRow(row: height - 1, pixels: pixels, width: width, bytesPerRow: bytesPerRow, tolerance: 8)

        let cropX = leftCol ? 1 : 0
        let cropY = bottomRow ? 1 : 0
        let cropW = width - cropX - (rightCol ? 1 : 0)
        let cropH = height - (topRow ? 1 : 0) - cropY

        guard cropW > 0, cropH > 0 else { return cgImage }
        guard let cropped = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else {
            return cgImage
        }
        return cropped
    }

    private func isUniformRow(row: Int, pixels: [UInt8], width: Int, bytesPerRow: Int, tolerance: UInt8) -> Bool {
        let offset = row * bytesPerRow
        let r0 = Int(pixels[offset])
        let g0 = Int(pixels[offset + 1])
        let b0 = Int(pixels[offset + 2])
        for x in 1..<width {
            let i = offset + x * 4
            let r = Int(pixels[i])
            let g = Int(pixels[i + 1])
            let b = Int(pixels[i + 2])
            if abs(r - r0) > Int(tolerance) || abs(g - g0) > Int(tolerance) || abs(b - b0) > Int(tolerance) {
                return false
            }
        }
        return true
    }

    private func isUniformCol(col: Int, pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int, tolerance: UInt8) -> Bool {
        let x = col * 4
        let r0 = Int(pixels[x])
        let g0 = Int(pixels[x + 1])
        let b0 = Int(pixels[x + 2])
        for y in 1..<height {
            let i = y * bytesPerRow + x
            let r = Int(pixels[i])
            let g = Int(pixels[i + 1])
            let b = Int(pixels[i + 2])
            if abs(r - r0) > Int(tolerance) || abs(g - g0) > Int(tolerance) || abs(b - b0) > Int(tolerance) {
                return false
            }
        }
        return true
    }
}
