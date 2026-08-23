import CoreGraphics
import Foundation
import ImageIO

/// Deterministic preprocessing contract for the FSSP CAPTCHA model.
///
/// FSSP serves a 240x80 image on a black background. Unlike the GАС
/// (`sudrfToken`) CAPTCHA, its foreground is not a fixed teal colour. The
/// model therefore receives the full frame, reduced by box averaging, where
/// each source pixel contributes `max(R, G, B) / 255`.
public enum FSSPPreprocessor {

    public static let version = "fssp-max-rgb-box-v1"
    public static let sourceWidth = 240
    public static let sourceHeight = 80
    public static let outputWidth = 64
    public static let outputHeight = 20

    /// Decodes one native-size FSSP PNG and returns a row-major 64x20 mask.
    /// The source dimensions are part of the contract: silently resizing a
    /// challenge would make Swift inference disagree with the trainer.
    public static func process(pngData: Data) throws -> [Float] {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptchaSolverError.imageDecodeFailed
        }
        guard image.width == sourceWidth, image.height == sourceHeight else {
            throw CaptchaSolverError.visionFailed(
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

        // Bitmap contexts have a lower-left drawing origin while the PNG
        // trainer works in top-left rows. Make that convention explicit and
        // keep interpolation out of this integer-size render.
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(sourceHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: sourceWidth, height: sourceHeight))

        var output = [Float](repeating: 0,
                             count: outputWidth * outputHeight)
        for outputY in 0..<outputHeight {
            let y0 = outputY * sourceHeight / outputHeight
            let y1 = (outputY + 1) * sourceHeight / outputHeight
            for outputX in 0..<outputWidth {
                let x0 = outputX * sourceWidth / outputWidth
                let x1 = (outputX + 1) * sourceWidth / outputWidth
                var sum: Float = 0
                var count = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let offset = (y * sourceWidth + x) * 4
                        let r = pixels[offset]
                        let g = pixels[offset + 1]
                        let b = pixels[offset + 2]
                        sum += Float(max(r, max(g, b))) / 255.0
                        count += 1
                    }
                }
                output[outputY * outputWidth + outputX] =
                    count == 0 ? 0 : sum / Float(count)
            }
        }
        return output
    }
}
