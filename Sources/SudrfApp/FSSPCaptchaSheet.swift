import AppKit
import SwiftUI
import SudrfKit

struct FSSPCaptchaPresentation: Identifiable {
    let caseKey: String
    let requestID: UUID
    let document: CourtEnforcementDocument
    let challenge: FSSPCaptchaChallenge
    var message: String?
    var isSubmitting: Bool

    /// `codeID` changes whenever the server rejects an answer, so SwiftUI can
    /// refresh the sheet content without reusing the old image.
    var id: String { "\(caseKey):\(requestID.uuidString):\(challenge.codeID)" }

    init(caseKey: String,
         requestID: UUID,
         document: CourtEnforcementDocument,
         challenge: FSSPCaptchaChallenge,
         message: String? = nil,
         isSubmitting: Bool = false) {
        self.caseKey = caseKey
        self.requestID = requestID
        self.document = document
        self.challenge = challenge
        self.message = message
        self.isSubmitting = isSubmitting
    }
}

/// Компактный ручной лист для CAPTCHA публичного поиска ФССП.
///
/// Результат отправки намеренно остаётся у AppRouter: после отказа он получает
/// новый `FSSPCaptchaChallenge` и заменяет содержимое листа. Поэтому старая
/// картинка и её `codeID` никогда не переиспользуются.
struct FSSPCaptchaSheet: View {
    let challenge: FSSPCaptchaChallenge
    let documentNumber: String
    var isSubmitting = false
    var message: String? = nil
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var normalizedCode: String {
        String(code.filter { ("0"..."9").contains($0) }.prefix(5))
    }

    private var canSubmit: Bool {
        !isSubmitting && normalizedCode.count == 5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "building.columns.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CAPTCHA ФССП")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Исполнительный документ: \(documentNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Отмена", action: onCancel)
                    .buttonStyle(.glass)
            }

            Divider()

            Text(message ?? "Введите пять цифр с картинки. После отказа будет загружена новая.")
                .font(.caption)
                .foregroundStyle(message == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            captchaImage

            TextField("5 цифр", text: $code)
                .font(.system(size: 23, weight: .semibold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .focused($codeFocused)
                .disabled(isSubmitting)
                .onChange(of: code) { _, newValue in
                    let filtered = String(newValue.filter {
                        ("0"..."9").contains($0)
                    }.prefix(5))
                    if filtered != newValue { code = filtered }
                }
                .onSubmit(submit)

            HStack {
                Spacer()
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                            .frame(width: 13, height: 13)
                    } else {
                        Label("Проверить", systemImage: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { codeFocused = true }
        .onChange(of: challenge.codeID) { _, _ in
            // A rejected answer always comes with a fresh challenge. Do not
            // leave the previous answer in the field next to the new image.
            code = ""
            codeFocused = true
        }
    }

    private var captchaImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.045))
            if let image = NSImage(data: challenge.imagePNG) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(18)
            } else {
                ContentUnavailableView("Не удалось показать CAPTCHA",
                                       systemImage: "photo.badge.exclamationmark")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.08)))
    }

    private func submit() {
        let value = normalizedCode
        guard value.count == 5, !isSubmitting else { return }
        onSubmit(value)
    }
}
