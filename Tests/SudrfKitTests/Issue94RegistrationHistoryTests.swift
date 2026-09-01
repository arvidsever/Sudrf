import Foundation
import XCTest
@testable import SudrfKit

final class Issue94RegistrationHistoryTests: XCTestCase {
    private let uid = "50RS0048-01-2025-013535-76"
    private let court = Court(domain: "history--mo.sudrf.ru",
                              title: "Химкинский городской суд", level: .district)

    private func cardURL(_ id: String, srvNum: String = "1") -> URL {
        URL(string: "https://history--mo.sudrf.ru/modules.php?name=sud_delo"
            + "&name_op=case&case_id=\(id)&case_uid=link-\(id)&delo_id=1540005"
            + "&new=0&srv_num=\(srvNum)")!
    }

    private func row(_ number: String, id: String, date: String? = nil,
                     result: String? = nil, cardURL: URL? = nil) -> CaseSearchResult {
        CaseSearchResult(caseNumber: number, receiptDate: date, decisionDate: date,
                         result: result, caseID: id, caseUID: "link-\(id)", cardURL: cardURL)
    }

    private func card(_ number: String, date: String? = "01.01.2026",
                      uid: String? = nil, actText: String? = nil,
                      acts: [CaseActText] = [], appeals: [AppealRecord] = [],
                      result: String? = nil,
                      predecessor: PreviousRegistrationReference? = nil) -> CaseCard {
        CaseCard(
            rawText: "", actText: actText,
            sessions: date.map { [CaseSession(date: $0, event: "Рассмотрение дела")] } ?? [],
            result: result, uid: uid ?? self.uid, caseNumber: number,
            receiptDate: date, decisionDate: date, acts: acts, appeals: appeals,
            previousRegistration: predecessor)
    }

    private func cartoteka(_ id: String) throws -> Cartoteka {
        try XCTUnwrap(CartotekaRegistry.find(level: .district, id: id))
    }

