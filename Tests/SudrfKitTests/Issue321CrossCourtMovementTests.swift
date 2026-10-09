import XCTest
@testable import SudrfKit

private enum Issue321ClientMode: Equatable, Sendable {
    case valid
    case partialListing
    case captcha
    case mismatchedTitle
    case mismatchedHost
    case mismatchedUID
    case mismatchedNumber
    case mismatchedResponseHost
}

private actor Issue321CaseClient: CaseProviding {
    private let sourceHost = "uwsud.komi.sudrf.ru"
    private let rows: [CaseSearchResult]
    private let mode: Issue321ClientMode
    private let judicialUID: String
    private let baseCard: CaseCard
    private let fetchedCaseNumbers: [String: String]
    private(set) var requestedListings: [URL] = []
    private(set) var requestedCards: [URL] = []

    init(rows: [CaseSearchResult], mode: Issue321ClientMode,
         judicialUID: String, baseCard: CaseCard,
         fetchedCaseNumbers: [String: String] = [:]) {
        self.rows = rows
        self.mode = mode
        self.judicialUID = judicialUID
        self.baseCard = baseCard
        self.fetchedCaseNumbers = fetchedCaseNumbers
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        []
    }

    func uidRegistrations(url: URL, court: Court, cartoteka: Cartoteka,
                          judicialUID: String) async throws -> [CaseSearchResult]? {
        requestedListings.append(url)
        guard judicialUID == self.judicialUID else { return nil }
        if mode == .partialListing { throw IncompleteCaseSearchError() }
        if mode == .captcha {
            throw SudrfError.captchaRequired(formURL: URL(string: "https://uwsud.komi.sudrf.ru/")!)
        }
        var result = rows
        switch mode {
        case .mismatchedTitle:
            if let index = result.firstIndex(where: { $0.caseNumber == "12-879/2026" }) {
                result[index].courtTitle = "Кировский районный суд города Санкт-Петербурга"
            }
        case .mismatchedHost:
            if let index = result.firstIndex(where: { $0.caseNumber == "12-879/2026" }) {
                result[index].cardURL = URL(string: result[index].cardURL!.absoluteString
                    .replacingOccurrences(of: "syktsud.komi.sudrf.ru", with: "other.sudrf.ru"))
            }
        case .valid, .partialListing, .captcha, .mismatchedUID,
             .mismatchedNumber, .mismatchedResponseHost:
            break
        }
        return result
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        baseCard
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "case_id" })?.value
        if SudrfHost.moduleHost(url.host ?? "") == SudrfHost.moduleHost(sourceHost),
           id == "34759060" {
            return baseCard
        }
        if let row = rows.first(where: {
            $0.caseID == id
                && $0.cardURL.map {
                    SudrfHost.moduleHost($0.host ?? "")
                        == SudrfHost.moduleHost(url.host ?? "")
                } == true
        }) {
            return CaseCard(rawText: "", actText: nil, judge: row.judge, result: row.result,
                            uid: judicialUID,
                            caseNumber: fetchedCaseNumbers[row.caseID ?? ""] ?? row.caseNumber)
        }
        throw SudrfError.http(status: 404)
    }

    func fetchCardWithResponseURL(url: URL) async throws -> SudrfCaseCardFetchResult {
        requestedCards.append(url)
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "case_id" })?.value
        guard let row = rows.first(where: { $0.caseID == id }) else {
            throw SudrfError.http(status: 404)
        }
        var uid = judicialUID
        var number = fetchedCaseNumbers[row.caseID ?? ""] ?? row.caseNumber
        if mode == .mismatchedUID && row.caseNumber == "12-879/2026" {
            uid = "11RS0020-01-2026-000001-00"
        }
        if mode == .mismatchedNumber && row.caseNumber == "12-879/2026" {
            number = "12-888/2026"
        }
        let card = CaseCard(
            rawText: "", actText: nil, judge: row.judge, result: row.result,
            uid: uid, caseNumber: number,
            receiptDate: row.receiptDate, decisionDate: row.decisionDate)
        let responseURL: URL
        if mode == .mismatchedResponseHost && row.caseNumber == "12-879/2026" {
            responseURL = URL(string: url.absoluteString.replacingOccurrences(
                of: "syktsud.komi.sudrf.ru", with: "uwsud.komi.sudrf.ru"))!
        } else {
            responseURL = url
        }
        return SudrfCaseCardFetchResult(card: card, responseURL: responseURL)
    }
}

