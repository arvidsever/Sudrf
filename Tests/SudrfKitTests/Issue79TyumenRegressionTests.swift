import XCTest
@testable import SudrfKit

final class Issue79TyumenFixtureTests: XCTestCase {
    private let court = Court(
        domain: "leninsky--tum.sudrf.ru",
        title: "Ленинский районный суд г. Тюмени",
        level: .district
    )

    func testUserArchiveSearchFormRemainsCaptcha() throws {
        let html = try fixture("leninsky_tyumen_search_form")

        XCTAssertTrue(CaptchaDetector.hasCaptcha(in: html))
        guard case .captcha = SearchPageClassifier.classify(html: html) else {
            return XCTFail("Форма из пользовательского WebArchive должна оставаться CAPTCHA-страницей")
        }
    }

    func testUserArchiveResultsKeepThreeCasesAndCanonicalCardHosts() throws {
        let html = try fixture("leninsky_tyumen_results")

        guard case .results = SearchPageClassifier.classify(html: html) else {
            return XCTFail("Выдача из пользовательского WebArchive должна распознаваться как results")
        }
        let rows = try ResultsParser.parse(html: html, court: court)

        XCTAssertEqual(rows.map(\.caseNumber), [
            "2-5322/2026 ~ М-2791/2026",
            "2-3891/2026 ~ М-1817/2026",
            "9-542/2026 ~ М-866/2026",
        ])
        XCTAssertEqual(Set(rows.compactMap(\.cardURL?.host)), [court.domain])
    }

