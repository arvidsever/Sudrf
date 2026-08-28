import XCTest
@testable import SudrfKit

final class CaptchaTokenStoreTests: XCTestCase {

    func testStoreAndLookupNormalizesHostForm() async {
        let store = CaptchaTokenStore()
        let token = CaptchaToken(value: "1234", id: "999888777")
        await store.store(token, domain: "anninsky.vrn.sudrf.ru")   // точечная форма

        let hit = await store.token(forDomain: "anninsky--vrn.sudrf.ru")  // дефисная
        XCTAssertEqual(hit, token)
    }

    func testInvalidate() async {
        let store = CaptchaTokenStore()
        await store.store(CaptchaToken(value: "1", id: "2"), domain: "x--y.sudrf.ru")
        await store.invalidate(domain: "x.y.sudrf.ru")
        let hit = await store.token(forDomain: "x--y.sudrf.ru")
        XCTAssertNil(hit)
    }

    func testConditionalInvalidateDoesNotRemoveNewerToken() async {
        let store = CaptchaTokenStore()
        let old = CaptchaToken(value: "old", id: "1")
        let newer = CaptchaToken(value: "new", id: "2")
        await store.store(old, domain: "x--y.sudrf.ru")
        await store.store(newer, domain: "x.y.sudrf.ru")

        await store.invalidate(domain: "x--y.sudrf.ru", matching: old)

        let hit = await store.token(forDomain: "x.y.sudrf.ru")
        XCTAssertEqual(hit, newer,
                       "stale response must not invalidate the replacement token")

        await store.invalidate(domain: "x.y.sudrf.ru", matching: newer)
        let removed = await store.token(forDomain: "x--y.sudrf.ru")
        XCTAssertNil(removed, "the matching current token must still be invalidated")
    }

    func testTTLExpiry() async {
        let store = CaptchaTokenStore(ttl: 0.01)
        await store.store(CaptchaToken(value: "1", id: "2",
                                       obtainedAt: Date(timeIntervalSinceNow: -1)),
                          domain: "x--y.sudrf.ru")
        let hit = await store.token(forDomain: "x--y.sudrf.ru")
        XCTAssertNil(hit)
    }

    func testSeparateCourtsSeparateTokens() async {
        let store = CaptchaTokenStore()
        await store.store(CaptchaToken(value: "1", id: "2"), domain: "a--b.sudrf.ru")
        let other = await store.token(forDomain: "c--d.sudrf.ru")
        XCTAssertNil(other)
    }
}
