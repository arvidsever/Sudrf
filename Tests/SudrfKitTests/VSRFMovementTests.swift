import Foundation
import XCTest
@testable import SudrfKit

/// Интеграция второй кассации (ВС РФ) в `MovementService` на РЕАЛЬНЫХ фикстурах
/// выдачи ВС (дело Воробьёва). Проверяется:
///  • истребованное дело (с УИД) даёт одну инстанцию `.vsCassation` (foundByUID);
///  • истребовавшая жалоба НЕ дублируется отдельной записью, её «Истребовано дело»
///    вливается в движение дела;
///  • «отказ в передаче» попадает в результат и в пометку `note`;
///  • посторонние регионы с тем же № дела 1-й инстанции отсеиваются тройкой;
///  • без внедрённого клиента `vsrf` вторая кассация не добавляется.
final class VSRFMovementTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let uid = "11RS0001-01-2021-021221-14"

    private func district() -> Court {
        Court(domain: "syktsud--komi.sudrf.ru",
              title: "Сыктывкарский городской суд", level: .district)
    }
    private func base() -> CaseSearchResult {
        CaseSearchResult(caseNumber: "2-1649/2022", caseID: "900001", caseUID: "guid-000")
    }
    private func baseCard() throws -> CaseCard {
        // Датированная сессия обязательна: instanceOrderKey сортирует инстанции
        // по самому раннему событию движения, недатированные уходят в конец —
        // без неё 1-я инстанция «утонула» бы ниже второй кассации ВС.
        CaseCard(rawText: "", actText: nil,
                 sessions: [CaseSession(date: "02.03.2022", event: "Судебное заседание",
                                        result: "Иск удовлетворён полностью")],
                 judge: "О.А. Машкалева",
                 result: "Иск удовлетворён полностью", uid: uid,
                 caseNumber: "2-1649/2022",
                 parties: CaseParties(plaintiffs: ["Воробьёв Виктор Викторович"],
                                      defendants: ["Администрация муниципального округа Хамовники"]))
    }

    private func makeVSRF() throws -> MockVSRF {
        MockVSRF(uidResults: try VSRFSearchParser.parse(html: try fixture("vsrf_search_uid")),
                 numberResults: try VSRFSearchParser.parse(html: try fixture("vsrf_search_number")),
                 card: try VSRFCardParser.parse(html: try fixture("vsrf_card_vorobyev")))
    }

    func testSecondCassationWiredFromVSRF() async throws {
        let client = MockCase(firstCardID: "900001", firstCard: try baseCard())
        let service = MovementService(client: client, higherCourtDomains: [], vsrf: try makeVSRF())

        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.movement(for: base(), court: district(), cartoteka: cart)

        let vs = mv.instances.filter { $0.level == .vsCassation }
        XCTAssertEqual(vs.count, 1, "должна быть ровно одна инстанция второй кассации (дело)")
        let d = try XCTUnwrap(vs.first)
        XCTAssertEqual(d.court, "Верховный Суд РФ")
        XCTAssertEqual(d.caseNumber, "3-КГ23-1-К3")
        XCTAssertTrue(d.foundByUID)
        XCTAssertEqual(d.judge, "Жубрин М.А.")
        XCTAssertEqual(d.note, "отказ в передаче")
        XCTAssertEqual(d.result, "Отказ в передаче дела в суд кассационной инстанции")
        // «Истребовано дело» из жалобы влилось в движение дела.
        XCTAssertTrue(d.sessions.contains { $0.event.contains("Истребовано дело") && $0.date == "19.12.2022" })
        XCTAssertTrue(d.sessions.contains { $0.event.contains("Отказ в передаче") })
        // Отдельной «жалобной» инстанции быть не должно (жалоба истребована).
        XCTAssertFalse(vs.contains { $0.caseNumber == "3-КФ22-336-К3" })
    }

    func testSecondCassationAfterLowerInstancesInOrder() async throws {
        let client = MockCase(firstCardID: "900001", firstCard: try baseCard())
        let service = MovementService(client: client, higherCourtDomains: [], vsrf: try makeVSRF())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.movement(for: base(), court: district(), cartoteka: cart)

        // 1-я инстанция должна идти раньше второй кассации ВС.
        let levels = mv.instances.map { $0.level }
        if let iFirst = levels.firstIndex(of: .first), let iVS = levels.firstIndex(of: .vsCassation) {
            XCTAssertLessThan(iFirst, iVS)
        } else {
            XCTFail("ожидались инстанции .first и .vsCassation")
        }
    }

    func testNoVSRFClientMeansNoSecondCassation() async throws {
        let client = MockCase(firstCardID: "900001", firstCard: try baseCard())
        let service = MovementService(client: client, higherCourtDomains: [])   // vsrf не внедрён
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.movement(for: base(), court: district(), cartoteka: cart)
        XCTAssertFalse(mv.instances.contains { $0.level == .vsCassation })
    }

    func testSupremeCourtCardsKeepPublishedFirstAndAppealInstances() throws {
        let firstActURL = URL(string: "https://www.vsrf.ru/files/first.pdf")!
        let appealActURL = URL(string: "https://www.vsrf.ru/files/appeal.pdf")!
        let first = VSRFProduction(
            cardID: "12-first", cardSection: .cases, kind: .caseFile,
            number: "АКПИ25-1", instanceType: "Первая инстанция",
            publishedActs: [VSRFPublishedAct(url: firstActURL, date: "01.02.2025",
                                             title: "Определение")])
        let appeal = VSRFProduction(
            cardID: "12-appeal", cardSection: .cases, kind: .caseFile,
            number: "АПЛ25-1", instanceType: "Апелляционная инстанция",
            publishedActs: [VSRFPublishedAct(url: appealActURL, date: "01.03.2025",
                                              title: "Определение")])
        let romanLabelFirst = VSRFProduction(
            cardID: "12-roman-first", cardSection: .claims, kind: .caseFile,
            number: "3-КГ25-12-К5", instanceType: "I инстанция")

        let firstMovement = try MovementService.vsrfAnchorMovement(
            card: VSRFCard(productions: [first]), productionID: "12-first",
            section: .cases, expectedNumber: first.number!)
        let appealMovement = try MovementService.vsrfAnchorMovement(
            card: VSRFCard(productions: [appeal]), productionID: "12-appeal",
            section: .cases, expectedNumber: appeal.number!)
        let romanLabelMovement = try MovementService.vsrfAnchorMovement(
            card: VSRFCard(productions: [romanLabelFirst]), productionID: "12-roman-first",
            section: .claims, expectedNumber: romanLabelFirst.number!)
        let firstInstance = try XCTUnwrap(firstMovement.instances.first)
        let appealInstance = try XCTUnwrap(appealMovement.instances.first)
        let romanLabelInstance = try XCTUnwrap(romanLabelMovement.instances.first)
        let firstMappedAct = try XCTUnwrap(firstMovement.acts.first)
        let appealMappedAct = try XCTUnwrap(appealMovement.acts.first)

        XCTAssertEqual(firstInstance.level, .first)
        XCTAssertEqual(firstMappedAct.instanceLevel, .first)
        XCTAssertEqual(firstMappedAct.title, "Определение")
        XCTAssertEqual(appealInstance.level, .appeal)
        XCTAssertEqual(appealMappedAct.instanceLevel, .appeal)
        XCTAssertEqual(appealMappedAct.title, "Апелляционное определение")
        XCTAssertEqual(romanLabelInstance.level, .first,
                       "метка I инстанция сильнее кассационного номера производства")
    }

    func testFailedUIDSearchKeepsSuccessfulCaseNumberResultAsPartial() async throws {
        let first = VSRFFirstInstance(court: "Сыктывкарский городской суд",
                                      caseNumber: "2-1649/2022")
        let complaint = VSRFProduction(
            cardID: "21-33970283", kind: .complaint, number: "3-КФ22-336-К3",
            incomingDate: "10.12.2022", firstInstance: first,
            applicant: "Воробьёв Виктор Викторович")
        let mock = MockVSRF(
            uidResults: .init(total: 0, results: []),
            numberResults: .init(total: 1, results: [complaint]),
            card: .init(productions: []), failUID: true)

        let result = try await MovementService.vsrfInstancesOutcome(
            vsrf: mock, uid: uid, firstInstanceCourt: "Сыктывкарский городской суд",
            firstInstanceCaseNumber: "2-1649/2022", partySurnames: ["ВОРОБЬЕВ"])

        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.instances.map(\.caseNumber), ["3-КФ22-336-К3"])
    }

    func testIntakeIsAssignedOnlyToNearestFollowingCaseRound() async {
        let first = VSRFFirstInstance(court: "Сыктывкарский городской суд", caseNumber: "2-1649/2022")
        let complaintOne = VSRFProduction(cardID: "c1", kind: .complaint, number: "3-КФ-1",
                                           incomingDate: "01.01.2025", firstInstance: first,
                                           events: [VSRFEvent(date: "10.01.2025", text: "Истребовано дело")])
        let complaintUnmatched = VSRFProduction(cardID: "c2", kind: .complaint, number: "3-КФ-2",
                                                 incomingDate: "01.04.2025", firstInstance: first,
                                                 events: [VSRFEvent(date: "20.04.2025", text: "Истребовано дело")])
        let caseOne = VSRFProduction(cardID: "d1", kind: .caseFile, number: "3-КГ-1",
                                     incomingDate: "12.01.2025", uid: uid, firstInstance: first,
                                     events: [VSRFEvent(date: "15.01.2025", text: "Передано судье")])
        let caseTwo = VSRFProduction(cardID: "d2", kind: .caseFile, number: "3-КГ-2",
                                     incomingDate: "15.03.2025", uid: uid, firstInstance: first,
                                     events: [VSRFEvent(date: "16.03.2025", text: "Принято к производству")])
        let results = VSRFSearchResults(total: 4, results: [caseOne, caseTwo, complaintOne, complaintUnmatched])
        let cards = Dictionary(uniqueKeysWithValues: [caseOne, caseTwo, complaintOne, complaintUnmatched].map {
            ($0.id, VSRFCard(productions: [$0]))
        })
        let mock = MockVSRF(uidResults: results, numberResults: results, cardsByID: cards)

        let instances = await MovementService.vsrfInstances(
            vsrf: mock, uid: uid, firstInstanceCourt: first.court!,
            firstInstanceCaseNumber: first.caseNumber!, partySurnames: [])
        let roundOne = instances.first { $0.caseNumber == "3-КГ-1" }
        let roundTwo = instances.first { $0.caseNumber == "3-КГ-2" }
        XCTAssertTrue(roundOne?.sessions.contains { $0.event.contains("Истребовано дело") } == true)
        XCTAssertFalse(roundTwo?.sessions.contains { $0.event.contains("Истребовано дело") } == true)
        XCTAssertNotNil(instances.first { $0.caseNumber == "3-КФ-2" },
                        "жалоба без датированного последующего дела остаётся отдельной")
    }

    func testCurrentSearchAndCardFixturesFlowThroughVSRFClientAndMovementService() async throws {
        VSRFMovementURLProtocol.install(
            search: try Data(fixture("vsrf_current_search_340").utf8),
            card: try Data(fixture("vsrf_current_card_340").utf8))
        defer { VSRFMovementURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VSRFMovementURLProtocol.self]
        let client = VSRFClient(session: URLSession(configuration: configuration), minInterval: 0)
        let outcome = try await MovementService.vsrfInstancesOutcome(
            vsrf: client, uid: "11OS0000-01-2025-000169-68",
            firstInstanceCourt: "Модельный городской суд",
            firstInstanceCaseNumber: "3а-85/2025", partySurnames: [])

        XCTAssertFalse(outcome.incomplete)
        let instance = try XCTUnwrap(outcome.instances.first)
        XCTAssertEqual(outcome.instances.count, 1)
        XCTAssertEqual(instance.caseNumber, "3-ИКАД25-3-А2")
        XCTAssertEqual(instance.sourceURL?.absoluteString,
                       "https://www.vsrf.ru/lk/practice/claims/12-36321243")
        XCTAssertEqual(instance.result,
                       "Определение. Жалоба (представление) оставлена без удовлетворения")
        XCTAssertEqual(instance.sessions.map(\.date), ["16.09.2025", "15.10.2025", "15.10.2025"])
        XCTAssertEqual(instance.sessions[0].event, "Передано судье")
        XCTAssertEqual(instance.sessions[1].result,
                       "Вынесено решение по существу. Определение. Жалоба (представление) оставлена без удовлетворения")
        XCTAssertEqual(instance.sessions[2].result,
                       "Дата размещения информации о времени и месте заседания 16.09.2025 16:24")
        let act = try XCTUnwrap(outcome.acts.first)
        XCTAssertEqual(outcome.acts.count, 1)
        XCTAssertEqual(act.id, "act_vsrf_12-36321243_/lk/practice/stor_pdf/34000001")
        XCTAssertEqual(act.title, "Кассационное определение")
        XCTAssertEqual(act.date, "15.10.2025")
        XCTAssertEqual(act.productionNumber, "3-ИКАД25-3-А2")
        XCTAssertEqual(act.sourceFileURL?.absoluteString,
                       "https://www.vsrf.ru/lk/practice/stor_pdf/34000001")
        XCTAssertEqual(instance.linkedActIDs, [act.id])
        XCTAssertEqual(instance.linkedActURLs, [act.sourceFileURL!])

        let requests = VSRFMovementURLProtocol.requests()
        XCTAssertEqual(requests.count, 3, "UID search, ordinary search, and one verified card fetch")
        XCTAssertEqual(requests.filter { $0.path == "/lk/practice/claims" }.count, 2)
        XCTAssertEqual(requests.filter { $0.path == "/lk/practice/claims/12-36321243" }.count, 1)
        XCTAssertTrue(requests.contains {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "uniqueNumber" && $0.value == "11OS0000-01-2025-000169-68"
            } == true
        })
        XCTAssertTrue(requests.contains {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "oldCaseNumber1" && $0.value == "3а-85/2025"
            } == true
        })
    }

    func testDirectVSRFAnchorUsesExactCardAndOnlyUnambiguousCoLocatedPair() throws {
        let card = try VSRFCardParser.parse(html: fixture("vsrf_card_vorobyev"))
        let caseProduction = try XCTUnwrap(card.productions.first { $0.kind == .caseFile })
        let caseID = try XCTUnwrap(caseProduction.cardID)
        let number = try XCTUnwrap(caseProduction.number)
        let movement = try MovementService.vsrfAnchorMovement(
            card: card, productionID: caseID,
            section: caseProduction.resolvedSection, expectedNumber: number)

        XCTAssertEqual(movement.instances.count, 2,
                       "точная карточка публикует ровно одно дело и одну жалобу")
        XCTAssertEqual(Set(movement.instances.compactMap(\.sourceURL).compactMap {
            SourceNativeCardLocator.vsrf(url: $0)?.sourceNativeID
        }), Set(card.productions.compactMap(\.cardID)))
        XCTAssertEqual(movement.incompleteHigherCourtDomains, ["vsrf.ru"],
                       "прямая карточка не является полным списком ВС РФ")
        XCTAssertEqual(movement.sourceRefreshCoverage?.first?.loadedCardIdentities.count, 2)

        XCTAssertThrowsError(try MovementService.vsrfAnchorMovement(
            card: card, productionID: caseID,
            section: caseProduction.resolvedSection, expectedNumber: "не тот номер"))

        let ambiguous = VSRFCard(productions: card.productions + [
            VSRFProduction(cardID: "21-ambiguous", cardSection: .appeals,
                           kind: .complaint, number: "3-КФ26-999-К3")
        ])
        let safe = try MovementService.vsrfAnchorMovement(
            card: ambiguous, productionID: caseID,
            section: caseProduction.resolvedSection, expectedNumber: number)
        XCTAssertEqual(safe.instances.map(\.sourceURL), [caseProduction.cardURL],
                       "неоднозначные жалобы не приписываются делу")
    }

    func testPublishedComplaintPDFRemainsLinkedWhenComplaintTimelineIsAttachedToCase() async throws {
        let first = VSRFFirstInstance(court: "Модельный городской суд",
                                      caseNumber: "3а-85/2025")
        let caseRow = VSRFProduction(cardID: "12-201", cardSection: .claims,
                                     kind: .caseFile, number: "3-ИКАД25-3-А2",
                                     incomingDate: "12.01.2025",
                                     uid: "11OS0000-01-2025-000169-68",
                                     firstInstance: first,
                                     events: [VSRFEvent(date: "12.01.2025", text: "Передано судье")])
        let complaintRow = VSRFProduction(cardID: "21-202", cardSection: .claims,
                                          kind: .complaint, number: "3-КФ25-7-К3",
                                          incomingDate: "01.01.2025", firstInstance: first,
                                          events: [VSRFEvent(date: "10.01.2025", text: "Истребовано дело")])
        let publishedURL = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/909090")!
        let caseDetail = caseRow
        var complaintDetail = complaintRow
        complaintDetail.publishedActs = [VSRFPublishedAct(url: publishedURL,
                                                          date: "15.01.2025",
                                                          title: "Определение")]
        let mock = MockVSRF(
            uidResults: VSRFSearchResults(total: 1, results: [caseRow]),
            numberResults: VSRFSearchResults(total: 2, results: [caseRow, complaintRow]),
            cardsByID: ["12-201": VSRFCard(productions: [caseDetail]),
                        "21-202": VSRFCard(productions: [complaintDetail])])

        let outcome = try await MovementService.vsrfInstancesOutcome(
            vsrf: mock, uid: caseRow.uid, firstInstanceCourt: first.court!,
            firstInstanceCaseNumber: first.caseNumber!, partySurnames: [])

        XCTAssertEqual(outcome.instances.count, 1, "истребованная жалоба остаётся в общей инстанции")
        let instance = try XCTUnwrap(outcome.instances.first)
        let act = try XCTUnwrap(outcome.acts.first)
        XCTAssertEqual(outcome.acts.count, 1)
        XCTAssertEqual(instance.linkedActIDs, [act.id])
        XCTAssertEqual(instance.linkedActURLs, [publishedURL])
        XCTAssertEqual(act.productionNumber, "3-КФ25-7-К3",
                       "реквизиты акта принадлежат жалобе, не производству дела")
        XCTAssertEqual(act.sourceFileURL, publishedURL)
    }

    func testFailedComplaintCardDoesNotAttachUnverifiedIntakeToVerifiedCase() async throws {
        let first = VSRFFirstInstance(court: "Модельный городской суд", caseNumber: "3а-85/2025")
        let caseRow = VSRFProduction(cardID: "d1", cardSection: .claims, kind: .caseFile,
                                     number: "3-ИКАД25-3-А2", incomingDate: "20.01.2025",
                                     uid: "11OS0000-01-2025-000169-68", firstInstance: first,
                                     events: [VSRFEvent(date: "20.01.2025", text: "Передано судье")])
        let complaintRow = VSRFProduction(cardID: "c1", cardSection: .claims, kind: .complaint,
                                          number: "3-КФ25-1-К3", incomingDate: "01.01.2025",
                                          firstInstance: first,
                                          events: [VSRFEvent(date: "15.01.2025", text: "Истребовано дело")])
        let verifiedCase = VSRFProduction(cardID: "d1", cardSection: .claims, kind: .caseFile,
                                          number: caseRow.number, incomingDate: caseRow.incomingDate,
                                          uid: caseRow.uid, firstInstance: first,
                                          events: [VSRFEvent(date: "20.01.2025", text: "Передано судье"),
                                                   VSRFEvent(date: "15.10.2025", text: "Результат рассмотрения",
                                                             details: "Опубликованный результат")])
        let search = VSRFSearchResults(total: 2, results: [caseRow, complaintRow])
        let mock = MockVSRF(uidResults: .init(total: 1, results: [caseRow]),
                            numberResults: search,
                            cardsByID: ["d1": VSRFCard(productions: [verifiedCase])],
                            failingCardIDs: ["c1"])

        let outcome = try await MovementService.vsrfInstancesOutcome(
            vsrf: mock, uid: caseRow.uid, firstInstanceCourt: first.court!,
            firstInstanceCaseNumber: first.caseNumber!, partySurnames: [])
        let instance = try XCTUnwrap(outcome.instances.first)

        XCTAssertTrue(outcome.incomplete)
        XCTAssertEqual(instance.caseNumber, caseRow.number)
        XCTAssertEqual(instance.note, "Движение жалобы временно недоступно")
        XCTAssertTrue(instance.sessions.contains { $0.event == "Передано судье" })
        XCTAssertTrue(instance.sessions.contains { $0.event == "Результат рассмотрения" })
        XCTAssertFalse(instance.sessions.contains { $0.event == "Истребовано дело" },
                       "search-row intake is not authoritative until the complaint card verifies")
    }

    func testFailedOwnCardKeepsSummaryAndOnlyVerifiedComplaintIntake() async throws {
        let first = VSRFFirstInstance(court: "Модельный городской суд", caseNumber: "3а-85/2025")
        let caseRow = VSRFProduction(cardID: "d1", cardSection: .claims, kind: .caseFile,
                                     number: "3-ИКАД25-3-А2", incomingDate: "20.01.2025",
                                     uid: "11OS0000-01-2025-000169-68", firstInstance: first,
                                     events: [VSRFEvent(date: "15.10.2025", text: "Поиск: опубликованный итог")])
        let complaintRow = VSRFProduction(cardID: "c1", cardSection: .claims, kind: .complaint,
                                          number: "3-КФ25-1-К3", incomingDate: "01.01.2025",
                                          firstInstance: first,
                                          events: [VSRFEvent(date: "15.01.2025", text: "Истребовано дело")])
        let verifiedComplaint = VSRFProduction(cardID: "c1", cardSection: .claims,
                                              kind: .complaint, number: complaintRow.number,
                                              incomingDate: complaintRow.incomingDate,
                                              firstInstance: first,
                                              events: [VSRFEvent(date: "15.01.2025", text: "Истребовано дело",
                                                                details: "Подтверждённая карточкой жалобы")])
        let mock = MockVSRF(uidResults: .init(total: 1, results: [caseRow]),
                            numberResults: .init(total: 2, results: [caseRow, complaintRow]),
                            cardsByID: ["c1": VSRFCard(productions: [verifiedComplaint])],
                            failingCardIDs: ["d1"])

        let outcome = try await MovementService.vsrfInstancesOutcome(
            vsrf: mock, uid: caseRow.uid, firstInstanceCourt: first.court!,
            firstInstanceCaseNumber: first.caseNumber!, partySurnames: [])
        let instance = try XCTUnwrap(outcome.instances.first)

        XCTAssertTrue(outcome.incomplete)
        XCTAssertEqual(instance.caseNumber, caseRow.number)
        XCTAssertEqual(instance.result, "Поиск: опубликованный итог",
                       "the verified card failure keeps the search disposition as its header")
        XCTAssertEqual(instance.note, "Движение временно недоступно · жалоба проверена")
        XCTAssertEqual(instance.sessions.count, 1)
        XCTAssertEqual(instance.sessions.first?.event, "Истребовано дело")
        XCTAssertEqual(instance.sessions.first?.result, "Подтверждённая карточкой жалобы")
        XCTAssertFalse(instance.sessions.contains { $0.event.contains("Поиск:") })
    }

    func testDetailWithMatchingIDButWrongKindOrUIDFallsBackToSearchSummary() async throws {
        let uid = "11OS0000-01-2025-000169-68"
        let first = VSRFFirstInstance(court: "Модельный городской суд", caseNumber: "3а-85/2025")
        let row = VSRFProduction(cardID: "d1", cardSection: .claims, kind: .caseFile,
                                 number: "3-ИКАД25-3-А2", incomingDate: "20.01.2025",
                                 uid: uid, firstInstance: first,
                                 events: [VSRFEvent(date: "15.10.2025", text: "Search summary")])
        let wrongKind = VSRFProduction(cardID: "d1", cardSection: .claims, kind: .complaint,
                                       number: row.number, incomingDate: row.incomingDate,
                                       uid: uid, firstInstance: first,
                                       events: [VSRFEvent(date: "15.10.2025", text: "Wrong kind detail")])
        let wrongUID = VSRFProduction(cardID: "d1", cardSection: .claims, kind: .caseFile,
                                      number: row.number, incomingDate: row.incomingDate,
                                      uid: "11OS0000-01-2025-000170-68", firstInstance: first,
                                      events: [VSRFEvent(date: "15.10.2025", text: "Wrong UID detail")])

        for (mismatch, detail) in [("kind", wrongKind), ("UID", wrongUID)] {
            let mock = MockVSRF(uidResults: .init(total: 1, results: [row]),
                                numberResults: .init(total: 1, results: [row]),
                                cardsByID: ["d1": VSRFCard(productions: [detail])])
            let outcome = try await MovementService.vsrfInstancesOutcome(
                vsrf: mock, uid: uid, firstInstanceCourt: first.court!,
                firstInstanceCaseNumber: first.caseNumber!, partySurnames: [])
            let instance = try XCTUnwrap(outcome.instances.first, "\(mismatch) mismatch")

            XCTAssertTrue(outcome.incomplete, "\(mismatch) mismatch must mark the source incomplete")
            XCTAssertEqual(instance.note, "Движение временно недоступно", "\(mismatch) mismatch")
            XCTAssertEqual(instance.result, "Search summary", "\(mismatch) mismatch")
            XCTAssertTrue(instance.sessions.contains { $0.event == "Search summary" }, "\(mismatch) mismatch")
            XCTAssertFalse(instance.sessions.contains { $0.event == "Wrong kind detail" || $0.event == "Wrong UID detail" },
                           "unverified detail rows must not replace search fallback")
        }
    }
}

