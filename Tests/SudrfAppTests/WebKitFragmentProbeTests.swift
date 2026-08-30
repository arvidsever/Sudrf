import XCTest
import WebKit

@MainActor
final class WebKitFragmentProbeTests: XCTestCase {
    func testFragmentSurvivesClickAndFormSubmitNavigationAction() async {
        for method in ["click", "submit", "formaction"] {
            let delegate = FragmentProbeDelegate(method: method)
            let webView = WKWebView()
            webView.navigationDelegate = delegate
            delegate.webView = webView
            let navigationObserved = expectation(description: "navigation action for \(method)")
            let navigationStarted = expectation(description: "didStart for \(method)")
            var actionFragment: String?
            var startedFragment: String?
            delegate.onActionFragment = { fragment in
                actionFragment = fragment
                navigationObserved.fulfill()
            }
            delegate.onStartedFragment = { fragment in
                startedFragment = fragment
                navigationStarted.fulfill()
            }
            delegate.start()
            await fulfillment(of: [navigationObserved, navigationStarted], timeout: 3)
            XCTAssertEqual(actionFragment, "sudrf-attempt-7", method)
            XCTAssertEqual(startedFragment, "sudrf-attempt-7", method)
        }
    }
}

@MainActor
private final class FragmentProbeDelegate: NSObject, WKNavigationDelegate {
    weak var webView: WKWebView?
    let method: String
    var onActionFragment: ((String?) -> Void)?
    var onStartedFragment: ((String?) -> Void)?
    private var submitted = false

    init(method: String) { self.method = method }

    func start() {
        webView?.loadHTMLString("""
            <form action="https://example.test/search" method="get">
              <input name="captcha" value="123"><button id="go" type="submit"
                \(method == "formaction" ? "formaction=\"https://example.test/alternate\"" : "")>Go</button>
            </form>
            """, baseURL: URL(string: "https://example.test/form"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !submitted else { return }
        submitted = true
        webView.evaluateJavaScript("""
            const form = document.querySelector('form');
            const submit = document.getElementById('go');
            const destination = new URL((submit && submit.formAction) || form.action || window.location.href,
                                        window.location.href);
            destination.hash = 'sudrf-attempt-7';
            if (submit && submit.hasAttribute('formaction')) {
              submit.formAction = destination.href;
            } else {
              form.action = destination.href;
            }
            \(method == "submit" ? "form.submit();" : "submit.click();")
            """)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard submitted else { return }
        onStartedFragment?(webView.url?.fragment)
        onStartedFragment = nil
        webView.stopLoading()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard submitted else {
            decisionHandler(.allow)
            return
        }
        let fragment = navigationAction.request.url?.fragment
        decisionHandler(.allow)
        onActionFragment?(fragment)
        onActionFragment = nil
    }
}
