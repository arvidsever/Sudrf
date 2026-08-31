import Foundation
import XCTest
@testable import SudrfKit

final class MagistrateCaptchaTransportTests: XCTestCase {
    private var session: URLSession!
    private var sessionMarker = ""
    private let formURL = URL(string: "https://example.msudrf.ru/modules.php?name=sud_delo&op=hl")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MagistrateCaptchaURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        sessionMarker = UUID().uuidString
        configuration.httpAdditionalHeaders = ["X-Sudrf-Test-Session": sessionMarker]
        configuration.protocolClasses = [MagistrateCaptchaURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        sessionMarker = ""
        MagistrateCaptchaURLProtocol.reset()
        try super.tearDownWithError()
    }

    func testLoadThenSubmitUsesOneSessionAndEscapedHiddenFields() async throws {
        MagistrateCaptchaURLProtocol.mode = .accepted
        let client = SudrfClient(session: session, minInterval: 0)

        let challenge = try await client.loadMagistrateCaptcha(formURL: formURL)
        XCTAssertEqual(challenge.imageData, Data([0x89, 0x50, 0x4E, 0x47]))

        guard case .accepted = try await client.submitMagistrateCaptcha(
            code: "A+B & Я", challenge: challenge) else {
            return XCTFail("valid response must unlock the session")
        }

        let requests = MagistrateCaptchaURLProtocol.requests()
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path ?? "")" }, [
            "GET /modules.php", "GET /captcha.php", "POST /modules.php"
        ])
        XCTAssertEqual(requests[1].httpShouldHandleCookies, true)
        XCTAssertEqual(requests[2].httpShouldHandleCookies, true)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Content-Type"),
                       "application/x-www-form-urlencoded")
        XCTAssertEqual(Set(requests.compactMap {
            $0.value(forHTTPHeaderField: "X-Sudrf-Test-Session")
        }), Set([sessionMarker]), "the form, image and POST must use the injected cookie session")
        // A custom URLProtocol sees requests before CFNetwork synthesizes the
        // Cookie header, so the stable session marker plus
        // httpShouldHandleCookies is the observable unit-level contract. The
        // live acceptance check covers PHPSESSID transmission end to end.
        XCTAssertEqual(String(data: requests[2].httpBody ?? Data(), encoding: .utf8),
                       "csrf=a%26b&space=hello+world&empty=&captcha-response=A%2BB+%26+%DF")
    }

    func testCrossOriginRedirectCannotReplayCaptchaPOST() throws {
        let delegate = MagistrateCaptchaRedirectDelegate()
        let target = URL(string: "https://attacker.example/stolen")!
        var replay = URLRequest(url: target)
        replay.httpMethod = "POST"
        replay.httpBody = Data("captcha-response=secret".utf8)
        // Deliberately make currentRequest point at the redirect target. The
        // policy must use response.url as the source, not task.currentRequest.
        let task = session.dataTask(with: replay)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: formURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        ))
        var forwarded: URLRequest?

        delegate.urlSession(session, task: task,
                            willPerformHTTPRedirection: response,
                            newRequest: replay) { forwarded = $0 }

        XCTAssertNil(forwarded, "the CAPTCHA body must never be replayed to another host")
    }

    func testRejectedSubmissionFetchesFreshImageFromReturnedForm() async throws {
        MagistrateCaptchaURLProtocol.mode = .rejected
        let client = SudrfClient(session: session, minInterval: 0)
        let first = try await client.loadMagistrateCaptcha(formURL: formURL)

        guard case .rejected(let replacement) = try await client.submitMagistrateCaptcha(
            code: "wrong", challenge: first) else {
            return XCTFail("wrong code must return a replacement challenge")
        }

        XCTAssertEqual(first.imageData, Data([1, 2, 3]))
        XCTAssertEqual(replacement.imageData, Data([4, 5, 6]))
        XCTAssertNotEqual(first.imageData, replacement.imageData)
        XCTAssertEqual(MagistrateCaptchaURLProtocol.requests().count, 4,
                       "POST response supplies the new form; only its image needs another GET")
        let requests = MagistrateCaptchaURLProtocol.requests()
        XCTAssertEqual(requests[3].httpShouldHandleCookies, true)
    }

    func testMissingFormIsParserFailure() async throws {
        MagistrateCaptchaURLProtocol.mode = .missingForm
        let client = SudrfClient(session: session, minInterval: 0)

        do {
            _ = try await client.loadMagistrateCaptcha(formURL: formURL)
            XCTFail("missing kcaptchaForm must fail explicitly")
        } catch let error as SudrfError {
            guard case .parsing = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(MagistrateCaptchaURLProtocol.requests().count, 1)
    }

    func testCrossHostActionIsRejectedBeforeImageRequest() async throws {
        MagistrateCaptchaURLProtocol.mode = .crossHostAction
        let client = SudrfClient(session: session, minInterval: 0)

        do {
            _ = try await client.loadMagistrateCaptcha(formURL: formURL)
            XCTFail("cross-host action must be rejected")
        } catch let error as SudrfError {
            guard case .parsing = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(MagistrateCaptchaURLProtocol.requests().count, 1)
    }

    func testCrossHostImageIsRejectedBeforeImageRequest() async throws {
        MagistrateCaptchaURLProtocol.mode = .crossHostImage
        let client = SudrfClient(session: session, minInterval: 0)

        do {
            _ = try await client.loadMagistrateCaptcha(formURL: formURL)
            XCTFail("cross-host image must be rejected")
        } catch let error as SudrfError {
            guard case .parsing = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(MagistrateCaptchaURLProtocol.requests().count, 1)
    }

    func testHTMLImageResponseIsRejected() async throws {
        MagistrateCaptchaURLProtocol.mode = .htmlImage
        let client = SudrfClient(session: session, minInterval: 0)

        do {
            _ = try await client.loadMagistrateCaptcha(formURL: formURL)
            XCTFail("HTML returned for the image must not be displayable CAPTCHA data")
        } catch let error as SudrfError {
            guard case .parsing = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(MagistrateCaptchaURLProtocol.requests().count, 2)
    }

    func testOversizedImageIsRejected() async throws {
        MagistrateCaptchaURLProtocol.mode = .oversizedImage
        let client = SudrfClient(session: session, minInterval: 0)

        do {
            _ = try await client.loadMagistrateCaptcha(formURL: formURL)
            XCTFail("an oversized CAPTCHA response must not be retained")
        } catch let error as SudrfError {
            guard case .parsing = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testHTTPFallbackKeepsMagistrateChallengeFlowOnTheSameHost() async throws {
        MagistrateCaptchaURLProtocol.mode = .tlsFallback
        let client = SudrfClient(session: session, minInterval: 0)

        let challenge = try await client.loadMagistrateCaptcha(formURL: formURL)
        guard case .accepted = try await client.submitMagistrateCaptcha(
            code: "ok", challenge: challenge) else {
            return XCTFail("fallback response without CAPTCHA must unlock the session")
        }

        let requests = MagistrateCaptchaURLProtocol.requests()
        XCTAssertEqual(requests.map { "\($0.httpMethod ?? "GET") \($0.url?.scheme ?? "")" }, [
            "GET https", "GET http", "GET http", "POST http"
        ])
    }

    func testAcceptedChallengeStillRequiresNormalSearchToRecognizeResponse() async throws {
        MagistrateCaptchaURLProtocol.mode = .accepted
        let transport = SudrfClient(session: session, minInterval: 0)
        let challenge = try await transport.loadMagistrateCaptcha(formURL: formURL)
        guard case .accepted = try await transport.submitMagistrateCaptcha(
            code: "тест", challenge: challenge) else {
            return XCTFail("CAPTCHA POST should unlock before the search reruns")
        }

        let client = MagistrateClient(sudrfClient: transport)
        let court = Court(domain: "example.msudrf.ru", title: "Участок", level: .magistrate)
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        do {
            _ = try await client.search(court: court, cartoteka: cartoteka,
                                        field: .caseNumber, value: "9-999/2026")
            XCTFail("unknown response after accepted CAPTCHA must not become honest zero")
        } catch SudrfError.searchModuleUnavailable(let domain) {
            XCTAssertEqual(domain, court.domain)
        }
    }
}

private final class MagistrateCaptchaURLProtocol: URLProtocol {
    enum Mode {
        case accepted
        case rejected
        case missingForm
        case crossHostAction
        case crossHostImage
        case htmlImage
        case oversizedImage
        case tlsFallback
    }

    nonisolated(unsafe) static var mode: Mode = .accepted
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        capturedRequests = []
        mode = .accepted
        lock.unlock()
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index: Int
        let mode: Mode
        Self.lock.lock()
        index = Self.capturedRequests.count
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            capturedRequest.httpBody = Self.read(stream)
        }
        Self.capturedRequests.append(capturedRequest)
        mode = Self.mode
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isImage = url.path == "/captcha.php"
        let body: Data
        let headers: [String: String]
        switch (mode, index, isImage) {
        case (.tlsFallback, 0, false):
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        case (.tlsFallback, 1, false):
            body = Data(Self.form().utf8)
            headers = Self.htmlHeaders(withCookie: true)
        case (.tlsFallback, _, true):
            body = Data([0x89, 0x50, 0x4E, 0x47])
            headers = ["Content-Type": "image/png"]
        case (.missingForm, 0, false):
            body = Data("<html>no captcha here</html>".utf8)
            headers = ["Content-Type": "text/html; charset=utf-8"]
        case (.crossHostAction, 0, false):
            body = Data(Self.form(action: "https://attacker.example/submit").utf8)
            headers = Self.htmlHeaders(withCookie: true)
        case (.crossHostImage, 0, false):
            body = Data(Self.form(image: "https://attacker.example/captcha.php").utf8)
            headers = Self.htmlHeaders(withCookie: true)
        case (.htmlImage, 0, false), (.accepted, 0, false), (.rejected, 0, false):
            body = Data(Self.form().utf8)
            headers = Self.htmlHeaders(withCookie: true)
        case (.rejected, 2, false):
            body = Data(Self.form(hiddenValue: "fresh-token").utf8)
            headers = ["Content-Type": "text/html; charset=utf-8"]
        case (.htmlImage, _, true):
            body = Data("<html>not an image</html>".utf8)
            headers = ["Content-Type": "text/html; charset=utf-8"]
        case (.oversizedImage, _, true):
            body = Data(repeating: 0, count: 1_048_577)
            headers = ["Content-Type": "image/png"]
        case (.rejected, _, true):
            body = index == 1 ? Data([1, 2, 3]) : Data([4, 5, 6])
            headers = ["Content-Type": "image/png"]
        case (.accepted, _, true), (.crossHostAction, _, true), (.crossHostImage, _, true):
            body = Data([0x89, 0x50, 0x4E, 0x47])
            headers = ["Content-Type": "image/png"]
        default:
            body = Data("<main>unlocked</main>".utf8)
            headers = ["Content-Type": "text/html; charset=utf-8"]
        }

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static func htmlHeaders(withCookie: Bool = false) -> [String: String] {
        var headers = ["Content-Type": "text/html; charset=utf-8"]
        if withCookie { headers["Set-Cookie"] = "PHPSESSID=session-1; Path=/" }
        return headers
    }

    private static func form(action: String = "",
                             image: String = "/captcha.php",
                             hiddenValue: String = "a&b") -> String {
        let actionAttribute = action.isEmpty ? "" : " action=\"\(action)\""
        return """
        <form id="kcaptchaForm" method="post"\(actionAttribute)>
          <input type="hidden" name="csrf" value="\(hiddenValue)">
          <input type="hidden" name="space" value="hello world">
          <input type="hidden" name="empty" value="">
          <input type="hidden" name="disabled" value="skip" disabled>
          <img src="\(image)">
          <input type="text" name="captcha-response">
        </form>
        """
    }
}