// MARK: - Моки

private actor MockCase: CaseProviding {
    let firstCardID: String
    let firstCard: CaseCard
    init(firstCardID: String, firstCard: CaseCard) {
        self.firstCardID = firstCardID; self.firstCard = firstCard
    }
    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] { [] }
    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)   // в этих сценариях путь по ссылке не используется
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard { firstCard }
}

private actor MockVSRF: VSRFProviding {
    let uidResults: VSRFSearchResults
    let numberResults: VSRFSearchResults
    private let defaultCard: VSRFCard?
    private let cardsByID: [String: VSRFCard]
    private let failingCardIDs: Set<String>
    let failUID: Bool

    init(uidResults: VSRFSearchResults, numberResults: VSRFSearchResults,
         card: VSRFCard, failUID: Bool = false, failingCardIDs: Set<String> = []) {
        self.uidResults = uidResults
        self.numberResults = numberResults
        self.defaultCard = card
        self.cardsByID = [:]
        self.failingCardIDs = failingCardIDs
        self.failUID = failUID
    }

    init(uidResults: VSRFSearchResults, numberResults: VSRFSearchResults,
         cardsByID: [String: VSRFCard], failingCardIDs: Set<String> = []) {
        self.uidResults = uidResults
        self.numberResults = numberResults
        self.defaultCard = nil
        self.cardsByID = cardsByID
        self.failingCardIDs = failingCardIDs
        self.failUID = false
    }

    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults {
        if uniqueNumber != nil {
            if failUID { throw SudrfError.parsing("неизвестный формат выдачи ВС РФ") }
            return uidResults
        }
        if oldCaseNumber != nil { return numberResults }
        return VSRFSearchResults(total: 0, results: [])
    }

    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        if failingCardIDs.contains(productionID) { throw SudrfError.http(status: 503) }
        return cardsByID[productionID] ?? defaultCard ?? VSRFCard(productions: [])
    }
}

private final class VSRFMovementURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var searchBody = Data()
    nonisolated(unsafe) private static var cardBody = Data()
    nonisolated(unsafe) private static var seen: [URL] = []
    private static let lock = NSLock()

    static func install(search: Data, card: Data) {
        lock.lock(); defer { lock.unlock() }
        searchBody = search
        cardBody = card
        seen = []
    }

    static func requests() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        searchBody = Data()
        cardBody = Data()
        seen = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.seen.append(url)
        let body = url.path == "/lk/practice/claims/12-36321243"
            ? Self.cardBody : Self.searchBody
        Self.lock.unlock()

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
