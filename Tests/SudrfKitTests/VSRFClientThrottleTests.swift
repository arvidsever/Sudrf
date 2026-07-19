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

        let clock = ContinuousClock()
        let launched = clock.now
        async let first = client.searchByName("Иванов")
        async let second = client.searchByName("Петров")
        async let third = client.searchByName("Сидоров")
        _ = try await [first, second, third]
        let elapsed = clock.now - launched

        let starts = VSRFThrottleStub.requestStarts()
        XCTAssertEqual(starts.count, 3)
        // Интервалы между `startLoading` в URLProtocol проверять нельзя:
        // это слот троттла + джиттер доставки (планировщик, диспатч
        // URLSession), и на CI лаг одного запроса достигает полного
        // minInterval — соседний наблюдаемый интервал сжимается вплоть
        // до нуля при исправном троттле (наблюдалось 0.091с и 0.0003с).
        // Вместо этого меряем монотонными часами суммарное время всех
        // трёх await: резервация слотов до `await` гарантирует, что
        // третий запрос спит до T0 + 2×minInterval, а `Task.sleep`
        // никогда не просыпается раньше срока. Регрессия «резервация
        // после await» даёт elapsed в единицы миллисекунд. Запас 0.9 —
        // на расхождение wall-clock (Date в throttle) и монотонных часов.
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(2 * minInterval * 0.9),
                                    "три запроса должны занять не меньше двух слотов троттла")
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