    func testUserArchiveCardKeepsMovementAndAppealShape() throws {
        let card = try CaseCardParser.parse(html: fixture("leninsky_tyumen_card"))

        XCTAssertEqual(card.caseNumber, "2-3891/2026 ~ М-1817/2026")
        XCTAssertEqual(card.sessions.count, 10)
        XCTAssertEqual(card.sessions.first?.event, "Регистрация иска (заявления, жалобы) в суде")
        XCTAssertEqual(card.sessions.last?.event, "Дело сдано в отдел судебного делопроизводства")
        XCTAssertEqual(card.appeals.count, 1)
        XCTAssertEqual(card.appeals.first?.kind, .appeal)
        XCTAssertEqual(
            card.appeals.first?.rawKind,
            "Апелляционная жалоба (на не вступивший в силу судебный акт)"
        )
        XCTAssertEqual(card.appeals.first?.higherCourt, "Тюменский областной суд")
        XCTAssertEqual(card.appeals.first?.sentUpDate, "03.07.2026")
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "html",
            subdirectory: "Fixtures"
        ))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class Issue79CanonicalResponseURLTests: XCTestCase {
    private var session: URLSession!
    private var diagnosticsDir: URL!
    private var originalDiagnosticsDir: URL!
    private var originalDiagnosticsEnabled = false

    private let court = Court(
        domain: "legacy--tum.sudrf.ru",
        title: "Тестовый суд",
        level: .district
    )
    private let cartoteka = Cartoteka(
        id: "g1",
        title: "Гражданское",
        prefixes: ["2"],
        deloID: "1540005",
        deloTable: "g1_case",
        caseNumberField: "g1_case__CASE_NUMBERSS",
        uidField: "g1_case__JUDICIAL_UIDSS",
        nameField: "G1_PARTS__NAMESS"
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        CanonicalResponseURLStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CanonicalResponseURLStub.self]
        session = URLSession(configuration: configuration)

        diagnosticsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Issue79CanonicalResponseURLTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: diagnosticsDir, withIntermediateDirectories: true)
        originalDiagnosticsDir = SearchDiagnostics.setDirForTesting(diagnosticsDir)
        originalDiagnosticsEnabled = SearchDiagnostics.enabled
        SearchDiagnostics.enabled = true
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        SearchDiagnostics.enabled = originalDiagnosticsEnabled
        SearchDiagnostics.setDirForTesting(originalDiagnosticsDir)
        try? FileManager.default.removeItem(at: diagnosticsDir)
        CanonicalResponseURLStub.reset()
        try super.tearDownWithError()
    }

    func testResultsResolveRelativeCardURLsAgainstFinalResponseHost() async throws {
        CanonicalResponseURLStub.body = try fixtureData("leninsky_tyumen_results")
        CanonicalResponseURLStub.finalURL = URL(
            string: "https://leninsky--tum.sudrf.ru/modules.php?name=sud_delo&name_op=r"
        )!
        let tokenStore = CaptchaTokenStore()
        await tokenStore.store(CaptchaToken(value: "redacted", id: "redacted"), domain: court.domain)
        let client = SudrfClient(
            session: session,
            minInterval: 0,
            variantStore: WorkingVariantStore(),
            captchaStore: tokenStore
        )
        await client.setMaxAttemptsForTesting(1)

        let rows = try await client.search(
            court: court,
            cartoteka: cartoteka,
            field: .caseNumber,
            value: "2-3891/2026"
        )

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.compactMap(\.cardURL?.host)), ["leninsky--tum.sudrf.ru"])
        XCTAssertEqual(Set(CanonicalResponseURLStub.requestHosts), [court.domain])
    }

    func testCaptchaContinuationUsesFinalResponseHost() async throws {
        CanonicalResponseURLStub.body = try fixtureData("leninsky_tyumen_search_form")
        CanonicalResponseURLStub.finalURL = URL(
            string: "https://leninsky--tum.sudrf.ru/modules.php?name=sud_delo&name_op=sf&delo_id=1540005"
        )!
        let client = SudrfClient(
            session: session,
            minInterval: 0,
            variantStore: WorkingVariantStore(),
            captchaStore: CaptchaTokenStore()
        )
        await client.setMaxAttemptsForTesting(1)

        do {
            _ = try await client.search(
                court: court,
                cartoteka: cartoteka,
                field: .caseNumber,
                value: "2-3891/2026"
            )
            XCTFail("Ожидалась CAPTCHA")
        } catch SudrfError.captchaRequired(let formURL) {
            XCTAssertEqual(formURL.host, "leninsky--tum.sudrf.ru")
            XCTAssertEqual(formURL.query?.contains("name_op=sf"), true)
        }
    }

    func testUnknownResponseUsesFinalHostInErrorAndVerbatimDiagnostic() async throws {
        let raw = Data([0x3C, 0x68, 0x31, 0x3E, 0xFF, 0x3C, 0x2F, 0x68, 0x31, 0x3E])
        CanonicalResponseURLStub.body = raw
        CanonicalResponseURLStub.contentType = "text/html; charset=windows-1251"
        CanonicalResponseURLStub.finalURL = URL(
            string: "https://leninsky--tum.sudrf.ru/modules.php?name=sud_delo&name_op=r"
        )!
        let tokenStore = CaptchaTokenStore()
        await tokenStore.store(CaptchaToken(value: "redacted", id: "redacted"), domain: court.domain)
        let client = SudrfClient(
            session: session,
            minInterval: 0,
            variantStore: WorkingVariantStore(),
            captchaStore: tokenStore
        )
        await client.setMaxAttemptsForTesting(1)

        do {
            _ = try await client.search(
                court: court,
                cartoteka: cartoteka,
                field: .caseNumber,
                value: "2-3891/2026"
            )
            XCTFail("Неизвестная страница не должна считаться пустой выдачей")
        } catch SudrfError.searchModuleUnavailable(let domain) {
            XCTAssertEqual(domain, "leninsky--tum.sudrf.ru")
        }

        let diagnostics = try FileManager.default.contentsOfDirectory(
            at: diagnosticsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix("_variant.html") }
        XCTAssertFalse(diagnostics.isEmpty)
        XCTAssertTrue(diagnostics.allSatisfy {
            $0.lastPathComponent.hasPrefix("leninsky--tum.sudrf.ru_")
        })
        XCTAssertTrue(try diagnostics.allSatisfy { try Data(contentsOf: $0) == raw })

        let message = SudrfError.searchModuleUnavailable(domain: "leninsky--tum.sudrf.ru").description
        XCTAssertTrue(message.contains("не считается пустой выдачей"))
        XCTAssertFalse(message.contains("JS-защита"))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "html",
            subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }
}

private final class CanonicalResponseURLStub: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var finalURL: URL?
    nonisolated(unsafe) static var contentType = "text/html; charset=utf-8"
    nonisolated(unsafe) static var requestHosts: [String] = []

    static func reset() {
        body = Data()
        finalURL = nil
        contentType = "text/html; charset=utf-8"
        requestHosts = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestHosts.append(request.url?.host ?? "")
        let response = HTTPURLResponse(
            url: Self.finalURL ?? request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
