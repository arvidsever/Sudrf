import XCTest
import SudrfKit
@testable import SudrfApp

private actor OriginProviderStub: CaseProviding {
    var uidRows: [CaseSearchResult]
    var numberRows: [CaseSearchResult]
    var cards: [String: CaseCard]
    var throwTransientOnUID: Bool
    private(set) var fields: [SearchField] = []

    init(uidRows: [CaseSearchResult] = [], numberRows: [CaseSearchResult],
         cards: [String: CaseCard], throwTransientOnUID: Bool = false) {
        self.uidRows = uidRows; self.numberRows = numberRows
        self.cards = cards; self.throwTransientOnUID = throwTransientOnUID
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        fields.append(field)
        if field == .uid, throwTransientOnUID {
            throw SudrfError.transientNetworkError(domain: court.domain,
                                                    code: .timedOut, attempt: 3)
        }
        return field == .uid ? uidRows : numberRows
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        guard let card = cards[caseID] else { throw SudrfError.http(status: 404) }
        return card
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
}

final class CaseOriginResolverTests: XCTestCase {
    private let uid = "11RS0001-01-2025-011255-03"

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
