import Foundation
import XCTest
@testable import SudrfKit

final class SudrfClientCardURLTests: XCTestCase {

    func testBothCardFetchPathsUseEffectiveResponseURLForPreviousRegistration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EffectiveCardURLStub.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        let expected = PreviousRegistrationReference(
            caseNumber: "5-78/2026",
            url: try XCTUnwrap(URL(string:
                "https://requested--tum.sudrf.ru/previous?case_uid=old")))

        // Internal published predecessor links intentionally remain permissive:
        // unlike the user-facing direct-link contract, old courts sometimes
        // publish a same-court path without the standard modules.php query.
        let direct = try await client.fetchCard(url: URL(string:
            "https://requested.tum.sudrf.ru/previous?case_uid=old")!)
        XCTAssertEqual(direct.previousRegistration, expected)

        let court = Court(domain: "court--test.sudrf.ru", title: "Тестовый суд", level: .district)
        let constructed = try await client.fetchCard(court: court, caseID: "current",
                                                     caseUID: "current-uid", deloID: "1540005")
        XCTAssertEqual(constructed.previousRegistration, expected)
    }
}

private final class EffectiveCardURLStub: URLProtocol {
    private static let effectiveURL = URL(string:
        "https://requested--tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
        + "&case_id=current&case_uid=current-uid&delo_id=1540005&redirected=1")!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let html = """
        <div class="casenumber">ДЕЛО № 5-174/2026</div>
        <table><tr>
          <td>Номер по предыдущей регистрации</td>
          <td><a href="previous?case_uid=old">5-78/2026</a></td>
        </tr></table>
        """
        let response = HTTPURLResponse(url: Self.effectiveURL, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
