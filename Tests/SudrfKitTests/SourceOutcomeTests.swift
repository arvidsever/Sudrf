import Foundation
import XCTest
@testable import SudrfKit

final class SourceOutcomeTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testTransportFailureCategoryMatrix() {
        let groups: [(SourceTransportFailureCategory, [URLError.Code])] = [
            (.timeout, [.timedOut]), (.dns, [.cannotFindHost, .dnsLookupFailed]),
            (.tls, [.secureConnectionFailed, .serverCertificateHasBadDate,
                    .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                    .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired]),
            (.connection, [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet]),
            (.cancelled, [.cancelled]), (.network, [.badURL, URLError.Code(rawValue: -99999)])
        ]
        for (category, codes) in groups {
            for code in codes { XCTAssertEqual(SourceTransportFailureCategory.classify(code), category) }
        }
    }

    func testDerivedTransportCategoryUsesExistingProvenanceOnly() throws {
        let errors: [Error] = [
            NSError(domain: NSURLErrorDomain, code: -1200,
                    userInfo: [NSLocalizedDescriptionKey: "private sentinel"]),
            SudrfError.transientNetworkError(domain: "court.invalid", code: .timedOut, attempt: 3),
            URLError(.cancelled)
        ]
        for (error, category) in zip(errors, [SourceTransportFailureCategory.tls, .timeout, .cancelled]) {
            let attempt = SourceOutcomeClassifier.attempt(for: error, operation: .search,
                sourceFamily: "sudrf", host: "court.invalid", observedAt: observedAt)
            XCTAssertEqual(attempt.kind, .transportFailure)
            XCTAssertEqual(attempt.transportFailureCategory, category)
            let data = try JSONEncoder().encode(attempt)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private sentinel"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("transportFailureCategory"))
            let decoded = try JSONDecoder().decode(SourceAttempt.self, from: data)
            XCTAssertEqual(decoded, attempt)
            XCTAssertEqual(decoded.transportFailureCategory, category)
        }
    }

    func testDerivedTransportCategoryExcludesMissingMalformedHTTPAndOtherOutcomes() throws {
        for code in [nil, "", "not-a-number"] as [String?] {
            let attempt = SourceAttempt(kind: .transportFailure,
                provenance: .init(operation: .search, sourceFamily: "sudrf", host: "court.invalid", errorCode: code))
            XCTAssertNil(attempt.transportFailureCategory)
        }
        for kind in [SourceOutcomeKind.parserFailure, .captcha, .maintenance, .partial, .usableSnapshot] {
            XCTAssertNil(SourceAttempt(kind: kind, provenance: .init(operation: .search,
                sourceFamily: "sudrf", host: "court.invalid", errorCode: "-1200")).transportFailureCategory)
        }
        XCTAssertNil(SourceAttempt(kind: .transportFailure, provenance: .init(operation: .search,
            sourceFamily: "sudrf", host: "court.invalid", httpStatus: 503, errorCode: "-1200")).transportFailureCategory)
        let legacy = Data(#"{"kind":"transportFailure","provenance":{"operation":"search","sourceFamily":"sudrf","host":"court.invalid","observedAt":0,"errorCode":"-1200"}}"#.utf8)
        let decoded = try JSONDecoder().decode(SourceAttempt.self, from: legacy)
        XCTAssertEqual(decoded.transportFailureCategory, .tls)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "provenance"])
    }

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

    func testOptionalRefreshBackoffMetadataRoundTripsAndOldAttemptDecodes() throws {
        let legacy = SourceAttempt(
            kind: .partial,
            provenance: SourceProvenance(operation: .movement, sourceFamily: "sudrf",
                                         host: "court.test", observedAt: observedAt))
        let oldJSON = try JSONEncoder().encode(legacy)
        let decodedOld = try JSONDecoder().decode(SourceAttempt.self, from: oldJSON)
        XCTAssertNil(decodedOld.consecutiveRefreshFailures)
        XCTAssertNil(decodedOld.retryNotBefore)

        var scheduled = legacy
        scheduled.consecutiveRefreshFailures = 3
        scheduled.retryNotBefore = observedAt.addingTimeInterval(3_600)
        let roundTrip = try JSONDecoder().decode(
            SourceAttempt.self, from: JSONEncoder().encode(scheduled))
        XCTAssertEqual(roundTrip, scheduled)
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
