//  CaptchaWebView.swift — SudrfApp
//  Всплывающее окно для судов, чья форма поиска защищена кодом с картинки.
//  Приложение НЕ решает капчу: оно держит настоящую форму суда в скрытом
//  WKWebView, а пользователь видит только картинку и сам вводит код.
//
//  Поток: открыть форму (УИД/№ дела подставляются автоматически) → показать
//  картинку из той же web-сессии → пользователь вводит код → скрытая форма
//  отправляется → приложение сохраняет captcha/captchaid и повторяет поиск.

import AppKit
import SwiftUI
import WebKit
import SudrfKit

struct CaptchaWebView: NSViewRepresentable {
    let url: URL
    let uid: String
    var caseNumber: String? = nil
    var kind: SearchModel.CaptchaContext.Kind = .sudrfToken
    @Binding var captchaImageData: Data?
    let captchaCode: String
    @Binding var submitRequestID: Int
    var onCaptchaReady: () -> Void = {}
    var onSubmissionState: (CaptchaSubmissionState) -> Void = { _ in }
    var onCardHTML: (String) -> Void
    var onCaptchaPair: ((String, CaptchaToken) -> Void)? = nil
    var onSessionUnlocked: ((String) -> Void)? = nil

    var contextKindRequiresToken: Bool { kind == .sudrfToken }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> HiddenCaptchaWebViewHost {
        let host = HiddenCaptchaWebViewHost(navigationDelegate: context.coordinator)
        host.webView.load(URLRequest(url: url))
        return host
    }

    func updateNSView(_ nsView: HiddenCaptchaWebViewHost, context: Context) {
        context.coordinator.parent = self
        let coordinator = context.coordinator
        let webView = nsView.webView
        DispatchQueue.main.async { [weak coordinator, weak webView] in
            guard let webView else { return }
            coordinator?.submitIfNeeded(in: webView)
        }
    }

    typealias Coordinator = CaptchaWebViewCoordinator
}

final class HiddenCaptchaWebViewHost: NSView {
    let webView: WKWebView

    init(navigationDelegate: WKNavigationDelegate) {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: -2000, y: -2000, width: 900, height: 700),
                            configuration: cfg)
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        wantsLayer = true
        layer?.masksToBounds = true
        webView.navigationDelegate = navigationDelegate
        addSubview(webView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        webView.frame = NSRect(x: -2000, y: -2000, width: 900, height: 700)
    }
}
