import XCTest
import Foundation
@testable import SudrfKit

/// Regression coverage for the production transport policy used by SUDRF.
/// The delays are asserted directly instead of sleeping through a retry cycle.
final class SudrfClientTransportPolicyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SerializedTransportStub.reset()
        RotatingTransportStub.reset()
    }

    func testProductionTimeoutAndRetryPolicy() async {
        let configuration = SudrfClient.productionConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 90,
                       "запросам судов нужен длинный таймаут")
        XCTAssertEqual(SudrfClient.retryDelay(after: 0), 2,
                       accuracy: 0.001,
                       "после первой попытки пауза должна быть 2 секунды")
        XCTAssertEqual(SudrfClient.retryDelay(after: 1), 4,
                       accuracy: 0.001,
                       "после второй попытки пауза должна быть 4 секунды")

        let client = SudrfClient(minInterval: 0)
        let maxAttempts = await client.maxAttempts
        XCTAssertEqual(maxAttempts, 3,
                       "должна остаться одна начальная попытка и два повтора")
    }

    func testRequestsAcrossHostsAreFIFOAndNeverOverlap() async throws {
        let (client, session) = makeClient(minInterval: 0.04)
        defer { session.invalidateAndCancel() }
        await client.setMaxAttemptsForTesting(1)

        let first = Task { try await client.fetchHTML(URL(string: "https://one.sudrf.ru/first")!) }
        try await waitUntil { SerializedTransportStub.snapshot().started.count == 1 }
        let second = Task { try await client.fetchHTML(URL(string: "https://two.sudrf.ru/second")!) }
        try await Task.sleep(for: .milliseconds(10))
        let third = Task { try await client.fetchHTML(URL(string: "https://three.sudrf.ru/third")!) }

        _ = try await (first.value, second.value, third.value)
        let snapshot = SerializedTransportStub.snapshot()
        XCTAssertEqual(snapshot.started, ["/first", "/second", "/third"])
        XCTAssertEqual(snapshot.peak, 1, "запросы к разным доменам не должны пересекаться")
        XCTAssertEqual(snapshot.completed, 3)
        XCTAssertGreaterThanOrEqual(snapshot.startDates[1].timeIntervalSince(snapshot.startDates[0]),
                                    0.035)
        XCTAssertGreaterThanOrEqual(snapshot.startDates[2].timeIntervalSince(snapshot.startDates[1]),
                                    0.035)
    }

    func testTimeoutReleasesSlotBeforeRetryBackoff() async throws {
        SerializedTransportStub.failFirstPath = "/retry"
        let (client, session) = makeClient(minInterval: 0)
        defer { session.invalidateAndCancel() }
        await client.setMaxAttemptsForTesting(2)

        let retrying = Task {
            try await client.fetchHTML(URL(string: "https://one.sudrf.ru/retry")!)
        }
        try await waitUntil { SerializedTransportStub.snapshot().completed == 1 }

        let started = Date()
        _ = try await client.fetchHTML(URL(string: "https://two.sudrf.ru/during-backoff")!)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "чужой запрос должен пройти, пока первый ждёт повтор")
        _ = try await retrying.value

        let snapshot = SerializedTransportStub.snapshot()
        XCTAssertEqual(snapshot.started, ["/retry", "/during-backoff", "/retry"])
        XCTAssertEqual(snapshot.peak, 1)
    }

    func testCancellingActiveRequestDoesNotStrandQueue() async throws {
        SerializedTransportStub.slowPaths = ["/cancelled"]
        let (client, session) = makeClient(minInterval: 0)
        defer { session.invalidateAndCancel() }
        await client.setMaxAttemptsForTesting(1)

        let cancelled = Task {
            try await client.fetchHTML(URL(string: "https://one.sudrf.ru/cancelled")!)
        }
        try await waitUntil { SerializedTransportStub.snapshot().started == ["/cancelled"] }
        cancelled.cancel()
        _ = try? await cancelled.value

        _ = try await client.fetchHTML(URL(string: "https://two.sudrf.ru/after-cancel")!)
        let snapshot = SerializedTransportStub.snapshot()
        XCTAssertEqual(snapshot.started, ["/cancelled", "/after-cancel"])
        XCTAssertEqual(snapshot.peak, 1)
        XCTAssertEqual(snapshot.completed, 2)
    }

    func testCancellingQueuedWaiterRemovesItAndStartsNext() async throws {
        SerializedTransportStub.slowPaths = ["/holding"]
        let (client, session) = makeClient(minInterval: 0)
        defer { session.invalidateAndCancel() }
        await client.setMaxAttemptsForTesting(1)

        let holding = Task {
            try await client.fetchHTML(URL(string: "https://one.sudrf.ru/holding")!)
        }
        try await waitUntil { SerializedTransportStub.snapshot().started == ["/holding"] }
        let cancelled = Task {
            try await client.fetchHTML(URL(string: "https://two.sudrf.ru/queued-cancel")!)
        }
        try await Task.sleep(for: .milliseconds(10))
        let next = Task {
            try await client.fetchHTML(URL(string: "https://three.sudrf.ru/after-queued-cancel")!)
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("отменённый waiter не должен выполнять запрос")
        } catch is CancellationError {
            // expected
        }
        _ = try await (holding.value, next.value)

        let snapshot = SerializedTransportStub.snapshot()
        XCTAssertEqual(snapshot.started, ["/holding", "/after-queued-cancel"])
        XCTAssertEqual(snapshot.peak, 1)
        XCTAssertEqual(snapshot.completed, 2)
    }

    func testProductionOriginSessionReusesNormalizedOriginThenRotates() async throws {
        let factory = RotatingSessionFactory()
        let client = SudrfClient(sessionFactory: { delegate in
            factory.makeSession(delegate: delegate)
        }, minInterval: 0, sessionInvalidationObserver: {
            factory.recordInvalidation()
        })
        await client.setMaxAttemptsForTesting(1)

        _ = try await client.fetchHTML(URL(string: "https://ONE.sudrf.ru/first")!)
        _ = try await client.fetchHTML(URL(string: "https://one.sudrf.ru:443/again")!)
        _ = try await client.fetchHTML(URL(string: "https://two.sudrf.ru/next")!)

        XCTAssertEqual(factory.createdSessionIDs(), [1, 2])
        XCTAssertEqual(factory.sessionCreationInvalidationCounts(), [0, 1],
                       "новая сессия создаётся только после didBecomeInvalid старой")
        XCTAssertEqual(RotatingTransportStub.snapshot().map(\.sessionID), ["1", "1", "2"])
    }

    func testGenericRedirectReentersFIFOAndKeepsGlobalInterval() async throws {
        let factory = RotatingSessionFactory()
        let client = SudrfClient(sessionFactory: { delegate in
            factory.makeSession(delegate: delegate)
        }, minInterval: 0.04)
        await client.setMaxAttemptsForTesting(1)
        RotatingTransportStub.setRedirect(
            from: "/redirect", to: URL(string: "https://two.sudrf.ru/final")!, delay: 0.08)

        let redirected = Task {
            try await client.fetchHTML(URL(string: "https://one.sudrf.ru/redirect")!)
        }
        try await waitUntil { RotatingTransportStub.snapshot().count == 1 }
        let waiting = Task {
            try await client.fetchHTML(URL(string: "https://one.sudrf.ru/waiting")!)
        }
        _ = try await (redirected.value, waiting.value)

        XCTAssertEqual(factory.createdSessionIDs(), [1, 2])
        let requests = RotatingTransportStub.snapshot()
        XCTAssertEqual(requests.map(\.path), ["/redirect", "/waiting", "/final"])
        XCTAssertEqual(requests.map(\.sessionID), ["1", "1", "2"])
        XCTAssertGreaterThanOrEqual(requests[1].startedAt.timeIntervalSince(requests[0].startedAt), 0.035)
        XCTAssertGreaterThanOrEqual(requests[2].startedAt.timeIntervalSince(requests[1].startedAt), 0.035)
    }

    func testCancellationWhileAwaitingInvalidationDoesNotCreateSuccessor() async throws {
        let factory = RotatingSessionFactory()
        let gate = InvalidationGate()
        let client = SudrfClient(sessionFactory: { delegate in
            factory.makeSession(delegate: delegate)
        }, minInterval: 0, sessionInvalidationObserver: {
            gate.waitForRelease()
        })
        await client.setMaxAttemptsForTesting(1)

        _ = try await client.fetchHTML(URL(string: "https://one.sudrf.ru/first")!)
        let cancelled = Task {
            try await client.fetchHTML(URL(string: "https://two.sudrf.ru/cancelled")!)
        }
        try await waitUntil { gate.hasReachedInvalidation }
        cancelled.cancel()
        gate.release()

        do {
            _ = try await cancelled.value
            XCTFail("отмена во время invalidation не должна создавать successor session")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(factory.createdSessionIDs(), [1])

        _ = try await client.fetchHTML(URL(string: "https://three.sudrf.ru/after-cancel")!)
        XCTAssertEqual(factory.createdSessionIDs(), [1, 2])
    }

    private func makeClient(minInterval: TimeInterval) -> (SudrfClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SerializedTransportStub.self]
        let session = URLSession(configuration: configuration)
        return (SudrfClient(session: session, minInterval: minInterval), session)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "условие тестового транспорта не выполнено вовремя")
    }
}

