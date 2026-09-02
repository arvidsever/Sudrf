import Foundation
import XCTest
@testable import SudrfKit

final class SudrfCaseCardLinkTests: XCTestCase {

    func testParsesModernLinkAndSanitizesKnownQueryItems() throws {
        let link = try SudrfCaseCardLink.parse(URL(string:
            "https://court.tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=42&case_uid=uid-42&delo_id=1540005&new=0&srv_num=2"
            + "&vnkod=72&source=mail&utm_source=message&captcha=123&captchaid=456#card")!)

        XCTAssertEqual(link.host, "court.tum.sudrf.ru")
        XCTAssertEqual(link.moduleHost, "court--tum.sudrf.ru")
        XCTAssertEqual(link.caseID, "42")
        XCTAssertEqual(link.caseUID, "uid-42")
        XCTAssertEqual(link.deloID, "1540005")
        XCTAssertEqual(link.new, "0")
        XCTAssertEqual(link.resolvedNew, "0")
        XCTAssertEqual(link.srvNum, "2")
        XCTAssertEqual(link.url.fragment, nil)
        XCTAssertTrue(link.url.absoluteString.contains("srv_num=2"))
        XCTAssertTrue(link.url.absoluteString.contains("vnkod=72"))
        XCTAssertTrue(link.url.absoluteString.contains("source=mail"))
        XCTAssertFalse(link.url.absoluteString.contains("utm_source"))
        XCTAssertFalse(link.url.absoluteString.contains("captcha"))
    }

    func testParsesVintageUnderscoreUIDOnlyLink() throws {
        let link = try SudrfCaseCardLink.parse("https://court--tum.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&_uid=uid-42&_deloId=1540005&_new=5"
            + "&_caseType=0&srv_num=3")

        XCTAssertNil(link.caseID)
        XCTAssertEqual(link.caseUID, "uid-42")
        XCTAssertEqual(link.deloID, "1540005")
        XCTAssertEqual(link.new, "5")
        XCTAssertEqual(link.resolvedNew, "5")
        XCTAssertTrue(link.url.absoluteString.contains("_caseType=0"))
        XCTAssertTrue(link.url.absoluteString.contains("srv_num=3"))
    }

    func testAcceptsPlainHTTPForSupportedFederalCourt() throws {
        let link = try SudrfCaseCardLink.parse(
            "http://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=42&delo_id=1540005")

        XCTAssertEqual(link.url.scheme, "http")
        XCTAssertEqual(link.host, "court--tum.sudrf.ru")
    }

    func testAcceptsPublishedEmptyNewAsDefaultRegister() throws {
        let link = try SudrfCaseCardLink.parse(
            "https://leninsky--kir.sudrf.ru/modules.php?name=sud_delo"
            + "&name_op=case&case_id=20398142&case_uid=old&delo_id=1500001&new=")

        XCTAssertEqual(link.new, "0")
        XCTAssertEqual(link.resolvedNew, "0")
        XCTAssertTrue(link.url.absoluteString.hasSuffix("&new="))
    }

    func testEqualDuplicatesAcrossModernAndVintageNamesAreAccepted() throws {
        let link = try SudrfCaseCardLink.parse(URL(string:
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name=sud_delo"
            + "&name_op=case&name_op=case&case_id=42&case_id=42&_id=42"
            + "&case_uid=uid&_uid=uid&delo_id=1540005&_deloId=1540005"
            + "&new=5&_new=5")!)

        XCTAssertEqual(link.caseID, "42")
        XCTAssertEqual(link.caseUID, "uid")
        XCTAssertEqual(link.deloID, "1540005")
        XCTAssertEqual(link.new, "5")
    }

    func testConflictingDuplicatesAreRejected() {
        let urls = [
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name=sud_delo"
                + "&name_op=case&case_id=1&case_id=2&delo_id=1540005",
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_uid=a&_uid=b&delo_id=1540005",
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=1&delo_id=1540005&new=1&_new=2",
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=1&delo_id=1540005&name_op=r"
        ]

        for rawURL in urls {
            XCTAssertThrowsError(try SudrfCaseCardLink.parse(rawURL), rawURL)
        }
    }

    func testRejectsListingsUnsupportedHostsCredentialsAndIncompleteCards() {
        let urls = [
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=r"
                + "&delo_id=1540005&case_id=1",
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=r_juid"
                + "&delo_id=1540005&case_id=1",
            "https://court--tum.sudrf.ru/modules.php?name=sud_other&name_op=case"
                + "&delo_id=1540005&case_id=1",
            "https://example.org/modules.php?name=sud_delo&name_op=case"
                + "&delo_id=1540005&case_id=1",
            "https://user:password@court--tum.sudrf.ru/modules.php?name=sud_delo"
                + "&name_op=case&delo_id=1540005&case_id=1",
            "ftp://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&delo_id=1540005&case_id=1",
            "https://court--tum.sudrf.ru/index.php?name=sud_delo&name_op=case"
                + "&delo_id=1540005&case_id=1",
            "https://court--tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&delo_id=1540005"
        ]

        for rawURL in urls {
            XCTAssertThrowsError(try SudrfCaseCardLink.parse(rawURL), rawURL)
        }
    }

    func testRedirectResponseURLIsValidatedAndSanitized() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingCardStub.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)

        let result = try await client.fetchCardWithResponseURL(url: URL(string:
            "https://redirect.tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=42&case_uid=uid-42&delo_id=1540005")!)

        XCTAssertEqual(result.card.caseNumber, "2-42/2026")
        XCTAssertEqual(result.responseURL.host, "other--tum.sudrf.ru")
        XCTAssertNil(result.responseURL.fragment)
        XCTAssertTrue(result.responseURL.absoluteString.contains("srv_num=2"))
        XCTAssertTrue(result.responseURL.absoluteString.contains("source=route"))
        XCTAssertFalse(result.responseURL.absoluteString.contains("utm_campaign"))
        XCTAssertFalse(result.responseURL.absoluteString.contains("captcha"))
    }

    func testRedirectOutsideSudrfIsRejectedBeforeFollowing() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalRedirectingCardStub.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        let url = URL(string:
            "https://redirect.tum.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                + "&case_id=42&case_uid=uid-42&delo_id=1540005")!

        do {
            _ = try await client.fetchCardWithResponseURL(url: url)
            XCTFail("expected an external redirect to be rejected")
        } catch SudrfError.http(let status) {
            XCTAssertEqual(status, 302)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private final class RedirectingCardStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if requestURL.host == "redirect.tum.sudrf.ru" {
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Location": "https://other--tum.sudrf.ru/modules.php"
                        + "?name=sud_delo&name_op=case&case_id=42&case_uid=uid-42"
                        + "&delo_id=1540005&srv_num=2&source=route"
                        + "&utm_campaign=mail&captcha=123#fragment"
                ])!
            let redirectURL = URL(string: response.value(forHTTPHeaderField: "Location")!)!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL),
                                redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let html = "<div class=\"casenumber\">ДЕЛО № 2-42/2026</div>"
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ExternalRedirectingCardStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.org/stolen"]
        )!
        let redirect = URLRequest(url: URL(string: "https://example.org/stolen")!)
        client?.urlProtocol(self, wasRedirectedTo: redirect, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
