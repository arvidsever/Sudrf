import ArgumentParser
import Foundation
import SudrfKit

extension SudrfCLI {
    struct CalendarImport: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "calendar-import",
            abstract: "Проверить сохранённую страницу производственного календаря К+ и вывести нормализованные данные."
        )

        @Option(name: .long, help: "Год календаря.")
        var year: Int?

        @Option(name: .long, help: "Путь к исходному HTML.")
        var input: String?

        @Option(name: .customLong("source-url"), help: "Запрошенный URL источника.")
        var sourceURL: String?

        @Option(name: .customLong("final-url"), help: "Конечный URL после перенаправлений.")
        var finalURL: String?

        @Option(name: .long, help: "JSON-манифест для сборки полного архива.")
        var manifest: String?

        @Option(name: .customLong("input-directory"), help: "Каталог ранее загруженных HTML; без него страницы загружаются сейчас.")
        var inputDirectory: String?

        @Option(name: .customLong("existing-archive"), help: "Прежний архив, редакции которого нужно сохранить.")
        var existingArchive: String?

        @Option(name: .long, help: "Выходной ProductionCalendar.json; без него JSON печатается в stdout.")
        var output: String?

        func run() async throws {
            if let manifest { try await buildArchive(manifestPath: manifest); return }
            guard let year, let input, let sourceURL, let finalURL,
                  let requested = URL(string: sourceURL), let final = URL(string: finalURL) else {
                throw ValidationError("Для одной страницы нужны --year, --input, --source-url и --final-url")
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            let parsed = try ProductionCalendarImporter.parse(
                data: data, expectedYear: year, requestedURL: requested, finalURL: final)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try write(encoder.encode(parsed))
        }

        private func buildArchive(manifestPath: String) async throws {
            let decoder = JSONDecoder()
            let manifestURL = URL(fileURLWithPath: manifestPath)
            let manifest = try decoder.decode(ProductionCalendarImportManifest.self,
                                              from: Data(contentsOf: manifestURL))
            var pages: [Int: ProductionCalendarImportPage] = [:]
            for config in manifest.years {
                guard let requestedURL = ProductionCalendarImporter.sourceURL(for: config.year) else {
                    throw ValidationError("Год \(config.year) отсутствует в проверенном списке")
                }
                let data: Data
                let finalURL: URL
                if let inputDirectory {
                    let slug = requestedURL.deletingPathExtension().lastPathComponent
                    let file = URL(fileURLWithPath: inputDirectory).appendingPathComponent("\(slug).html")
                    data = try Data(contentsOf: file)
                    // Offline imports remain strict: the committed manifest
                    // records the final URL observed during the download and
                    // the builder verifies the saved bytes against its hash.
                    finalURL = config.observedFinalURL
                } else {
                    let response: URLResponse
                    (data, response) = try await URLSession.shared.data(from: requestedURL)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200, let responseURL = http.url else {
                        throw ValidationError("Источник \(config.year) не вернул HTTP 200")
                    }
                    finalURL = responseURL
                }
                pages[config.year] = ProductionCalendarImportPage(
                    data: data, requestedURL: requestedURL, finalURL: finalURL)
            }
            let previous = try existingArchive.map {
                try decoder.decode(LegalCalendarArchive.self,
                                   from: Data(contentsOf: URL(fileURLWithPath: $0)))
            }
            if let output, FileManager.default.fileExists(atPath: output), previous == nil {
                throw ValidationError(
                    "Выходной архив уже существует; укажите --existing-archive, чтобы сохранить прежние редакции")
            }
            let archive = try ProductionCalendarArchiveBuilder.build(
                manifest: manifest, pagesByYear: pages, retaining: previous)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try write(encoder.encode(archive))
        }

        private func write(_ data: Data) throws {
            if let output {
                try (data + Data("\n".utf8)).write(
                    to: URL(fileURLWithPath: output), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }
}