final class Issue321CrossCourtMovementTests: XCTestCase {
    private let uid = "11RS0020-01-2026-000655-63"
    private let sourceHost = "uwsud.komi.sudrf.ru"
    private let targetHost = "syktsud.komi.sudrf.ru"
    private let sourceTitle = "Усть-Вымский районный суд Республики Коми"
    private let targetTitle = "Сыктывкарский городской суд Республики Коми"

    func testUIDListingFetchesPublishedCrossHostCardsAndSuppressesExactKnownMirror()
        async throws {
        let rows = try listingRows()
        let client = makeClient(rows: rows, mode: .valid)
        let movement = try await makeService(client: client).movement(
            for: try XCTUnwrap(rows.first), court: sourceCourt(), cartoteka: cartoteka())

        XCTAssertEqual(movement.uid, uid)
        XCTAssertNil(movement.incompleteHigherCourtDomains)
        XCTAssertEqual(movement.instances.map(\.caseNumber),
                       ["12-56/2026", "12-461/2026", "12-879/2026"])
        for (number, judge, receipt, decision, host) in [
            ("12-56/2026", "Балашенко Артем Игоревич", "02.04.2026", "06.04.2026", sourceHost),
            ("12-461/2026", "Печинина Людмила Анатольевна", "13.04.2026", "25.05.2026", targetHost),
            ("12-879/2026", "Леконцев Александр Пантелеевич", "19.06.2026", "25.08.2026", targetHost),
        ] {
            let instance = try XCTUnwrap(movement.instances.first { $0.caseNumber == number })
            XCTAssertEqual(instance.court, host == sourceHost ? sourceTitle : targetTitle)
            XCTAssertEqual(SudrfHost.moduleHost(instance.domain),
                           SudrfHost.moduleHost(host))
            XCTAssertEqual(instance.judge, judge)
            XCTAssertEqual(instance.sourceEvidence?.receiptDate, receipt)
            XCTAssertEqual(instance.sourceEvidence?.decisionDate, decision)
            XCTAssertEqual(instance.sourceEvidence?.judicialUID, uid)
        }

        let latest = try XCTUnwrap(movement.instances.first { $0.caseNumber == "12-879/2026" })
        XCTAssertTrue(latest.foundByUID)
        XCTAssertEqual(latest.sourceURL?.host, targetHost)
        let requestedListings = await client.requestedListings
        XCTAssertEqual(requestedListings, [uidListingURL()])
        let requestedCards = await client.requestedCards
        XCTAssertEqual(requestedCards.map(\.host), [targetHost, targetHost])
        XCTAssertFalse(requestedCards.contains { $0.host == sourceHost })
    }

    func testUIDListingUsesPublishedCardRegionForCrossRegionTransfer() async throws {
        var rows = try listingRows()
        let target = DistrictCourt(
            title: "Кировский районный суд города Санкт-Петербурга",
            domain: "krv.spb.sudrf.ru", code: "78RS0006", regionCode: "spb",
            kind: .district, portalSubject: "78")
        let index = try XCTUnwrap(rows.firstIndex { $0.caseNumber == "12-879/2026" })
        rows[index].courtTitle = target.title
        rows[index].cardURL = URL(string: try XCTUnwrap(rows[index].cardURL).absoluteString
            .replacingOccurrences(of: "syktsud.komi.sudrf.ru", with: target.domain))

        let client = makeClient(rows: rows, mode: .valid)
        let komiCourt = DistrictCourt(title: targetTitle, domain: targetHost,
                                      code: "11RS0001", regionCode: "komi",
                                      kind: .district, portalSubject: "11")
        let service = MovementService(client: client, transferCourts: { subjectCode in
            switch subjectCode {
            case "11":
                return [komiCourt]
            case "78":
                return [target]
            default:
                return []
            }
        })

        let movement = try await service.movement(
            for: try XCTUnwrap(rows.first), court: sourceCourt(), cartoteka: cartoteka())

        XCTAssertNil(movement.incompleteHigherCourtDomains)
        let transferred = try XCTUnwrap(movement.instances.first {
            $0.caseNumber == "12-879/2026"
        })
        XCTAssertEqual(transferred.court, target.title)
        XCTAssertEqual(transferred.sourceURL?.host, target.domain)
        XCTAssertEqual(transferred.sourceEvidence?.judicialUID, uid)
    }

