import XCTest
import Foundation
@testable import SudrfKit

final class HTMLCourtTransportTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        HTMLCourtTransportStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTMLCourtTransportStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        try super.tearDownWithError()
    }

    func testUTF8OnlyPolicyRejectsWindows1251Response() async throws {
        HTMLCourtTransportStub.setBody(windows1251HTML())
        let transport = HTMLCourtTransport(
            session: session, userAgent: "SudrfKitTests", minInterval: 0,
            decodingPolicy: .utf8Only, throttleSemantics: .lastRequestStart)

        do {
            _ = try await transport.fetch(testURL, maxAttempts: 1)
            XCTFail("Ответ cp1251 не должен приниматься московским UTF-8 порталом")
        } catch let error as SudrfError {
            guard case .decodingFailed = error else {
                return XCTFail("Ожидалась decodingFailed, получено: \(error)")
            }
        }
    }

    func testUTF8ThenWindows1251PolicyKeepsVSRFFallback() async throws {
        HTMLCourtTransportStub.setBody(windows1251HTML())
        let transport = HTMLCourtTransport(
            session: session, userAgent: "SudrfKitTests", minInterval: 0,
            decodingPolicy: .utf8ThenWindows1251, throttleSemantics: .reserveSlots)

        let html = try await transport.fetch(testURL, maxAttempts: 1)
        XCTAssertEqual(html, "<html>Тест</html>")
    }

    func testMosGorSudClientUsesUTF8OnlyTransportPolicy() async throws {
        HTMLCourtTransportStub.setBody(windows1251HTML())
        let client = MosGorSudClient(session: session, minInterval: 0)

        do {
            _ = try await client.search(
                participant: "Иванов", instance: MosGorSudInstance.first, processType: .civil)
            XCTFail("Московский клиент не должен принимать cp1251 как UTF-8")
        } catch let error as SudrfError {
            guard case .decodingFailed = error else {
                return XCTFail("Ожидалась decodingFailed, получено: \(error)")
            }
        }
    }

    func testVSRFClientKeepsWindows1251CompatibilityFallback() async throws {
        HTMLCourtTransportStub.setBody(windows1251HTML())
        let client = VSRFClient(session: session, minInterval: 0)

        let results = try await client.searchByName("Иванов")
        XCTAssertEqual(results.total, 0)
        XCTAssertTrue(results.results.isEmpty)
    }

    private var testURL: URL { URL(string: "https://example.test/page")! }

    private func windows1251HTML() -> Data {
        // «Тест» в windows-1251; последовательность намеренно невалидна как UTF-8.
        Data("<html>".utf8) + Data([0xD2, 0xE5, 0xF1, 0xF2]) + Data("</html>".utf8)
    }
}

private final class HTMLCourtTransportStub: URLProtocol {
    nonisolated(unsafe) private static var responseBody = Data()
    private static let lock = NSLock()

    static func reset() {
        setBody(Data())
    }

    static func setBody(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        responseBody = data
    }

    private static func body() -> Data {
        lock.lock(); defer { lock.unlock() }
        return responseBody
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
