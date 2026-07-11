import SwiftUI
import CaptchaSolver

/// Содержимое блока «Captcha» в системном меню macOS.
/// Toggle включает/выключает авто-солвер; ниже — статус (число
/// решённых за сегодня и текущий порог уверенности).
///
/// **Замечание про «live status»:** элементы системного меню в
/// SwiftUI рендерятся ОДИН РАЗ при открытии меню — обновлений
/// после открытия не происходит (нет view lifecycle, как у
/// @State в обычном окне). `solvedToday` и `statusTick` зарезервированы
/// под будущее обновление через `MenuBarExtra` / `NSMenu` (см. issue
/// в фазе 11). Сейчас при открытии меню показывается снимок,
/// сделанный при инициализации `SudrfApp` (счётчик = 0).
struct CaptchaMenuContent: View {
    @ObservedObject var settings: CaptchaSettings

    var body: some View {
        Toggle(isOn: $settings.autoSolveEnabled) {
            Text("Автоматически решать капчу")
        }
        .keyboardShortcut("a", modifiers: [.command, .control])

        Divider()

        // Глобальный тоггл preprocess. v0.38.7: пользователь явно
        // включает preprocess для всех хостов, а не добавляет хосты
        // вручную. Под капотом — `VisionOCRStrategy.preprocessingProvider`,
        // который читает флаг при каждом вызове солвера. На суды без
        // rotated/struck-through капчи preprocess РЕГРЕССИРУЕТ (Vision
        // читает «667» как «49»), поэтому по умолчанию выключен.
        Toggle(isOn: $settings.preprocessorEnabled) {
            Text("Предобработка капчи (для rotated/struck-through)")
        }
        .help("Включает grayscale + 2x scale перед распознаванием. На простых captcha sudrf может РЕГРЕССИРОВАТЬ. Включайте, если авто-солвер возвращает неверный код.")

        Divider()

        Text("Решено сегодня: \(solvedToday())")
        Text("Порог уверенности: \(percent(settings.minConfidence))")
        Text("Версия солвера: Vision (on-device)")

        Divider()

        Button("Сбросить настройки") {
            settings.autoSolveEnabled = true
            settings.minConfidence = 0.55
            settings.preprocessorEnabled = false
        }
    }

    private func solvedToday() -> Int {
        CaptchaSolverLog.shared.solvedCountToday()
    }

    private func percent(_ value: Double) -> String {
        let clamped = max(0.0, min(1.0, value))
        return "\(Int(clamped * 100))%"
    }
}
