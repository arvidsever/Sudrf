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
import SudrfKit

struct CaptchaAssistSheet: View {
    let context: SearchModel.CaptchaContext
    var onCardHTML: (String) -> Void
    /// Решённая пользователем пара captcha/captchaid (хост, токен) — форма
    /// отправляется GET-ом, пара видна в URL выдачи и переиспользуется клиентом.
    var onCaptchaPair: ((String, CaptchaToken) -> Void)? = nil
    var onCancel: () -> Void

    @State private var captchaImageURL: URL? = nil
    @State private var assistStatus = "Открою форму, подставлю данные дела и поставлю курсор в поле кода."
    @State private var highContrast = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                CaptchaWebView(url: context.formURL, uid: context.uid,
                               caseNumber: context.caseNumber,
                               captchaImageURL: $captchaImageURL,
                               onAssistStatus: { assistStatus = $0 },
                               onCardHTML: onCardHTML, onCaptchaPair: onCaptchaPair)
                    .frame(minWidth: 680)
                Divider()
                assistPanel
                    .frame(width: 260)
            }
        }
        .frame(width: 1040, height: 700)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Код с картинки — \(context.courtTitle)")
                    .font(.system(size: 13, weight: .semibold))
                Text("Введите код и нажмите «Найти», затем откройте нужное дело — карточку приложение подхватит автоматически.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Отмена", action: onCancel)
                .buttonStyle(.glass)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 14))
    }

    private var assistPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Помощник ввода", systemImage: "sparkle.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
            Text(assistStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                Text("Картинка")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.tertiary)
                if let captchaImageURL {
                    CaptchaImagePreview(url: captchaImageURL, highContrast: highContrast)
                        .frame(height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.045))
                        .frame(height: 112)
                        .overlay {
                            Text("Появится после загрузки формы")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                }
                Toggle("Высокий контраст", isOn: $highContrast)
                    .font(.caption)
                    .toggleStyle(.checkbox)
            }

            if context.pendingCaseCount > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(context.pendingCaseCount) в очереди", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Этот код продолжит фоновые обновления того же суда.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(context.pendingCaseNumbers, id: \.self) { number in
                        Text("№ \(number)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()
            Text("Распознавание не выполняется автоматически: код читает и вводит пользователь.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }
}

struct CaptchaWebView: NSViewRepresentable {
    let url: URL
    let uid: String
    var caseNumber: String? = nil
    @Binding var captchaImageURL: URL?
    var onAssistStatus: (String) -> Void = { _ in }
    var onCardHTML: (String) -> Void
    var onCaptchaPair: ((String, CaptchaToken) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: CaptchaWebView
        private var didCapture = false
        private var didCapturePair = false

        init(_ parent: CaptchaWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let current = webView.url?.absoluteString ?? ""

            // Пользователь отправил форму с кодом: пара captcha/captchaid видна
            // в URL выдачи (форма отправляется GET-ом). Сохраняем её вместе с
            // cookies сессии WebView — суд может проверять пару только в связке
            // с сессией. Если код был неверный, суд отклонит пару при первом
            // переиспользовании — клиент её инвалидирует сам.
            if !didCapturePair, current.contains("name_op=r"),
               let comps = URLComponents(string: current),
               let cap = comps.queryItems?.first(where: { $0.name == "captcha" })?.value, !cap.isEmpty,
               let capID = comps.queryItems?.first(where: { $0.name == "captchaid" })?.value, !capID.isEmpty,
               let host = webView.url?.host {
                didCapturePair = true
                let token = CaptchaToken(value: cap, id: capID)
                let store = webView.configuration.websiteDataStore.httpCookieStore
                let lowerHost = host.lowercased()
                store.getAllCookies { [weak self] cookies in
                    for c in cookies {
                        // Домен cookie бывает точным («ann…vrn.sudrf.ru») или
                        // родительским с точкой («.sudrf.ru») — берём оба вида.
                        let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        if lowerHost == d || lowerHost.hasSuffix("." + d) {
                            HTTPCookieStorage.shared.setCookie(c)
                        }
                    }
                    self?.parent.onCaptchaPair?(host, token)
                }
            }

            // На странице карточки — считываем HTML и завершаем.
            if current.contains("name_op=case"), !didCapture {
                webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                    guard let self, let html = result as? String, !self.didCapture else { return }
                    self.didCapture = true
                    self.parent.onCardHTML(html)
                }
                return
            }

            // На форме поиска — подставляем УИД и № дела. Регистронезависимо:
            // современные поля ВЕРХНИМ регистром (<TABLE>__JUDICIAL_UIDSS),
            // винтажные (VNKOD-суды) — нижним (case__judicial_uidss).
            if current.contains("name_op=sf") || current.contains("name=sud_delo") || current.contains("name_op=r") {
                applyAssist(to: webView)
            }
        }

        private func applyAssist(to webView: WKWebView) {
            let js = """
            (function(){
              const uid = \(Self.jsStringLiteral(parent.uid));
              const num = \(Self.jsStringLiteral(parent.caseNumber ?? ""));
              const inputs = Array.prototype.slice.call(document.getElementsByTagName('input'));
              let captchaInput = null;
              for (const input of inputs) {
                const nm = (input.name || '').toLowerCase();
                if (uid && nm.indexOf('judicial_uidss') >= 0) { input.value = uid; }
                if (num && nm.indexOf('case_numberss') >= 0) { input.value = num; }
                if (nm === 'captcha' || (nm.indexOf('captcha') >= 0 && nm.indexOf('captchaid') < 0)) {
                  captchaInput = input;
                }
              }
              const images = Array.prototype.slice.call(document.images);
              const captchaImage = images.find(function(img) {
                const src = (img.currentSrc || img.src || '').toLowerCase();
                const id = (img.id || '').toLowerCase();
                const alt = (img.alt || '').toLowerCase();
                return src.indexOf('captcha') >= 0 || id.indexOf('captcha') >= 0 || alt.indexOf('captcha') >= 0;
              });
              if (captchaImage) {
                const width = Math.max(captchaImage.naturalWidth || captchaImage.width || 90, 90) * 2;
                captchaImage.style.width = width + 'px';
                captchaImage.style.height = 'auto';
                captchaImage.style.imageRendering = 'pixelated';
                captchaImage.style.border = '1px solid rgba(0,0,0,.22)';
                captchaImage.style.borderRadius = '4px';
                captchaImage.style.padding = '6px';
                captchaImage.style.background = 'white';
                captchaImage.scrollIntoView({block: 'center', inline: 'nearest'});
              }
              if (captchaInput) {
                captchaInput.focus();
                if (captchaInput.select) { captchaInput.select(); }
              }
              return {
                image: captchaImage ? (captchaImage.currentSrc || captchaImage.src || '') : '',
                focused: !!captchaInput,
                prefilledUID: !!uid,
                prefilledNumber: !!num
              };
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                let dict = result as? [String: Any]
                let image = (dict?["image"] as? String) ?? ""
                let focused = (dict?["focused"] as? Bool) ?? false
                DispatchQueue.main.async {
                    if let url = URL(string: image), !image.isEmpty {
                        self.parent.captchaImageURL = url
                    }
                    self.parent.onAssistStatus(focused
                        ? "Поля дела подставлены, курсор стоит в поле кода."
                        : "Поля дела подставлены. Если поле кода не видно, прокрутите форму чуть ниже.")
                }
            }
        }

        private static func jsStringLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8),
                  json.count >= 2 else { return "\"\"" }
            return String(json.dropFirst().dropLast())
        }
    }
}

private struct CaptchaImagePreview: NSViewRepresentable {
    let url: URL
    var highContrast: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        load(into: web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        load(into: web)
    }

    private func load(into web: WKWebView) {
        let src = htmlEscaped(url.absoluteString)
        let filter = highContrast ? "contrast(180%) grayscale(100%)" : "none"
        let html = """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
        html,body{margin:0;height:100%;background:transparent;}
        body{display:flex;align-items:center;justify-content:center;}
        img{max-width:100%;max-height:100%;image-rendering:pixelated;filter:\(filter);}
        </style></head><body><img src="\(src)"></body></html>
        """
        web.loadHTMLString(html, baseURL: url)
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {}
}

extension CaptchaImagePreview.Coordinator {
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