    func testG1RegistrationHistoryKeepsActsAppealOrderAndMaterialSeparate() async throws {
        let priorURL = cardURL("prior", srvNum: "9")
        let current = row("2-4461/2026 ~ М-2633/2026", id: "current", date: "10.04.2026")
        let prior = row("9-1693/2025", id: "prior", date: "10.01.2025", cardURL: priorURL)
        let material = row("13-7/2026", id: "material", date: "01.02.2026")
        let appeal = row("33-9548/2026", id: "appeal", date: "20.03.2026",
                         result: "Определение оставлено без изменения")
        let previousAppeal = AppealRecord(
            kind: .appeal, rawKind: "Апелляционная жалоба",
            higherCourt: "Московский областной суд", hearingDate: "20.03.2026")
        let priorCard = card(
            "9-1693/2025", date: "10.01.2025",
            acts: [CaseActText(id: "prior-act", kind: "Решение",
                               label: "Судебный акт", body: "prior act")],
            appeals: [previousAppeal])
        let client = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [prior],
                "history--mo.sudrf.ru/p1": [],
                "history--mo.sudrf.ru/m": [material],
                "appeal--mo.sudrf.ru/g2": [appeal],
            ],
            cardsByID: [
                "current": card(
                    "2-4461/2026 ~ М-2633/2026", date: "10.04.2026", actText: "current act",
                    predecessor: PreviousRegistrationReference(caseNumber: "9-1693/2025", url: priorURL)),
                "material": card("13-7/2026", date: "01.02.2026", actText: "material act"),
                "appeal": card("33-9548/2026", date: "20.03.2026", actText: "appeal act",
                                result: appeal.result),
            ],
            cardsByURL: [priorURL: priorCard])
        let service = MovementService(
            client: client,
            higherCourtTargets: [MovementSearchTarget(
                domain: "appeal--mo.sudrf.ru", courtTitle: "Московский областной суд",
                courtLevel: .subject, instanceLevel: .appeal, cartotekaIDs: ["g2"])])

        let movement = try await service.movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))

        let registrations = movement.instances.filter { $0.level == .first }
        XCTAssertEqual(registrations.map(\.caseNumber),
                       ["9-1693/2025", "2-4461/2026 ~ М-2633/2026"])
        XCTAssertEqual(registrations.first?.note, "Предыдущая регистрация")
        XCTAssertNil(registrations.last?.note)
        XCTAssertEqual(movement.instances.first { $0.caseNumber == "13-7/2026" }?.level, .material)
        XCTAssertEqual(movement.instances.first { $0.caseNumber == "33-9548/2026" }?.level, .appeal,
                       "appeal from the previous registration must still classify the higher card")

        let priorIndex = try XCTUnwrap(movement.instances.firstIndex { $0.caseNumber == "9-1693/2025" })
        let appealIndex = try XCTUnwrap(movement.instances.firstIndex { $0.caseNumber == "33-9548/2026" })
        let currentIndex = try XCTUnwrap(movement.instances.firstIndex {
            $0.caseNumber == "2-4461/2026 ~ М-2633/2026"
        })
        XCTAssertLessThan(priorIndex, appealIndex)
        XCTAssertLessThan(appealIndex, currentIndex)
        XCTAssertEqual(Set(movement.actBodies.values),
                       Set(["current act", "prior act", "material act", "appeal act"]))

        let searches = await client.searchKeys
        XCTAssertTrue(searches.contains("history--mo.sudrf.ru/g1"))
        XCTAssertTrue(searches.contains("history--mo.sudrf.ru/p1"))
        XCTAssertTrue(searches.contains("history--mo.sudrf.ru/m"))
        let directURLs = await client.directURLs
        XCTAssertEqual(directURLs.filter { $0 == priorURL }.count, 1,
                       "a UID result already matching the predecessor link must not refetch its URL")
    }

    func testPairedG1AndP1DiscoveryWorksInBothDirections() async throws {
        let scenarios = [
            (anchorID: "g1", pairedID: "p1", anchor: "2-10/2026", paired: "2а-11/2026"),
            (anchorID: "p1", pairedID: "g1", anchor: "2а-10/2026", paired: "2-11/2026"),
        ]

        for scenario in scenarios {
            let base = row(scenario.anchor, id: "base-\(scenario.anchorID)")
            let paired = row(scenario.paired, id: "paired-\(scenario.pairedID)")
            let client = Issue94RegistrationHistoryClient(
                rows: [
                    "history--mo.sudrf.ru/\(scenario.anchorID)": [],
                    "history--mo.sudrf.ru/\(scenario.pairedID)": [paired],
                    "history--mo.sudrf.ru/m": [],
                ],
                cardsByID: [
                    "base-\(scenario.anchorID)": card(scenario.anchor),
                    "paired-\(scenario.pairedID)": card(scenario.paired),
                ])
            let movement = try await MovementService(client: client).movement(
                for: base, court: court, cartoteka: try cartoteka(scenario.anchorID))

            let registrations = movement.instances.filter { $0.level == .first }.map(\.caseNumber)
            XCTAssertEqual(Set(registrations), Set([scenario.anchor, scenario.paired]))
            let searches = await client.searchKeys
            XCTAssertTrue(searches.contains("history--mo.sudrf.ru/\(scenario.anchorID)"))
            XCTAssertTrue(searches.contains("history--mo.sudrf.ru/\(scenario.pairedID)"))
        }
    }

    func testPairedRegistrationDoesNotTurnEmptyAnchorIntoHonestZero() async throws {
        let base = row("2-10/2026", id: "base")
        let paired = row("2а-11/2026", id: "paired")
        let material = row("13-1/2026", id: "material")
        let client = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [],
                "history--mo.sudrf.ru/p1": [paired],
                "history--mo.sudrf.ru/m": [material],
            ],
            cardsByID: [
                "base": card("2-10/2026"),
                "paired": card("2а-11/2026"),
                "material": card("13-1/2026"),
            ])

        let movement = try await MovementService(client: client).movement(
            for: base, court: court, cartoteka: try cartoteka("g1"))

        XCTAssertNil(movement.honestZeroDomains)
        XCTAssertTrue(movement.instances.contains { $0.caseNumber == paired.caseNumber })
    }

    func testChangedUIDIsAdmittedOnlyThroughExactPredecessorURL() async throws {
        let priorURL = URL(string: "https://history--mo.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&_id=changed-uid&_uid=link-changed-uid"
            + "&_deloId=1540005&_new=0&srv_num=7")!
        let current = row("2-200/2026", id: "current")
        let client = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [],
                "history--mo.sudrf.ru/p1": [],
                "history--mo.sudrf.ru/m": [],
            ],
            cardsByID: [
                "current": card(
                    "2-200/2026", uid: "50RS0048-01-2026-000001-01",
                    predecessor: PreviousRegistrationReference(caseNumber: "9-1693/2025", url: priorURL)),
            ],
            cardsByURL: [
                priorURL: card("9-1693/2025", uid: "50RS0048-01-2025-099999-76"),
            ])

        let movement = try await MovementService(client: client).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))

        let prior = try XCTUnwrap(movement.instances.first { $0.caseNumber == "9-1693/2025" })
        XCTAssertEqual(prior.sourceURL, priorURL)
        let directURLs = await client.directURLs
        XCTAssertEqual(directURLs, [priorURL])
        XCTAssertEqual(MovementService.queryValue(["case_id", "_id"], in: priorURL),
                       "changed-uid")
        XCTAssertEqual(MovementService.cartoteka(
            from: priorURL, court: court, caseNumber: "9-1693/2025")?.id, "g1")
    }

    func testUIDAndDifferentPublishedURLForSameNativeCardFetchOnlyOnce() async throws {
        let uidURL = cardURL("prior")
        let publishedURL = URL(string: uidURL.absoluteString + "&from=published")!
        let current = row("2-4461/2026", id: "current")
        let prior = row("9-1693/2025", id: "prior", cardURL: uidURL)
        let client = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [prior],
                "history--mo.sudrf.ru/p1": [],
                "history--mo.sudrf.ru/m": [row("13-1/2026", id: "material")],
            ],
            cardsByID: [
                "current": card(
                    "2-4461/2026", predecessor: PreviousRegistrationReference(
                        caseNumber: "9-1693/2025", url: publishedURL)),
                "material": card("13-1/2026"),
            ],
            cardsByURL: [uidURL: card("9-1693/2025")])

        let movement = try await MovementService(client: client).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))

        XCTAssertEqual(movement.instances.filter { $0.caseNumber == "9-1693/2025" }.count, 1)
        let directURLs = await client.directURLs
        XCTAssertEqual(directURLs, [uidURL])
    }

    func testInvalidPredecessorLinksAreIgnoredOrMarkHomeCourtIncomplete() async throws {
        let current = row("2-200/2026", id: "current")
        let otherCourtURL = URL(string: "https://other--mo.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=other&delo_id=1540005&new=0")!
        let otherCourt = Issue94RegistrationHistoryClient(
            rows: [:],
            cardsByID: ["current": card(
                "2-200/2026", predecessor: PreviousRegistrationReference(
                    caseNumber: "9-1/2025", url: otherCourtURL))])
        let otherMovement = try await MovementService(client: otherCourt).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))
        XCTAssertEqual(otherMovement.instances.filter { $0.level == .first }.count, 1)
        let otherDirectURLs = await otherCourt.directURLs
        XCTAssertTrue(otherDirectURLs.isEmpty)

        let mismatchedURL = cardURL("mismatch")
        let mismatch = Issue94RegistrationHistoryClient(
            rows: [:],
            cardsByID: ["current": card(
                "2-200/2026", predecessor: PreviousRegistrationReference(
                    caseNumber: "9-1/2025", url: mismatchedURL))],
            cardsByURL: [mismatchedURL: card("9-999/2025")])
        let mismatchMovement = try await MovementService(client: mismatch).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))
        XCTAssertFalse(mismatchMovement.instances.contains { $0.caseNumber == "9-999/2025" })

        let brokenURL = cardURL("broken")
        let broken = Issue94RegistrationHistoryClient(
            rows: [:],
            cardsByID: ["current": card(
                "2-200/2026", predecessor: PreviousRegistrationReference(
                    caseNumber: "9-1/2025", url: brokenURL))])
        let brokenMovement = try await MovementService(client: broken).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))
        XCTAssertTrue((brokenMovement.incompleteHigherCourtDomains ?? []).contains(court.domain))
        let brokenDirectURLs = await broken.directURLs
        XCTAssertEqual(brokenDirectURLs, [brokenURL])
    }

    func testNewestUIDRegistrationIsCurrentEvenWhenTrackedAnchorIsOlder() async throws {
        let old = row("9-1693/2025", id: "old", date: "10.01.2025")
        let current = row("2-4461/2026", id: "current", date: "10.04.2026")
        let client = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [current],
                "history--mo.sudrf.ru/p1": [],
                "history--mo.sudrf.ru/m": [],
            ],
            cardsByID: [
                "old": card("9-1693/2025", date: "10.01.2025"),
                "current": card("2-4461/2026", date: "10.04.2026"),
            ])

        let movement = try await MovementService(client: client).movement(
            for: old, court: court, cartoteka: try cartoteka("g1"))
        let registrations = movement.instances.filter { $0.level == .first }
        XCTAssertEqual(registrations.map(\.caseNumber), ["9-1693/2025", "2-4461/2026"])
        XCTAssertEqual(registrations.first?.note, "Предыдущая регистрация")
        XCTAssertNil(registrations.last?.note)
    }

    func testLongPredecessorChainStopsAtEightCards() async throws {
        let current = row("2-4461/2026", id: "current")
        let urls = (1...10).map { cardURL("chain-\($0)", srvNum: "\($0)") }
        var cardsByURL: [URL: CaseCard] = [:]
        for index in 1...10 {
            let next = index == 10 ? nil : PreviousRegistrationReference(
                caseNumber: "9-\(index + 1)/2025", url: urls[index])
            cardsByURL[urls[index - 1]] = card(
                "9-\(index)/2025", date: "\(String(format: "%02d", min(index, 28))).01.2025",
                predecessor: next)
        }
        let client = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [],
                "history--mo.sudrf.ru/p1": [],
                "history--mo.sudrf.ru/m": [],
            ],
            cardsByID: [
                "current": card(
                    "2-4461/2026", predecessor: PreviousRegistrationReference(
                        caseNumber: "9-1/2025", url: urls[0])),
            ],
            cardsByURL: cardsByURL)

        let movement = try await MovementService(client: client).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))

        XCTAssertEqual(movement.instances.filter { $0.level == .first }.count,
                       MovementService.maxRegistrationCards)
        let directURLs = await client.directURLs
        XCTAssertEqual(directURLs.count, MovementService.maxRegistrationCards - 1)
        XCTAssertEqual(Set(directURLs.map(MovementService.canonicalCardURL)).count, directURLs.count)
    }

    func testPredecessorCycleDoesNotRefetchPublishedCards() async throws {
        let current = row("2-4461/2026", id: "current")
        let firstURL = cardURL("cycle-1", srvNum: "1")
        let secondURL = cardURL("cycle-2", srvNum: "2")
        let client = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [],
                "history--mo.sudrf.ru/p1": [],
                "history--mo.sudrf.ru/m": [],
            ],
            cardsByID: [
                "current": card(
                    "2-4461/2026", predecessor: PreviousRegistrationReference(
                        caseNumber: "9-1/2025", url: firstURL)),
            ],
            cardsByURL: [
                firstURL: card(
                    "9-1/2025", predecessor: PreviousRegistrationReference(
                        caseNumber: "9-2/2025", url: secondURL)),
                secondURL: card(
                    "9-2/2025", predecessor: PreviousRegistrationReference(
                        caseNumber: "9-1/2025", url: firstURL)),
            ])

        let movement = try await MovementService(client: client).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))

        let registrations = movement.instances.filter { $0.level == .first }.map(\.caseNumber)
        XCTAssertEqual(Set(registrations), Set(["9-1/2025", "9-2/2025", "2-4461/2026"]))
        let directURLs = await client.directURLs
        XCTAssertEqual(directURLs, [firstURL, secondURL])
    }

    func testHomeRegistrationQueryAndCardFailuresMarkDomainIncomplete() async throws {
        let current = row("2-4461/2026", id: "current")
        let currentCard = card("2-4461/2026")
        let queryFailure = Issue94RegistrationHistoryClient(
            rows: [:], cardsByID: ["current": currentCard],
            failingSearchKeys: ["history--mo.sudrf.ru/g1"])
        let queryMovement = try await MovementService(client: queryFailure).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))
        XCTAssertTrue((queryMovement.incompleteHigherCourtDomains ?? []).contains(court.domain))

        let unavailable = row("9-1693/2025", id: "unavailable")
        let cardFailure = Issue94RegistrationHistoryClient(
            rows: [
                "history--mo.sudrf.ru/g1": [unavailable],
                "history--mo.sudrf.ru/p1": [],
                "history--mo.sudrf.ru/m": [],
            ],
            cardsByID: ["current": currentCard], failingCardIDs: ["unavailable"])
        let cardMovement = try await MovementService(client: cardFailure).movement(
            for: current, court: court, cartoteka: try cartoteka("g1"))
        XCTAssertTrue((cardMovement.incompleteHigherCourtDomains ?? []).contains(court.domain))
        XCTAssertFalse(cardMovement.instances.contains { $0.caseNumber == unavailable.caseNumber })
    }
}

