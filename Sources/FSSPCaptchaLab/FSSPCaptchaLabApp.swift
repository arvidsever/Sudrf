import AppKit
import SwiftUI

@main
struct FSSPCaptchaLabApp: App {
    @NSApplicationDelegateAdaptor(FSSPCaptchaLabAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Лаборатория CAPTCHA ФССП") {
            FSSPCaptchaLabView()
        }
        .defaultSize(width: 620, height: 760)
        .windowResizability(.contentSize)
    }
}

final class FSSPCaptchaLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private struct FSSPCaptchaLabView: View {
    @StateObject private var model: FSSPCaptchaLabModel
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    init() {
        _model = StateObject(wrappedValue: FSSPCaptchaLabModel(
            dependencies: FSSPCaptchaLabRuntime.makeDependencies()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            documentField
            captcha
            answerField
            controls
            status
            trainingControls
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 560)
        .task { await model.start() }
        .onChange(of: model.challenge?.codeID) { _, _ in
            code = ""
            codeFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Лаборатория CAPTCHA ФССП", systemImage: "flask.fill")
                .font(.title2.weight(.semibold))
            Text("Developer-only: пары сохраняются только после ответа ФССП.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var documentField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Номер исполнительного документа")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Номер ИД", text: $model.documentID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(model.isBusy)
                .onSubmit { Task { await model.start() } }
        }
    }

    @ViewBuilder
    private var captcha: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.045))
            if let challenge = model.challenge, let image = NSImage(data: challenge.imagePNG) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(18)
            } else if model.state == .training {
                ProgressView("Обучение черновой модели")
            } else if model.state == .loading {
                ProgressView("Запрашиваем новую CAPTCHA")
            } else {
                ContentUnavailableView("Нет активной CAPTCHA", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.primary.opacity(0.09)))
    }

    private var answerField: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let suggested = model.suggestedCode,
               let confidence = model.suggestionConfidence {
                Text("Модель предлагает \(suggested) (\(confidence.formatted(.percent.precision(.fractionLength(0)))))")
                    .font(.caption)
                    .foregroundStyle(confidence >= FSSPCaptchaLabModel.automaticConfidence
                                     ? Color.secondary : Color.orange)
            } else {
                Text("Введите код вручную; модель не отправит неуверенный ответ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField("5 цифр", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .focused($codeFocused)
                .disabled(!model.canSubmitManually)
                .onChange(of: code) { _, value in
                    let digits = String(value.filter { ("0"..."9").contains($0) }.prefix(5))
                    if digits != value { code = digits }
                }
                .onSubmit { submitManualCode() }
        }
    }

    private var controls: some View {
        HStack {
            Button("Проверить", action: submitManualCode)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitManually || code.count != 5)
                .keyboardShortcut(.return, modifiers: [])
            Button("Новая задача") { Task { await model.start() } }
                .disabled(model.isBusy)
            Button("Остановить") { model.stop() }
                .disabled(model.state == .idle)
            Spacer()
            if !model.automaticCollectionEnabled {
                Button("Возобновить автосбор") {
                    Task { await model.resumeAutomaticCollection() }
                }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !model.message.isEmpty {
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(model.state == .error || model.state == .trainingFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow {
                    Text("Корпус")
                    Text("\(model.corpusCount) уникальных PNG")
                }
                GridRow {
                    Text("Успехи")
                    Text("ручных \(model.manualAcceptedCount) · автоматических \(model.automaticAcceptedCount)")
                }
                GridRow {
                    Text("Отказы")
                    Text("\(model.rejectedCount), подряд авто: \(model.consecutiveAutomaticRejections)")
                }
                GridRow {
                    Text("Модель")
                    Text(model.modelStatus)
                        .lineLimit(2)
                }
            }
            .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var trainingControls: some View {
        if model.state == .trainingFailed {
            HStack {
                Button("Повторить обучение") { Task { await model.retryTraining() } }
                Button("Продолжить сбор") { Task { await model.continueAfterTrainingFailure() } }
            }
        }
        VStack(alignment: .leading, spacing: 3) {
            Text("Журнал последнего обучения")
                .font(.caption.weight(.semibold))
            Text(model.trainingLog)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .textSelection(.enabled)
        }
    }

    private func submitManualCode() {
        let submitted = code
        code = ""
        Task { await model.submitManual(code: submitted) }
    }
}
