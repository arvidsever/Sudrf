import XCTest
@testable import SudrfKit

final class MovementCoverageTests: XCTestCase {
    func testNativeLocatorsKeepCourtAndRegisterScope() throws {
        let districtCart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let sudrfURL = try SudrfURLBuilder(court: Court(
            domain: "syktsud--komi.sudrf.ru", title: "Сыктывкарский городской суд",
            level: .district)).cardURL(caseID: "card-42", caseUID: "link-guid",
                                     deloID: districtCart.deloID, new: districtCart.new)

        XCTAssertEqual(SourceNativeCardLocator.sudrf(url: sudrfURL, cartoteka: districtCart)?.identity,
                       SourceNativeCardIdentity(sourceFamily: "sudrf",
                                                courtKey: "syktsud--komi.sudrf.ru",
                                                cartotekaKey: "g1", sourceNativeID: "card-42"))

        let firstURL = URL(string:
            "https://mos-gorsud.ru/rs/tverskoj/services/cases/civil/details/11111111-1111-4111-8111-111111111111")!
        let secondURL = URL(string:
            "https://mos-gorsud.ru/rs/basmannyj/services/cases/civil/details/22222222-2222-4222-8222-222222222222")!
        let first = try XCTUnwrap(SourceNativeCardLocator.mosgorsud(
            url: firstURL, cartoteka: districtCart)?.identity)
        let second = try XCTUnwrap(SourceNativeCardLocator.mosgorsud(
            url: secondURL, cartoteka: districtCart)?.identity)
        XCTAssertEqual(first.courtKey, "tverskoj")
        XCTAssertEqual(second.courtKey, "basmannyj")
        XCTAssertNotEqual(first, second)

        let vsrf = try XCTUnwrap(SourceNativeCardLocator.vsrf(url: URL(string:
            "https://www.vsrf.ru/lk/practice/claims/12-36321243")!))
        XCTAssertEqual(vsrf.identity,
                       SourceNativeCardIdentity(sourceFamily: "vsrf", courtKey: "vsrf.ru",
                                                cartotekaKey: "claims",
                                                sourceNativeID: "12-36321243"))
    }

    func testCoverageIsPositivePerCourtAndPartialCannotBeClearedByRescue() throws {
        let loaded = try XCTUnwrap(SourceNativeCardLocator(
            sourceFamily: "mosgorsud", courtKey: "tverskoj",
            cartotekaKey: "g1", sourceNativeID: "card-1"))
        var coverage = MovementCoverageAccumulator()
        coverage.markPartial(sourceFamily: "mosgorsud", courtKey: "tverskoj")
        coverage.recordLoaded(loaded)
        coverage.mark(.honestZero, sourceFamily: "mosgorsud", courtKey: "basmannyj")

        let tverskoy = try XCTUnwrap(coverage.values.first { $0.courtKey == "tverskoj" })
        XCTAssertEqual(tverskoy.kind, .partial)
        XCTAssertEqual(tverskoy.loadedCardIdentities, [loaded.identity])
        XCTAssertFalse(tverskoy.isFull)

        let basmanny = try XCTUnwrap(coverage.values.first { $0.courtKey == "basmannyj" })
        XCTAssertEqual(basmanny.kind, .honestZero)
        XCTAssertTrue(basmanny.loadedCardIdentities.isEmpty)
    }

    func testMovementCoverageRoundTripsAndMissingCoverageRemainsUnknown() throws {
        let identity = SourceNativeCardIdentity(sourceFamily: "sudrf", courtKey: "court.test",
                                               cartotekaKey: "g1", sourceNativeID: "card-1")
        let movement = CaseMovement(
            uid: "uid", caseNumber: "2-1/2026", inForce: false, instances: [],
            complaints: [:], acts: [],
            sourceRefreshCoverage: [MovementCourtCoverage(
                sourceFamily: "sudrf", courtKey: "court.test", kind: .usableSnapshot,
                loadedCardIdentities: [identity])])
        let encoded = try JSONEncoder().encode(movement)
        let decoded = try JSONDecoder().decode(CaseMovement.self, from: encoded)
        XCTAssertEqual(decoded.sourceRefreshCoverage, movement.sourceRefreshCoverage)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded)
                                         as? [String: Any])
        legacyObject.removeValue(forKey: "sourceRefreshCoverage")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(CaseMovement.self, from: legacyData)
        XCTAssertNil(legacy.sourceRefreshCoverage)
    }
}
