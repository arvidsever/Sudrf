import Foundation
import XCTest
@testable import SudrfKit

final class SudrfClientCompleteSearchTests: XCTestCase {
    func testPublishedTruncatedResultsFailClosedAndKeepRequestedSrvNum() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncompleteSearchURLProtocol.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        let court = Court(domain: "complete--test.sudrf.ru",
                          title: "Тестовый суд", level: .subject)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "p2"))

        do {
            _ = try await client.searchComplete(
                court: court, cartoteka: cartoteka, field: .caseNumber,
                value: "33а-1/2026", srvNum: 3)
            XCTFail("truncated first page must not be returned as complete")
        } catch is IncompleteCaseSearchError {
            // expected
        }
    }
}

private final class IncompleteSearchURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "srv_num" })?.value == "3" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let operation = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "name_op" })?.value
        let html: String
        if operation == "r" {
            html = """
            <html><body><p>Всего по запросу найдено — 2</p><table id="tablcont">
              <tr><td><a href="/modules.php?name=sud_delo&amp;srv_num=3&amp;name_op=case&amp;case_id=1&amp;case_uid=one&amp;delo_id=42&amp;new=0">33а-1/2026</a></td></tr>
            </table></body></html>
            """
        } else {
            html = "<html><body><form>Поиск информации по делам</form></body></html>"
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
