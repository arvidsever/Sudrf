import XCTest
import SudrfKit
@testable import SudrfApp

private actor OriginProviderStub: CaseProviding {
    var uidRows: [CaseSearchResult]
    var numberRows: [CaseSearchResult]
    var cards: [String: CaseCard]
    var rowsByCartAndValue: [String: [CaseSearchResult]]
    var throwTransientOnUID: Bool
    var transientUIDCartID: String?
    var cancelUIDCartID: String?
    var unreadableCardIDs: Set<String>
    var captchaOnUIDURL: URL?
    var captchaOnCardURL: URL?
    private(set) var fields: [SearchField] = []

    init(uidRows: [CaseSearchResult] = [], numberRows: [CaseSearchResult],
         cards: [String: CaseCard], rowsByCartAndValue: [String: [CaseSearchResult]] = [:],
         throwTransientOnUID: Bool = false, captchaOnUIDURL: URL? = nil,
         captchaOnCardURL: URL? = nil, transientUIDCartID: String? = nil,
         cancelUIDCartID: String? = nil, unreadableCardIDs: Set<String> = []) {
        self.uidRows = uidRows; self.numberRows = numberRows
        self.cards = cards; self.rowsByCartAndValue = rowsByCartAndValue
        self.throwTransientOnUID = throwTransientOnUID; self.captchaOnUIDURL = captchaOnUIDURL
        self.captchaOnCardURL = captchaOnCardURL
        self.transientUIDCartID = transientUIDCartID
        self.cancelUIDCartID = cancelUIDCartID
        self.unreadableCardIDs = unreadableCardIDs
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        fields.append(field)
        if field == .uid, throwTransientOnUID {
            throw SudrfError.transientNetworkError(domain: court.domain,
                                                    code: .timedOut, attempt: 3)
        }
        if field == .uid, cartoteka.id == transientUIDCartID {
            throw SudrfError.transientNetworkError(domain: court.domain,
                                                    code: .timedOut, attempt: 3)
        }
        if field == .uid, cartoteka.id == cancelUIDCartID { throw CancellationError() }
        if field == .uid, let captchaOnUIDURL {
            throw SudrfError.captchaRequired(formURL: captchaOnUIDURL)
        }
        return rowsByCartAndValue["\(cartoteka.id)|\(value)"] ?? (field == .uid ? uidRows : numberRows)
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        if let captchaOnCardURL { throw SudrfError.captchaRequired(formURL: captchaOnCardURL) }
        if unreadableCardIDs.contains(caseID) { throw SudrfError.http(status: 503) }
        guard let card = cards[caseID] else { throw SudrfError.http(status: 404) }
        return card
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
}

private actor MoscowOriginStub: MoscowOriginProviding {
    var rows: [MosGorSudResult]
    var cards: [URL: MosGorSudCard]
    var requestedAliases: [String?] = []
    var unreadable: Set<URL> = []

    init(rows: [MosGorSudResult], cards: [URL: MosGorSudCard], unreadable: Set<URL> = []) {
        self.rows = rows; self.cards = cards; self.unreadable = unreadable
    }

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        requestedAliases.append(courtAlias)
        return rows
    }

    func fetchCard(url: URL) async throws -> MosGorSudCard {
        if unreadable.contains(url) { throw SudrfError.http(status: 503) }
        guard let card = cards[url] else { throw SudrfError.http(status: 404) }
        return card
    }
}

final class CaseOriginResolverTests: XCTestCase {
    private let uid = "11RS0001-01-2025-011255-03"

    private func issue322Fixture(_ name: String) throws -> String {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../SudrfKitTests/Fixtures/\(name).html")
            .standardizedFileURL
        return try String(contentsOf: source, encoding: .utf8)
    }

