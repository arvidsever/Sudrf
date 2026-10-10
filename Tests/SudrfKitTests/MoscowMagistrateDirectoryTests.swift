import Foundation
import XCTest
@testable import SudrfKit

final class MoscowMagistrateDirectoryTests: XCTestCase {
    private func fixture() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "moscow_magistrate_directory", withExtension: "html", subdirectory: "Fixtures"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPublishedDirectoryKeepsNativeIdentityFieldsAndFiltersCanceledUnits() throws {
        let all = try MoscowMagistrateDirectoryParser.parse(html: fixture())
        let active = all.filter(\.isActive)

        XCTAssertEqual(all.count, 476)
        XCTAssertEqual(active.count, 471)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.code)).count, all.count)
        XCTAssertEqual(Set(all.map(\.alias)).count, all.count)
        XCTAssertEqual(Set(all.compactMap(\.unitPathID)).count, all.count)
        XCTAssertLessThan(Set(all.map(\.rsCourtId)).count, all.count,
                          "rsCourtId группирует несколько участков и не является их ключом")

        let unit424 = try XCTUnwrap(all.first { $0.unitPathID == "424" })
        XCTAssertEqual(unit424.alias, "424")
        XCTAssertEqual(unit424.code, "77MS0424")
        XCTAssertEqual(URL(string: unit424.url)?.path, "/rs/424")
        XCTAssertEqual(unit424.magistrateCourt.domain, "mos-sud.ru")
        XCTAssertEqual(unit424.magistrateCourt.title, unit424.courtFullNameWithMunicipal)
        XCTAssertFalse(unit424.magistrateCourt.isSupported,
                       "mos-sud.ru не должен попадать в обычный клиент *.msudrf.ru")

        let canceled = try XCTUnwrap(all.first { $0.unitPathID == "480" })
        XCTAssertFalse(canceled.isActive)
        XCTAssertFalse(active.contains { $0.unitPathID == "480" })
        XCTAssertTrue(all.contains { $0.code == "77MS02-388" },
                      "классификационный код хранится как опубликован, без нормализации")
    }

    func testParserDerivesUnitPathIDOnlyFromCanonicalPublishedURL() throws {
        let html = syntheticPage([
            row(url: "https://mos-sud.ru/rs/424", alias: "0424", code: "77MS0424",
                id: "id-a", rsCourtId: "shared"),
            row(url: "https://mos-sud.ru/rs/3910", alias: "historic-391", code: "77MS0391",
                id: "id-b", rsCourtId: "shared")
        ])

        let units = try MoscowMagistrateDirectoryParser.parse(html: html)
        XCTAssertEqual(units.map(\.unitPathID), ["424", "3910"])
        XCTAssertEqual(units.map(\.alias), ["0424", "historic-391"])
        XCTAssertEqual(units.map(\.code), ["77MS0424", "77MS0391"])
        XCTAssertEqual(units.map(\.rsCourtId), ["shared", "shared"])
    }

    func testParserRejectsMissingArrayNoncanonicalURLAndDuplicatePath() {
        XCTAssertThrowsError(try MoscowMagistrateDirectoryParser.parse(
            html: "<script>window.state = { currentCourt: '' };</script>"))

        let external = syntheticPage([
            row(url: "https://example.org/rs/424", alias: "424", code: "77MS0424",
                id: "id-a", rsCourtId: "group")
        ])
        XCTAssertThrowsError(try MoscowMagistrateDirectoryParser.parse(html: external))

        let duplicates = syntheticPage([
            row(url: "https://mos-sud.ru/rs/424", alias: "424", code: "77MS0424",
                id: "id-a", rsCourtId: "group"),
            row(url: "https://mos-sud.ru/rs/424", alias: "424-copy", code: "77MS0425",
                id: "id-b", rsCourtId: "group")
        ])
        XCTAssertThrowsError(try MoscowMagistrateDirectoryParser.parse(html: duplicates))

        let duplicateRow = row(url: "https://mos-sud.ru/rs/424", alias: "424", code: "77MS0424",
                               id: "id-a", rsCourtId: "group")
        let duplicateMarkers = "<script>window.state = { courts: [\(duplicateRow)], courts: [\(duplicateRow)] };</script>"
        XCTAssertThrowsError(try MoscowMagistrateDirectoryParser.parse(html: duplicateMarkers))
    }

    func testResolverLoadsCurrentMoscowRowsAndReplacesStaleSubjectCache() async throws {
        let cacheURL = try temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let staleMoscow = MagistrateCourt(title: "Агрегат Москвы", domain: "mos-sud.ru",
                                          code: "77MS0000", portalSubject: "77")
        let otherRegion = MagistrateCourt(title: "Сохранённый участок Коми",
                                          domain: "saved.komi.msudrf.ru",
                                          code: "11MS0001", portalSubject: "11")
        try JSONEncoder().encode([staleMoscow, otherRegion]).write(to: cacheURL)

        MoscowMagistrateDirectoryStub.reset(body: try fixture())
        let resolver = try makeResolver(cacheURL: cacheURL)
        let courts = try await resolver.courts(forSubjectCode: "77")
        let units = try await resolver.moscowUnits()

        XCTAssertEqual(courts.count, 471)
        XCTAssertEqual(units.count, 471)
        XCTAssertEqual(MoscowMagistrateDirectoryStub.requestURLs(), [MoscowMagistrateKoAPSource.homeURL])
        XCTAssertTrue(courts.contains { $0.code == "77MS0424" && $0.domain == "mos-sud.ru" })
        XCTAssertFalse(courts.contains { $0.title == "Агрегат Москвы" })

        let persisted = try JSONDecoder().decode([MagistrateCourt].self,
                                                 from: Data(contentsOf: cacheURL))
        XCTAssertTrue(persisted.contains { $0.code == "11MS0001" })
        XCTAssertFalse(persisted.contains { $0.code == "77MS0000" })
        XCTAssertEqual(persisted.filter { $0.portalSubject == "77" }.count, 471)
    }

    func testResolverDoesNotReturnCachedMoscowAggregateWhenSourceIsMalformed() async throws {
        let cacheURL = try temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let staleMoscow = MagistrateCourt(title: "Агрегат Москвы", domain: "mos-sud.ru",
                                          code: "77MS0000", portalSubject: "77")
        try JSONEncoder().encode([staleMoscow]).write(to: cacheURL)
        MoscowMagistrateDirectoryStub.reset(body: "<script>window.state = { courts: [ };</script>")

        let resolver = try makeResolver(cacheURL: cacheURL)
        do {
            _ = try await resolver.courts(forSubjectCode: "77")
            XCTFail("ошибочная выдача не должна возвращать старую агрегированную запись")
        } catch {
            XCTAssertEqual(MoscowMagistrateDirectoryStub.requestURLs(), [MoscowMagistrateKoAPSource.homeURL])
        }
    }

    private func makeResolver(cacheURL: URL) throws -> MagistrateCourtResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoscowMagistrateDirectoryStub.self]
        let client = MoscowMagistrateKoAPClient(session: URLSession(configuration: configuration),
                                                minInterval: 0, maxAttempts: 1)
        return MagistrateCourtResolver(cacheURL: cacheURL, moscowDirectoryClient: client)
    }

    private func temporaryCacheURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoscowMagistrateDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cache.json")
    }

    private func row(url: String, alias: String, code: String, id: String, rsCourtId: String) -> String {
        "{url: \"\(url)\", name: \"Участок мирового судьи № 424\", alias: \"\(alias)\", "
            + "courtFullNameWithMunicipal: \"Участок мирового судьи № 424 (Тестовый округ)\", "
            + "id: \"\(id)\", code: \"\(code)\", rsCourtId: \"\(rsCourtId)\", canceledAt: \"\"}"
    }

    private func syntheticPage(_ rows: [String]) -> String {
        "<script>window.state = { courts: [\(rows.joined(separator: ",")),] };</script>"
    }
}

private final class MoscowMagistrateDirectoryStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = ""
    nonisolated(unsafe) private static var urls: [URL] = []

    static func reset(body: String) {
        lock.lock()
        self.body = body
        urls = []
        lock.unlock()
    }

    static func requestURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.urls.append(url)
        let body = Self.body
        Self.lock.unlock()

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
