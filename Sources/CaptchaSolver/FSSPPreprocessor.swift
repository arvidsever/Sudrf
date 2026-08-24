import CoreGraphics
import Foundation
import ImageIO

/// Deterministic preprocessing contract for the FSSP CAPTCHA model.
///
/// FSSP images use a transparent palette: the digits and their main curve
/// share one opaque colour, while the dots and anti-aliasing use others. The
/// v3 mask keeps only that dominant opaque colour, stretches the detected
/// horizontal digit span to the native 240 columns, then box-averages it to
/// 64x20.
public enum FSSPPreprocessor {

    public static let version = "fssp-dominant-span-box-v3"
    public static let sourceWidth = 240
    public static let sourceHeight = 80
    public static let outputWidth = 64
    public static let outputHeight = 20

    private static let minimumForegroundPixelsPerColumn = 5
    private static let maximumMergedGap = 10
    private static let horizontalMargin = 4

    /// Decodes one native-size FSSP PNG and returns a row-major 64x20 mask.
    /// Unknown palette/layout variants are rejected so callers fall back to
    /// the manual CAPTCHA path rather than feed a mismatched model.
    public static func process(pngData: Data) throws -> [Float] {
        let pixels = try decodedPixels(pngData: pngData)
        guard (0..<(sourceWidth * sourceHeight)).allSatisfy({
            let alpha = pixels[$0 * 4 + 3]
            return alpha == 0 || alpha == 255
        }) else {
            throw invalidChallenge("FSSP CAPTCHA uses unsupported partial transparency")
        }
        guard (0..<(sourceWidth * sourceHeight)).contains(where: {
            pixels[$0 * 4 + 3] == 0
        }) else {
            throw invalidChallenge("FSSP CAPTCHA must have a transparent background")
        }
        guard let colour = dominantOpaqueColour(in: pixels) else {
            throw invalidChallenge("FSSP CAPTCHA has no opaque foreground")
        }

        let foreground = (0..<(sourceWidth * sourceHeight)).map { index in
            let offset = index * 4
            return pixels[offset + 3] == 255
                && RGB(pixels[offset], pixels[offset + 1], pixels[offset + 2]) == colour
        }
        guard let span = dominantSpan(in: foreground) else {
            throw invalidChallenge("FSSP CAPTCHA has no stable digit span")
        }

        let cropStart = max(0, span.start - horizontalMargin)
        let cropEnd = min(sourceWidth, span.end + 1 + horizontalMargin)
        let cropWidth = cropEnd - cropStart
        guard cropWidth >= 16 else {
            throw invalidChallenge("FSSP CAPTCHA digit span is too narrow")
        }

        var output = [Float](repeating: 0, count: outputWidth * outputHeight)
        for outputY in 0..<outputHeight {
            let y0 = outputY * sourceHeight / outputHeight
            let y1 = (outputY + 1) * sourceHeight / outputHeight
            for outputX in 0..<outputWidth {
                let normalizedX0 = outputX * sourceWidth / outputWidth
                let normalizedX1 = (outputX + 1) * sourceWidth / outputWidth
                var foregroundCount = 0
                var count = 0
                for y in y0..<y1 {
                    for normalizedX in normalizedX0..<normalizedX1 {
                        let x = min(cropEnd - 1,
                                    cropStart + normalizedX * cropWidth / sourceWidth)
                        foregroundCount += foreground[y * sourceWidth + x] ? 1 : 0
                        count += 1
                    }
                }
                output[outputY * outputWidth + outputX] =
                    count == 0 ? 0 : Float(foregroundCount) / Float(count)
            }
        }
        return output
    }

    private static func decodedPixels(pngData: Data) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptchaSolverError.imageDecodeFailed
        }
        guard image.width == sourceWidth, image.height == sourceHeight else {
            throw invalidChallenge(
                "FSSP CAPTCHA must be 240x80, got \(image.width)x\(image.height)"
            )
        }

        var pixels = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sourceWidth,
            height: sourceHeight,
            bitsPerComponent: 8,
            bytesPerRow: sourceWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptchaSolverError.coreImageContextUnavailable
        }

        // Core Graphics and Pillow both read this raster top-to-bottom here.
        // Flipping it would make Swift inference disagree with the trainer.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: sourceWidth, height: sourceHeight))
        return pixels
    }

    private static func dominantOpaqueColour(in pixels: [UInt8]) -> RGB? {
        var frequencies: [RGB: (count: Int, firstIndex: Int)] = [:]
        for pixel in 0..<(sourceWidth * sourceHeight) {
            let offset = pixel * 4
            guard pixels[offset + 3] == 255 else { continue }
            let colour = RGB(pixels[offset], pixels[offset + 1], pixels[offset + 2])
            if var entry = frequencies[colour] {
                entry.count += 1
                frequencies[colour] = entry
            } else {
                frequencies[colour] = (count: 1, firstIndex: pixel)
            }
        }
        var best: (colour: RGB, count: Int, firstIndex: Int)?
        for (colour, entry) in frequencies {
            guard let current = best else {
                best = (colour, entry.count, entry.firstIndex)
                continue
            }
            if entry.count > current.count
                || (entry.count == current.count && entry.firstIndex < current.firstIndex) {
                best = (colour, entry.count, entry.firstIndex)
            }
        }
        return best?.colour
    }

    private static func dominantSpan(in foreground: [Bool]) -> Span? {
        var runs: [Span] = []
        var activeStart: Int?
        for x in 0..<sourceWidth {
            let count = (0..<sourceHeight).reduce(into: 0) { result, y in
                result += foreground[y * sourceWidth + x] ? 1 : 0
            }
            if count >= minimumForegroundPixelsPerColumn {
                activeStart = activeStart ?? x
            } else if let start = activeStart {
                runs.append(Span(start: start, end: x - 1))
                activeStart = nil
            }
        }
        if let start = activeStart {
            runs.append(Span(start: start, end: sourceWidth - 1))
        }

        var merged: [Span] = []
        for run in runs {
            guard var previous = merged.popLast() else {
                merged.append(run)
                continue
            }
            if run.start - previous.end - 1 <= maximumMergedGap {
                previous.end = run.end
                merged.append(previous)
            } else {
                merged.append(previous)
                merged.append(run)
            }
        }
        return merged.max { left, right in
            left.width == right.width ? left.start > right.start : left.width < right.width
        }
    }

    private static func invalidChallenge(_ message: String) -> CaptchaSolverError {
        .visionFailed(message)
    }
}

private struct RGB: Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

private struct Span {
    let start: Int
    var end: Int

    var width: Int { end - start + 1 }
}
