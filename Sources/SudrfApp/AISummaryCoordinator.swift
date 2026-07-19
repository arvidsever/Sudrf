import Foundation
import SudrfKit
import SwiftUI

struct AnyActSummarizer: ActSummarizing {
    private let operation: @Sendable (ActDocument, SummaryOptions) async throws -> ActSummary

    init<S: ActSummarizing>(_ summarizer: S) {
        operation = { document, options in
            try await summarizer.summarize(document: document, options: options)
        }
    }

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        try await operation(document, options)
    }
}

struct ConfiguredActSummarizer: Sendable {
    let provider: String
    let model: String
    let options: SummaryOptions
    let pipelineVersion: String
    let summarizer: AnyActSummarizer
}

@MainActor
enum ActSummarizerFactory {
    static func configured(settings: AISettings = .shared) throws -> ConfiguredActSummarizer {
        let kind = settings.provider
        let model = settings.model
        if kind.isCloud {
            guard settings.cloudConsent else { throw AISummarizerError.cloudConsentRequired }
            guard !model.isEmpty, !model.lowercased().contains("latest") else {
                throw AISummarizerError.concreteModelRequired
            }
        }

        switch kind {
        case .mock:
            return wrap(MockActSummarizer(), provider: kind.rawValue,
                        model: "mock-v1", budget: 18_000)
        case .groq:
            let key = try requiredKey(kind)
            return wrap(GroqActSummarizer(key: key, model: model),
                        provider: kind.rawValue, model: model, budget: 18_000)
        case .gigaChat:
            let key = try requiredKey(kind)
            return wrap(GigaChatActSummarizer(
                authorizationKey: key, scope: settings.gigaChatScope, model: model),
                provider: kind.rawValue, model: model, budget: 18_000)
        case .yandexGPT:
            let key = try requiredKey(kind)
            guard !settings.yandexFolderID.isEmpty else { throw AISummarizerError.missingCredential }
            return wrap(YandexGPTActSummarizer(
                apiKey: key, folderID: settings.yandexFolderID, model: model),
                provider: kind.rawValue, model: model, budget: 18_000)
        case .appleDirect:
            let osBuild = Self.osBuildCacheComponent
            return wrap(AppleDirectActSummarizer(), provider: kind.rawValue,
                        model: "SystemLanguageModel.default", budget: 6_000,
                        pipelineVersion: "apple-direct-v1|\(osBuild)")
        case .appleTranslated:
            guard settings.appleEnglishExperimental else {
                throw AISummarizerError.providerUnavailable(
                    "Включите «Apple через английский — экспериментально» в Настройки → AI.")
            }
            guard settings.translationPairPrepared else {
                throw AISummarizerError.providerUnavailable(
                    "Сначала подготовьте языковую пару русский ↔ английский в Настройки → AI.")
            }
            let pair = InstalledTranslationPair()
            let translated = AppleTranslatedActSummarizer(
                englishSummarizer: AppleDirectActSummarizer(
                    requiredLocaleIdentifier: "en_US"),
                russianToEnglish: { text in try await pair.toEnglish(text) },
                englishToRussian: { text in try await pair.toRussian(text) })
            let osBuild = Self.osBuildCacheComponent
            return wrap(translated, provider: kind.rawValue,
                        model: "SystemLanguageModel.default", budget: 6_000,
                        pipelineVersion: "apple-translate-v1|ru-en-ru|\(osBuild)")
        }
    }

    private static var osBuildCacheComponent: String {
        ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func requiredKey(_ kind: AIProviderKind) throws -> String {
        guard let key = try AIKeychain.load(provider: kind), !key.isEmpty else {
            throw AISummarizerError.missingCredential
        }
        return key
    }

    private static func wrap<S: ActSummarizing>(_ base: S, provider: String,
                                                 model: String, budget: Int,
                                                 pipelineVersion: String = "summary-pipeline-v1")
        -> ConfiguredActSummarizer {
        let pipeline = ValidatedActSummarizer(base: ChunkingActSummarizer(base: base))
        return ConfiguredActSummarizer(
            provider: provider, model: model,
            options: SummaryOptions(maxInputCharacters: budget),
            pipelineVersion: pipelineVersion,
            summarizer: AnyActSummarizer(pipeline))
    }
}

struct ActSummarySheet: View {
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI-сводка судебного акта").font(.headline)
                if router.selectedSummaryIsStale {
                    Text("Устарела").font(.caption.bold()).foregroundStyle(.orange)
                }
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            .padding()
            Divider()

            Group {
                if router.summaryGenerating {
                    ProgressView("Анализ выбранного акта…")
                } else if let error = router.summaryError {
                    ContentUnavailableView("Сводка не создана", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let summary = router.selectedSummary {
                    ScrollView {
                        SummarySections(summary: summary) { paragraphID in
                            router.highlightSelectedActParagraph(paragraphID)
                            dismiss()
                        }
                        .padding(20)
                    }
                } else {
                    ContentUnavailableView(
                        "Сводки ещё нет", systemImage: "sparkles",
                        description: Text("В облако уйдёт только выбранный акт и только после явного запроса."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text("AI может ошибаться. Проверьте выводы по оригиналу.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(router.selectedSummary == nil ? "Создать сводку" : "Создать заново") {
                    router.generateSelectedActSummary()
                }
                .disabled(router.summaryGenerating || router.selectedActText == nil)
            }
            .padding()
        }
        .frame(minWidth: 680, minHeight: 620)
        .task { router.loadSelectedActSummary() }
    }
}

private struct SummarySections: View {
    let summary: ActSummary
    let onCitation: (String) -> Void

    private let sections: [(String, KeyPath<ActSummary, [SummaryClaim]>)] = [
        ("Требования", \.claims), ("Позиции сторон", \.partyPositions),
        ("Обстоятельства", \.circumstances), ("Мотивировка", \.reasoning),
        ("Резолютивная часть", \.disposition), ("Суммы", \.amounts),
        ("Даты", \.dates), ("Сроки", \.deadlines), ("Обжалование", \.appeal),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if summary.usedDoubleTranslation {
                Label("Двойной перевод: экспериментальный результат", systemImage: "translate")
                    .foregroundStyle(.orange)
            }
            ForEach(sections, id: \.0) { title, path in
                let claims = summary[keyPath: path]
                if !claims.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(title).font(.headline)
                        ForEach(claims) { claim in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(claim.text)
                                HStack(spacing: 6) {
                                    ForEach(Array(Set(claim.citations.map(\.paragraphID))).sorted(),
                                            id: \.self) { paragraphID in
                                        Button(paragraphID) { onCitation(paragraphID) }
                                            .buttonStyle(.link)
                                            .font(.caption)
                                            .help("Перейти к \(paragraphID) в русском оригинале")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            ForEach(summary.warnings, id: \.self) {
                Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let english = summary.intermediateEnglishSummary {
                DisclosureGroup("Диагностика: английская промежуточная сводка") {
                    Text(english).textSelection(.enabled).padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
