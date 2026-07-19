import AppKit
import Foundation
import Security
import SudrfKit
import SwiftUI
@preconcurrency import Translation
import UniformTypeIdentifiers

enum AIProviderKind: String, CaseIterable, Identifiable, Sendable {
    case mock
    case groq
    case gigaChat
    case yandexGPT
    case appleDirect
    case appleTranslated

    var id: String { rawValue }
    var title: String {
        switch self {
        case .mock: "Тестовый (без сети)"
        case .groq: "Groq BYOK"
        case .gigaChat: "GigaChat BYOK"
        case .yandexGPT: "YandexGPT BYOK"
        case .appleDirect: "Apple на устройстве"
        case .appleTranslated: "Apple через английский — экспериментально"
        }
    }
    var isCloud: Bool { [.groq, .gigaChat, .yandexGPT].contains(self) }

}

enum AIKeychain {
    private static let service = "ru.sudrf.app.ai-provider-key"

    static func save(_ value: String, provider: AIProviderKind) throws {
        let account = provider.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(provider: AIProviderKind) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain вернул ошибку \(status)." }
    }
}

@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()
    static let personalProvider: AIProviderKind = .groq
    static let personalModelID = "openai/gpt-oss-120b"

    @AppStorage("ai.cloudConsent") var cloudConsent = false
    @AppStorage("ai.appleEnglishExperimental") var appleEnglishExperimental = false
    @AppStorage("ai.yandexFolderID") var yandexFolderID = ""
    @AppStorage("ai.gigachatScope") var gigaChatScope = "GIGACHAT_API_PERS"
    @Published private(set) var translationPairPrepared = false
    @Published var draftKey = ""
    @Published var statusMessage: String?
    @Published var connectionTestRunning = false
    @Published var benchmarkRunning = false
    private var benchmarkTask: Task<Void, Never>?

    private init() {}

    var provider: AIProviderKind { Self.personalProvider }
    var model: String { Self.personalModelID }
    var credentialProvider: AIProviderKind { Self.personalProvider }

    func loadKey() { draftKey = (try? AIKeychain.load(provider: credentialProvider)) ?? "" }

    func saveKey() {
        do {
            try AIKeychain.save(draftKey, provider: credentialProvider)
            statusMessage = draftKey.isEmpty ? "Ключ удалён." : "Ключ сохранён в Keychain."
        } catch { statusMessage = error.localizedDescription }
    }

    func revokeCloudConsent() {
        cloudConsent = false
        statusMessage = "Согласие отозвано. Новые акты не будут отправляться в облако."
    }

    func beginTranslationPreparation() {
        translationPairPrepared = false
        statusMessage = "Подготовка языковой пары русский ↔ английский…"
    }

    func completeTranslationPreparation() {
        Task {
            do {
                try await InstalledTranslationPair.shared.refreshInstalledSessions()
                translationPairPrepared = true
                statusMessage = "Языковая пара русский ↔ английский готова."
            } catch {
                translationPairPrepared = false
                statusMessage = "Не удалось подготовить перевод: \(error.localizedDescription)"
            }
        }
    }

    func failTranslationPreparation(_ error: Error) {
        translationPairPrepared = false
        statusMessage = "Не удалось подготовить перевод: \(error.localizedDescription)"
    }

    func markTranslationPairUnavailable() {
        translationPairPrepared = false
        statusMessage = "Языковая пара русский ↔ английский больше не установлена. Подготовьте её заново."
    }

    func testConnection() {
        guard !connectionTestRunning else { return }
        connectionTestRunning = true
        statusMessage = "Проверка провайдера…"
        Task {
            do {
                let configured = try ActSummarizerFactory.configured(settings: self)
                let document = ActDocument(
                    caseKey: "connection-test", sourceActID: "synthetic",
                    caseNumber: "TEST-1", judicialUID: nil, court: "Тестовый суд",
                    instanceLevel: .first, kind: "Проверка соединения", date: "",
                    sourceText: "Синтетический текст для проверки соединения. Реальный судебный акт не отправляется.")
                _ = try await configured.summarizer.summarize(
                    document: document, options: configured.options)
                statusMessage = "Провайдер доступен. Проверка выполнена на синтетическом тексте."
            } catch {
                statusMessage = "Проверка не пройдена: \(error.localizedDescription)"
            }
            connectionTestRunning = false
        }
    }

    func chooseAndRunBenchmark() {
        guard !benchmarkRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите JSON-корпус AI benchmark"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let inputURL = panel.url else { return }

        benchmarkRunning = true
        statusMessage = "Benchmark запущен…"
        benchmarkTask = Task {
            do {
                let configured = try ActSummarizerFactory.configured(settings: self)
                let runner = SummaryBenchmarkRunner()
                let fixtures = try await runner.loadFixtures(from: inputURL)
                let report = await runner.run(fixtures: fixtures, configured: configured)
                try Task.checkCancellation()
                let output = try JSONEncoder.benchmark.encode(report)
                let savePanel = NSSavePanel()
                savePanel.title = "Сохранить отчёт benchmark"
                savePanel.allowedContentTypes = [.json]
                let safeModel = configured.model.replacingOccurrences(of: "/", with: "-")
                savePanel.nameFieldStringValue = "sudrf-ai-benchmark-\(safeModel).json"
                if savePanel.runModal() == .OK, let outputURL = savePanel.url {
                    try output.write(to: outputURL, options: .atomic)
                }
                statusMessage = String(format:
                    "Benchmark: citations %.1f%%, реквизиты %.1f%%, разделы %.1f%% — %@.",
                    report.citationAccuracy * 100, report.criticalAccuracy * 100,
                    report.sectionCompleteness * 100, report.passed ? "пройден" : "не пройден")
            } catch is CancellationError {
                statusMessage = "Benchmark отменён."
            } catch {
                statusMessage = "Benchmark не завершён: \(error.localizedDescription)"
            }
            benchmarkRunning = false
            benchmarkTask = nil
        }
    }

    func cancelBenchmark() { benchmarkTask?.cancel() }
}

