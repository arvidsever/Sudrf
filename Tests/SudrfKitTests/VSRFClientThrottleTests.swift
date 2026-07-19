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
        let minInterval = 0.15
        let client = VSRFClient(session: session, minInterval: minInterval)

        async let first = client.searchByName("Иванов")
        async let second = client.searchByName("Петров")
        async let third = client.searchByName("Сидоров")
        _ = try await [first, second, third]

        let starts = VSRFThrottleStub.requestStarts()
        XCTAssertEqual(starts.count, 3)
        let sorted = starts.sorted()
        // Тест меряет не слоты троттла, а `startLoading` в URLProtocol —
        // слот + джиттер доставки (oversleep Task.sleep, планировщик,
        // диспатч URLSession). Лаг одного запроса сжимает соседний
        // наблюдаемый интервал, поэтому высокий порог на отдельный
        // интервал флакует на CI (0.091 < 0.11 при исправном троттле).
        // Ловим регрессию «резервация после await»: без неё все три
        // запроса стартуют почти одновременно, интервалы ~0–5мс.
        XCTAssertGreaterThanOrEqual(sorted[1].timeIntervalSince(sorted[0]), minInterval / 3)
        XCTAssertGreaterThanOrEqual(sorted[2].timeIntervalSince(sorted[1]), minInterval / 3)
        // Суммарный разбег устойчивее отдельных интервалов: джиттер
        // соседних запросов взаимно компенсируется.
        XCTAssertGreaterThanOrEqual(sorted[2].timeIntervalSince(sorted[0]), minInterval)
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
