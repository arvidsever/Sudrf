import XCTest
@testable import CaptchaSolver
import AppKit
import CoreImage

/// Снапшот-тест пайплайна предобработки. Синтетическая 100×40 картинка
/// с 1px тёмной рамкой прогоняется через `ImagePreprocessor.process`;
/// проверяется, что выход ровно 200×64 и что рамка ушла.
final class ImagePreprocessorTests: XCTestCase {

    func testProcessesSyntheticCaptcha() throws {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 40,
                                            digits: "12345",
                                            hasBorder: true)
        let output = try ImagePreprocessor.process(pngData: png)
        XCTAssertEqual(output.widthPx, 200)
        XCTAssertEqual(output.heightPx, 64)
        XCTAssertGreaterThan(output.processed.count, 0)
    }

    func testProcessesNoBorderImage() throws {
        let png = SyntheticCaptcha.makePNG(width: 110, height: 44,
                                            digits: "98765",
                                            hasBorder: false)
        let output = try ImagePreprocessor.process(pngData: png)
        XCTAssertEqual(output.widthPx, 200)
        XCTAssertEqual(output.heightPx, 64)
    }

    func testOtsuThresholdInRange() throws {
        let png = SyntheticCaptcha.makePNG(width: 100, height: 40,
                                            digits: "42",
                                            hasBorder: true)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let raw = CIImage(data: png) else {
            XCTFail("can't decode synthetic png"); return
        }
        let gray = raw.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])
        let threshold = try ImagePreprocessor.otsuThreshold(grayscale: gray, context: context)
        XCTAssertGreaterThanOrEqual(threshold, 0.0)
        XCTAssertLessThanOrEqual(threshold, 1.0)
    }

    func testRejectsNonImageData() {
        let bogus = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(try ImagePreprocessor.process(pngData: bogus)) { error in
            XCTAssertEqual(error as? CaptchaSolverError, .imageDecodeFailed)
        }
    }
}

/// Помощник для генерации тестовых PNG: белый фон, чёрные цифры, опциональная
/// 1px-рамка. Используется только в тестах, чтобы не зависеть от наличия
/// фикстур при начальном запуске пайплайна.
enum SyntheticCaptcha {

    static func makePNG(width: Int, height: Int, digits: String, hasBorder: Bool) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0xFF, count: width * height * 4)
        if hasBorder {
            for x in 0..<width {
                for y in [0, height - 1] {
                    let i = y * bytesPerRow + x * 4
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
                }
            }
            for y in 0..<height {
                for x in [0, width - 1] {
                    let i = y * bytesPerRow + x * 4
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
                }
            }
        }
        // Чёрные квадратики вместо цифр (пайплайн не зависит от шрифта —
        // тестируем геометрию, не OCR).
        let glyphW = max(4, (width - 12) / max(1, digits.count))
        let glyphH = max(6, height - 12)
        for (index, _) in digits.enumerated() {
            let gx = 6 + index * glyphW
            let gy = 6
            for dy in 0..<glyphH {
                for dx in 0..<(glyphW - 2) {
                    let x = gx + dx
                    let y = gy + dy
                    guard x < width - 1, y < height - 1 else { continue }
                    let i = y * bytesPerRow + x * 4
                    pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
                }
            }
        }
        let ctx = CGContext(data: &pixels,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}