private actor Issue94RegistrationHistoryClient: CaseProviding {
    private let rows: [String: [CaseSearchResult]]
    private let cardsByID: [String: CaseCard]
    private let cardsByURL: [URL: CaseCard]
    private let failingSearchKeys: Set<String>
    private let failingCardIDs: Set<String>
    private(set) var searchKeys: [String] = []
    private(set) var directURLs: [URL] = []

    init(rows: [String: [CaseSearchResult]], cardsByID: [String: CaseCard],
         cardsByURL: [URL: CaseCard] = [:], failingSearchKeys: Set<String> = [],
         failingCardIDs: Set<String> = []) {
        self.rows = rows
        self.cardsByID = cardsByID
        self.cardsByURL = cardsByURL
        self.failingSearchKeys = failingSearchKeys
        self.failingCardIDs = failingCardIDs
    }

    func search(court: Court, cartoteka: Cartoteka, field: SearchField,
                value: String) async throws -> [CaseSearchResult] {
        let key = "\(court.domain)/\(cartoteka.id)"
        searchKeys.append(key)
        if failingSearchKeys.contains(key) { throw URLError(.timedOut) }
        return rows[key] ?? []
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        if failingCardIDs.contains(caseID) { throw URLError(.timedOut) }
        guard let card = cardsByID[caseID] else { throw SudrfError.http(status: 404) }
        return card
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        directURLs.append(url)
        guard let card = cardsByURL[url] else { throw SudrfError.http(status: 404) }
        return card
    }
}
