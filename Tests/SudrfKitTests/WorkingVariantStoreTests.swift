import XCTest
@testable import SudrfKit

final class WorkingVariantStoreTests: XCTestCase {

    private var u1: Cartoteka { CartotekaRegistry.find(level: .district, id: "u1")! }
    private var g1: Cartoteka { CartotekaRegistry.find(level: .district, id: "g1")! }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wvs-test-\(UUID().uuidString).json")
    }

    func testRememberAndLookup() async {
        let store = WorkingVariantStore(cacheURL: tempURL())
        await store.remember(variantID: "vnkod:1540006:0", domain: "anninsky--vrn.sudrf.ru", cartoteka: u1)

        let hit = await store.workingVariantID(domain: "anninsky--vrn.sudrf.ru", cartoteka: u1)
        XCTAssertEqual(hit, "vnkod:1540006:0")

        // Точечная форма хоста нормализуется к дефисной — та же запись.
        let dotForm = await store.workingVariantID(domain: "anninsky.vrn.sudrf.ru", cartoteka: u1)
        XCTAssertEqual(dotForm, "vnkod:1540006:0")

        // Другая картотека того же суда — отдельный ключ.
        let other = await store.workingVariantID(domain: "anninsky--vrn.sudrf.ru", cartoteka: g1)
        XCTAssertNil(other)
    }

    func testForget() async {
        let store = WorkingVariantStore(cacheURL: tempURL())
        await store.remember(variantID: "primary", domain: "x--y.sudrf.ru", cartoteka: u1)
        await store.forget(domain: "x--y.sudrf.ru", cartoteka: u1)
        let hit = await store.workingVariantID(domain: "x--y.sudrf.ru", cartoteka: u1)
        XCTAssertNil(hit)
    }

    func testExpiry() async throws {
        let store = WorkingVariantStore(cacheURL: tempURL(), ttl: 0.05)
        await store.remember(variantID: "primary", domain: "x--y.sudrf.ru", cartoteka: u1)
        try await Task.sleep(nanoseconds: 100_000_000)
        let hit = await store.workingVariantID(domain: "x--y.sudrf.ru", cartoteka: u1)
        XCTAssertNil(hit)
    }

    func testPersistsAcrossInstances() async {
        let url = tempURL()
        let first = WorkingVariantStore(cacheURL: url)
        await first.remember(variantID: "vnkod:41:0", domain: "x--y.sudrf.ru", cartoteka: u1)

        let second = WorkingVariantStore(cacheURL: url)
        let hit = await second.workingVariantID(domain: "x--y.sudrf.ru", cartoteka: u1)
        XCTAssertEqual(hit, "vnkod:41:0")
    }

    func testNilCacheURLWorksInMemory() async {
        let store = WorkingVariantStore(cacheURL: nil)
        await store.remember(variantID: "primary", domain: "x--y.sudrf.ru", cartoteka: u1)
        let hit = await store.workingVariantID(domain: "x--y.sudrf.ru", cartoteka: u1)
        XCTAssertEqual(hit, "primary")
    }
}
