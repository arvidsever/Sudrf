import ArgumentParser
import Foundation
import SudrfKit

@main
struct SudrfCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sudrf-cli",
        abstract: "Поиск дел и судебных актов на сайтах судов общей юрисдикции (ГАС «Правосудие»).",
        subcommands: [Search.self, Card.self, Route.self, District.self, Harvest.self],
        defaultSubcommand: Search.self
    )
}

// MARK: - общие опции суда

struct CourtOptions: ParsableArguments {
    @Option(name: .long, help: "Домен суда на sudrf.ru.")
    var domain: String = Court.syktyvkarskiy.domain

    @Option(name: .long, help: "Звено: district | subject | appeal | cassation.")
    var level: String = CourtLevel.district.rawValue

    func court() -> Court {
        let lvl = CourtLevel(rawValue: level) ?? .district
        return Court(domain: domain, title: domain, level: lvl)
    }
}

// MARK: - search

extension SudrfCLI {
    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Поиск по № дела, УИД или ФИО. По умолчанию воспроизводит пример: Сыктывкарский горсуд, дело об АП 5-470/2026."
        )

        @OptionGroup var courtOpts: CourtOptions

        @Option(name: .long, help: "Картотека (id). Районный суд: u1,g1,p1,adm,admj,m.")
        var type: String = "adm"

        @Option(name: .long, help: "№ дела, напр. 5-470/2026.")
        var number: String?

        @Option(name: .long, help: "УИД дела.")
        var uid: String?

        @Option(name: .long, help: "ФИО стороны.")
        var name: String?

        func run() async throws {
            let court = courtOpts.court()
            guard let cartoteka = CartotekaRegistry.find(level: court.level, id: type) else {
                throw ValidationError("Неизвестная картотека «\(type)» для звена «\(court.level.rawValue)».")
            }

            let field: SearchField
            let value: String
            if let number { field = .caseNumber; value = number }
            else if let uid { field = .uid; value = uid }
            else if let name { field = .name; value = name }
            else { field = .caseNumber; value = "5-470/2026" } // дефолт примера

            FileHandle.standardError.write(Data(
                "→ \(court.domain) | \(cartoteka.title) | \(value)\n".utf8))

            let client = SudrfClient()
            do {
                let results = try await client.search(
                    court: court, cartoteka: cartoteka, field: field, value: value)
                if results.isEmpty {
                    print("Ничего не найдено (учтите ограничения публикации по 262-ФЗ).")
                    return
                }
                print("Найдено: \(results.count)")
                for (i, r) in results.enumerated() {
                    print("""

                    [\(i + 1)] № \(r.caseNumber)
                        поступило: \(r.receiptDate ?? "—")  |  результат: \(r.result ?? "—")
                        судья: \(r.judge ?? "—")
                        case_id=\(r.caseID ?? "—")  case_uid=\(r.caseUID ?? "—")
                        карточка: \(r.cardURL?.absoluteString ?? "—")
                    """)
                }
            } catch let e as SudrfError {
                FileHandle.standardError.write(Data((e.description + "\n").utf8))
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - card

extension SudrfCLI {
    struct Card: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Загрузить карточку дела по case_id/case_uid и вывести текст акта."
        )

        @OptionGroup var courtOpts: CourtOptions

        @Option(name: .customLong("case-id")) var caseID: String
        @Option(name: .customLong("case-uid")) var caseUID: String
        @Option(name: .customLong("delo-id"), help: "delo_id картотеки.") var deloID: String
        @Option(name: .customLong("new"), help: "new (для апелляции/кассации; 1-я инстанция = 0).") var new: String = "0"

        func run() async throws {
            let court = courtOpts.court()
            let client = SudrfClient()
            do {
                let card = try await client.fetchCard(
                    court: court, caseID: caseID, caseUID: caseUID, deloID: deloID, new: new)
                print(card.actText ?? card.rawText)
            } catch let e as SudrfError {
                FileHandle.standardError.write(Data((e.description + "\n").utf8))
                throw ExitCode.failure
            }
        }
    }
}

// MARK: - route

extension SudrfCLI {
    struct Route: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "route",
            abstract: "По региону показать суд субъекта, апелляционный и кассационный суды ОСЮ."
        )

        @Option(name: .customLong("subject-code"), help: "Двухзначный код субъекта РФ, напр. «11» (Коми).")
        var subjectCode: String

        func run() throws {
            let code = CourtDirectory.normalizedSubjectCode(subjectCode)
            guard let subject = CourtDirectory.subjectCourt(forSubjectCode: code) else {
                throw ValidationError("Неизвестный код субъекта: «\(subjectCode)».")
            }
            print("Суд субъекта:   \(subject.title) — \(subject.domain)")
            if let a = CourtDirectory.appealCourt(forSubjectCode: code) {
                print("Апелляция ОСЮ:  \(a.title) — \(a.domain)")
            }
            if let k = CourtDirectory.cassationCourt(forSubjectCode: code) {
                print("Кассация ОСЮ:   \(k.title) — \(k.domain)")
            }
        }
    }
}

// MARK: - district

extension SudrfCLI {
    struct District: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "district",
            abstract: "Резолв районных/городских судов региона через единый портал (с кэшем)."
        )

        @Option(name: .customLong("subject-code"), help: "Двухзначный код субъекта РФ, напр. «11» (Коми).")
        var subjectCode: String

        @Flag(name: .long, help: "Принудительно перечитать портал.")
        var refresh = false

        @Flag(name: .long, help: "Диагностика: URL, размер ответа, статистика парсинга и фильтрации.")
        var debug = false

        func run() async throws {
            let resolver = DistrictCourtResolver()
            let code = CourtDirectory.normalizedSubjectCode(subjectCode)
            guard let region = CourtDirectory.subjectName(forSubjectCode: code) else {
                throw ValidationError("Неизвестный код субъекта: «\(subjectCode)».")
            }
            if debug {
                print(await resolver.diagnose(region: region))
                return
            }
            if refresh {
                let n = try await resolver.refresh(forRegion: region)
                FileHandle.standardError.write(Data("Портал: получено \(n) судов\n".utf8))
            }
            let courts = try await resolver.courts(forRegion: region)
            let military = try await resolver.militaryCourts(forRegion: region)
            if courts.isEmpty && military.isEmpty {
                print("Не найдено для субъекта \(code). Попробуйте --refresh.")
                return
            }
            print("Районные/городские суды (\(courts.count)):")
            for c in courts { print("  \(c.title) — \(c.domain)  [\(c.code ?? "—")]") }
            if !military.isEmpty {
                print("\nВоенные суды (\(military.count)):")
                for c in military { print("  \(c.title) — \(c.domain)  [\(c.code ?? "—")]") }
            }
        }
    }
}

extension SudrfCLI {
    struct Harvest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "harvest",
            abstract: "Снять с портала ВСЕ суды типа одним запросом (court_subj=0&court_type=…) "
                    + "и напечатать готовые строки для хардкода в CourtDirectory."
        )

        @Option(name: .long, help: "Буквенный тип кода: GV, OV, AV, KV, OS, RS…")
        var type: String = "OV"

        func run() async throws {
            let resolver = DistrictCourtResolver()
            let courts = try await resolver.courtsNationwide(type: type)
            print("// court_type=\(type.uppercased()): \(courts.count) судов")
            for c in courts {
                print("DirectoryCourt(title: \"\(c.title)\", domain: \"\(c.domain)\", "
                    + "level: .subject),  // \(c.code ?? "—")")
            }
        }
    }
}
