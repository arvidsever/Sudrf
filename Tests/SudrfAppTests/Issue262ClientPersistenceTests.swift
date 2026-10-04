import Foundation
import SwiftData
import XCTest
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue262ClientPersistenceTests: XCTestCase {
    func testHTTPCardThroughNativeClientMovementRefreshAndDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        let store = try TrackedStore(container: SudrfModelContainerFactory.make(
            inMemory: false, storeURL: url), prepared: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Тестовый регион",
            searchDomain: "acceptance262--test.sudrf.ru", displayDomain: "acceptance262--test.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-262/2026", caseID: "262", caseUID: "fixture-only")
        let key = try store.upsert(context: context, snapshot: nil, collections: []).key
        for judge in ["Судья A", "Судья B", "Судья B"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Issue262CardHTTP.self]
            configuration.httpAdditionalHeaders = ["X-Fixture-Judge": judge]
            let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                                     variantStore: WorkingVariantStore(cacheURL: nil),
                                     captchaStore: CaptchaTokenStore())
            let service = MovementService(client: client)
            let center = RefreshCenter(store: store, client: client, serviceBuilder: { _ in service })
            let result = await center.refresh(key: key)?.value
            XCTAssertEqual(result?.outcome, .refreshed)
        }
        let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(
            inMemory: false, storeURL: url), prepared: true)
        let saved = try XCTUnwrap(reopened.record(forKey: key))
        XCTAssertEqual(saved.movement?.instances.first?.judge, "Судья B")
        XCTAssertEqual(saved.eventJournal?.events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(saved.eventJournal?.events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(saved.eventJournal?.events.first?.evidence.value, "Судья B")
        XCTAssertNil(saved.movement?.sourceRefreshCoverage, "fresh proof is never reused from disk")
        XCTAssertEqual(saved.eventJournal?.semanticBaselines?.courts.count, 1)
    }
}

private final class Issue262CardHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "acceptance262--test.sudrf.ru",
              let judge = request.value(forHTTPHeaderField: "X-Fixture-Judge") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let html = """
        <html><body><div class="casenumber">ДЕЛО № 2-262/2026</div>
        <div id="cont1"><table id="tablcont">
        <tr><th colspan="2">ДЕЛО</th></tr>
        <tr><td>Уникальный идентификатор дела</td><td></td></tr>
        <tr><td>Судья</td><td>\(judge)</td></tr></table></div></body></html>
        """
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
