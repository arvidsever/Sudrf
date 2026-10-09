import Foundation
import XCTest
@testable import SudrfKit

private final class UnexpectedNetworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTFail("Unexpected network request in offline provider test: \(request.url?.absoluteString ?? "<missing URL>")")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

enum TestNetworkGuard {
    static func sudrfClient() -> SudrfClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedNetworkURLProtocol.self]
        return SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                           variantStore: WorkingVariantStore(cacheURL: nil),
                           captchaStore: CaptchaTokenStore())
    }
}
