import Foundation
import XCTest
@testable import SudrfKit

final class SourceOutcomeTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testSearchPageKindsMapToTypedOutcomes() {
        XCTAssertEqual(SearchPageKind.results.sourceOutcomeKind, .usableSnapshot)
        XCTAssertEqual(SearchPageKind.empty.sourceOutcomeKind, .honestZero)
        XCTAssertEqual(SearchPageKind.captcha.sourceOutcomeKind, .captcha)
        XCTAssertEqual(SearchPageKind.captchaRejected.sourceOutcomeKind, .captcha)
        XCTAssertEqual(SearchPageKind.maintenance.sourceOutcomeKind, .maintenance)
        XCTAssertEqual(SearchPageKind.unrecognized.sourceOutcomeKind, .parserFailure)
    }

    func testMovementWithIncompleteCourtIsPartial() {
        let movement = CaseMovement(
            uid: "uid", caseNumber: "2-1/2026", inForce: false,
            instances: [], complaints: [:], acts: [],
            incompleteHigherCourtDomains: ["3kas.sudrf.ru"])

        let attempt = SourceOutcomeClassifier.attempt(
            for: movement, sourceFamily: "sudrf", host: "court--komi.sudrf.ru",
            observedAt: observedAt)

        XCTAssertEqual(attempt.kind, .partial)
        XCTAssertEqual(attempt.provenance.operation, .movement)
        XCTAssertEqual(attempt.provenance.affectedSources, ["3kas.sudrf.ru"])
    }

    func testMovementWithHonestZeroSourceIsPartialAndDiagnostic() {
        let movement = CaseMovement(
            uid: "uid", caseNumber: "2-1/2026", inForce: false,
            instances: [], complaints: [:], acts: [],
            honestZeroDomains: ["https://vs--komi.sudrf.ru/path?token=secret"])

        let attempt = SourceOutcomeClassifier.attempt(
            for: movement, sourceFamily: "sudrf", host: "court--komi.sudrf.ru",
            observedAt: observedAt)

        XCTAssertEqual(attempt.kind, .partial)
        XCTAssertEqual(attempt.provenance.affectedSources, ["vs--komi.sudrf.ru"])
    }

    func testCaseProvidingSearchBoundaryProducesHonestZero() async throws {
        let court = Court(domain: "court.test", title: "Суд", level: .district)
        let cart = Cartoteka(id: "g1", title: "Гражданское", prefixes: ["2"],
                             deloID: "1", deloTable: "g1_case",
                             caseNumberField: "number", uidField: "uid", nameField: "name")

        let outcome = try await EmptyCaseProvider().searchOutcome(
            court: court, cartoteka: cart, field: .caseNumber, value: "2-1/2026",
            operation: .discovery)

        guard case .honestZero(let attempt) = outcome else {
            return XCTFail("empty search должен стать typed honest-zero")
        }
        XCTAssertEqual(attempt.provenance.operation, .discovery)
    }

    func testKnownFailuresMapDeterministically() {
        let cases: [(Error, SourceOutcomeKind)] = [
            (SudrfError.captchaRequired(formURL: URL(string: "https://court.test/form?captchaid=secret")!), .captcha),
            (SudrfError.caseCardTemporarilyUnavailable, .maintenance),
            (SudrfError.http(status: 503), .transportFailure),
            (SudrfError.parsing("unknown"), .parserFailure),
        ]

        for (error, expected) in cases {
            let first = SourceOutcomeClassifier.attempt(
                for: error, operation: .movement, sourceFamily: "sudrf",
                host: "court.test", observedAt: observedAt)
            let second = SourceOutcomeClassifier.attempt(
                for: error, operation: .movement, sourceFamily: "sudrf",
                host: "court.test", observedAt: observedAt)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.kind, expected)
        }
    }

    func testPersistedProvenanceDropsURLQueryAndCaptchaData() throws {
        let attempt = SourceAttempt(
            kind: .captcha,
            provenance: SourceProvenance(
                operation: .search, sourceFamily: "sudrf",
                host: "https://court.test/modules.php?captchaid=secret&captcha=12345",
                observedAt: observedAt))
        let data = try JSONEncoder().encode(attempt)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(attempt.provenance.host, "court.test")
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("12345"))
        XCTAssertFalse(json.contains("modules.php"))
    }
}

private struct EmptyCaseProvider: CaseProviding {
    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] { [] }
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        throw SudrfError.parsing("unused")
    }
    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.parsing("unused")
    }
}
