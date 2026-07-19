import AppIntents
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Runtime bridge

/// App Intents запускаются тем же приложением, но не должны создавать второй
/// ModelContainer. Мост слабо держит уже созданный AppRouter и тем самым
/// сохраняет единую SwiftData/concurrency-границу.
@MainActor
final class SudrfIntentRuntime {
    static let shared = SudrfIntentRuntime()
    private weak var router: AppRouter?

    private init() {}

    func install(_ router: AppRouter) { self.router = router }

    func requireRouter() throws -> AppRouter {
        guard let router, router.storageStartupError == nil else {
            throw SudrfIntentError.applicationUnavailable
        }
        return router
    }
}

enum SudrfIntentError: Error, CustomLocalizedStringResourceConvertible {
    case applicationUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .applicationUnavailable:
            "Sudrf не смог открыть локальную базу. Откройте приложение для восстановления."
        }
    }
}

// MARK: - Open

struct OpenCaseIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть судебное дело"
    static let description = IntentDescription("Открывает отслеживаемое дело в Sudrf.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Дело") var courtCase: CaseEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Открыть \(\.$courtCase)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let opened = try await MainActor.run {
            try SudrfIntentRuntime.shared.requireRouter().intentOpenCase(key: courtCase.id)
        }
        return .result(dialog: opened ? "Дело открыто в Sudrf." : "Дело больше не отслеживается.")
    }
}

struct OpenCourtActIntent: AppIntent {
    static let title: LocalizedStringResource = "Открыть судебный акт"
    static let description = IntentDescription("Открывает опубликованный акт и его дело в Sudrf.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Судебный акт") var courtAct: CourtActEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Открыть \(\.$courtAct)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let document = courtAct.document
        let opened = try await MainActor.run {
            try SudrfIntentRuntime.shared.requireRouter().intentOpenAct(
                caseKey: document.caseKey, sourceActID: document.sourceActID)
        }
        return .result(dialog: opened ? "Судебный акт открыт в Sudrf." : "Акт больше не доступен.")
    }
}

// MARK: - Refresh and collections

struct RefreshCaseIntent: AppIntent {
    static let title: LocalizedStringResource = "Обновить судебное дело"
    static let description = IntentDescription(
        "Обновляет выбранное дело. CAPTCHA решается автоматически; ручной ввод возможен только в приложении.")
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Дело") var courtCase: CaseEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Обновить \(\.$courtCase)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await SudrfIntentRuntime.shared.requireRouter()
            .intentRefreshCase(key: courtCase.id)
        switch outcome {
        case .refreshed:
            return .result(dialog: "Дело обновлено.")
        case .captchaRequired:
            return .result(dialog: "Показан сохранённый кэш. Для ручного ввода CAPTCHA откройте Sudrf.")
        case .failed(let message):
            return .result(dialog: IntentDialog(
                full: "Обновить дело не удалось.", supporting: "\(message) Сохранённый кэш не изменён."))
        case .notFound:
            return .result(dialog: "Дело больше не отслеживается.")
        }
    }
}

struct AddCaseToCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Добавить дело в подборку"
    static let description = IntentDescription("Добавляет отслеживаемое дело в существующую или новую подборку.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Дело") var courtCase: CaseEntity
    @Parameter(title: "Название подборки") var collectionName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Добавить \(\.$courtCase) в подборку \(\.$collectionName)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let added = try await MainActor.run {
            try SudrfIntentRuntime.shared.requireRouter().intentAddCase(
                key: courtCase.id, collection: collectionName)
        }
        return .result(dialog: added
            ? "Дело добавлено в подборку."
            : "Не удалось добавить дело: проверьте название и наличие дела.")
    }
}

// MARK: - Hearings and PDF

struct ShowUpcomingHearingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Показать ближайшие заседания"
    static let description = IntentDescription("Возвращает ближайшие заседания из локальной базы Sudrf.")
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try await MainActor.run {
            try SudrfIntentRuntime.shared.requireRouter().intentUpcomingHearings()
        }
        return .result(value: text, dialog: IntentDialog(LocalizedStringResource(stringLiteral: text)))
    }
}

struct ExportCourtActPDFIntent: AppIntent {
    static let title: LocalizedStringResource = "Экспортировать судебный акт в PDF"
    static let description = IntentDescription("Создаёт PDF выбранного судебного акта локально.")
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Судебный акт") var courtAct: CourtActEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Экспортировать \(\.$courtAct) в PDF")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        let document = courtAct.document
        guard let data = await ActPDFExporter.renderData(text: document.sourceText) else {
            throw SudrfIntentError.applicationUnavailable
        }
        let safeNumber = document.caseNumber.replacingOccurrences(of: "/", with: "-")
        let file = IntentFile(data: data, filename: "Дело № \(safeNumber).pdf", type: .pdf)
        return .result(value: file, dialog: "PDF создан локально.")
    }
}

// MARK: - App Shortcuts

struct SudrfAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCaseIntent(),
            phrases: [
                "Открыть дело в \(.applicationName)",
                "Open a case in \(.applicationName)",
            ],
            shortTitle: "Открыть дело",
            systemImageName: "briefcase")
        AppShortcut(
            intent: RefreshCaseIntent(),
            phrases: [
                "Обновить дело в \(.applicationName)",
                "Refresh a case in \(.applicationName)",
            ],
            shortTitle: "Обновить дело",
            systemImageName: "arrow.clockwise")
        AppShortcut(
            intent: ShowUpcomingHearingsIntent(),
            phrases: [
                "Заседания в \(.applicationName)",
                "Upcoming hearings in \(.applicationName)",
            ],
            shortTitle: "Ближайшие заседания",
            systemImageName: "calendar")
    }
}