private extension JSONEncoder {
    static var benchmark: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

struct AISettingsView: View {
    @StateObject private var settings = AISettings.shared
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var confirmingCloudConsent = false

    var body: some View {
        Form {
            LabeledContent("Провайдер", value: "Groq BYOK")
            LabeledContent("Модель", value: AISettings.personalModelID)
            Text("Для первого личного прогона провайдер и model ID зафиксированы. Выбор вернётся после сравнительного benchmark.")
                .font(.caption).foregroundStyle(.secondary)

            if settings.credentialProvider.isCloud {
                SecureField("API/authorization key", text: $settings.draftKey)
                if settings.credentialProvider == .yandexGPT {
                    TextField("Yandex Cloud folder ID", text: $settings.yandexFolderID)
                }
                if settings.credentialProvider == .gigaChat {
                    TextField("GigaChat scope", text: $settings.gigaChatScope)
                }
                Button("Сохранить ключ в Keychain") { settings.saveKey() }
                Toggle("Разрешить облачную обработку выбранного акта", isOn: Binding(
                    get: { settings.cloudConsent },
                    set: { enabled in
                        if enabled { confirmingCloudConsent = true }
                        else { settings.revokeCloudConsent() }
                    }))
                Text("Внимание: выбранный судебный акт может содержать ФИО и другие персональные данные третьих лиц. Sudrf отправляет только акт по явному нажатию — никогда не базу и не фоновые данные.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Отозвать согласие") { settings.revokeCloudConsent() }
            }

            Button(settings.connectionTestRunning ? "Проверка…" : "Проверить соединение") {
                settings.testConnection()
            }
            .disabled(settings.connectionTestRunning)
            Text("Проверка использует только синтетическую фразу и не отправляет судебный акт.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Запустить benchmark из JSON…") { settings.chooseAndRunBenchmark() }
                    .disabled(settings.benchmarkRunning)
                if settings.benchmarkRunning {
                    ProgressView().controlSize(.small)
                    Button("Отменить") { settings.cancelBenchmark() }
                }
            }
            Text("Корпус и отчёт выбираются вручную и остаются вне Git.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Apple через английский — экспериментально",
                   isOn: $settings.appleEnglishExperimental)
            Button(settings.translationPairPrepared
                   ? "Проверить языковую пару русский ↔ английский"
                   : "Подготовить языковую пару русский ↔ английский") {
                settings.beginTranslationPreparation()
                var configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "ru"),
                    target: Locale.Language(identifier: "en"))
                configuration.invalidate()
                translationConfiguration = configuration
            }
            Text("Режим выключен по умолчанию и сохраняет статус Experimental до отдельного go/no-go benchmark.")
                .font(.caption).foregroundStyle(.secondary)

            if let message = settings.statusMessage {
                Text(message).font(.caption)
            }
        }
        .padding(20)
        .frame(width: 610, height: 650)
        .onAppear { settings.loadKey() }
        .alert("Разрешить отправку выбранного акта в Groq?",
               isPresented: $confirmingCloudConsent) {
            Button("Разрешить") {
                settings.cloudConsent = true
                settings.statusMessage = "Облачная обработка включена."
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Sudrf отправит только акт, для которого вы явно нажмёте «Создать сводку». Опубликованный текст может содержать персональные данные третьих лиц.")
        }
        .translationTask(translationConfiguration) { session in
            do {
                try await session.prepareTranslation()
                let sourceCode = session.sourceLanguage?.languageCode?.identifier
                if sourceCode == "ru" {
                    await MainActor.run {
                        var reverse = TranslationSession.Configuration(
                            source: Locale.Language(identifier: "en"),
                            target: Locale.Language(identifier: "ru"))
                        reverse.invalidate()
                        translationConfiguration = reverse
                    }
                } else {
                    await MainActor.run {
                        translationConfiguration = nil
                        settings.completeTranslationPreparation()
                    }
                }
            } catch {
                await MainActor.run {
                    translationConfiguration = nil
                    settings.failTranslationPreparation(error)
                }
            }
        }
    }
}