private final class RotatingSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var createdIDs: [Int] = []
    private var invalidationCount = 0
    private var invalidationCountsWhenCreated: [Int] = []

    func makeSession(delegate: URLSessionDelegate) -> URLSession {
        lock.lock()
        nextID += 1
        let id = nextID
        createdIDs.append(id)
        invalidationCountsWhenCreated.append(invalidationCount)
        lock.unlock()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RotatingTransportStub.self]
        configuration.httpAdditionalHeaders = ["X-Sudrf-Test-Session": "\(id)"]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func createdSessionIDs() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return createdIDs
    }

    func recordInvalidation() {
        lock.lock()
        invalidationCount += 1
        lock.unlock()
    }

    func sessionCreationInvalidationCounts() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return invalidationCountsWhenCreated
    }
}

private final class InvalidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var reached = false

    var hasReachedInvalidation: Bool {
        lock.lock(); defer { lock.unlock() }
        return reached
    }

    func waitForRelease() {
        lock.lock()
        reached = true
        lock.unlock()
        semaphore.wait()
    }

    func release() { semaphore.signal() }
}

private final class RotatingTransportStub: URLProtocol {
    struct Request: Equatable {
        let path: String
        let sessionID: String?
        let startedAt: Date
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [Request] = []
    nonisolated(unsafe) private static var redirects: [String: (url: URL, delay: TimeInterval)] = [:]
    private var redirectWorkItem: DispatchWorkItem?

