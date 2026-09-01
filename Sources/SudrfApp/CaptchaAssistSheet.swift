import AppKit
import SwiftUI
import SudrfKit

/// Ручной fallback: токеновая CAPTCHA идёт через скрытый WebView, а KCaptcha
/// мировых судей — через исходную URLSession суда.
struct CaptchaAssistSheet: View {
    let context: SearchModel.CaptchaContext
    var onCardHTML: (String) -> Void
    var onCaptchaPair: ((String, CaptchaToken) -> Void)? = nil
    var onSessionUnlocked: ((String) -> Void)? = nil
    var onMagistrateCaptchaAccepted: ((Data, String, String) async -> Void)? = nil
    let onLoadMagistrateCaptcha: () async throws -> MagistrateCaptchaChallenge
    let onSubmitMagistrateCaptcha: (String, MagistrateCaptchaChallenge) async throws
        -> MagistrateCaptchaSubmission
    var onCancel: () -> Void

    @State private var captchaCode = ""
    @State private var captchaImageData: Data? = nil
    @State private var magistrateChallenge: MagistrateCaptchaChallenge? = nil
    @State private var assistStatus = "Загружаю форму суда…"
    @State private var highContrast = false
    @State private var submitRequestID = 0
    @State private var submissionState: CaptchaSubmissionState = .loading
    @State private var nativeOperationGeneration = 0
    @FocusState private var codeFocused: Bool