    func testUIDListingKeepsDistinctNativeCardsWithSameNumberAsSeparateRegistrations()
        async throws {
        var rows = try listingRows()
        var secondCard = try XCTUnwrap(rows.first { $0.caseNumber == "12-461/2026" })
        secondCard.caseID = "99999999"
        secondCard.caseUID = "99999999-9999-4999-8999-999999999999"
        secondCard.cardURL = URL(string: "https://\(targetHost)/modules.php?name=sud_delo"
            + "&name_op=case&case_id=99999999"
            + "&case_uid=99999999-9999-4999-8999-999999999999"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")
        rows.append(secondCard)

        let client = makeClient(rows: rows, mode: .valid)
        let movement = try await makeService(client: client, includeKnownMirror: false).movement(
            for: try XCTUnwrap(rows.first), court: sourceCourt(), cartoteka: cartoteka())

        let registrations = movement.instances.filter { $0.caseNumber == "12-461/2026" }
        XCTAssertEqual(registrations.count, 2)
        XCTAssertEqual(Set(registrations.compactMap {
            URLComponents(url: $0.sourceURL!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "case_id" }?.value
        }), ["35190605", "99999999"])
    }

    func testUIDListingKeepsCrossCourtCardWhoseNumberMatchesLoadedCompositeAlias()
        async throws {
        let compositeNumber = "2а-5090/2026 ~ М-2417/2026"
        let caseID = "crosscourt-alias-card"
        var rows = try listingRows()
        var aliasRow = try XCTUnwrap(rows.first { $0.caseNumber == "12-461/2026" })
        aliasRow.caseNumber = "М-2417/2026"
        aliasRow.caseID = caseID
        aliasRow.caseUID = "crosscourt-alias-guid"
        aliasRow.courtTitle = targetTitle
        var components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(aliasRow.cardURL), resolvingAgainstBaseURL: false))
        components.queryItems = (components.queryItems ?? []).map { item in
            switch item.name {
            case "case_id": URLQueryItem(name: item.name, value: caseID)
            case "case_uid": URLQueryItem(name: item.name, value: "crosscourt-alias-guid")
            default: item
            }
        }
        aliasRow.cardURL = components.url
        rows.append(aliasRow)

        let client = makeClient(
            rows: rows, mode: .valid, baseCardCaseNumber: compositeNumber,
            fetchedCaseNumbers: [caseID: compositeNumber])
        let movement = try await makeService(client: client, includeKnownMirror: false).movement(
            for: try XCTUnwrap(rows.first), court: sourceCourt(), cartoteka: cartoteka())

