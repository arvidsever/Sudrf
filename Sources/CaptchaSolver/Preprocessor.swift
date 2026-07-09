import Foundation
import AppKit
import CoreImage

/// Лёгкая предобработка капчи перед `VNRecognizeTextRequest`. Адресует
/// два систематических провала Vision на sudrf-капчах:
///   1. **Цвет и контраст**: blue-on-grey с цветными strikethrough-линиями.
///      Vision лучше работает с grayscale + повышенным контрастом.
///   2. **Малый размер текста**: 100×30 PNG, текст может быть 20–25% высоты.
///      2x upscale + `minimumTextHeight = 0.2` даёт Vision больше пикселей.
///
/// Поток:
///   PNG `Data` → `CIImage` → grayscale (`CIColorControls` sat=0, contrast=1.4)
///   → 2x scale (CGAffineTransform, **без** Y-flip — мы передаём результат
///   обратно как PNG `Data` через `CIContext.createCGImage → NSBitmapImageRep`,
///   и Y-инверсия в `CIImage`-координатах не возникает) → grayscale PNG.
///
/// На выходе PNG, который `VNImageRequestHandler(data:)` принимает напрямую.
/// Возвращает `nil` при любой внутренней ошибке (битые данные, не PNG,
/// не инициализировался CIContext) — тогда `VisionOCRStrategy` падает
/// обратно на raw-pass-through.
public enum Preprocessor {

    /// Конвертирует PNG `Data` в предобработанный PNG `Data`. Возвращает
    /// `nil`, если вход не PNG или произошла ошибка рендеринга.
    public static func process(pngData: Data) -> Data? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let raw = CIImage(data: pngData) else { return nil }

        // 1) Grayscale + contrast boost. CIColorControls принимает
        // saturation/contrast/brightness; saturation 0 → grayscale, а
        // contrast 1.4 тянет фон темнее, цифры светлее.
        let tonned = raw.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputBrightnessKey: 0.05,
            kCIInputContrastKey: 1.4
        ])

        // 2) 2x scale. CGAffineTransform(scaleX: 2, y: 2) — простая
        // билинейная интерполяция, достаточная для OCR. Без Y-flip,
        // потому что дальше мы рендерим в CGImage через `createCGImage`:
        // тот сам учитывает CIImage-координаты (origin внизу-слева)
        // и рисует пиксели в «правильном» для PNG порядке (origin вверху-слева).
        let scaled = tonned.transformed(by: CGAffineTransform(scaleX: 2.0, y: 2.0))

        // 3) Render → CGImage → PNG `Data`. Используем sRGB — это
        // нейтральное цветовое пространство, которое Vision и так
        // ожидает. `extent` берём из результата scaling.
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: cs) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return bitmap.representation(using: .png, properties: [:])
    }
}