    var body: some View {
        ZStack {
            if presentationPath == .webView {
                CaptchaWebView(url: context.formURL,
                               uid: context.uid,
                               caseNumber: context.caseNumber,
                               kind: context.kind,
                               captchaImageData: $captchaImageData,
                               captchaCode: captchaCode,
                               submitRequestID: $submitRequestID,
                               onCaptchaReady: {
                                   submissionState = .ready
                                   codeFocused = true
                               },
                               onSubmissionState: updateSubmissionState(_:),
                               onCardHTML: onCardHTML,
                               onCaptchaPair: onCaptchaPair,
                               onSessionUnlocked: onSessionUnlocked)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 0) {
                header
                Divider()
                assistPanel
            }
        }
        .frame(width: 460, height: 540)
        .task(id: context.id) {
            guard presentationPath == .nativeMagistrate else { return }
            await loadMagistrateChallenge()
        }
        .onDisappear { nativeOperationGeneration &+= 1 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Код с картинки — \(context.courtTitle)")
                    .font(.system(size: 13, weight: .semibold))
                Text("Введите код — поиск продолжится за кадром.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Отмена", action: onCancel)
                .buttonStyle(.glass)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 14))
    }

    private var assistPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(assistStatus)
                .font(.caption)
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)

            captchaImageBox

            if canRetryNativeLoad {
                Button("Повторить загрузку", action: retryMagistrateLoad)
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Код")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                TextField(context.kind == .kcaptcha ? "буквы и цифры" : "5 цифр",
                          text: $captchaCode)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($codeFocused)
                    .disabled(!canSubmitInput)
                    .onSubmit(submitCaptcha)
                    .onChange(of: captchaCode) { normalizeCaptchaCode() }
            }

            HStack(spacing: 10) {
                Toggle("Высокий контраст", isOn: $highContrast)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Spacer()
                Button {
                    submitCaptcha()
                } label: {
                    Label("Найти", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: [])
            }

            if context.pendingCaseCount > 0 {
                Divider()
                pendingQueueView
            }

            Spacer()

            Text("Распознавание не выполняется автоматически: код читает и вводит пользователь.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    private var captchaImageBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Картинка")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.045))
                if let captchaImageData, let image = NSImage(data: captchaImageData) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .contrast(highContrast ? 1.9 : 1.0)
                        .saturation(highContrast ? 0 : 1)
                        .padding(22)
                } else if canRetryNativeLoad {
                    ContentUnavailableView("Не удалось показать CAPTCHA",
                                           systemImage: "photo.badge.exclamationmark")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    private var pendingQueueView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(context.pendingCaseCount) в очереди",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
            Text("Этот код продолжит фоновые обновления того же суда.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(context.pendingCaseNumbers, id: \.self) { number in
                Text("№ \(number)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var canSubmitInput: Bool {
        switch submissionState {
        case .ready, .rejected, .failed:
            return true
        case .loading, .submitting, .accepted:
            return false
        }
    }

    private var canSubmit: Bool {
        canSubmitInput && !captchaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var presentationPath: CaptchaAssistPresentationPath {
        CaptchaAssistPresentationPath.forKind(context.kind)
    }

    private var canRetryNativeLoad: Bool {
        guard presentationPath == .nativeMagistrate else { return false }
        if case .failed = submissionState { return true }
        return false
    }

    private var statusColor: Color {
        switch submissionState {
        case .rejected, .failed:
            return .red
        case .accepted:
            return .green
        default:
            return .secondary
        }
    }

    private func normalizeCaptchaCode() {
        let filtered: String
        switch context.kind {
        case .sudrfToken:
            filtered = String(captchaCode.filter(\.isNumber).prefix(8))
        case .kcaptcha:
            filtered = String(captchaCode.filter { $0.isLetter || $0.isNumber }.prefix(12))
        }
        if filtered != captchaCode { captchaCode = filtered }
    }

    private func submitCaptcha() {
        normalizeCaptchaCode()
        guard canSubmit else { return }
        switch presentationPath {
        case .webView:
            submissionState = .submitting
            assistStatus = "Отправляю код…"
            submitRequestID += 1
        case .nativeMagistrate:
            submitMagistrateCaptcha()
        }
    }

    private func retryMagistrateLoad() {
        Task { await loadMagistrateChallenge() }
    }

    private func loadMagistrateChallenge() async {
        guard presentationPath == .nativeMagistrate else { return }
        nativeOperationGeneration &+= 1
        let operation = nativeOperationGeneration
        captchaCode = ""
        captchaImageData = nil
        magistrateChallenge = nil
        updateSubmissionState(.loading)

        do {
            let challenge = try await onLoadMagistrateCaptcha()
            guard nativeOperationGeneration == operation else { return }
            guard !Task.isCancelled else {
                updateSubmissionState(.failed("Загрузка CAPTCHA прервана. Повторите загрузку."))
                return
            }
            guard MagistrateCaptchaLoadDecision.decide(imageData: challenge.imageData) == .showChallenge,
                  NSImage(data: challenge.imageData) != nil else {
                updateSubmissionState(.failed(
                    "Суд прислал картинку CAPTCHA, но её не удалось показать. Повторите загрузку."))
                return
            }
            magistrateChallenge = challenge
            captchaImageData = challenge.imageData
            updateSubmissionState(.ready)
        } catch is CancellationError {
            guard nativeOperationGeneration == operation else { return }
            updateSubmissionState(.failed("Загрузка CAPTCHA прервана. Повторите загрузку."))
        } catch {
            guard nativeOperationGeneration == operation else { return }
            updateSubmissionState(.failed(
                "Не удалось загрузить CAPTCHA: \(error.localizedDescription). Повторите загрузку."))
        }
    }

    private func submitMagistrateCaptcha() {
        guard let challenge = magistrateChallenge else {
            updateSubmissionState(.failed("Картинка CAPTCHA не загружена. Повторите загрузку."))
            return
        }
        let code = captchaCode
        nativeOperationGeneration &+= 1
        let operation = nativeOperationGeneration
        updateSubmissionState(.submitting)

        Task {
            do {
                let result = try await onSubmitMagistrateCaptcha(code, challenge)
                guard nativeOperationGeneration == operation else { return }
                guard !Task.isCancelled else {
                    updateSubmissionState(.failed("Отправка кода прервана. Повторите загрузку."))
                    return
                }
                switch result {
                case .accepted:
                    guard let sample = VerifiedMagistrateCaptchaSample.make(
                        outcome: .accepted,
                        imageData: challenge.imageData,
                        code: code,
                        formURL: context.formURL
                    ) else {
                        updateSubmissionState(.failed(
                            "Суд принял код, но адрес сессии не определён. Повторите загрузку."))
                        return
                    }
                    if let onMagistrateCaptchaAccepted {
                        await onMagistrateCaptchaAccepted(
                            sample.imageData, sample.code, sample.host)
                        guard nativeOperationGeneration == operation else { return }
                    }
                    updateSubmissionState(.accepted)
                    onSessionUnlocked?(sample.host)
                case .rejected(let replacement):
                    guard MagistrateCaptchaLoadDecision.decide(imageData: replacement.imageData)
                        == .showChallenge,
                          NSImage(data: replacement.imageData) != nil else {
                        captchaCode = ""
                        captchaImageData = nil
                        magistrateChallenge = nil
                        updateSubmissionState(.failed(
                            "Суд прислал новую картинку CAPTCHA, но её не удалось показать. Повторите загрузку."))
                        return
                    }
                    magistrateChallenge = replacement
                    captchaImageData = replacement.imageData
                    updateSubmissionState(.rejected)
                }
            } catch is CancellationError {
                guard nativeOperationGeneration == operation else { return }
                updateSubmissionState(.failed("Отправка кода прервана. Повторите загрузку."))
            } catch {
                guard nativeOperationGeneration == operation else { return }
                updateSubmissionState(.failed(
                    "Не удалось отправить код: \(error.localizedDescription). Повторите загрузку."))
            }
        }
    }

    private func updateSubmissionState(_ state: CaptchaSubmissionState) {
        submissionState = state
        switch state {
        case .loading:
            assistStatus = "Загружаю форму суда…"
        case .ready:
            assistStatus = "Картинка загружена. Введите код и нажмите Enter."
            codeFocused = true
        case .submitting:
            assistStatus = "Отправляю код…"
        case .accepted:
            assistStatus = "Код принят. Продолжаю поиск…"
        case .rejected:
            captchaCode = ""
            assistStatus = "Код не принят. Введите новый код с картинки."
            codeFocused = true
        case .failed(let message):
            assistStatus = message
            codeFocused = true
        }
    }
}
