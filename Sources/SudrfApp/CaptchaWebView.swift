//  CaptchaWebView.swift — SudrfApp
//  Всплывающее окно для судов, чья форма поиска защищена кодом с картинки.
//  Приложение НЕ решает капчу: оно открывает настоящую форму суда, код вводит
//  пользователь (как в обычном браузере). Когда пользователь доходит до карточки
//  дела (`name_op=case`), приложение считывает её HTML и передаёт в разбор.
//
//  Поток: открыть форму (УИД подставляется автоматически) → пользователь вводит
//  код и жмёт «Найти» → в выдаче кликает по делу → открывается карточка →
//  onCardHTML(html). Карточка капчей не защищена, поэтому шаг с кодом нужен только
//  чтобы пройти поиск.

import SwiftUI
import WebKit

struct CaptchaSheet: View {
    let context: SearchModel.CaptchaContext
    var onCardHTML: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Код с картинки — \(context.courtTitle)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Введите код и нажмите «Найти», затем откройте нужное дело — "
                       + "карточку приложение подхватит автоматически.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена", action: onCancel)
                    .buttonStyle(.glass)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 14))
            Divider()
            CaptchaWebView(url: context.formURL, uid: context.uid, onCardHTML: onCardHTML)
        }
        .frame(width: 900, height: 680)
    }
}

struct CaptchaWebView: NSViewRepresentable {
    let url: URL
    let uid: String
    var onCardHTML: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: CaptchaWebView
        private var didCapture = false

        init(_ parent: CaptchaWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let current = webView.url?.absoluteString ?? ""

            // На странице карточки — считываем HTML и завершаем.
            if current.contains("name_op=case"), !didCapture {
                webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                    guard let self, let html = result as? String, !self.didCapture else { return }
                    self.didCapture = true
                    self.parent.onCardHTML(html)
                }
                return
            }

            // На форме поиска — подставляем УИД в соответствующее поле.
            if current.contains("name_op=sf") || current.contains("name=sud_delo") {
                let safeUID = parent.uid.replacingOccurrences(of: "'", with: "")
                let js = """
                (function(){var n=document.getElementsByTagName('input');for(var i=0;i<n.length;i++){\
                if(n[i].name&&n[i].name.indexOf('JUDICIAL_UIDSS')>=0){n[i].value='\(safeUID)';}}})();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
}

// Метод обработки серверного сертификата вынесен в extension: так компилятор
// macOS 26 не считает его «почти совпадающим» с опциональным требованием
// WKNavigationDelegate и не выдаёт предупреждение. Логика не изменилась.
extension CaptchaWebView.Coordinator {
    // Российские корневые сертификаты (Минцифры) не входят в доверенное
    // хранилище Apple — принимаем серверный сертификат только для судов sudrf.
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let host = challenge.protectionSpace.host.lowercased()
        if host == "sudrf.ru" || host.hasSuffix(".sudrf.ru") {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
