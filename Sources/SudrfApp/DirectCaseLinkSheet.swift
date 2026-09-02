import SwiftUI
import SudrfKit

/// Реквизиты, которые пользователь проверяет перед добавлением прямой ссылки.
/// Это отдельная проекция результата resolver-а, чтобы sheet не зависел от
/// деталей network/parser слоя.
struct DirectCaseLinkPreview: Equatable {
    let context: MovementContext
    let caseNumber: String
    let courtTitle: String
    let judicialUID: String?
    let category: String?
    let judge: String?
    let result: String?

    init(context: MovementContext, caseNumber: String, courtTitle: String,
         judicialUID: String? = nil, category: String? = nil,
         judge: String? = nil, result: String? = nil) {
        self.context = context
        self.caseNumber = caseNumber
        self.courtTitle = courtTitle
        self.judicialUID = judicialUID
        self.category = category
        self.judge = judge
        self.result = result
    }

    init(_ resolution: DirectCaseLinkResolution) {
        self.init(context: resolution.context, caseNumber: resolution.caseNumber,
                  courtTitle: resolution.courtTitle, judicialUID: resolution.judicialUID,
                  category: resolution.category, judge: resolution.judge,
                  result: resolution.result)
    }

    var fields: [(String, String)] {
        func value(_ value: String?) -> String {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return "—" }
            return value
        }
        return [("Номер дела", value(caseNumber)),
                ("Суд", value(courtTitle)),
                ("УИД", value(judicialUID)),
                ("Категория", value(category)),
                ("Судья", value(judge)),
                ("Результат", value(result))]
    }
}

enum DirectCaseLinkSheetState: Equatable {
    case input
    case resolving
    case preview(DirectCaseLinkPreview)
    case failed(String)

    mutating func invalidateForChangedInput() {
        self = .input
    }
}

struct DirectCaseLinkSheet: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @FocusState private var urlFocused: Bool
    @State private var urlText = ""
    @State private var state: DirectCaseLinkSheetState = .input
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Добавить дело по ссылке")
                .font(.title2.weight(.bold))

            Text("Вставьте прямую ссылку на карточку дела с сайта суда.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("https://…/modules.php?name=sud_delo…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFocused)
                    .onSubmit { resolve() }
                    .onChange(of: urlText) { _, _ in
                        task?.cancel()
                        task = nil
                        state.invalidateForChangedInput()
                    }
                Button("Проверить", action: resolve)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isResolving || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            content

            HStack {
                Button("Через поиск") {
                    task?.cancel()
                    dismiss()
                    router.go(.search)
                }
                .buttonStyle(.glass)
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
            }
        }
        .padding(26)
        .frame(width: 620)
        .onAppear { urlFocused = true }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }

    private var isResolving: Bool {
        if case .resolving = state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .input:
            Text("Поддерживаются прямые ссылки на карточки федеральных судов *.sudrf.ru.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .resolving:
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("Загружаю карточку и проверяю реквизиты…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 9) {
                Label("Не удалось проверить ссылку", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Повторить", action: resolve)
                    .buttonStyle(.glass)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .preview(let preview):
            previewView(preview)
        }
    }

    private func previewView(_ preview: DirectCaseLinkPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Проверьте найденное дело", systemImage: "checkmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.bottom, 8)
            CardBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(preview.fields.enumerated()), id: \.offset) { _, field in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(field.0)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 105, alignment: .leading)
                            Text(field.1)
                                .font(.system(size: 12.5, weight: field.0 == "Номер дела" ? .semibold : .regular))
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(14)
            }
            .padding(.bottom, 10)
            HStack {
                Spacer()
                Button("Добавить в «Мои дела»") {
                    add(preview)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func resolve() {
        let rawValue = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            state = .failed("Вставьте ссылку на карточку дела.")
            return
        }
        task?.cancel()
        state = .resolving
        task = Task { @MainActor in
            do {
                let resolution = try await router.resolveDirectCaseLink(rawValue)
                guard !Task.isCancelled else { return }
                state = .preview(DirectCaseLinkPreview(resolution))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func add(_ preview: DirectCaseLinkPreview) {
        task?.cancel()
        guard let key = router.track(context: preview.context, movement: nil) else { return }
        router.openTrackedCase(key: key)
        dismiss()
    }
}
