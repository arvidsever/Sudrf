import Foundation
import XCTest
@_spi(Diagnostics) import SudrfKit
@testable import SudrfKit

final class TransportTimingTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TimingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimingURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        try super.tearDownWithError()
    }

    func testCollectorIsScopedAndStoresOnlyCanonicalHostAndTimings() async throws {
        let transport = HTMLCourtTransport(
            session: session, userAgent: "SudrfKitTests", minInterval: 0,
            decodingPolicy: .utf8Only, throttleSemantics: .lastRequestStart)
        let collector = TransportTimingCollector()
        let privateURL = URL(string: "https://VS.KOMI.SUDRF.RU/cases/123?case_uid=private-value")!

        try await TransportTiming.$collector.withValue(collector) {
            _ = try await transport.fetch(privateURL, maxAttempts: 1)
        }
        _ = try await transport.fetch(privateURL, maxAttempts: 1)

        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.transportAttemptCount, 1)
        XCTAssertEqual(snapshot.cancelledCount, 0)
        XCTAssertEqual(snapshot.hostTimings.map(\.host), ["vs--komi.sudrf.ru"])
        XCTAssertEqual(snapshot.hostTimings.first?.attemptCount, 1)
        let description = String(reflecting: snapshot)
        XCTAssertFalse(description.contains("/cases/123"))
        XCTAssertFalse(description.contains("case_uid"))
        XCTAssertFalse(description.contains("private-value"))
    }

    func testSudrfFIFOWaitIsSeparateFromNetworkTime() async throws {
        let client = SudrfClient(session: session, minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let collector = TransportTimingCollector()
        let slowURL = URL(string: "https://vs.komi.sudrf.ru/slow?case=private")!
        let fastURL = URL(string: "https://vs.komi.sudrf.ru/fast?case=private")!

        let slow = Task {
            try await TransportTiming.$collector.withValue(collector) {
                try await client.fetchHTML(slowURL)
            }
        }
        let slowStarted = await TimingURLProtocol.waitForSlowRequest()
        XCTAssertTrue(slowStarted, "slow URLProtocol request should start before queueing the second request")
        let fast = Task {
            try await TransportTiming.$collector.withValue(collector) {
                try await client.fetchHTML(fastURL)
            }
        }

        _ = try await slow.value
        _ = try await fast.value

        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.transportAttemptCount, 2)
        XCTAssertEqual(snapshot.hostTimings.first?.host, "vs--komi.sudrf.ru")
        let queued = try XCTUnwrap(snapshot.samples.max(by: {
            $0.queueWaitSeconds < $1.queueWaitSeconds
        }))
        XCTAssertGreaterThan(queued.queueWaitSeconds, 0.15)
        XCTAssertLessThan(queued.responseSeconds, 0.15,
                          "FIFO wait must not be counted as the queued request's network time")
        XCTAssertGreaterThan(snapshot.hostTimings.first?.queueWaitP95Seconds ?? 0, 0.15)
    }

    func testConcurrentTaskLocalCollectorsAndUnscopedCallStaySeparate() async throws {
        let client = SudrfClient(session: session, minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let firstCollector = TransportTimingCollector()
        let secondCollector = TransportTimingCollector()
        let slowURL = URL(string: "https://vs.komi.sudrf.ru/slow?case=private")!
        let scopedURL = URL(string: "https://vs.komi.sudrf.ru/scoped?case=private")!
        let manualURL = URL(string: "https://vs.komi.sudrf.ru/manual?case=private")!

        let slow = Task {
            try await TransportTiming.$collector.withValue(firstCollector) {
                try await client.fetchHTML(slowURL)
            }
        }
        let slowStarted = await TimingURLProtocol.waitForSlowRequest()
        XCTAssertTrue(slowStarted)
        let scoped = Task {
            try await TransportTiming.$collector.withValue(secondCollector) {
                try await client.fetchHTML(scopedURL)
            }
        }
        let manual = Task { try await client.fetchHTML(manualURL) }

        _ = try await slow.value
        _ = try await scoped.value
        _ = try await manual.value

        XCTAssertEqual(firstCollector.snapshot().transportAttemptCount, 1)
        XCTAssertEqual(secondCollector.snapshot().transportAttemptCount, 1)
        XCTAssertEqual(firstCollector.snapshot().hostTimings.first?.host, "vs--komi.sudrf.ru")
        XCTAssertEqual(secondCollector.snapshot().hostTimings.first?.host, "vs--komi.sudrf.ru")
    }

    func testCancelledFIFOWaiterDoesNotCountAsNetworkAttempt() async throws {
        let client = SudrfClient(session: session, minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let collector = TransportTimingCollector()
        let slowURL = URL(string: "https://vs.komi.sudrf.ru/slow?case=private")!
        let waitingURL = URL(string: "https://vs.komi.sudrf.ru/waiting?case=private")!

        let slow = Task {
            try await TransportTiming.$collector.withValue(collector) {
                try await client.fetchHTML(slowURL)
            }
        }
        let slowStarted = await TimingURLProtocol.waitForSlowRequest()
        XCTAssertTrue(slowStarted)
        let waiting = Task {
            try await TransportTiming.$collector.withValue(collector) {
                try await client.fetchHTML(waitingURL)
            }
        }

        let deadline = ContinuousClock.now + .seconds(1)
        var waiterIsQueued = false
        while ContinuousClock.now < deadline {
            if await client.requestWaiterCountForTesting() == 1 {
                waiterIsQueued = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(waiterIsQueued, "second request should be waiting behind the active FIFO slot")

        waiting.cancel()
        _ = try? await waiting.value
        _ = try await slow.value

        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.transportAttemptCount, 1,
                       "cancellation before URLSession starts is not a network attempt")
        XCTAssertEqual(snapshot.cancelledCount, 0)
    }

    func testFileTransportRecordsNetworkTimingWithoutRetainingURL() async throws {
        let transport = HTMLCourtTransport(
            session: session, userAgent: "SudrfKitTests", minInterval: 0,
            decodingPolicy: .utf8Only, throttleSemantics: .reserveSlots)
        let collector = TransportTimingCollector()
        let privateURL = URL(string: "https://files.example.test/document?token=private-value")!

        let file = try await TransportTiming.$collector.withValue(collector) {
            try await transport.fetchFile(
                privateURL, maxAttempts: 1, allowedHosts: ["files.example.test"], maxBytes: 100)
        }

        XCTAssertFalse(file.data.isEmpty)
        let snapshot = collector.snapshot()
        XCTAssertEqual(snapshot.transportAttemptCount, 1)
        XCTAssertEqual(snapshot.hostTimings.first?.host, "files.example.test")
        XCTAssertFalse(String(reflecting: snapshot).contains("document"))
        XCTAssertFalse(String(reflecting: snapshot).contains("private-value"))
    }
}

private final class TimingURLProtocol: URLProtocol {
    private static let slowStarted = DispatchSemaphore(value: 0)

    static func reset() {
        while slowStarted.wait(timeout: .now()) == .success {}
    }

    static func waitForSlowRequest() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let succeeded = Self.slowStarted.wait(timeout: .now() + .seconds(3)) == .success
                continuation.resume(returning: succeeded)
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/slow" {
            Self.slowStarted.signal()
            Thread.sleep(forTimeInterval: 0.4)
        }

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/pdf"] )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>ok</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
