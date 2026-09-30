import CryptoKit
import Foundation
import XCTest
@testable import SudrfKit

final class ActFileLoaderTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        ActFileURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActFileURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        try super.tearDownWithError()
    }

    func testExtractsValidPDFDOCAndDOCXWithSanitizedProvenance() async throws {
        let inputs: [(String, PublishedActFormat, String)] = [
            ("valid.pdf", .pdf, "application/pdf"),
            ("valid.doc", .doc, "application/msword"),
            ("valid.docx", .docx,
             "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        ]
        let loader = ActFileLoader(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let source = URL(string: "https://mos-gorsud.ru/mgs/cases/docs/content/abc?token=secret#part")!
        let final = URL(string: "https://www.mos-gorsud.ru/mgs/cases/docs/content/abc?ignored=1#x")!

        for (name, format, contentType) in inputs {
            let result = try await loader.extract(
                data: try fixtureData(name), sourceURL: source, finalURL: final,
                contentType: contentType + "; charset=binary")
            XCTAssertEqual(result.provenance.format, format, name)
            XCTAssertEqual(result.provenance.contentType, contentType, name)
            XCTAssertEqual(result.provenance.sourceURL.absoluteString,
                           "https://mos-gorsud.ru/mgs/cases/docs/content/abc", name)
            XCTAssertEqual(result.provenance.finalURL.absoluteString,
                           "https://www.mos-gorsud.ru/mgs/cases/docs/content/abc", name)
            XCTAssertEqual(result.provenance.extractorVersion, 1, name)
            XCTAssertTrue(result.text.contains("Тестовый судебный акт"), name)
            XCTAssertEqual(result.provenance.contentHash, sha256(try fixtureData(name)), name)
        }
    }

    func testGenericMIMESucceedsOnlyWhenBytesAreVerified() async throws {
        let client = MosGorSudClient(session: session, minInterval: 0)
        let data = try fixtureData("valid.docx")
        ActFileURLProtocol.set(Response(data: data, contentType: "Application/Octect-Stream; charset=binary"))

        let result = try await client.fetchPublishedAct(url: Self.testURL)
        XCTAssertEqual(result.provenance.format, .docx)
        XCTAssertEqual(result.provenance.contentType, "application/octect-stream")
        XCTAssertTrue(result.text.contains("Тестовый судебный акт"))
    }

    func testVSRFFetchReturnsPDFBytesAndRejectsUnsafeLinks() async throws {
        let client = VSRFClient(session: session, minInterval: 0)
        let data = try fixtureData("valid.pdf")
        let url = Self.vsrfTestURL
        ActFileURLProtocol.set(Response(data: data, contentType: "application/pdf"))

        let result = try await client.fetchPublishedAct(url: url)
        XCTAssertEqual(result.data, data)
        XCTAssertEqual(result.provenance.format, .pdf)
        XCTAssertEqual(result.provenance.sourceURL, url)
        XCTAssertEqual(result.provenance.contentHash, sha256(data))

        let beforeUnsafeRequests = ActFileURLProtocol.requestCount()
        for unsafe in [
            URL(string: "http://www.vsrf.ru/lk/practice/stor_pdf/123")!,
            URL(string: "https://evil.vsrf.ru/lk/practice/stor_pdf/123")!,
            URL(string: "https://www.vsrf.ru/lk/practice/cases/123")!,
            URL(string: "https://user:secret@www.vsrf.ru/lk/practice/stor_pdf/123")!
        ] {
            await assertError(.unsafeSourceURL) {
                try await client.fetchPublishedAct(url: unsafe)
            }
        }
        XCTAssertEqual(ActFileURLProtocol.requestCount(), beforeUnsafeRequests)
    }

    func testVSRFFetchRejectsHTMLAndUnsafeFinalHost() async throws {
        let client = VSRFClient(session: session, minInterval: 0)
        ActFileURLProtocol.set(Response(data: Data("<html>challenge</html>".utf8),
                                         contentType: "text/html"))
        await assertError(.htmlResponse) {
            try await client.fetchPublishedAct(url: Self.vsrfTestURL)
        }

        ActFileURLProtocol.set(Response(
            data: try fixtureData("valid.pdf"),
            finalURL: URL(string: "https://example.test/final.pdf")!,
            contentType: "application/pdf"))
        await assertError(.unsafeFinalURL) {
            try await client.fetchPublishedAct(url: Self.vsrfTestURL)
        }

        ActFileURLProtocol.set(Response(data: try fixtureData("valid.pdf"),
                                         contentType: "text/plain"))
        await assertError(.incompatibleContentType) {
            try await client.fetchPublishedAct(url: Self.vsrfTestURL)
        }

        ActFileURLProtocol.set(Response(
            data: try fixtureData("valid.docx"),
            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"))
        await assertError(.unsupportedFormat) {
            try await client.fetchPublishedAct(url: Self.vsrfTestURL)
        }
    }

    func testOnlyVSRFFlowAcceptsPDFWithoutExtractedText() async throws {
        let data = makePDF(text: nil)
        let loader = ActFileLoader()
        let result = try await loader.extract(
            data: data, sourceURL: Self.vsrfTestURL, finalURL: Self.vsrfTestURL,
            contentType: "application/pdf", allowEmptyPDFText: true)
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertEqual(result.data, data)

        await assertError(.noExtractableText) {
            try await loader.extract(
                data: data, sourceURL: Self.testURL, finalURL: Self.testURL,
                contentType: "application/pdf")
        }
    }

    func testReadableConflictingProductionNumberIsRejected() async throws {
        let loader = ActFileLoader()
        let pdf = makePDF(text: "3-KG24-1-K3")
        await assertError(.productionNumberMismatch) {
            try await loader.extract(
                data: pdf, sourceURL: Self.vsrfTestURL, finalURL: Self.vsrfTestURL,
                contentType: "application/pdf", allowEmptyPDFText: true,
                expectedProductionNumber: "3-KG23-1-K3")
        }
        await assertError(.productionNumberMismatch) {
            try await loader.extract(
                data: makePDF(text: "3-KG24-1-K3; cited 3-KG23-1-K3"),
                sourceURL: Self.vsrfTestURL, finalURL: Self.vsrfTestURL,
                contentType: "application/pdf", allowEmptyPDFText: true,
                expectedProductionNumber: "3-KG23-1-K3")
        }

        let matching = try await loader.extract(
            data: makePDF(text: "11RS0001-01-2024-000123-45 3-KG23-1-K3"), sourceURL: Self.vsrfTestURL,
            finalURL: Self.vsrfTestURL, contentType: "application/pdf",
            allowEmptyPDFText: true, expectedProductionNumber: "3-kg23-1-k3")
        XCTAssertTrue(matching.text.contains("3-KG23-1-K3"))
    }

    func testActFileCacheWritesAndRevalidatesPDFBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sudrf-act-cache-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ActFileCache(directory: directory)
        let data = try fixtureData("valid.pdf")
        let file = try await ActFileLoader().extract(
            data: data, sourceURL: Self.vsrfTestURL, finalURL: Self.vsrfTestURL,
            contentType: "application/pdf", allowEmptyPDFText: true)

        let wrongHash = PublishedActProvenance(
            sourceURL: file.provenance.sourceURL, finalURL: file.provenance.finalURL,
            format: .pdf, contentType: file.provenance.contentType,
            contentHash: String(repeating: "0", count: 64), byteCount: data.count,
            fetchedAt: file.provenance.fetchedAt,
            extractorVersion: file.provenance.extractorVersion)
        let wrongHashFile = PublishedActFile(text: file.text, provenance: wrongHash, data: data)
        await assertError(.extractionFailed) {
            try await cache.save(file: wrongHashFile)
        }
        let wrongLength = PublishedActProvenance(
            sourceURL: file.provenance.sourceURL, finalURL: file.provenance.finalURL,
            format: .pdf, contentType: file.provenance.contentType,
            contentHash: file.provenance.contentHash, byteCount: data.count + 1,
            fetchedAt: file.provenance.fetchedAt,
            extractorVersion: file.provenance.extractorVersion)
        await assertError(.extractionFailed) {
            try await cache.save(file: PublishedActFile(
                text: file.text, provenance: wrongLength, data: data))
        }

        let savedURL = try await cache.save(file: file)
        XCTAssertEqual(try Data(contentsOf: savedURL), data)
        let loaded = await cache.load(provenance: file.provenance)
        XCTAssertEqual(loaded, data)
        let cachedURL = await cache.fileURL(provenance: file.provenance)
        XCTAssertEqual(cachedURL, savedURL)

        try Data("changed".utf8).write(to: savedURL)
        let corruptedData = await cache.load(provenance: file.provenance)
        XCTAssertNil(corruptedData)
        let corruptedURL = await cache.fileURL(provenance: file.provenance)
        XCTAssertNil(corruptedURL)
    }

    func testVSRFRedirectDelegateStopsInsecureAndOffPortalRedirects() throws {
        let delegate = VSRFTLSDelegate(trustVSRFCertificate: false)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: Self.vsrfTestURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: Self.vsrfTestURL, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/next"]))

        func redirected(_ value: String) -> URLRequest? {
            var result: URLRequest?
            delegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: value)!),
                completionHandler: { result = $0 })
            return result
        }

        XCTAssertNotNil(redirected("https://vsrf.ru/next"))
        XCTAssertNotNil(redirected("https://www.vsrf.ru/next"))
        XCTAssertNil(redirected("https://evil.vsrf.ru/next"))
        XCTAssertNil(redirected("http://www.vsrf.ru/next"))
        XCTAssertNil(redirected("https://user:secret@www.vsrf.ru/next"))
    }

    func testRejectsHTMLAndExplicitlyIncompatibleMIME() async throws {
        let loader = ActFileLoader()
        let html = try fixtureData("html-response.html")
        await assertError(.htmlResponse) {
            try await loader.extract(data: html, sourceURL: Self.testURL, finalURL: Self.testURL,
                                     contentType: "application/octet-stream")
        }

        let pdf = try fixtureData("valid.pdf")
        await assertError(.incompatibleContentType) {
            try await loader.extract(data: pdf, sourceURL: Self.testURL, finalURL: Self.testURL,
                                     contentType: "text/plain")
        }
    }

    func testAcceptsPDFHeaderWithinPermittedPreamble() async throws {
        let loader = ActFileLoader()
        let pdf = Data(repeating: 0, count: 32) + (try fixtureData("valid.pdf"))
        let result = try await loader.extract(
            data: pdf, sourceURL: Self.testURL, finalURL: Self.testURL,
            contentType: "application/octet-stream")
        XCTAssertEqual(result.provenance.format, .pdf)
        XCTAssertTrue(result.text.contains("Тестовый судебный акт"))
    }

    func testCaptchaWordInValidPDFPreambleIsNotMistakenForHTML() async throws {
        let loader = ActFileLoader()
        let pdf = Data("benign captcha diagnostic\n".utf8) + (try fixtureData("valid.pdf"))
        let result = try await loader.extract(
            data: pdf, sourceURL: Self.testURL, finalURL: Self.testURL,
            contentType: "application/octet-stream")
        XCTAssertEqual(result.provenance.format, .pdf)
        XCTAssertTrue(result.text.contains("Тестовый судебный акт"))
    }

    func testRejectsFakeDOCXAndLocalLimits() async throws {
        let loader = ActFileLoader()
        let fakeZip = Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0, count: 48)
        await assertError(.unsafeDOCX) {
            try await loader.extract(data: fakeZip, sourceURL: Self.testURL, finalURL: Self.testURL,
                                     contentType: "application/octet-stream")
        }

        let pdf = try fixtureData("valid.pdf")
        let tooSmall = ActFileLoader(limits: .init(
            maxDownloadBytes: pdf.count - 1, maxExtractedTextBytes: 5 * 1024 * 1024,
            maxPDFPages: 500, maxDOCXEntries: 512, maxDOCXUncompressedBytes: 40 * 1024 * 1024,
            maxDOCXCompressionRatio: 100))
        await assertError(.downloadTooLarge(limit: pdf.count - 1)) {
            try await tooSmall.extract(data: pdf, sourceURL: Self.testURL, finalURL: Self.testURL,
                                       contentType: "application/pdf")
        }

        let noPagesAllowed = ActFileLoader(limits: .init(
            maxDownloadBytes: 25 * 1024 * 1024, maxExtractedTextBytes: 5 * 1024 * 1024,
            maxPDFPages: 0, maxDOCXEntries: 512, maxDOCXUncompressedBytes: 40 * 1024 * 1024,
            maxDOCXCompressionRatio: 100))
        await assertError(.tooManyPDFPages(limit: 0)) {
            try await noPagesAllowed.extract(data: pdf, sourceURL: Self.testURL, finalURL: Self.testURL,
                                             contentType: "application/pdf")
        }
    }

    func testRejectsUnsafeDOCXCentralDirectoryVariants() async throws {
        let original = try fixtureData("valid.docx")
        let eocd = try zipEndOfCentralDirectory(in: original)
        let central = Int(try readUInt32(original, at: eocd + 16))
        let local = Int(try readUInt32(original, at: central + 42))

        var encrypted = original
        writeUInt16(&encrypted, at: central + 8, value: 0x0001)
        await assertUnsafeDOCX(encrypted)

        var zip64Version = original
        writeUInt16(&zip64Version, at: central + 6, value: 45)
        await assertUnsafeDOCX(zip64Version)

        var unsupportedMethod = original
        writeUInt16(&unsupportedMethod, at: central + 10, value: 12)
        await assertUnsafeDOCX(unsupportedMethod)

        var localNameMismatch = original
        localNameMismatch[local + 30] = 0x58 // X instead of "["
        await assertUnsafeDOCX(localNameMismatch)

        var zip64Extra = original
        writeUInt16(&zip64Extra, at: central + 30, value: 4)
        let extra = central + 46 + Int(try readUInt16(original, at: central + 28))
        writeUInt16(&zip64Extra, at: extra, value: 0x0001)
        writeUInt16(&zip64Extra, at: extra + 2, value: 0)
        await assertUnsafeDOCX(zip64Extra)

        var centralGap = original
        writeUInt32(&centralGap, at: eocd + 12,
                    value: try readUInt32(original, at: eocd + 12) - 1)
        await assertUnsafeDOCX(centralGap)
    }

    func testRejectsDOCXBombAndArchiveBoundaryVariants() async throws {
        let original = try fixtureData("valid.docx")
        let eocd = try zipEndOfCentralDirectory(in: original)
        let central = Int(try readUInt32(original, at: eocd + 16))
        let local = Int(try readUInt32(original, at: central + 42))

        var tooManyEntries = original
        writeUInt16(&tooManyEntries, at: eocd + 8, value: 513)
        writeUInt16(&tooManyEntries, at: eocd + 10, value: 513)
        await assertUnsafeDOCX(tooManyEntries)

        var expandedBomb = original
        writeUInt32(&expandedBomb, at: central + 24, value: 41 * 1024 * 1024)
        await assertUnsafeDOCX(expandedBomb)

        var ratioBomb = original
        writeUInt32(&ratioBomb, at: central + 20, value: 1)
        writeUInt32(&ratioBomb, at: central + 24, value: 101)
        await assertUnsafeDOCX(ratioBomb)

        var traversal = original
        let centralName = central + 46
        traversal[centralName] = 0x2E
        traversal[centralName + 1] = 0x2E
        traversal[centralName + 2] = 0x2F
        await assertUnsafeDOCX(traversal)

        var localSizeMismatch = original
        writeUInt32(&localSizeMismatch, at: local + 18,
                    value: try readUInt32(original, at: local + 18) + 1)
        await assertUnsafeDOCX(localSizeMismatch)

        var missingDataDescriptor = original
        let flags = try readUInt16(original, at: central + 8) | 0x0008
        writeUInt16(&missingDataDescriptor, at: central + 8, value: flags)
        writeUInt16(&missingDataDescriptor, at: local + 6, value: flags)
        writeUInt32(&missingDataDescriptor, at: local + 14, value: 0)
        writeUInt32(&missingDataDescriptor, at: local + 18, value: 0)
        writeUInt32(&missingDataDescriptor, at: local + 22, value: 0)
        await assertUnsafeDOCX(missingDataDescriptor)

        await assertUnsafeDOCX(overlappingLocalEntriesDOCX())
    }

    func testTransportUsesExact200HardLimitAndAllowedFinalHost() async throws {
        let transport = HTMLCourtTransport(
            session: session, userAgent: "SudrfKitTests", minInterval: 0,
            decodingPolicy: .utf8Only, throttleSemantics: .lastRequestStart)
        let body = Data(repeating: 0x41, count: 32)
        ActFileURLProtocol.set(Response(data: body, contentType: "application/octet-stream"))
        await assertError(.downloadTooLarge(limit: 16)) {
            try await transport.fetchFile(
                Self.testURL, maxAttempts: 1,
                allowedHosts: PublishedActURLPolicy.allowedMosGorSudHosts, maxBytes: 16)
        }

        ActFileURLProtocol.set(Response(data: body, status: 201,
                                         contentType: "application/octet-stream"))
        await assertError(.unexpectedHTTPStatus(201)) {
            try await transport.fetchFile(
                Self.testURL, maxAttempts: 1,
                allowedHosts: PublishedActURLPolicy.allowedMosGorSudHosts, maxBytes: 64)
        }

        ActFileURLProtocol.set(Response(data: body, finalURL: URL(string: "https://example.test/file")!,
                                         contentType: "application/octet-stream"))
        await assertError(.unsafeFinalURL) {
            try await transport.fetchFile(
                Self.testURL, maxAttempts: 1,
                allowedHosts: PublishedActURLPolicy.allowedMosGorSudHosts, maxBytes: 64)
        }
    }

    func testRejectsInsecureOrOffPortalRequestBeforeStartingTransport() async throws {
        let client = MosGorSudClient(session: session, minInterval: 0)
        await assertError(.unsafeSourceURL) {
            try await client.fetchPublishedAct(url: URL(string: "http://mos-gorsud.ru/file")!)
        }
        await assertError(.unsafeSourceURL) {
            try await client.fetchPublishedAct(url: URL(string: "https://example.test/file")!)
        }
        await assertError(.unsafeSourceURL) {
            try await client.fetchPublishedAct(
                url: URL(string: "https://user:secret@mos-gorsud.ru/file")!)
        }
        XCTAssertEqual(ActFileURLProtocol.requestCount(), 0)
    }

    func testProductionFileTransportHasBoundedResourceTimeout() {
        let configuration = MosGorSudClient.productionConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 120)
    }

    func testRedirectPolicyAcceptsOnlyExactHTTPSPortalHosts() throws {
        let delegate = SudrfTLSDelegate(
            strictEvaluation: true,
            allowedRedirectHosts: PublishedActURLPolicy.allowedMosGorSudHosts)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: Self.testURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: Self.testURL, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/next"]))

        func redirected(_ value: String) -> URLRequest? {
            var result: URLRequest?
            delegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: value)!),
                completionHandler: { result = $0 })
            return result
        }

        XCTAssertEqual(redirected("https://mos-gorsud.ru/next")?.url?.host, "mos-gorsud.ru")
        XCTAssertEqual(redirected("https://www.mos-gorsud.ru/next")?.url?.host,
                       "www.mos-gorsud.ru")
        XCTAssertNil(redirected("https://example.test/next"))
        XCTAssertNil(redirected("http://mos-gorsud.ru/next"))
        XCTAssertNil(redirected("https://user:secret@mos-gorsud.ru/next"))

        let firstHop = try XCTUnwrap(redirected("https://www.mos-gorsud.ru/next"))
        var secondHop: URLRequest?
        delegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.test/final")!),
            completionHandler: { secondHop = $0 })
        XCTAssertEqual(firstHop.url?.host, "www.mos-gorsud.ru")
        XCTAssertNil(secondHop)
    }

    private static let testURL = URL(string: "https://mos-gorsud.ru/mgs/cases/docs/content/test-file")!
    private static let vsrfTestURL = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/12345")!

    private func fixtureData(_ name: String) throws -> Data {
        let components = name.split(separator: ".", maxSplits: 1).map(String.init)
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: components[0], withExtension: components.count == 2 ? components[1] : nil,
            subdirectory: "Fixtures/file-acts"), "Нет fixture \(name)")
        return try Data(contentsOf: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makePDF(text: String?) -> Data {
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        func appendObject(_ number: Int, _ body: String) {
            offsets.append(data.count)
            data.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }
        appendObject(1, "<< /Type /Catalog /Pages 2 0 R >>")
        appendObject(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        appendObject(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " +
                     "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>")
        let stream = text.map { "BT /F1 12 Tf 72 720 Td (\($0)) Tj ET" } ?? ""
        appendObject(4, "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        appendObject(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let xref = data.count
        data.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func assertUnsafeDOCX(_ data: Data) async {
        let loader = ActFileLoader()
        await assertError(.unsafeDOCX) {
            try await loader.extract(data: data, sourceURL: Self.testURL, finalURL: Self.testURL,
                                     contentType: "application/octet-stream")
        }
    }

    private func zipEndOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else { throw CocoaError(.fileReadCorruptFile) }
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            if try readUInt32(data, at: offset) == 0x06054B50 { return offset }
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    private func readUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private func writeUInt16(_ data: inout Data, at offset: Int, value: UInt16) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func overlappingLocalEntriesDOCX() -> Data {
        let firstName = Data("[Content_Types].xml".utf8)
        let secondName = Data("_rels/.rels".utf8)
        var data = Data(repeating: 0, count: 200)

        writeLocalEntry(&data, at: 0, name: firstName, compressedSize: 120,
                        uncompressedSize: 120)
        writeLocalEntry(&data, at: 80, name: secondName, compressedSize: 0,
                        uncompressedSize: 0)

        let centralOffset = data.count
        appendCentralEntry(&data, name: firstName, localOffset: 0,
                           compressedSize: 120, uncompressedSize: 120)
        appendCentralEntry(&data, name: secondName, localOffset: 80,
                           compressedSize: 0, uncompressedSize: 0)
        let centralSize = data.count - centralOffset
        appendUInt32(&data, 0x06054B50)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, 2)
        appendUInt16(&data, 2)
        appendUInt32(&data, UInt32(centralSize))
        appendUInt32(&data, UInt32(centralOffset))
        appendUInt16(&data, 0)
        return data
    }

    private func writeLocalEntry(_ data: inout Data, at offset: Int, name: Data,
                                 compressedSize: UInt32, uncompressedSize: UInt32) {
        writeUInt32(&data, at: offset, value: 0x04034B50)
        writeUInt16(&data, at: offset + 4, value: 20)
        writeUInt16(&data, at: offset + 6, value: 0)
        writeUInt16(&data, at: offset + 8, value: 0)
        writeUInt32(&data, at: offset + 14, value: 0)
        writeUInt32(&data, at: offset + 18, value: compressedSize)
        writeUInt32(&data, at: offset + 22, value: uncompressedSize)
        writeUInt16(&data, at: offset + 26, value: UInt16(name.count))
        writeUInt16(&data, at: offset + 28, value: 0)
        data.replaceSubrange((offset + 30)..<(offset + 30 + name.count), with: name)
    }

    private func appendCentralEntry(_ data: inout Data, name: Data, localOffset: UInt32,
                                    compressedSize: UInt32, uncompressedSize: UInt32) {
        appendUInt32(&data, 0x02014B50)
        appendUInt16(&data, 20)
        appendUInt16(&data, 20)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt32(&data, 0)
        appendUInt32(&data, compressedSize)
        appendUInt32(&data, uncompressedSize)
        appendUInt16(&data, UInt16(name.count))
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt16(&data, 0)
        appendUInt32(&data, 0)
        appendUInt32(&data, localOffset)
        data.append(name)
    }

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func assertError(_ expected: PublishedActFileError,
                             _ operation: () async throws -> Any) async {
        do {
            _ = try await operation()
            XCTFail("Ожидалась ошибка \(expected)")
        } catch let error as PublishedActFileError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Ожидалась PublishedActFileError, получено: \(error)")
        }
    }
}

private struct Response {
    let data: Data
    var status: Int = 200
    var finalURL: URL? = nil
    var contentType: String
}

private final class ActFileURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var response = Response(
        data: Data(), contentType: "application/octet-stream")
    nonisolated(unsafe) private static var count = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        response = Response(data: Data(), contentType: "application/octet-stream")
        count = 0
    }

    static func set(_ next: Response) {
        lock.lock(); defer { lock.unlock() }
        response = next
    }

    static func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    private static func current() -> Response {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return response
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.current()
        let http = HTTPURLResponse(
            url: response.finalURL ?? request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": response.contentType,
                           "Content-Length": String(response.data.count)])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
