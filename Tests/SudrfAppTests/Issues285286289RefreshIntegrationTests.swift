import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor AppealDispositionMovements: MovementProviding {
    let full: [String: CaseMovement]
    let partial: [String: CaseMovement]
    private var calls: [String: Int] = [:]

    init(full: [String: CaseMovement], partial: [String: CaseMovement]) {
        self.full = full
        self.partial = partial
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        let call = (calls[base.caseNumber] ?? 0) + 1
        calls[base.caseNumber] = call
        if call == 2, let value = partial[base.caseNumber] { return value }
        return try XCTUnwrap(full[base.caseNumber])
    }
}

@MainActor
final class Issues285286289RefreshIntegrationTests: XCTestCase {
    private let today = DateUtil.parse("01.04.2026")!

    func testAppealDispositionsSurviveFullPartialRefreshAndReopenWithoutDuplicates()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issues-285-286-289-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let contexts = try makeContexts()
        let full = makeMovements()
        let partial = makePartialMovements(from: full)
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        var keys: [String: String] = [:]

        for context in contexts {
            let movement = try XCTUnwrap(full[context.caseNumber])
            var storedMovement = movement
            if context.caseNumber == "10-25/2026" {
                storedMovement.acts[0].date = "—"
            }
            var stale = MovementDerivation.snapshot(
                from: storedMovement, context: context, today: today)
            stale.stageRaw = CaseStageKind.appeal.rawValue
            stale.stageTag = "Апелляция"
            stale.statusText = "В производстве"
            stale.semanticProjectionVersion = 4
            stale.deadlines.append(StoredDeadline(
                kind: "custom", what: "Пользовательский срок", basis: "fixture",
                calLabel: "ручной",
                dateRef: DateUtil.parse("01.01.2030")!.timeIntervalSinceReferenceDate,
                statusRaw: DeadlineStatus.confirmed.rawValue,
                occurrenceKey: "\(context.caseNumber)-manual"))
            let record = try store.upsert(
                context: context, snapshot: stale, movement: storedMovement,
                collections: ["Регрессия 285-286-289"])
            let seed = CaseEvent.make(
                kind: .complaintRegistered, occurrence: ["\(context.caseNumber)-seed"],
                observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
            record.eventJournal = CaseEventJournal(derivationVersion: 4, events: [seed])
            keys[context.caseNumber] = record.key
        }
        try store.save()

        let issue285Key = try XCTUnwrap(keys["10-25/2026"])
        let partialOnly = AppealDispositionMovements(full: partial, partial: partial)
        let partialCenter = RefreshCenter(store: store, client: SudrfClient(),
                                          serviceBuilder: { _ in partialOnly })
        guard case .partial = await partialCenter.refresh(key: issue285Key)?.value.outcome else {
            return XCTFail("старый movement № 285 должен пережить partial refresh")
        }
        let repairedFromEvidence = try XCTUnwrap(store.record(forKey: issue285Key))
        XCTAssertEqual(repairedFromEvidence.snapshot?.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertEqual(repairedFromEvidence.movement?.acts.first?.date, "—")
        XCTAssertEqual(repairedFromEvidence.snapshot?.semanticProjectionVersion, 5)
        XCTAssertEqual(repairedFromEvidence.eventJournal?.derivationVersion, 5)
        XCTAssertEqual(repairedFromEvidence.eventJournal?.events.count, 1)

        let service = AppealDispositionMovements(full: full, partial: partial)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })
        for context in contexts {
            let key = try XCTUnwrap(keys[context.caseNumber])
            let execution = await center.refresh(key: key)?.value
            XCTAssertEqual(execution?.outcome, .refreshed)
        }
        try assertState(in: store, container: container, keys: keys)

