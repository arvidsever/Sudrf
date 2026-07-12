import XCTest
import Foundation
@testable import SudrfKit

final class VSRFClientThrottleTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        VSRFThrottleStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VSRFThrottleStub.self]
        session = URLSession(configuration: config)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        try super.tearDownWithError()
    }

    func testConcurrentRequestsReserveSeparateThrottleSlots() async throws {
        let client = VSRFClient(session: session, minInterval: 0.15)

        async let first = client.searchByName("Иванов")
        async let second = client.searchByName("Петров")
        async let third = client.searchByName("Сидоров")
        _ = try await [first, second, third]

        let starts = VSRFThrottleStub.requestStarts()
        XCTAssertEqual(starts.count, 3)
        let sorted = starts.sorted()
        XCTAssertGreaterThanOrEqual(sorted[1].timeIntervalSince(sorted[0]), 0.11)
        XCTAssertGreaterThanOrEqual(sorted[2].timeIntervalSince(sorted[1]), 0.11)
    }
}

private final class VSRFThrottleStub: URLProtocol {
    nonisolated(unsafe) private static var starts: [Date] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        starts = []
    }

    static func requestStarts() -> [Date] {
        lock.lock(); defer { lock.unlock() }
        return starts
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.starts.append(Date()); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<span class='count-label'>0</span>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
