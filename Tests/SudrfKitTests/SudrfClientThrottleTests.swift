import XCTest
import Foundation
@testable import SudrfKit

final class SudrfClientThrottleTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThrottleStub.self] + (config.protocolClasses ?? [])
        session = URLSession(configuration: config)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        try super.tearDownWithError()
    }

    func testCancelledTailReservationDoesNotDelayNextRequestByAnotherInterval() async throws {
        let client = SudrfClient(session: session, minInterval: 0.5)
        await client.setMaxAttemptsForTesting(1)
        let url = URL(string: "https://throttle.example/card")!
        _ = try await client.fetchHTML(url) // бронирует первый реальный интервал

        let cancelled = Task { try await client.fetchHTML(url) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        _ = try? await cancelled.value

        let started = Date()
        _ = try await client.fetchHTML(url)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.75,
                          "отменённый хвост очереди не должен оставлять ещё один интервал ожидания")
    }
}

private final class ThrottleStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
