import XCTest
import SwiftSoup
@testable import SudrfKit

final class CaptchaImageExtractorTests: XCTestCase {

    func testDecodesBase64ImagePayload() {
        let source = Data([0x89, 0x50, 0x4E, 0x47])
        let payload = "data:image/png;base64," + source.base64EncodedString()

        XCTAssertEqual(CaptchaImageExtractor.data(fromDataURL: payload), source)
    }

    func testDecodesPercentEncodedTextPayload() {
        let payload = "data:text/plain,%36%38%39%35%38"
        XCTAssertEqual(CaptchaImageExtractor.data(fromDataURL: payload), Data("68958".utf8))
    }

    func testRejectsNonDataPayload() {
        XCTAssertNil(CaptchaImageExtractor.data(fromDataURL: "https://example.test/captcha.png"))
    }

    func testExtractsInlineCaptchaAndID() throws {
        // 9 байт → 12 символов base64. `Data(base64Encoded:)` строгий
        // и требует длину, кратную 4 — поэтому 9 байт (которые сами
        // дают кратную длину) подходят идеально.
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF])
        let b64 = pngBytes.base64EncodedString()
        let html = """
        <html><body>
          <form>
            <input name="captchaid" type="hidden" value="abc123xyz">
            <img src="data: image/png;base64, \(b64)" style="border:1px solid;">
            <input name="captcha" type="text">
          </form>
        </body></html>
        """
        let result = try CaptchaImageExtractor.extract(html: html)
        XCTAssertEqual(result?.captchaid, "abc123xyz")
        XCTAssertEqual(result?.png, pngBytes)
    }

    func testExtractReturnsNilWithoutCaptchaID() throws {
        let html = "<html><body><form><input name=\"other\"></form></body></html>"
        XCTAssertNil(try CaptchaImageExtractor.extract(html: html))
    }
}
