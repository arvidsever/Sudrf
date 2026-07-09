import XCTest
@testable import SudrfApp

final class CaptchaPendingQueueTests: XCTestCase {

    func testDotAndDashHostsShareOnePendingGroup() {
        var queue = CaptchaPendingQueue()

        queue.add(key: "anninsky.vrn.sudrf.ru/2-1/2026",
                  caseNumber: "2-1/2026",
                  host: "anninsky.vrn.sudrf.ru")
        queue.add(key: "anninsky.vrn.sudrf.ru/2-2/2026",
                  caseNumber: "2-2/2026",
                  host: "anninsky--vrn.sudrf.ru")

        XCTAssertEqual(queue.groups.count, 1)
        XCTAssertEqual(queue.groups.first?.host, "anninsky--vrn.sudrf.ru")
        XCTAssertEqual(queue.groups.first?.keys.count, 2)
        XCTAssertEqual(queue.group(forHost: "anninsky.vrn.sudrf.ru")?.caseNumbers,
                       ["2-1/2026", "2-2/2026"])
    }

    func testDrainReturnsQueuedKeysAndClearsHost() {
        var queue = CaptchaPendingQueue()
        queue.add(key: "a/1", caseNumber: "1", host: "a.b.sudrf.ru")
        queue.add(key: "a/2", caseNumber: "2", host: "a--b.sudrf.ru")

        let drained = queue.drain(host: "a.b.sudrf.ru")

        XCTAssertEqual(drained?.keys, ["a/1", "a/2"])
        XCTAssertNil(queue.group(forHost: "a--b.sudrf.ru"))
    }

    func testMovingKeyBetweenHostsRemovesOldEntry() {
        var queue = CaptchaPendingQueue()
        queue.add(key: "case", caseNumber: "2-1/2026", host: "old.sudrf.ru")
        queue.add(key: "case", caseNumber: "2-1/2026", host: "new.sudrf.ru")

        XCTAssertNil(queue.group(forHost: "old.sudrf.ru"))
        XCTAssertEqual(queue.group(forHost: "new.sudrf.ru")?.keys, ["case"])
    }
}