        for context in contexts {
            let key = try XCTUnwrap(keys[context.caseNumber])
            guard case .partial = await center.refresh(key: key)?.value.outcome else {
                return XCTFail("ожидался partial refresh для \(context.caseNumber)")
            }
        }

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertState(in: reopened, container: reopenedContainer, keys: keys)

        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { _ in AppealDispositionMovements(full: full, partial: partial) })
        for context in contexts {
            let key = try XCTUnwrap(keys[context.caseNumber])
            let execution = await reopenedCenter.refresh(key: key)?.value
            XCTAssertEqual(execution?.outcome, .refreshed)
        }
        try assertState(in: reopened, container: reopenedContainer, keys: keys)
    }

    private func assertState(in store: TrackedStore, container: ModelContainer,
                             keys: [String: String]) throws {
        XCTAssertEqual(store.all().count, 3)
        let expectations: [String: (CaseStageKind, String?, Bool)] = [
            "10-25/2026": (.first, nil, false),
            "5-619/2021": (.done, "Изменено", true),
            "22-227/2020": (.done, "СНЯТО по ДРУГИМ ОСНОВАНИЯМ", false),
        ]
        for (number, expected) in expectations {
            let record = try XCTUnwrap(store.record(forKey: try XCTUnwrap(keys[number])))
            XCTAssertEqual(record.snapshot?.stageRaw, expected.0.rawValue, number)
            if let status = expected.1 {
                XCTAssertEqual(record.snapshot?.statusText, status, number)
            }
            XCTAssertEqual(record.snapshot?.inForce, expected.2, number)
            XCTAssertEqual(record.collectionNames, ["Регрессия 285-286-289"])
            XCTAssertEqual(record.snapshot?.semanticProjectionVersion, 5)
            XCTAssertEqual(record.eventJournal?.derivationVersion, 5)
            XCTAssertEqual(record.eventJournal?.events.count, 1)
            XCTAssertEqual(record.snapshot?.deadlines.first {
                $0.occurrenceKey == "\(number)-manual"
            }?.status, .confirmed)
        }
        let issue285 = try XCTUnwrap(store.record(forKey: try XCTUnwrap(keys["10-25/2026"])))
        XCTAssertEqual(issue285.movement?.acts.map(\.id), ["issue-285-act"])
        XCTAssertNotNil(issue285.movement?.actBodies["issue-285-act"])

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: today)
        XCTAssertEqual(router.cases.count, 3)
        XCTAssertNil(router.stageCounts.first { $0.0 == .appeal })
        XCTAssertEqual(router.stageCounts.first { $0.0 == .first }?.1, 1)
        XCTAssertEqual(router.stageCounts.first { $0.0 == .done }?.1, 2)
        XCTAssertEqual(router.tierCounts.first { $0.0 == .district }?.1, 1)
        XCTAssertEqual(router.tierCounts.first { $0.0 == nil }?.1, 2)
        router.stageFilter = .appeal
        XCTAssertTrue(router.filteredCases().isEmpty)
        router.stageFilter = .first
        XCTAssertEqual(router.filteredCases().map(\.caseNumber), ["10-25/2026"])
        router.stageFilter = .done
        XCTAssertEqual(Set(router.filteredCases().map(\.caseNumber)),
                       Set(["5-619/2021", "22-227/2020"]))
    }

    private func makeContexts() throws -> [MovementContext] {
        [
            context(number: "10-25/2026", domain: "syktsud--komi.sudrf.ru",
                    court: "Сыктывкарский городской суд Республики Коми",
                    level: .district, cartoteka: "u2", base: .appeal),
            context(number: "5-619/2021", domain: "syktsud--komi.sudrf.ru",
                    court: "Сыктывкарский городской суд Республики Коми",
                    level: .district, cartoteka: "adm", base: .first),
            context(number: "22-227/2020", domain: "sankt-peterburgsky--spb.sudrf.ru",
                    court: "Санкт-Петербургский городской суд",
                    level: .subject, cartoteka: "u2", base: .appeal),
        ]
    }

    private func context(number: String, domain: String, court: String,
                         level: CourtLevel, cartoteka: String,
                         base: CaseInstance.Level) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: number == "22-227/2020" ? "Санкт-Петербург" : "Республика Коми",
            searchDomain: domain, displayDomain: domain.replacingOccurrences(of: "--", with: "."),
            courtTitle: court, courtLevelRaw: level.rawValue, courtCode: nil,
            cartotekaId: cartoteka, cartotekaLevelRaw: level.rawValue,
            caseNumber: number, caseID: number, caseUID: "fixture-\(number)",
            judicialUID: number == "5-619/2021" ? "11RS0001-01-2021-000619-01" : nil,
            baseInstanceLevelRaw: base.rawValue)
    }

    private func makeMovements() -> [String: CaseMovement] {
        let issue285Appeal = CaseInstance(
            level: .appeal, court: "Сыктывкарский городской суд Республики Коми",
            caseNumber: "10-25/2026", judge: "Котов Р.В.",
            domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: "Вынесено другое ПОСТАНОВЛЕНИЕ", sessions: [
                CaseSession(date: "23.03.2026", event: "Судебное заседание",
                            result: "Вынесено другое ПОСТАНОВЛЕНИЕ"),
                CaseSession(date: "27.03.2026",
                            event: "Дело сдано в отдел судебного делопроизводства"),
            ], actID: "issue-285-act", sourceEvidence: .init(
                receiptDate: "05.03.2026", decisionDate: "23.03.2026",
                judicialUID: "11MS0006-01-2026-000251-54"))
        let issue285Act = CaseAct(
            id: "issue-285-act", title: "Апелляционное постановление",
            date: "23.03.2026", courtShort: issue285Appeal.court, instanceLevel: .appeal)
        let issue285 = CaseMovement(
            uid: "11MS0006-01-2026-000251-54", caseNumber: "10-25/2026",
            inForce: false, instances: [issue285Appeal], complaints: [:],
            acts: [issue285Act], actBodies: [issue285Act.id:
                "УСТАНОВИЛ: доводы жалобы. ПОСТАНОВИЛ: постановление отменить, уголовное дело направить на новое рассмотрение мировому судье."])

        let first286 = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд Республики Коми",
            caseNumber: "5-619/2021", judge: nil,
            domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: "Назначено административное наказание", sessions: [
                CaseSession(date: "27.01.2021", event: "Судебное заседание",
                            result: "Назначено административное наказание"),
            ])
        let appeal286 = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми",
            caseNumber: "12-149/2021", judge: "Щенникова Е.В.",
            domain: "vs--komi.sudrf.ru", foundByUID: true, result: "Изменено",
            sessions: [
                CaseSession(date: "07.04.2021", event: "Судебное заседание",
                            result: "Изменено"),
                CaseSession(date: "15.03.2022", event: "Сдача материалов дела в архив"),
            ], actID: "issue-286-act")
        let issue286Act = CaseAct(
            id: "issue-286-act", title: "Решение", date: "07.04.2021",
            courtShort: appeal286.court, instanceLevel: .appeal)
        let issue286 = CaseMovement(
            uid: "11RS0001-01-2021-000619-01", caseNumber: "5-619/2021",
            inForce: false, instances: [first286, appeal286], complaints: [:],
            acts: [issue286Act], actBodies: [issue286Act.id:
                "РЕШИЛ: постановление судьи изменить. В остальной части оставить без изменения."])

        let appeal289 = CaseInstance(
            level: .appeal, court: "Санкт-Петербургский городской суд",
            caseNumber: "22-227/2020", judge: nil,
            domain: "sankt-peterburgsky--spb.sudrf.ru", foundByUID: false,
            result: "СНЯТО по ДРУГИМ ОСНОВАНИЯМ", sessions: [
                CaseSession(date: "12.12.2019", time: "09:17", event: "Передача дела судье"),
                CaseSession(date: "23.12.2019", time: "10:40", event: "Судебное заседание",
                            result: "Заседание отложено"),
                CaseSession(date: "23.01.2020", time: "16:00", event: "Судебное заседание",
                            result: "СНЯТО по ДРУГИМ ОСНОВАНИЯМ"),
            ])
        let issue289 = CaseMovement(
            uid: "", caseNumber: "22-227/2020", inForce: false,
            instances: [appeal289], complaints: [:], acts: [])
        return ["10-25/2026": issue285, "5-619/2021": issue286,
                "22-227/2020": issue289]
    }

    private func makePartialMovements(from full: [String: CaseMovement]) -> [String: CaseMovement] {
        var result: [String: CaseMovement] = [:]
        for (number, movement) in full {
            var partial = movement
            let missingDomain: String
            switch number {
            case "5-619/2021":
                missingDomain = "vs--komi.sudrf.ru"
                partial.instances.removeAll { $0.level == .appeal }
            case "22-227/2020":
                missingDomain = "sankt-peterburgsky--spb.sudrf.ru"
                partial.instances.removeAll()
            default:
                missingDomain = "syktsud--komi.sudrf.ru"
                partial.instances.removeAll()
            }
            partial.acts.removeAll()
            partial.actBodies.removeAll()
            partial.incompleteHigherCourtDomains = [missingDomain]
            result[number] = partial
        }
        return result
    }
}