    private func moscowAnchor(number: String, lowerNumber: String, lowerCourt: String,
                              lowerDate: String? = nil, lowerJudge: String,
                              anchorDate: String? = nil,
                              uid: String? = nil,
                              courtLevel: CourtLevel = .appeal) -> (MovementContext, CaseCard) {
        let isCassation = courtLevel == .cassation
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "город Москва",
            searchDomain: isCassation ? "2kas.sudrf.ru" : "1ap.sudrf.ru",
            displayDomain: isCassation ? "2kas.sudrf.ru" : "1ap.sudrf.ru",
            courtTitle: isCassation ? "Второй кассационный суд общей юрисдикции"
                : "Первый апелляционный суд общей юрисдикции",
            courtLevelRaw: isCassation ? "cassation" : "appeal",
            courtCode: nil, cartotekaId: isCassation ? "p3" : "p2",
            cartotekaLevelRaw: isCassation ? "cassation" : "appeal",
            caseNumber: number)
        context.judicialUID = uid
        context.baseInstanceLevelRaw = isCassation
            ? CaseInstance.Level.cassation.rawValue : CaseInstance.Level.appeal.rawValue
        let card = CaseCard(rawText: "", actText: nil, uid: uid,
                            caseNumber: number,
                            decisionDate: anchorDate,
                            lowerCourt: LowerCourtReference(
                                region: "77 - город Москва", courtTitle: lowerCourt,
                                caseNumber: lowerNumber, decisionDate: lowerDate,
                                judge: lowerJudge))
        return (context, card)
    }

    func testIssue322BothAppealsResolveSameMoscowFirstCard() async throws {
        let url = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/49e1e932-ca18-4a54-9797-987d15209322?caseNumber=3%D0%B0-3696/2020"))
        let row = MosGorSudResult(caseNumber: "3а-3696/2020", judge: "Севастьянова Н.Ю.",
                                  section: "first-admin", cardURL: url)
        let card = MosGorSudCard(uid: "77OS0000-01-2020-002855-77",
                                  caseNumber: "3а-3696/2020", judge: "Севастьянова Н.Ю.",
                                  result: "Удовлетворено частично, 26.06.2020",
                                  sessions: [CaseSession(date: "26.06.2020", event: "Решение")],
                                  rawText: "02.04.2020 Определение суда апелляционной инстанции "
                                    + "10.09.2020 Определение суда апелляционной инстанции")
        let stub = MoscowOriginStub(rows: [row], cards: [url: card])
        let resolver = CaseOriginResolver(client: SudrfClient(), moscowProvider: stub)
        for number in ["66а-2013/2020", "66а-4311/2020"] {
            let appealDate = number.contains("2013") ? "02.04.2020" : "10.09.2020"
            let (context, anchor) = moscowAnchor(
                number: number, lowerNumber: "3а-3696/2020",
                lowerCourt: "Московский городской суд",
                lowerJudge: "Севастьянова Наталия Юрьевна", anchorDate: appealDate)
            let found = try await resolver.resolve(anchorContext: context, anchorCard: anchor)
            XCTAssertEqual(found.result.cardURL, url)
            XCTAssertEqual(found.card.uid, card.uid)
            XCTAssertEqual(found.court.domain, "mos-gorsud.ru")
            XCTAssertEqual(found.cartoteka.id, "p1")
        }
        let aliases = await stub.requestedAliases
        XCTAssertEqual(aliases, ["mgs", "mgs"])
        let duplicateListing = CaseOriginResolver(
            client: SudrfClient(),
            moscowProvider: MoscowOriginStub(rows: [row, row], cards: [url: card]))
        let (context, anchor) = moscowAnchor(
            number: "66а-4311/2020", lowerNumber: "3а-3696/2020",
            lowerCourt: "Московский городской суд",
            lowerJudge: "Севастьянова Наталия Юрьевна", anchorDate: "10.09.2020")
        let deduplicated = try await duplicateListing.resolve(anchorContext: context,
                                                              anchorCard: anchor)
        XCTAssertEqual(deduplicated.result.cardURL, url)
    }

    func testIssue322ParsedOfficialCardsUseRealCrossPortalRoute() async throws {
        let firstRows = try MosGorSudResultsParser.parse(
            html: issue322Fixture("issue322_mgs_search_first"))
        let firstURL = try XCTUnwrap(firstRows.first?.cardURL)
        let firstCard = try MosGorSudCardParser.parse(
            html: issue322Fixture("issue322_mgs_first"))
        let firstProvider = MoscowOriginStub(rows: firstRows, cards: [firstURL: firstCard])
        let firstResolver = CaseOriginResolver(client: SudrfClient(),
                                               moscowProvider: firstProvider)
        for (fixture, number) in [("issue322_asoy_2013", "66а-2013/2020"),
                                  ("issue322_asoy_4311", "66а-4311/2020")] {
            let anchor = try CaseCardParser.parse(html: issue322Fixture(fixture))
            let (context, _) = moscowAnchor(
                number: number, lowerNumber: "3а-3696/2020",
                lowerCourt: "Московский городской суд",
                lowerJudge: "Севастьянова Наталия Юрьевна")
            let origin = try await firstResolver.resolve(anchorContext: context,
                                                         anchorCard: anchor)
            XCTAssertEqual(origin.result.cardURL, firstURL)
            XCTAssertEqual(origin.card.uid, "77OS0000-01-2020-002855-77")
        }

        let uidRows = try MosGorSudResultsParser.parse(
            html: issue322Fixture("issue322_mgs_search_uid"))
        let khamov = try MosGorSudCardParser.parse(
            html: issue322Fixture("issue322_mgs_hamov"))
        let khamovURL = try XCTUnwrap(uidRows.first(where: {
            $0.caseNumber == "02а-0419/2021"
        })?.cardURL)
        let provider = MoscowOriginStub(rows: uidRows, cards: [khamovURL: khamov])
        let resolver = CaseOriginResolver(client: SudrfClient(), moscowProvider: provider)
        let cassation = try CaseCardParser.parse(html: issue322Fixture("issue322_ksoyu_8501"))
        let (context, _) = moscowAnchor(
            number: "8а-7078/2022", lowerNumber: "2а-419/2021",
            lowerCourt: "Хамовнический районный суд", lowerJudge: "Бугынин Герман Геннадиевич",
            uid: "77RS0030-02-2021-008181-07", courtLevel: .cassation)
        let origin = try await resolver.resolve(anchorContext: context, anchorCard: cassation)
        XCTAssertEqual(origin.result.cardURL, khamovURL)
        XCTAssertEqual(origin.card.caseNumber, "02а-0419/2021")
    }

    func testIssue322CassationResolvesZeroPaddedKhamovnikiNumberByUID() async throws {
        let url = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/hamovnicheskij/services/cases/kas/details/1b274aa1-0cb0-11ec-a70f-232197c57890?uid=77RS0030-02-2021-008181-07"))
        let uid = "77RS0030-02-2021-008181-07"
        let row = MosGorSudResult(caseNumber: "02а-0419/2021", uid: uid,
                                  section: "kas", cardURL: url)
        let card = MosGorSudCard(uid: uid, caseNumber: "02а-0419/2021",
                                  judge: "Бугынин Г.Г.")
        let stub = MoscowOriginStub(rows: [row], cards: [url: card])
        let resolver = CaseOriginResolver(client: SudrfClient(), moscowProvider: stub)
        let (context, anchor) = moscowAnchor(
            number: "8а-7078/2022", lowerNumber: "2а-419/2021",
            lowerCourt: "Хамовнический районный суд", lowerDate: "09.09.2021",
            lowerJudge: "Бугынин Герман Геннадиевич", uid: uid,
            courtLevel: .cassation)
        let found = try await resolver.resolve(anchorContext: context, anchorCard: anchor)
        XCTAssertEqual(found.card.caseNumber, "02а-0419/2021")
        XCTAssertEqual(found.court.title, "Хамовнический районный суд")
        XCTAssertEqual(found.courtCode, "77RS0030")
        let aliases = await stub.requestedAliases
        XCTAssertEqual(aliases, ["hamovnicheskij"])
    }

    func testIssue322RejectsWrongYearHostUIDAndIncompleteCandidates() async throws {
        let good = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/49e1e932-ca18-4a54-9797-987d15209322"))
        let wrongHost = try XCTUnwrap(URL(string:
            "https://example.invalid/mgs/services/cases/first-admin/details/49e1e932-ca18-4a54-9797-987d15209322"))
        let (context, anchor) = moscowAnchor(
            number: "66а-4311/2020", lowerNumber: "3а-3696/2020",
            lowerCourt: "Московский городской суд",
            lowerJudge: "Севастьянова Наталия Юрьевна", anchorDate: "10.09.2020")
        let card = MosGorSudCard(uid: "77OS0000-01-2020-002855-77",
                                  caseNumber: "3а-3696/2020", judge: "Севастьянова Н.Ю.",
                                  sessions: [CaseSession(date: "26.06.2020", event: "Решение")])
        let wrongYear = MoscowOriginStub(
            rows: [MosGorSudResult(caseNumber: "3а-3696/2019", cardURL: good)],
            cards: [good: card])
        let wrongHostStub = MoscowOriginStub(
            rows: [MosGorSudResult(caseNumber: "3а-3696/2020", cardURL: wrongHost)],
            cards: [wrongHost: card])
        for stub in [wrongYear, wrongHostStub] {
            let resolver = CaseOriginResolver(client: SudrfClient(), moscowProvider: stub)
            do { _ = try await resolver.resolve(anchorContext: context, anchorCard: anchor)
                XCTFail("unverified Moscow card must not join")
            } catch let error as CaseOriginResolutionError {
                XCTAssertTrue(error == .notFound || error == .incompleteCandidates)
            }
        }
        let unreadable = MoscowOriginStub(
            rows: [MosGorSudResult(caseNumber: "3а-3696/2020", cardURL: good)],
            cards: [:], unreadable: [good])
        let resolver = CaseOriginResolver(client: SudrfClient(), moscowProvider: unreadable)
        do { _ = try await resolver.resolve(anchorContext: context, anchorCard: anchor)
            XCTFail("unreadable candidate must remain transient")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .incompleteCandidates)
        }
    }

    func testIssue322RejectsConflictingMoscowQueryAndAmbiguousCards() async throws {
        let good = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/49e1e932-ca18-4a54-9797-987d15209322?caseNumber=3%D0%B0-3696/2020"))
        let conflicting = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/49e1e932-ca18-4a54-9797-987d15209322?caseNumber=3%D0%B0-3696/2019"))
        let other = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/b8390500-58cc-11ec-b06c-31916f371c35"))
        let card = MosGorSudCard(uid: "77OS0000-01-2020-002855-77",
                                  caseNumber: "3а-3696/2020", judge: "Севастьянова Н.Ю.",
                                  rawText: "10.09.2020 Определение суда апелляционной инстанции")
        let (context, anchor) = moscowAnchor(
            number: "66а-4311/2020", lowerNumber: "3а-3696/2020",
            lowerCourt: "Московский городской суд",
            lowerJudge: "Севастьянова Наталия Юрьевна", anchorDate: "10.09.2020")
        let wrongQuery = MoscowOriginStub(
            rows: [MosGorSudResult(caseNumber: "3а-3696/2020", cardURL: conflicting)],
            cards: [conflicting: card])
        do {
            _ = try await CaseOriginResolver(client: SudrfClient(),
                                             moscowProvider: wrongQuery)
                .resolve(anchorContext: context, anchorCard: anchor)
            XCTFail("a contradictory published URL is not evidence")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
        let ambiguous = MoscowOriginStub(
            rows: [MosGorSudResult(caseNumber: "3а-3696/2020", cardURL: good),
                   MosGorSudResult(caseNumber: "3а-3696/2020", cardURL: other)],
            cards: [good: card, other: card])
        do {
            _ = try await CaseOriginResolver(client: SudrfClient(),
                                             moscowProvider: ambiguous)
                .resolve(anchorContext: context, anchorCard: anchor)
            XCTFail("two exact Moscow cards must remain ambiguous")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .ambiguous)
        }
    }

    private func anchor(uid: String?) -> (MovementContext, CaseCard) {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный Суд Республики Коми", courtLevelRaw: "subject",
            courtCode: "11", cartotekaId: "g2", cartotekaLevelRaw: "subject",
            caseNumber: "33-4818/2025")
        context.judicialUID = uid
        context.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue
        let card = CaseCard(rawText: "", actText: nil, uid: uid,
                            caseNumber: "33-4818/2025",
                            lowerCourt: LowerCourtReference(
                                region: "11 - Республика Коми",
                                courtTitle: "Сыктывкарский городской суд",
                                caseNumber: "2-7212/2025"))
        return (context, card)
    }

    private var courtOverride: OriginCourtResolution {
        OriginCourtResolution(
            court: Court(domain: "syktsud--komi.sudrf.ru",
                         title: "Сыктывкарский городской суд", level: .district),
            branch: .general, code: "11RS0001")
    }

    private func subjectPreliminary(
        number: String, cartotekaID: String = "p1", uid: String? = nil
    ) throws -> (MovementContext, CaseCard) {
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: cartotekaID))
        let url = try XCTUnwrap(URL(string:
            "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=anchor&case_uid=anchor-guid"
                + "&delo_id=\(cart.deloID)&new=\(cart.new)"))
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный Суд Республики Коми", courtLevelRaw: "subject",
            courtCode: "11", cartotekaId: cartotekaID,
            cartotekaLevelRaw: "subject", caseNumber: number,
            caseID: "anchor", caseUID: "anchor-guid", cardURLString: url.absoluteString)
        context.judicialUID = uid
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        return (context, CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: number))
    }

    private func subjectURL(cartotekaID: String, caseID: String,
                            srvNum: String = "1") throws -> URL {
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: cartotekaID))
        return try XCTUnwrap(URL(string:
            "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=\(srvNum)"
                + "&name_op=case&case_id=\(caseID)&case_uid=\(caseID)-guid"
                + "&delo_id=\(cart.deloID)&new=\(cart.new)"))
    }

    func testMissingUIDResolvesBySingleExactLowerNumber() async throws {
        let exact = CaseSearchResult(caseNumber: "2-7212/2025 ~ М-5922/2025",
                                     caseID: "exact", caseUID: "guid")
        let noise = CaseSearchResult(caseNumber: "2-721/2025",
                                     caseID: "noise", caseUID: "guid2")
        let provider = OriginProviderStub(
            numberRows: [noise, exact],
            cards: ["exact": CaseCard(rawText: "", actText: nil,
                                      caseNumber: exact.caseNumber)])
        let resolver = CaseOriginResolver(client: SudrfClient(),
                                          regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, card) = anchor(uid: nil)

        let result = try await resolver.resolve(anchorContext: context, anchorCard: card)
        let fields = await provider.fields

        XCTAssertEqual(result.result.caseID, "exact")
        XCTAssertEqual(result.cartoteka.id, "g1")
        XCTAssertEqual(result.region, "Республика Коми")
        XCTAssertEqual(fields, [.caseNumber])
    }

    func testIssue290SubjectAppealWithoutUIDResolvesExactDistrictMaterial() async throws {
        let lowerURL = try XCTUnwrap(URL(string:
            "https://oktibrsky--spb.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=892526215"
                + "&case_uid=7c9bc768-720c-4537-a3b3-6ab56e36fc5f&delo_id=1610001"))
        let lower = CaseSearchResult(
            caseNumber: "4-111/2019", caseID: "892526215",
            caseUID: "7c9bc768-720c-4537-a3b3-6ab56e36fc5f", cardURL: lowerURL)
        let lowerCard = CaseCard(
            rawText: "", actText: nil, caseNumber: lower.caseNumber,
            parties: CaseParties(plaintiffs: ["ООО «Инвестиционная компания „Пулковская“»"]))
        let provider = OriginProviderStub(numberRows: [lower],
                                          cards: ["892526215": lowerCard])
        let lowerCourt = OriginCourtResolution(
            court: Court(domain: "oktibrsky--spb.sudrf.ru",
                         title: "Октябрьский районный суд города Санкт-Петербурга",
                         level: .district),
            branch: .general, code: "78RS0016")
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: lowerCourt)
        var context = anchor(uid: nil).0
        context.region = "Город Санкт-Петербург"
        context.searchDomain = "sankt-peterburgsky--spb.sudrf.ru"
        context.displayDomain = "sankt-peterburgsky.spb.sudrf.ru"
        context.courtTitle = "Санкт-Петербургский городской суд"
        context.courtCode = "78OS0000"
        context.cartotekaId = "u2"
        context.caseNumber = "22-227/2020"
        let appealCard = CaseCard(
            rawText: "", actText: nil, caseNumber: "22-227/2020 (22-8976/2019;)",
            parties: CaseParties(defendants: ["Ефремов Алексей Кимович"]),
            lowerCourt: LowerCourtReference(courtTitle: "Октябрьский районный суд",
                                            caseNumber: lower.caseNumber))

        let result = try await resolver.resolve(anchorContext: context,
                                                anchorCard: appealCard)
        let fields = await provider.fields

        XCTAssertEqual(result.cartoteka.id, "m")
        XCTAssertEqual(result.result.caseNumber, lower.caseNumber)
        XCTAssertEqual(result.card.caseNumber, lower.caseNumber)
        XCTAssertEqual(result.card.parties.plaintiffs,
                       ["ООО «Инвестиционная компания „Пулковская“»"])
        XCTAssertEqual(fields, [.caseNumber])
    }

    func testMissingUIDRejectsExactRowWithContradictorySourceLocator() async throws {
        let rowURL = try XCTUnwrap(URL(string:
            "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                + "&name_op=case&case_id=exact&case_uid=guid&delo_id=1540006&new=0"))
        let exact = CaseSearchResult(caseNumber: "2-7212/2025", caseID: "exact",
                                     caseUID: "guid", cardURL: rowURL)
        let provider = OriginProviderStub(
            numberRows: [exact],
            cards: ["exact": CaseCard(rawText: "", actText: nil,
                                       caseNumber: exact.caseNumber)])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, card) = anchor(uid: nil)

        do {
            _ = try await resolver.resolve(anchorContext: context, anchorCard: card)
            XCTFail("строка другой картотеки не подтверждает точную нижнюю карточку")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testUnreadableExactNoUIDCandidateIsIncomplete() async throws {
        let exact = CaseSearchResult(caseNumber: "2-7212/2025",
                                     caseID: "unreadable", caseUID: "guid")
        let provider = OriginProviderStub(numberRows: [exact], cards: [:],
                                          unreadableCardIDs: ["unreadable"])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, card) = anchor(uid: nil)

        do {
            _ = try await resolver.resolve(anchorContext: context, anchorCard: card)
            XCTFail("непрочитанный точный кандидат не доказывает отсутствие связи")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .incompleteCandidates)
        }
    }

    func testPreliminaryNumberResolvesOnlySingleSameCartotekaMainCaseByExactUID() async throws {
        let main = CaseSearchResult(caseNumber: "2а-5090/2026 ~ М-2417/2026",
                                    caseID: "main", caseUID: "guid")
        let provider = OriginProviderStub(
            uidRows: [], numberRows: [],
            cards: ["main": CaseCard(rawText: "", actText: nil, uid: uid,
                                      caseNumber: main.caseNumber)],
            rowsByCartAndValue: ["p1|\(uid)": [main]])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        var (context, card) = anchor(uid: uid)
        context.searchDomain = "syktsud--komi.sudrf.ru"
        context.displayDomain = "syktsud.komi.sudrf.ru"
        context.courtTitle = "Сыктывкарский городской суд"
        context.courtLevelRaw = CourtLevel.district.rawValue
        context.cartotekaId = "p1"
        context.cartotekaLevelRaw = CourtLevel.district.rawValue
        context.caseNumber = "М-2417/2026"
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        card.caseNumber = context.caseNumber

        let result = try await resolver.resolveMainCase(anchorContext: context, anchorCard: card)

        XCTAssertEqual(result.result.caseNumber, main.caseNumber)
        XCTAssertEqual(result.cartoteka.id, "p1")
        XCTAssertEqual(result.court.title, context.courtTitle)
    }

    func testSubjectPreliminaryUsesCurrentCompositeNumberFromSameExactCardWithoutUID() async throws {
        let provider = OriginProviderStub(numberRows: [], cards: [:])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        let (context, original) = try subjectPreliminary(number: "М-662/2026")
        let current = CaseCard(rawText: "", actText: nil,
                               caseNumber: "3а-685/2026 ~ М-662/2026")

        let result = try await resolver.resolveMainCase(
            anchorContext: context, anchorCard: current)

        XCTAssertEqual(original.caseNumber, "М-662/2026")
        XCTAssertEqual(result.result.caseNumber, "3а-685/2026 ~ М-662/2026")
        XCTAssertEqual(result.card.caseNumber, "3а-685/2026 ~ М-662/2026")
        XCTAssertEqual(result.cartoteka.id, "p1")
        let fields = await provider.fields
        XCTAssertTrue(fields.isEmpty)
    }

    func testSubject9AUsesStandaloneCurrentNumberFromSameExactCard() async throws {
        let provider = OriginProviderStub(numberRows: [], cards: [:])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        let (context, _) = try subjectPreliminary(number: "9а-118/2026")
        let current = CaseCard(rawText: "", actText: nil, caseNumber: "3а-151/2026")

        let result = try await resolver.resolveMainCase(
            anchorContext: context, anchorCard: current)

        XCTAssertEqual(result.cartoteka.id, "p1")
        XCTAssertEqual(result.result.caseNumber, "3а-151/2026")
        let fields = await provider.fields
        XCTAssertTrue(fields.isEmpty)
    }

    func testSameCardCurrentNumberRequiresCompletePublishedHeading() async throws {
        let provider = OriginProviderStub(numberRows: [], cards: [:])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        let (context, _) = try subjectPreliminary(number: "М-662/2026")
        let malformed = CaseCard(rawText: "", actText: nil,
                                 caseNumber: "3а-685/2026 решение ~ М-662/2026")

        do {
            _ = try await resolver.resolveMainCase(anchorContext: context, anchorCard: malformed)
            XCTFail("Посторонний текст не является опубликованным номером")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .noReference)
        }
    }

    func testSameCardCurrentNumberRequiresExactAnchorSource() async throws {
        let provider = OriginProviderStub(numberRows: [], cards: [:])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        var (context, _) = try subjectPreliminary(number: "М-662/2026")
        context.caseID = nil
        context.caseUID = nil
        context.cardURLString = nil
        let current = CaseCard(rawText: "", actText: nil,
                               caseNumber: "3а-685/2026 ~ М-662/2026")

        do {
            _ = try await resolver.resolveMainCase(anchorContext: context, anchorCard: current)
            XCTFail("Новый заголовок без идентичности карточки не доказывает связь")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .noReference)
        }
    }

    func testSameCardDoesNotSwitchCartotekaInferredOnlyFromNewHeading() async throws {
        let provider = OriginProviderStub(numberRows: [], cards: [:])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        let (context, _) = try subjectPreliminary(
            number: "М-662/2026", cartotekaID: "g1")
        let current = CaseCard(rawText: "", actText: nil,
                               caseNumber: "3а-685/2026 ~ М-662/2026")

        do {
            _ = try await resolver.resolveMainCase(anchorContext: context, anchorCard: current)
            XCTFail("Адрес g1 не доказывает, что карточка принадлежит p1")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .noReference)
        }
    }

    func testSameCardRejectsMalformedKnownJudicialUID() async throws {
        let provider = OriginProviderStub(numberRows: [], cards: [:])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        let (context, _) = try subjectPreliminary(number: "М-662/2026", uid: "not-a-uid")
        let current = CaseCard(rawText: "", actText: nil, uid: "not-a-uid",
                               caseNumber: "3а-685/2026 ~ М-662/2026")

        do {
            _ = try await resolver.resolveMainCase(anchorContext: context, anchorCard: current)
            XCTFail("Невалидное значение УИД нельзя игнорировать")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .noReference)
        }
    }

    func testSubjectMFindsUniqueKASRegistrationAcrossPairedCartotekas() async throws {
        let currentURL = try subjectURL(cartotekaID: "p1", caseID: "current")
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let row = CaseSearchResult(caseNumber: "3а-685/2026", caseID: "current",
                                   caseUID: "current-guid", cardURL: currentURL)
        let previous = PreviousRegistrationReference(
            caseNumber: context.caseNumber, url: try XCTUnwrap(context.baseResult.cardURL))
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["current": CaseCard(rawText: "", actText: nil, uid: uid,
                                        caseNumber: "3а-685/2026",
                                        previousRegistration: previous)],
            rowsByCartAndValue: ["p1|\(uid)": [row], "g1|\(uid)": []])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        let result = try await resolver.resolveMainCase(
            anchorContext: context, anchorCard: anchorCard)

        XCTAssertEqual(result.cartoteka.id, "p1")
        XCTAssertEqual(result.result.caseID, "current")
        let fields = await provider.fields
        XCTAssertEqual(fields, [.uid, .uid])
    }

    func testFallbackRejectsContradictoryPreviousRegistrationSource() async throws {
        let currentURL = try subjectURL(cartotekaID: "p1", caseID: "current")
        let wrongPreviousURL = try subjectURL(cartotekaID: "p1", caseID: "other")
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let row = CaseSearchResult(caseNumber: "3а-685/2026", caseID: "current",
                                   caseUID: "current-guid", cardURL: currentURL)
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["current": CaseCard(
                rawText: "", actText: nil, uid: uid, caseNumber: row.caseNumber,
                previousRegistration: PreviousRegistrationReference(
                    caseNumber: context.caseNumber, url: wrongPreviousURL))],
            rowsByCartAndValue: ["p1|\(uid)": [row], "g1|\(uid)": []])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("Ссылка на другую предыдущую карточку противоречит якорю")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testSubjectMDoesNotPromoteCivilCurrentRegistration() async throws {
        let currentURL = try subjectURL(cartotekaID: "g1", caseID: "civil")
        let (context, anchorCard) = try subjectPreliminary(
            number: "М-662/2026", cartotekaID: "g1", uid: uid)
        let row = CaseSearchResult(caseNumber: "3-91/2026", caseID: "civil",
                                   caseUID: "civil-guid", cardURL: currentURL)
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["civil": CaseCard(rawText: "", actText: nil, uid: uid,
                                      caseNumber: row.caseNumber)],
            rowsByCartAndValue: ["g1|\(uid)": [row], "p1|\(uid)": []])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("Гражданское дело суда субъекта относится к отдельному объёму #246")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testDistrict9ToCivil2PromotionRemainsSupported() async throws {
        let current = CaseSearchResult(caseNumber: "2-7212/2025",
                                       caseID: "current", caseUID: "current-guid")
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["current": CaseCard(rawText: "", actText: nil, uid: uid,
                                        caseNumber: current.caseNumber)],
            rowsByCartAndValue: ["g1|\(uid)": [current], "p1|\(uid)": []])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        var (context, card) = anchor(uid: uid)
        context.searchDomain = "syktsud--komi.sudrf.ru"
        context.displayDomain = "syktsud.komi.sudrf.ru"
        context.courtTitle = "Сыктывкарский городской суд"
        context.courtLevelRaw = CourtLevel.district.rawValue
        context.cartotekaId = "g1"
        context.cartotekaLevelRaw = CourtLevel.district.rawValue
        context.caseNumber = "9-1693/2025"
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        card.caseNumber = context.caseNumber

        let result = try await resolver.resolveMainCase(
            anchorContext: context, anchorCard: card)

        XCTAssertEqual(result.cartoteka.id, "g1")
        XCTAssertEqual(result.result.caseNumber, "2-7212/2025")
    }

    func testSubject9ADoesNotPromoteCivilRegistration() async throws {
        let civilURL = try subjectURL(cartotekaID: "g1", caseID: "civil")
        let (context, anchorCard) = try subjectPreliminary(number: "9а-118/2026", uid: uid)
        let row = CaseSearchResult(caseNumber: "3-91/2026", caseID: "civil",
                                   caseUID: "civil-guid", cardURL: civilURL)
        let provider = OriginProviderStub(
            numberRows: [], cards: [:],
            rowsByCartAndValue: ["p1|\(uid)": [], "g1|\(uid)": [row]])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("9а не доказывает связь с гражданским делом")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testPairedUIDSearchRejectsActualCartotekaMismatch() async throws {
        let kasURL = try subjectURL(cartotekaID: "p1", caseID: "current")
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let row = CaseSearchResult(caseNumber: "3а-685/2026", caseID: "current",
                                   caseUID: "current-guid", cardURL: kasURL)
        let provider = OriginProviderStub(
            numberRows: [], cards: [:],
            rowsByCartAndValue: ["p1|\(uid)": [], "g1|\(uid)": [row]])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("Строка p1, возвращённая поиском g1, не точна")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testPairedUIDSearchRejectsDifferentDatabaseInstance() async throws {
        let wrongSRVURL = try subjectURL(
            cartotekaID: "p1", caseID: "current", srvNum: "2")
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let row = CaseSearchResult(caseNumber: "3а-685/2026", caseID: "current",
                                   caseUID: "current-guid", cardURL: wrongSRVURL)
        let provider = OriginProviderStub(
            numberRows: [], cards: [:],
            rowsByCartAndValue: ["p1|\(uid)": [row], "g1|\(uid)": []])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("Другой srv_num не является той же базой суда")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .incompleteCandidates)
        }
    }

    func testPairedUIDSearchDoesNotAcceptPartialResult() async throws {
        let kasURL = try subjectURL(cartotekaID: "p1", caseID: "current")
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let row = CaseSearchResult(caseNumber: "3а-685/2026", caseID: "current",
                                   caseUID: "current-guid", cardURL: kasURL)
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["current": CaseCard(rawText: "", actText: nil, uid: uid,
                                        caseNumber: row.caseNumber)],
            rowsByCartAndValue: ["p1|\(uid)": [row]], transientUIDCartID: "g1")
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("Неполный парный поиск не доказывает единственность")
        } catch let error as SudrfError {
            guard case .transientNetworkError = error else {
                return XCTFail("Неожиданная ошибка: \(error)")
            }
        }
    }

    func testUnreadableEligibleCardDoesNotMakeAnotherCandidateUnique() async throws {
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let readable = CaseSearchResult(
            caseNumber: "3а-685/2026", caseID: "readable", caseUID: "readable-guid",
            cardURL: try subjectURL(cartotekaID: "p1", caseID: "readable"))
        let unreadable = CaseSearchResult(
            caseNumber: "3а-686/2026", caseID: "unreadable", caseUID: "unreadable-guid",
            cardURL: try subjectURL(cartotekaID: "p1", caseID: "unreadable"))
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["readable": CaseCard(rawText: "", actText: nil, uid: uid,
                                         caseNumber: readable.caseNumber)],
            rowsByCartAndValue: ["p1|\(uid)": [readable, unreadable], "g1|\(uid)": []],
            unreadableCardIDs: ["unreadable"])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("Непрочитанный кандидат не даёт доказать единственность")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .incompleteCandidates)
        }
    }

    func testPairedUIDSearchPropagatesCancellation() async throws {
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let provider = OriginProviderStub(
            numberRows: [], cards: [:],
            rowsByCartAndValue: ["p1|\(uid)": []], cancelUIDCartID: "g1")
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        do {
            _ = try await resolver.resolveMainCase(
                anchorContext: context, anchorCard: anchorCard)
            XCTFail("Отмена не должна превращаться в пустой результат")
        } catch is CancellationError {
            // expected
        }
    }

    func testSubjectMIgnoresCivilCandidateWhenKASRegistrationIsUnique() async throws {
        let (context, anchorCard) = try subjectPreliminary(number: "М-662/2026", uid: uid)
        let kas = CaseSearchResult(
            caseNumber: "3а-685/2026", caseID: "kas", caseUID: "kas-guid",
            cardURL: try subjectURL(cartotekaID: "p1", caseID: "kas"))
        let civil = CaseSearchResult(
            caseNumber: "3-91/2026", caseID: "civil", caseUID: "civil-guid",
            cardURL: try subjectURL(cartotekaID: "g1", caseID: "civil"))
        let provider = OriginProviderStub(
            numberRows: [],
            cards: [
                "kas": CaseCard(rawText: "", actText: nil, uid: uid,
                                caseNumber: kas.caseNumber),
                "civil": CaseCard(rawText: "", actText: nil, uid: uid,
                                  caseNumber: civil.caseNumber),
            ],
            rowsByCartAndValue: ["p1|\(uid)": [kas], "g1|\(uid)": [civil]])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        let result = try await resolver.resolveMainCase(
            anchorContext: context, anchorCard: anchorCard)

        XCTAssertEqual(result.cartoteka.id, "p1")
        XCTAssertEqual(result.result.caseID, "kas")
    }

    func testPreliminaryNumberRejectsMainCardWithDifferentUID() async throws {
        let main = CaseSearchResult(caseNumber: "2а-5090/2026", caseID: "main", caseUID: "guid")
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["main": CaseCard(rawText: "", actText: nil, uid: "47RS0005-other",
                                      caseNumber: main.caseNumber)],
            rowsByCartAndValue: ["p1|\(uid)": [main]])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        var (context, card) = anchor(uid: uid)
        context.searchDomain = "syktsud--komi.sudrf.ru"
        context.displayDomain = "syktsud.komi.sudrf.ru"
        context.courtLevelRaw = CourtLevel.district.rawValue
        context.cartotekaId = "p1"
        context.cartotekaLevelRaw = CourtLevel.district.rawValue
        context.caseNumber = "М-2417/2026"
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        card.caseNumber = context.caseNumber

        do {
            _ = try await resolver.resolveMainCase(anchorContext: context, anchorCard: card)
            XCTFail("Карточка с другим УИД не должна переякоривать дело")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testPreliminaryMagistrateCaseDoesNotAttemptUnsupportedUIDSearch() async throws {
        let regularProvider = OriginProviderStub(numberRows: [], cards: [:])
        let magistrateProvider = OriginProviderStub(numberRows: [], cards: [:])
        let resolver = CaseOriginResolver(
            client: SudrfClient(), regularProvider: regularProvider,
            magistrateProvider: magistrateProvider)
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "11ms0062.msudrf.ru", displayDomain: "11ms0062.msudrf.ru",
            courtTitle: "Судебный участок № 62", courtLevelRaw: "magistrate",
            courtCode: "11MS0062", cartotekaId: "g1",
            cartotekaLevelRaw: "magistrate", caseNumber: "М-100/2026")
        context.judicialUID = "11MS0062-01-2026-000100-10"
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        let card = CaseCard(rawText: "", actText: nil, uid: context.judicialUID,
                            caseNumber: context.caseNumber)

        do {
            _ = try await resolver.resolveMainCase(anchorContext: context, anchorCard: card)
            XCTFail("Мировой суд не должен получать неподдерживаемый UID-поиск")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .noReference)
        }
        let regularFields = await regularProvider.fields
        let magistrateFields = await magistrateProvider.fields
        XCTAssertTrue(regularFields.isEmpty)
        XCTAssertTrue(magistrateFields.isEmpty)
    }

    func testUIDRowsWithDifferentNumberFallBackToExactNumberSearch() async throws {
        let noise = CaseSearchResult(caseNumber: "2-999/2026",
                                     caseID: "noise", caseUID: "noise-guid")
        let exact = CaseSearchResult(caseNumber: "13-98/2026",
                                     caseID: "exact", caseUID: "exact-guid")
        let provider = OriginProviderStub(
            uidRows: [noise], numberRows: [exact],
            cards: ["exact": CaseCard(rawText: "", actText: nil, uid: uid,
                                       caseNumber: exact.caseNumber)])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        var (context, card) = anchor(uid: uid)
        context.caseNumber = "33-14101/2026"
        card.caseNumber = context.caseNumber
        card.lowerCourt = LowerCourtReference(
            region: "Город Санкт-Петербург",
            courtTitle: "Василеостровский районный суд",
            caseNumber: exact.caseNumber)

        let result = try await resolver.resolve(anchorContext: context, anchorCard: card)
        let fields = await provider.fields

        XCTAssertEqual(result.result.caseNumber, exact.caseNumber)
        XCTAssertEqual(fields, [.uid, .caseNumber, .uid])
    }

    func testTwoExactCardsAreAmbiguous() async throws {
        let a = CaseSearchResult(caseNumber: "2-7212/2025", caseID: "a", caseUID: "ga")
        let b = CaseSearchResult(caseNumber: "2-7212/2025", caseID: "b", caseUID: "gb")
        let card = CaseCard(rawText: "", actText: nil, caseNumber: "2-7212/2025")
        let provider = OriginProviderStub(numberRows: [a, b], cards: ["a": card, "b": card])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, anchorCard) = anchor(uid: nil)

        do {
            _ = try await resolver.resolve(anchorContext: context, anchorCard: anchorCard)
            XCTFail("ambiguous rows must not be accepted")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .ambiguous)
        }
    }

    func testTransientUIDSearchIsNotDowngradedToNotFound() async throws {
        let provider = OriginProviderStub(numberRows: [], cards: [:],
                                          throwTransientOnUID: true)
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, card) = anchor(uid: uid)

        do {
            _ = try await resolver.resolve(anchorContext: context, anchorCard: card)
            XCTFail("transient error must propagate")
        } catch let error as SudrfError {
            guard case .transientNetworkError = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUIDSearchCaptchaIsPropagatedForRetry() async throws {
        let formURL = URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo")!
        let provider = OriginProviderStub(numberRows: [], cards: [:],
                                          captchaOnUIDURL: formURL)
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, card) = anchor(uid: uid)

        do {
            _ = try await resolver.resolve(anchorContext: context, anchorCard: card)
            XCTFail("captcha must be returned to the repair coordinator")
        } catch let error as SudrfError {
            guard case .captchaRequired(let receivedURL) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(receivedURL, formURL)
        }
    }

    func testExactCardFetchCaptchaIsPropagatedForRetry() async throws {
        let formURL = URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo")!
        let exact = CaseSearchResult(caseNumber: "2-7212/2025",
                                     caseID: "exact", caseUID: "guid")
        let provider = OriginProviderStub(uidRows: [exact], numberRows: [], cards: [:],
                                          captchaOnCardURL: formURL)
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, card) = anchor(uid: uid)

        do {
            _ = try await resolver.resolve(anchorContext: context, anchorCard: card)
            XCTFail("card captcha must be returned to the repair coordinator")
        } catch let error as SudrfError {
            guard case .captchaRequired(let receivedURL) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(receivedURL, formURL)
        }
    }

    func testExpectedUIDRejectsExactNumberCardWithoutPublishedUID() async throws {
        let exact = CaseSearchResult(caseNumber: "2-7212/2025",
                                     caseID: "exact", caseUID: "guid")
        let provider = OriginProviderStub(
            uidRows: [exact], numberRows: [],
            cards: ["exact": CaseCard(rawText: "", actText: nil,
                                       caseNumber: exact.caseNumber)])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        let (context, card) = anchor(uid: uid)

        do {
            _ = try await resolver.resolve(anchorContext: context, anchorCard: card)
            XCTFail("a number-only card must not satisfy an expected exact UID")
        } catch let error as CaseOriginResolutionError {
            XCTAssertEqual(error, .notFound)
        }
    }

    /// Районный admj ведёт вниз в adm только при подтверждённом мировом судье.
    /// Для RS-ветки сам admj является первым судебным якорем.
    func testFirstCartotekaForAdmjAnchor() throws {
        let magistrate = try CaseOriginResolver.firstCartoteka(
            anchorID: "admj", lowerNumber: "5-100/2025", level: .magistrate)
        XCTAssertEqual(magistrate.id, "adm")

        XCTAssertThrowsError(try CaseOriginResolver.firstCartoteka(
            anchorID: "admj", lowerNumber: "5-100/2025", level: .district))
    }

    func testSubjectKoAPCartotekasResolveToTheirExactDistrictOrigins() throws {
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "adm1", lowerNumber: "12-999/2025", level: .district).id, "adm")
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "adm2", lowerNumber: "5-999/2025", level: .district).id, "admj")
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "adm33", lowerNumber: "12-10/2018", level: .district).id, "admj")
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "adm33", lowerNumber: "5-10/2026", level: .magistrate).id, "adm")
    }

    func testLowerNumberChoosesActualMaterialAndAppealCartotekas() throws {
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "g2", lowerNumber: "13-14/2026", level: .district).id, "m")
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "u2", lowerNumber: "4-111/2019", level: .district).id, "m")
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "u3", lowerNumber: "22К-7/2026", level: .subject).id, "u2")
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "g3", lowerNumber: "33-7/2026", level: .subject).id, "g2")
        XCTAssertEqual(try CaseOriginResolver.firstCartoteka(
            anchorID: "g3", lowerNumber: "11-7/2026", level: .district).id, "g2")
    }

    func testCourtTitleMatchesOnlyRegionalSuffix() {
        XCTAssertTrue(CaseOriginResolver.sameCourtTitle(
            "Фрунзенский районный суд Санкт-Петербурга",
            "Фрунзенский районный суд города Санкт-Петербурга",
            region: "Город Санкт-Петербург"))
        XCTAssertTrue(CaseOriginResolver.sameCourtTitle(
            "Сыктывкарский городской суд Республики Коми",
            "Сыктывкарский городской суд",
            region: "Республика Коми"))
        XCTAssertTrue(CaseOriginResolver.sameCourtTitle(
            "Василеостровский районный суд",
            "Василеостровский районный суд",
            region: "Город Санкт-Петербург"))
        XCTAssertTrue(CaseOriginResolver.sameCourtTitle(
            "Условный районный суд Московской области",
            "Условный районный суд",
            region: "Московская область"))
        XCTAssertTrue(CaseOriginResolver.sameCourtTitle(
            "Условный районный суд города Санкт-Петербурга",
            "Условный районный суд",
            region: "Город Санкт-Петербург"))
        XCTAssertFalse(CaseOriginResolver.sameCourtTitle(
            "Судебный участок № 10",
            "Судебный участок № 1",
            region: "Республика Коми"))
        XCTAssertFalse(CaseOriginResolver.sameCourtTitle(
            "Сыктывдинский районный суд Республики Коми",
            "Сыктывкарский городской суд",
            region: "Республика Коми"))
        XCTAssertFalse(CaseOriginResolver.sameCourtTitle(
            "Фрунзенский районный суд Санкт-Петербурга",
            "Московский районный суд города Санкт-Петербурга",
            region: "Город Санкт-Петербург"))
        XCTAssertFalse(CaseOriginResolver.sameCourtTitle(
            "Фрунзенский районный суд Санкт-Петербурга",
            "Фрунзенский районный суд города Саратова",
            region: "Город Санкт-Петербург"))
    }

    func test22KToStandaloneJudicialControlMaterialKeepsMaterialOrigin() async throws {
        let material = CaseSearchResult(caseNumber: "3/12-4/2026", caseID: "m", caseUID: "gm")
        let provider = OriginProviderStub(uidRows: [material], numberRows: [],
            cards: ["m": CaseCard(rawText: "", actText: nil, uid: uid,
                                  caseNumber: material.caseNumber)])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        var context = anchor(uid: uid).0
        context.cartotekaId = "u2"; context.caseNumber = "22К-1/2026"
        context.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue
        let card = CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: context.caseNumber,
                            lowerCourt: LowerCourtReference(courtTitle: courtOverride.court.title,
                                                            caseNumber: material.caseNumber))
        let origin = try await resolver.resolve(anchorContext: context, anchorCard: card)
        XCTAssertEqual(origin.cartoteka.id, "m")
        XCTAssertTrue(origin.intermediateCards.isEmpty)
    }

    func test33To13UsesVerifiedUIDParentAndRetainsMaterialIntermediate() async throws {
        let material = CaseSearchResult(caseNumber: "13-4/2026", caseID: "m", caseUID: "gm")
        let parent = CaseSearchResult(caseNumber: "2-7/2025", caseID: "p", caseUID: "gp")
        let provider = OriginProviderStub(uidRows: [material], numberRows: [],
            cards: ["m": CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: material.caseNumber,
                                  lowerCourt: nil),
                    "p": CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: parent.caseNumber)],
            rowsByCartAndValue: ["m|\(uid)": [material], "g1|\(uid)": [parent]])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider,
                                          courtOverride: courtOverride)
        var context = anchor(uid: uid).0
        context.cartotekaId = "g2"; context.caseNumber = "33-1/2026"
        let card = CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: context.caseNumber,
                            lowerCourt: LowerCourtReference(courtTitle: courtOverride.court.title,
                                                            caseNumber: material.caseNumber))
        let origin = try await resolver.resolve(anchorContext: context, anchorCard: card)
        XCTAssertEqual(origin.cartoteka.id, "g1")
        XCTAssertEqual(origin.card.caseNumber, parent.caseNumber)
        XCTAssertEqual(origin.intermediateCards.map(\.card.caseNumber), [material.caseNumber])
    }

    func testSaved13MaterialRestoresParentDirectlyByExactUID() async throws {
        let parent = CaseSearchResult(caseNumber: "2-2384/2024", caseID: "p", caseUID: "gp")
        let provider = OriginProviderStub(
            numberRows: [],
            cards: ["p": CaseCard(rawText: "", actText: nil, uid: uid,
                                   caseNumber: parent.caseNumber)],
            rowsByCartAndValue: ["g1|\(uid)": [parent]])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: "district",
            courtCode: "11RS0001", cartotekaId: "m", cartotekaLevelRaw: "district",
            caseNumber: "13-128/2025", caseID: "m", caseUID: "gm")
        context.judicialUID = uid
        context.baseInstanceLevelRaw = CaseInstance.Level.material.rawValue
        let material = CaseCard(rawText: "", actText: nil, uid: uid,
                                caseNumber: context.caseNumber)

        let origin = try await resolver.resolve(anchorContext: context, anchorCard: material)

        XCTAssertEqual(origin.cartoteka.id, "g1")
        XCTAssertEqual(origin.card.caseNumber, parent.caseNumber)
        XCTAssertEqual(origin.intermediateCards.map(\.card.caseNumber), [context.caseNumber])
    }

    func testHistoricalAdm33RSRequiresPreOctober2019Evidence() {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный Суд Республики Коми", courtLevelRaw: "subject",
            courtCode: "11", cartotekaId: "adm33", cartotekaLevelRaw: "subject",
            caseNumber: "4а-10/2026")
        context.judicialUID = "11RS0001-01-2026-000010-10"
        let modern = CaseCard(rawText: "", actText: nil, uid: context.judicialUID,
                              caseNumber: context.caseNumber, receiptDate: "11.05.2026")
        XCTAssertFalse(CaseOriginResolver.isHistoricalSubjectReview(
            context: context, card: modern))

        context.caseNumber = "4а-10/2019"
        let historical = CaseCard(rawText: "", actText: nil, uid: context.judicialUID,
                                  caseNumber: context.caseNumber, receiptDate: "30.09.2019")
        XCTAssertTrue(CaseOriginResolver.isHistoricalSubjectReview(
            context: context, card: historical))
    }

    func testMSAdmjResolvesToMagistrateAdm() async throws {
        let lower = CaseSearchResult(caseNumber: "5-100/2025", caseID: "m", caseUID: "g")
        let lowerCard = CaseCard(rawText: "", actText: nil,
                                 uid: "11MS0062-01-2025-000100-10",
                                 caseNumber: "5-100/2025")
        let provider = OriginProviderStub(numberRows: [lower], cards: ["m": lowerCard])
        let resolver = CaseOriginResolver(
            client: SudrfClient(), magistrateProvider: provider,
            courtOverride: OriginCourtResolution(
                court: Court(domain: "62.komi.msudrf.ru", title: "Судебный участок № 62",
                             level: .magistrate),
                branch: .general, code: "11MS0062"))
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: "district",
            courtCode: "11", cartotekaId: "admj", cartotekaLevelRaw: "district",
            caseNumber: "12-10/2025")
        context.judicialUID = "11MS0062-01-2025-000100-10"
        context.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue
        let anchor = CaseCard(
            rawText: "", actText: nil, uid: context.judicialUID,
            caseNumber: context.caseNumber,
            lowerCourt: LowerCourtReference(
                region: "11 - Республика Коми", courtTitle: "Судебный участок № 62",
                caseNumber: "5-100/2025"))

        let origin = try await resolver.resolve(anchorContext: context, anchorCard: anchor)

        XCTAssertEqual(origin.court.level, .magistrate)
        XCTAssertEqual(origin.cartoteka.id, "adm")
    }
}