    static func reset() {
        lock.lock()
        requests = []
        redirects = [:]
        lock.unlock()
    }

    static func snapshot() -> [Request] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func setRedirect(from path: String, to url: URL, delay: TimeInterval = 0) {
        lock.lock()
        redirects[path] = (url, delay)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let redirect: (url: URL, delay: TimeInterval)?
        Self.lock.lock()
        Self.requests.append(Request(
            path: path,
            sessionID: request.value(forHTTPHeaderField: "X-Sudrf-Test-Session"),
            startedAt: Date()))
        redirect = Self.redirects[path]
        Self.lock.unlock()

        guard let url = request.url else { return }
        if let redirect {
            let item = DispatchWorkItem { [weak self] in
                self?.sendRedirect(from: url, to: redirect.url)
            }
            redirectWorkItem = item
            if redirect.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + redirect.delay,
                                                   execute: item)
            } else {
                item.perform()
            }
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { redirectWorkItem?.cancel() }

    private func sendRedirect(from url: URL, to redirect: URL) {
        let response = HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirect.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect),
                            redirectResponse: response)
        // The production delegate rejects URLSession's automatic redirect so
        // SudrfClient can replay the hop through its FIFO. Complete the
        // original 302 as URLSession would after completionHandler(nil).
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SerializedTransportStub: URLProtocol {
    struct Snapshot {
        let started: [String]
        let startDates: [Date]
        let completed: Int
        let peak: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: [String] = []
    nonisolated(unsafe) private static var startDates: [Date] = []
    nonisolated(unsafe) private static var completed = 0
    nonisolated(unsafe) private static var active = 0
    nonisolated(unsafe) private static var peak = 0
    nonisolated(unsafe) private static var pathCounts: [String: Int] = [:]
    nonisolated(unsafe) static var failFirstPath: String?
    nonisolated(unsafe) static var slowPaths = Set<String>()

    private let stateLock = NSLock()
    private var workItem: DispatchWorkItem?
    private var finished = false

    static func reset() {
        lock.lock()
        started = []
        startDates = []
        completed = 0
        active = 0
        peak = 0
        pathCounts = [:]
        failFirstPath = nil
        slowPaths = []
        lock.unlock()
    }

    static func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(started: started, startDates: startDates,
                        completed: completed, peak: peak)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let shouldFail: Bool
        let delay: TimeInterval
        Self.lock.lock()
        let count = Self.pathCounts[path, default: 0]
        Self.pathCounts[path] = count + 1
        Self.started.append(path)
        Self.startDates.append(Date())
        Self.active += 1
        Self.peak = max(Self.peak, Self.active)
        shouldFail = Self.failFirstPath == path && count == 0
        delay = Self.slowPaths.contains(path) ? 0.5 : 0.02
        Self.lock.unlock()

        let item = DispatchWorkItem { [weak self] in
            self?.finish(path: path, shouldFail: shouldFail)
        }
        workItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }

    override func stopLoading() {
        workItem?.cancel()
        completeOnce {
            Self.recordCompletion()
        }
    }

    private func finish(path: String, shouldFail: Bool) {
        completeOnce {
            Self.recordCompletion()
            if shouldFail {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            } else if let url = request.url {
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("ok:\(path)".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func completeOnce(_ body: () -> Void) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        stateLock.unlock()
        body()
    }

    private static func recordCompletion() {
        lock.lock()
        active -= 1
        completed += 1
        lock.unlock()
    }
}