        let retained = try XCTUnwrap(movement.instances.first { instance in
            guard let sourceURL = instance.sourceURL,
                  let items = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?.queryItems
            else { return false }
            return items.contains { $0.name == "case_id" && $0.value == caseID }
        })
        XCTAssertEqual(retained.caseNumber, compositeNumber)
        XCTAssertEqual(retained.sourceURL?.host, targetHost)
    }

    func testSameCourtPreliminaryAliasIsNotSuppressedByCompositeCardFromAnotherCourt()
        async throws {
        let compositeNumber = "2а-5090/2026 ~ М-2417/2026"
        var rows = try listingRows()
        let crossCourtIndex = try XCTUnwrap(rows.firstIndex { $0.caseNumber == "12-461/2026" })
        rows[crossCourtIndex].caseNumber = "2а-5090/2026"
        rows[crossCourtIndex].courtTitle = targetTitle
        let crossCourtID = try XCTUnwrap(rows[crossCourtIndex].caseID)

        var sameCourtAlias = try XCTUnwrap(rows.first { $0.caseNumber == "12-56/2026" })
        let sameCourtID = "same-court-preliminary-alias"
        sameCourtAlias.caseNumber = "М-2417/2026"
        sameCourtAlias.caseID = sameCourtID
        sameCourtAlias.caseUID = "same-court-preliminary-guid"
        sameCourtAlias.courtTitle = sourceTitle
        var components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(sameCourtAlias.cardURL), resolvingAgainstBaseURL: false))
        components.queryItems = (components.queryItems ?? []).map { item in
            switch item.name {
            case "case_id": URLQueryItem(name: item.name, value: sameCourtID)
            case "case_uid": URLQueryItem(name: item.name, value: "same-court-preliminary-guid")
            default: item
            }
        }
        sameCourtAlias.cardURL = components.url
        rows.append(sameCourtAlias)

        let client = makeClient(
            rows: rows, mode: .valid,
            fetchedCaseNumbers: [crossCourtID: compositeNumber, sameCourtID: compositeNumber])
        let movement = try await makeService(client: client, includeKnownMirror: false).movement(
            for: try XCTUnwrap(rows.first), court: sourceCourt(), cartoteka: cartoteka())

        let compositeRegistrations = movement.instances.filter {
            $0.caseNumber == compositeNumber
        }
        XCTAssertEqual(compositeRegistrations.count, 2)
        XCTAssertEqual(Set(compositeRegistrations.compactMap {
            SudrfHost.moduleHost($0.domain)
        }), Set([sourceHost, targetHost].map(SudrfHost.moduleHost)))
        XCTAssertTrue(compositeRegistrations.contains {
            $0.sourceURL?.absoluteString.contains("case_id=\(sameCourtID)") == true
        })
        XCTAssertTrue(compositeRegistrations.contains {
            $0.sourceURL?.absoluteString.contains("case_id=\(crossCourtID)") == true
        })
    }

    func testContradictoryCourtOrCardIdentityAndPartialListingFailClosed() async throws {
        let rows = try listingRows()
        for mode in [Issue321ClientMode.mismatchedTitle, .mismatchedHost,
                     .mismatchedUID, .mismatchedNumber, .mismatchedResponseHost,
                     .partialListing, .captcha] {
            let client = makeClient(rows: rows, mode: mode)
            let movement = try await makeService(client: client, includeKnownMirror: false).movement(
                for: try XCTUnwrap(rows.first), court: sourceCourt(), cartoteka: cartoteka())
            XCTAssertTrue(movement.incompleteHigherCourtDomains?.contains {
                SudrfHost.moduleHost($0) == SudrfHost.moduleHost(sourceHost)
            } == true, "\(mode) must leave the source walk marked incomplete")
            XCTAssertFalse(movement.instances.contains { $0.caseNumber == "12-879/2026" },
                           "\(mode) must not publish an unverified Syktyvkar registration")
            if mode == .partialListing || mode == .captcha {
                XCTAssertFalse(movement.instances.contains { $0.caseNumber == "12-461/2026" })
            }
        }
    }

    private func makeService(client: Issue321CaseClient,
                             includeKnownMirror: Bool = true) -> MovementService {
        let court = DistrictCourt(title: targetTitle, domain: targetHost,
                                  code: "11RS0001", regionCode: "komi",
                                  kind: .district, portalSubject: "11")
        return MovementService(client: client,
                               knownCards: includeKnownMirror ? [knownOldHostMirror()] : [],
                               transferCourts: { subjectCode in
            subjectCode == "11" ? [court] : []
        })
    }

    private func makeClient(rows: [CaseSearchResult], mode: Issue321ClientMode,
                            baseCardCaseNumber: String = "12-56/2026",
                            fetchedCaseNumbers: [String: String] = [:])
        -> Issue321CaseClient {
        let base = CaseCard(
            rawText: "", actText: nil, judge: "Балашенко Артем Игоревич",
            result: "Направлено по подведомственности", uid: uid,
            uidListingURL: uidListingURL(), caseNumber: baseCardCaseNumber,
            receiptDate: "02.04.2026", decisionDate: "06.04.2026")
        return Issue321CaseClient(rows: rows, mode: mode, judicialUID: uid, baseCard: base,
                                  fetchedCaseNumbers: fetchedCaseNumbers)
    }

    private func listingRows() throws -> [CaseSearchResult] {
        let html = try fixture("issue321_rjuid_komi")
        return try ResultsParser.parseComplete(html: html, court: sourceCourt())
    }

    private func sourceCourt() -> Court {
        Court(domain: sourceHost, title: sourceTitle, level: .district)
    }

    private func cartoteka() throws -> Cartoteka {
        try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "admj"))
    }

    private func uidListingURL() -> URL {
        URL(string: "https://uwsud.komi.sudrf.ru/modules.php?name=sud_delo"
            + "&name_op=r_juid&vnkod=11RS0020&srv_num=1&delo_id=1502001"
            + "&case_type=0&judicial_uid=\(uid)")!
    }

    private func knownOldHostMirror() -> KnownCard {
        let url = URL(string: "http://uwsud.komi.sudrf.ru/modules.php?name=sud_delo"
            + "&name_op=case&case_id=38789069"
            + "&case_uid=bd3a69d0-4f96-445c-93ca-26ac9d56cee8"
            + "&delo_id=1502001&case_type=0&new=0&srv_num=1")!
        return KnownCard(domain: "uwsud--komi.sudrf.ru", courtTitle: sourceTitle,
                         caseID: "38789069",
                         caseUID: "bd3a69d0-4f96-445c-93ca-26ac9d56cee8",
                         deloID: "1502001", new: "0", caseNumber: "12-879/2026",
                         levelRaw: CaseInstance.Level.first.rawValue,
                         cartotekaID: "admj", sourceURL: url)
    }

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена в бандле теста")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
