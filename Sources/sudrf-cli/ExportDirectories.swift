import ArgumentParser
import Foundation
import SudrfKit

/// Выгрузка справочников в JSON для внешних потребителей — прежде всего
/// для харвестера правовой базы КСОЮ (`sudrfpractice`), который ходит
/// на те же суды из Python. Справочник ведётся здесь и только здесь;
/// харвестер потребляет выхлоп этой команды, а не свою копию списка.
///
/// Использование:
///     swift run sudrf-cli export-directories --what courts    > courts.json
///     swift run sudrf-cli export-directories --what cartoteki > cartoteki.json
extension SudrfCLI {
    struct ExportDirectories: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export-directories",
            abstract: "Выгрузить справочники кассационных судов и картотек в JSON."
        )

        enum What: String, ExpressibleByArgument, CaseIterable {
            case courts, cartoteki
        }

        @Option(name: .long, help: "Что выгружать: courts | cartoteki.")
        var what: What = .courts

        func run() throws {
            let payload: Any
            switch what {
            case .courts:    payload = Self.courtsPayload()
            case .cartoteki: payload = Self.cartotekiPayload()
            }
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
        }

        // MARK: - суды

        /// Девять КСОЮ (с регионами подсудности) плюс Кассационный военный суд.
        /// У военного суда территориальной подсудности по субъектам нет — он
        /// один на страну, поэтому `regions` пуст, а `number` отсутствует.
        static func courtsPayload() -> [String: Any] {
            var courts: [[String: Any]] = CourtDirectory.cassationCourts.map {
                [
                    "number": $0.number,
                    "title": $0.title,
                    "domain": $0.domain,
                    "level": CourtLevel.cassation.rawValue,
                    "regions": $0.regions,
                ]
            }
            let military = CourtDirectory.cassationMilitaryCourt
            courts.append([
                "title": military.title,
                "domain": military.domain,
                "level": military.level.rawValue,
                "regions": [String](),
            ])
            return [
                "source": "SudrfKit/CourtDirectory.swift",
                "level": CourtLevel.cassation.rawValue,
                "courts": courts,
            ]
        }

        // MARK: - картотеки

        /// Четыре кассационные картотеки КСОЮ. `new` важнее `delo_id`:
        /// `g33_case`/`u33_case` с `new=0` тихо отдают форму поиска — см.
        /// `Docs/architecture/ksoyu-listing-grammar.md`, §1 и §5.
        static func cartotekiPayload() -> [String: Any] {
            let items: [[String: Any]] = CartotekaRegistry.cassationSOYu.map {
                [
                    "id": $0.id,
                    "title": $0.title,
                    "prefixes": $0.prefixes,
                    "delo_id": $0.deloID,
                    "new": $0.new,
                    "delo_table": $0.deloTable,
                    "case_number_field": $0.caseNumberField,
                    "uid_field": $0.uidField,
                    "name_field": $0.nameField,
                ]
            }
            return [
                "source": "SudrfKit/Cartoteka.swift",
                "level": CourtLevel.cassation.rawValue,
                "cartoteki": items,
            ]
        }
    }
}
