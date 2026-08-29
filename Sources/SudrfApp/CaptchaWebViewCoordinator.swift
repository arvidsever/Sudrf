//  CaptchaWebViewCoordinator.swift
//  SudrfApp
//
//  WebKit navigation coordinator for the hidden captcha web view.

import Foundation
import WebKit
import SudrfKit
import os

private let captchaAssistLog = Logger(subsystem: "ru.sudrf.app", category: "CaptchaAssist")

final class CaptchaWebViewCoordinator: NSObject, WKNavigationDelegate {
    private static let unattributedNavigationAttempt = 0

    enum WebState {
        case loadingForm
        case ready
        case submitting
        case accepted
        case failed
    }

    var parent: CaptchaWebView
    private var didCapture = false
    private var didCapturePair = false
    private var lastSubmitRequestID = 0
    private var pendingSubmittedToken: CaptchaToken?
    private var state: WebState = .loadingForm

    // A15: attempt/generator/marker state.
    private var attemptGenerator = CaptchaWebViewAttemptGenerator()
    private var submittedAttempt: Int? = nil
    private var submittedNavigation: WKNavigation? = nil
    private var expectedSubmitMarker: CaptchaWebViewSubmitMarker? = nil
    private var observedResponseStatus: Int?
    private var observedResponseLocation: CaptchaAssistDiagnosticLocation?
    private var navigationAttempts: [ObjectIdentifier: Int] = [:]

    init(_ parent: CaptchaWebView) { self.parent = parent }

    // A15: маппинг private `WebState` → public `CaptchaWebViewState` для factory'ев.
    private static func mapState(_ s: WebState) -> CaptchaWebViewState {
        switch s {
        case .loadingForm: return .loadingForm
        case .ready: return .ready
        case .submitting: return .submitting
        case .accepted: return .accepted
        case .failed: return .failed
        }
    }

    private func notifySwiftUI(_ body: @escaping (inout CaptchaWebView) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            body(&self.parent)
        }
    }

    private func sendSubmissionState(_ next: CaptchaSubmissionState) {
        notifySwiftUI { $0.onSubmissionState(next) }
    }

    private func logOutcome(_ outcome: String, attempt: Int,
                            fallbackURL: URL? = nil) {
        let location = observedResponseLocation ?? CaptchaAssistDiagnosticLocation(url: fallbackURL)
        let status = observedResponseStatus.map(String.init) ?? "unknown"
        let host = location?.host ?? "unknown"
        let path = location?.path ?? "unknown"
        let message = "attempt=\(attempt) status=\(status) host=\(host) path=\(path) outcome=\(outcome)"
        captchaAssistLog.info("\(message, privacy: .public)")
    }

    private func consumeNavigationAttempt(for navigation: WKNavigation?) -> Int? {
        guard let navigation else { return nil }
        let id = ObjectIdentifier(navigation)
        defer { navigationAttempts.removeValue(forKey: id) }
        return navigationAttempts[id]
    }

    /// A15: единый helper финализации submit. Инвалидирует ВСЕ
    /// completion от этого attempt (через generator.finish) + сбрасывает
    /// `submittedNavigation` и `expectedSubmitMarker`. Защита от гонки:
    /// поздний completion от старой попытки НЕ перезаписывает состояние
    /// новой.
    private func completeSubmit(attempt: Int, nextState: WebState) {
        guard attemptGenerator.finish(activeAttempt: attempt) else { return }
        submittedNavigation = nil
        expectedSubmitMarker = nil
        state = nextState
    }

    private func fail(_ message: String) {
        // A15: fail() вызывается и при первичной загрузке формы (applyAssist),
        // когда submit-попытки ещё не было (activeID == nil). В этом случае
        // — просто .failed, без completeSubmit. Если был активный submit —
        // completeSubmit инвалидирует attempt + marker.
        if let a = attemptGenerator.activeID {
            completeSubmit(attempt: a, nextState: .failed)
        } else {
            state = .failed
        }
        sendSubmissionState(.failed(message))
    }

    func submitIfNeeded(in webView: WKWebView) {
        // A15: проверка state ПЕРЕД записью requestID. Раньше запись шла до
        // guard, и retry из .failed/.rejected/.loadingForm/.submitting
        // «съедал» requestID без submit, а следующая попытка проходила
        // тот же цикл — deadlock. Сейчас: если state не allow — requestID
        // не трогаем, пользователь может повторить submit явно.
        let decision = CaptchaWebViewSubmitDecisionFactory.decide(
            state: Self.mapState(state),
            currentRequestID: parent.submitRequestID,
            lastRequestID: lastSubmitRequestID)
        switch decision {
        case .skipSameRequestID, .skipStateNotAllowed:
            return
        case .submit:
            lastSubmitRequestID = parent.submitRequestID
            let attempt = attemptGenerator.start()
            submittedAttempt = attempt
            submittedNavigation = nil
            expectedSubmitMarker = CaptchaWebViewSubmitMarker(
                attempt: attempt,
                expectedURL: nil,
                setAt: Date(),
                expectedFragment: CaptchaWebViewSubmitMarkerFactory.fragment(for: attempt))
            observedResponseStatus = nil
            observedResponseLocation = nil
            state = .submitting
            // A15: ЕДИНСТВЕННАЯ точка отправки .submitting в SwiftUI.
            // Раньше ещё и в submitCaptcha() дублировалось.
            sendSubmissionState(.submitting)
            scheduleSubmitTimeout(for: attempt, in: webView)
            submitCaptcha(parent.captchaCode, attempt: attempt, in: webView)
        }
    }

    // A15: best-effort привязка навигации к attempt. WebKit не даёт прямого
    // идентификатора между WKNavigationAction и WKNavigation; используем URL +
    // 5-секундное окно. `defer` гарантирует `decisionHandler(.allow)` на любом
    // пути (ранний return, исключение, нормальный выход) — иначе WebKit
    // заблокирует навигацию.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        defer { decisionHandler(.allow) }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        guard isMainFrame,
              state == .submitting,
              let a = attemptGenerator.activeID,
              a == submittedAttempt else { return }

        if let taggedAttempt = CaptchaWebViewSubmitMarkerFactory.attempt(
            from: navigationAction.request.url) {
            // A late action retains the attempt fragment injected before the
            // submit. Never relabel attempt N as the active retry N+1.
            guard taggedAttempt == a else { return }
        } else if navigationAction.navigationType != .formSubmitted {
            return
        }

        // Если маркер уже есть от того же attempt и не протух — keep (не
        // перезаписываем; защита от наложения submit-типов навигаций в окне
        // одного attempt).
        if let marker = expectedSubmitMarker,
           marker.attempt == a,
           Date().timeIntervalSince(marker.setAt) <= CaptchaWebViewSubmitMarkerFactory.windowSeconds {
            return
        }
        // Иначе (другой attempt / протух) — overwrite.
        let now = Date()
        expectedSubmitMarker = CaptchaWebViewSubmitMarker(
            attempt: a, expectedURL: navigationAction.request.url, setAt: now)

        // Self-clear через 5 сек: если didStartProvisionalNavigation не
        // вызвался за это время — маркер протухает, не подхватит
        // следующую навигацию.
        DispatchQueue.main.asyncAfter(deadline: .now() + CaptchaWebViewSubmitMarkerFactory.windowSeconds) { [weak self] in
            guard let self,
                  let marker = self.expectedSubmitMarker,
                  marker.setAt == now else { return }
            self.expectedSubmitMarker = nil
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           state == .submitting,
           let attempt = submittedAttempt,
           attemptGenerator.activeID == attempt {
            observedResponseStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
            observedResponseLocation = CaptchaAssistDiagnosticLocation(
                url: navigationResponse.response.url)
        }
        decisionHandler(.allow)
    }

    // A15: привязка навигации к attempt через URL+window matcher.
    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        let now = Date()
        guard state == .submitting,
              let a = submittedAttempt,
              attemptGenerator.activeID == a else {
            expectedSubmitMarker = nil
            return
        }

        let navigationID = ObjectIdentifier(navigation)
        if let taggedAttempt = CaptchaWebViewSubmitMarkerFactory.attempt(from: webView.url) {
            navigationAttempts[navigationID] = taggedAttempt
            if taggedAttempt == a {
                submittedNavigation = navigation
                expectedSubmitMarker = nil
            }
            return
        }

        if let marker = expectedSubmitMarker {
            let decision = CaptchaWebViewSubmitMarkerFactory.decide(
                marker: marker, actualURL: webView.url, now: now)
            guard decision == .match else {
                // URL mismatch / expired / не наш attempt — очищаем, чтобы
                // старый маркер не подхватил следующую навигацию.
                navigationAttempts[navigationID] = Self.unattributedNavigationAttempt
                expectedSubmitMarker = nil
                return
            }
            navigationAttempts[navigationID] = marker.attempt
            submittedNavigation = navigation
            expectedSubmitMarker = nil
            return
        }

        // An untagged didStart cannot be safely attributed after a retry.
        // Preserve it as explicitly foreign; a failure delivered without any
        // didStart still uses the markerless fallback in the decision helper.
        navigationAttempts[navigationID] = Self.unattributedNavigationAttempt
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let navigationAttempt = consumeNavigationAttempt(for: navigation)
        let current = webView.url?.absoluteString ?? ""

        // A15: инспектируем результат submit'а, если он наш и attempt ещё
        // активен. best-effort привязка `submittedNavigation` НЕ должна
        // блокировать happy-path: WebKit при JS-submit (form.submit()/
        // синтетический click) часто рапортует navigationType == .other, не
        // .formSubmitted, поэтому `decidePolicyFor` не ставит маркер и
        // `submittedNavigation` остаётся nil. Раньше guard `=== navigation`
        // ронял ВЕСЬ успешный путь → лист висел до 60-сек watchdog и падал
        // ложным «Суд не ответил» даже при принятом коде. Теперь строгую
        // сверку навигации применяем ТОЛЬКО когда маркер реально сработал
        // (`submittedNavigation != nil`) — тогда отсекаем чужой поздний
        // didFinish; иначе полагаемся на attempt-guard (activeID == a) +
        // guard `activeID == attempt` внутри `inspectSubmittedResult`.
        let inspectDecision = CaptchaWebViewDidFinishDecisionFactory.decide(
            state: Self.mapState(state),
            submittedAttempt: submittedAttempt,
            activeID: attemptGenerator.activeID,
            navigationAttempt: navigationAttempt,
            hasSubmittedNavigation: submittedNavigation != nil,
            navigationMatchesSubmitted: submittedNavigation === navigation)
        if case .inspect(let a) = inspectDecision {
            inspectSubmittedResult(attempt: a, in: webView)
            return
        }

        if current.contains("name_op=case"), !didCapture {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let self, let html = result as? String, !self.didCapture else { return }
                self.didCapture = true
                self.notifySwiftUI { $0.onCardHTML(html) }
            }
            return
        }

        guard state == .loadingForm || state == .ready else { return }

        if current.contains("name_op=sf") || current.contains("name=sud_delo") {
            applyAssist(to: webView, rejected: false)
        }
    }

    // A15: навигационный fail (offline, timeout) — разблокирует лист.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        handleNavigationFailure(navigation: navigation, webView: webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleNavigationFailure(navigation: navigation, webView: webView, error: error)
    }

    private func handleNavigationFailure(navigation: WKNavigation, webView: WKWebView,
                                         error: Error) {
        let navigationAttempt = consumeNavigationAttempt(for: navigation)
        let decision = CaptchaWebViewNavigationFailureFactory.decide(
            state: Self.mapState(state),
            error: error,
            submittedAttempt: submittedAttempt,
            activeID: attemptGenerator.activeID,
            navigationAttempt: navigationAttempt,
            hasSubmittedNavigation: submittedNavigation != nil,
            navigationMatchesSubmitted: submittedNavigation === navigation)
        switch decision {
        case .ignore:
            return
        case .failSubmitting(let message):
            if let attempt = submittedAttempt {
                logOutcome("navigation_failed", attempt: attempt, fallbackURL: webView.url)
            }
            // completeSubmit произойдёт в fail() если был активный attempt.
            fail(message)
        case .failLoadingForm(let message):
            fail(message)
        }
    }

    // A15: 60-сек watchdog для .submitting без ответа. Guard по attempt:
    // если пользователь уже сделал retry, watchdog от старой попытки
    // ignore (activeID != attempt).
    private func scheduleSubmitTimeout(for attempt: Int, in webView: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak webView] in
            guard let self, let webView else { return }
            guard self.attemptGenerator.activeID == attempt,
                  self.state == .submitting else { return }
            // Submission is dispatched synchronously. Stop any remaining
            // load before enabling retry so WebKit cannot carry an untagged
            // navigation across the attempt boundary.
            webView.stopLoading()
            self.logOutcome("timeout", attempt: attempt)
            self.fail("Суд не ответил. Попробуйте ещё раз.")
        }
    }

    private func inspectSubmittedResult(attempt: Int, in webView: WKWebView) {
        let js = """
        const inputs = Array.prototype.slice.call(document.getElementsByTagName('input'));

        function isVisible(el) {
          const r = el.getBoundingClientRect();
          const style = window.getComputedStyle(el);
          return r.width > 0 && r.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
        }

        function isEditableInput(input) {
          const type = ((input.type || 'text') + '').toLowerCase();
          if (type === 'hidden' || type === 'submit' || type === 'button' || type === 'reset' || type === 'checkbox' || type === 'radio') { return false; }
          return !input.disabled && !input.readOnly && isVisible(input);
        }

        function isNamedCaptchaInput(input) {
          if (!isEditableInput(input)) { return false; }
          const nm = ((input.name || input.id || '') + '').toLowerCase();
          return nm === 'captcha' || (nm.indexOf('captcha') >= 0 && nm.indexOf('captchaid') < 0);
        }

        function nearbyText(input) {
          const row = input.closest('tr');
          if (row) { return row.innerText || ''; }
          const label = input.id ? Array.prototype.slice.call(document.getElementsByTagName('label')).find(function(label) {
            return label.htmlFor === input.id;
          }) : null;
          const parent = input.parentElement;
          return [(label && label.innerText) || '', (parent && parent.innerText) || ''].join(' ');
        }

        function hasCaptchaLabelNearEditableInput(input) {
          if (!isEditableInput(input)) { return false; }
          const text = nearbyText(input).toLowerCase();
          return text.indexOf('проверочный код') >= 0 || text.indexOf('код с картинки') >= 0;
        }

        return inputs.some(isNamedCaptchaInput) || inputs.some(hasCaptchaLabelNearEditableInput);
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self, weak webView] result in
            guard let self, let webView else { return }
            // A15: защита от гонки — если attempt больше не активный
            // (пользователь уже сделал retry), ignore.
            guard self.attemptGenerator.activeID == attempt else { return }
            let value = try? result.get()
            let hasCaptcha = (value as? Bool) ?? false
            switch CaptchaAssistPostSubmitDecision.decide(hasCaptchaMarkers: hasCaptcha,
                                                          hasPendingToken: self.resolvedCaptchaToken(from: webView) != nil,
                                                          requiresToken: self.parent.contextKindRequiresToken) {
            case .accept:
                if self.parent.contextKindRequiresToken {
                    self.captureCaptchaPair(attempt: attempt, from: webView)
                } else {
                    self.captureSession(attempt: attempt, from: webView)
                }
            case .reject:
                // A15: completeSubmit инвалидирует attempt + marker.
                self.logOutcome("rejected", attempt: attempt, fallbackURL: webView.url)
                self.completeSubmit(attempt: attempt, nextState: .loadingForm)
                self.applyAssist(to: webView, rejected: true)
            case .failMissingToken:
                // A15: completeSubmit инвалидирует attempt + marker ДО fail.
                self.logOutcome("missing_token", attempt: attempt, fallbackURL: webView.url)
                self.completeSubmit(attempt: attempt, nextState: .failed)
                self.fail("Код принят страницей суда, но captchaid не найден. Попробуйте ещё раз.")
            }
        }
    }

    private func captureCaptchaPair(attempt: Int, from webView: WKWebView) {
        // A15: защита attempt'а.
        guard attemptGenerator.activeID == attempt else { return }
        guard !didCapturePair, let host = webView.url?.host else {
            logOutcome("missing_token", attempt: attempt, fallbackURL: webView.url)
            completeSubmit(attempt: attempt, nextState: .failed)
            fail("Код отправлен, но ответ суда не содержит токен. Попробуйте ещё раз.")
            return
        }

        guard let token = resolvedCaptchaToken(from: webView) else {
            logOutcome("missing_token", attempt: attempt, fallbackURL: webView.url)
            completeSubmit(attempt: attempt, nextState: .failed)
            fail("Код принят страницей суда, но captchaid не найден. Попробуйте ещё раз.")
            return
        }

        didCapturePair = true
        logOutcome("accepted", attempt: attempt, fallbackURL: webView.url)
        completeSubmit(attempt: attempt, nextState: .accepted)
        sendSubmissionState(.accepted)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Self.copyCookies(from: store, host: host) { [weak self] in
            self?.notifySwiftUI { $0.onCaptchaPair?(host, token) }
        }
    }

    private func captureSession(attempt: Int, from webView: WKWebView) {
        // A15: защита attempt'а.
        guard attemptGenerator.activeID == attempt else { return }
        guard let host = webView.url?.host else {
            logOutcome("submit_failed", attempt: attempt, fallbackURL: webView.url)
            completeSubmit(attempt: attempt, nextState: .failed)
            fail("Код отправлен, но сессия суда не определена. Попробуйте ещё раз.")
            return
        }
        completeSubmit(attempt: attempt, nextState: .accepted)
        logOutcome("accepted", attempt: attempt, fallbackURL: webView.url)
        sendSubmissionState(.accepted)
        let store = webView.configuration.websiteDataStore.httpCookieStore
        Self.copyCookies(from: store, host: host) { [weak self] in
            self?.notifySwiftUI { $0.onSessionUnlocked?(host) }
        }
    }

    private static func copyCookies(from store: WKHTTPCookieStore, host: String,
                                    then completion: @escaping () -> Void) {
        let lowerHost = host.lowercased()
        store.getAllCookies { cookies in
            for c in cookies {
                // Домен cookie бывает точным («ann…vrn.sudrf.ru») или
                // родительским с точкой («.sudrf.ru») — берём оба вида.
                let d = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if lowerHost == d || lowerHost.hasSuffix("." + d) {
                    HTTPCookieStorage.shared.setCookie(c)
                }
            }
            completion()
        }
    }

    private func resolvedCaptchaToken(from webView: WKWebView) -> CaptchaToken? {
        let current = webView.url?.absoluteString ?? ""
        let urlToken: CaptchaToken? = {
            guard let comps = URLComponents(string: current),
                  let cap = comps.queryItems?.first(where: { $0.name == "captcha" })?.value, !cap.isEmpty,
                  let capID = comps.queryItems?.first(where: { $0.name == "captchaid" })?.value, !capID.isEmpty else {
                return nil
            }
            return CaptchaToken(value: cap, id: capID)
        }()
        return urlToken ?? pendingSubmittedToken
    }

    private func submitCaptcha(_ code: String, attempt: Int, in webView: WKWebView) {
        let navigationFragment = CaptchaWebViewSubmitMarkerFactory.fragment(for: attempt)
        let js = """
        (function(){
          const code = \(Self.jsStringLiteral(code));
          const navigationFragment = \(Self.jsStringLiteral(navigationFragment));
          const inputs = Array.prototype.slice.call(document.getElementsByTagName('input'));
          const captchaInput = inputs.find(function(input) {
            const nm = (input.name || '').toLowerCase();
            return nm === 'captcha' || (nm.indexOf('captcha') >= 0 && nm.indexOf('captchaid') < 0);
          });
          const captchaIDInput = inputs.find(function(input) {
            const nm = ((input.name || input.id || '') + '').toLowerCase();
            return nm === 'captchaid' || nm.indexOf('captchaid') >= 0;
          });
          if (!captchaInput) { return { ok: false, reason: 'captcha-input-missing' }; }
          captchaInput.value = code;
          captchaInput.dispatchEvent(new Event('input', { bubbles: true }));
          captchaInput.dispatchEvent(new Event('change', { bubbles: true }));

          const form = captchaInput.form || captchaInput.closest('form');
          const root = form || document;
          const controls = Array.prototype.slice.call(root.querySelectorAll('input, button'));
          const submit = controls.find(function(el) {
            const type = (el.type || '').toLowerCase();
            const value = ((el.value || el.textContent || '') + '').toLowerCase();
            return type === 'submit' || value.indexOf('най') >= 0 || value.indexOf('find') >= 0;
          });
          if (form) {
            const destination = new URL((submit && submit.formAction) || form.action || window.location.href,
                                        window.location.href);
            destination.hash = navigationFragment;
            if (submit && submit.hasAttribute('formaction')) {
              submit.formAction = destination.href;
            } else {
              form.action = destination.href;
            }
          }
          if (submit && submit.click) {
            submit.click();
            return { ok: true, method: 'click', captchaid: captchaIDInput ? captchaIDInput.value : '' };
          }
          if (form && form.submit) {
            form.submit();
            return { ok: true, method: 'form-submit', captchaid: captchaIDInput ? captchaIDInput.value : '' };
          }
          return { ok: false, reason: 'submit-missing' };
        })();
        """
        // A15: sendSubmissionState(.submitting) УБРАНО — submitIfNeeded
        // уже отправил его в SwiftUI. Дублирование исчезло.
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self else { return }
            // A15: защита attempt'а — если пользователь уже сделал retry,
            // completion от старой попытки ignore.
            guard self.attemptGenerator.activeID == attempt else { return }
            if let error {
                self.logOutcome("submit_failed", attempt: attempt)
                self.fail("Не удалось отправить код: \(error.localizedDescription)")
                return
            }
            let dict = result as? [String: Any]
            let ok = (dict?["ok"] as? Bool) ?? false
            if !ok {
                self.logOutcome("submit_failed", attempt: attempt)
                self.fail("Не нашёл кнопку отправки на форме суда. Обновите окно и попробуйте ещё раз.")
                return
            }
            if let captchaID = dict?["captchaid"] as? String, !captchaID.isEmpty {
                self.pendingSubmittedToken = CaptchaToken(value: code, id: captchaID)
            }
        }
    }

    private func applyAssist(to webView: WKWebView, rejected: Bool) {
        let js = """
        const uid = \(Self.jsStringLiteral(parent.uid));
        const num = \(Self.jsStringLiteral(parent.caseNumber ?? ""));

        function inputName(input) {
          return (input.name || input.id || '').toLowerCase();
        }

        function isCaptchaInput(input) {
          const nm = inputName(input);
          return nm === 'captcha' || (nm.indexOf('captcha') >= 0 && nm.indexOf('captchaid') < 0);
        }

        function isVisible(el) {
          const r = el.getBoundingClientRect();
          const style = window.getComputedStyle(el);
          return r.width > 0 && r.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
        }

        function scoreImage(img, captchaInput) {
          const src = (img.currentSrc || img.src || '').toLowerCase();
          const id = (img.id || '').toLowerCase();
          const alt = (img.alt || '').toLowerCase();
          if (src.indexOf('counter') >= 0 || src.indexOf('calendar') >= 0) { return Number.POSITIVE_INFINITY; }
          let score = 1000;
          if (src.indexOf('captcha') >= 0 || id.indexOf('captcha') >= 0 || alt.indexOf('captcha') >= 0) { score -= 800; }
          if (!captchaInput) { return score; }
          const inputRect = captchaInput.getBoundingClientRect();
          const imgRect = img.getBoundingClientRect();
          const ix = inputRect.left + inputRect.width / 2;
          const iy = inputRect.top + inputRect.height / 2;
          const cx = imgRect.left + imgRect.width / 2;
          const cy = imgRect.top + imgRect.height / 2;
          score += Math.abs(cx - ix) + Math.abs(cy - iy) * 1.6;
          const row = captchaInput.closest('tr');
          if (row && row.contains(img)) { score -= 350; }
          const parent = captchaInput.parentElement;
          if (parent && parent.contains(img)) { score -= 250; }
          const form = captchaInput.form || captchaInput.closest('form');
          if (form && form.contains(img)) { score -= 80; }
          return score;
        }

        function findCaptchaImage(captchaInput) {
          const images = Array.prototype.slice.call(document.images).filter(function(img) {
            if (!isVisible(img)) { return false; }
            const r = img.getBoundingClientRect();
            return r.width >= 35 && r.height >= 15 && r.width <= 420 && r.height <= 220;
          });
          images.sort(function(a, b) { return scoreImage(a, captchaInput) - scoreImage(b, captchaInput); });
          return images[0] || null;
        }

        function waitForImage(img) {
          if (!img || (img.complete && (img.naturalWidth || img.width))) { return Promise.resolve(); }
          return new Promise(function(resolve) {
            const done = function() { resolve(); };
            img.addEventListener('load', done, { once: true });
            img.addEventListener('error', done, { once: true });
            setTimeout(done, 1200);
          });
        }

        async function imageDataURL(img) {
          if (!img) { return ''; }
          await waitForImage(img);
          const w = Math.max(img.naturalWidth || img.width || img.clientWidth || 120, 1);
          const h = Math.max(img.naturalHeight || img.height || img.clientHeight || 40, 1);
          try {
            const canvas = document.createElement('canvas');
            canvas.width = w;
            canvas.height = h;
            const ctx = canvas.getContext('2d');
            ctx.drawImage(img, 0, 0, w, h);
            return canvas.toDataURL('image/png');
          } catch (e) {
            try {
              const response = await fetch(img.currentSrc || img.src, { credentials: 'include', cache: 'no-store' });
              const blob = await response.blob();
              return await new Promise(function(resolve) {
                const reader = new FileReader();
                reader.onloadend = function() { resolve(reader.result || ''); };
                reader.onerror = function() { resolve(''); };
                reader.readAsDataURL(blob);
              });
            } catch (_) {
              return '';
            }
          }
        }

        const inputs = Array.prototype.slice.call(document.getElementsByTagName('input'));
        let captchaInput = null;
        for (const input of inputs) {
          const nm = inputName(input);
          if (uid && nm.indexOf('judicial_uidss') >= 0) { input.value = uid; }
          if (num && nm.indexOf('case_numberss') >= 0) { input.value = num; }
          if (isCaptchaInput(input)) { captchaInput = input; }
        }

        if (!captchaInput) {
          return {
            image: '',
            foundInput: false,
            foundImage: false,
            prefilledUID: !!uid,
            prefilledNumber: !!num
          };
        }

        const captchaImage = findCaptchaImage(captchaInput);
        captchaInput.value = '';
        return {
          image: await imageDataURL(captchaImage),
          foundInput: !!captchaInput,
          foundImage: !!captchaImage,
          prefilledUID: !!uid,
          prefilledNumber: !!num
        };
        """
        sendSubmissionState(rejected ? .rejected : .loading)
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.state = .failed
                self.notifySwiftUI { parent in
                    parent.captchaImageData = nil
                    parent.onSubmissionState(.failed("Не удалось подготовить форму суда: \(error.localizedDescription)"))
                }
            case .success(let value):
                let dict = value as? [String: Any]
                let dataURL = (dict?["image"] as? String) ?? ""
                let foundInput = (dict?["foundInput"] as? Bool) ?? false
                let foundImage = (dict?["foundImage"] as? Bool) ?? false
                self.notifySwiftUI { parent in
                    if let data = CaptchaImagePayload.data(fromDataURL: dataURL) {
                        parent.captchaImageData = data
                    } else if !foundInput || !foundImage {
                        parent.captchaImageData = nil
                    }
                    if foundInput && foundImage {
                        self.state = .ready
                        parent.onCaptchaReady()
                        parent.onSubmissionState(rejected ? .rejected : .ready)
                    } else if foundInput {
                        self.state = .failed
                        parent.onSubmissionState(.failed("Поле кода найдено, но картинка не обнаружена. Обновите окно."))
                    } else {
                        self.state = .failed
                        parent.onSubmissionState(.failed("Не нашёл поле кода на форме суда. Обновите окно."))
                    }
                }
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

// Метод обработки серверного сертификата вынесен в extension: так компилятор
// macOS 26 не считает его «почти совпадающим» с опциональным требованием
// WKNavigationDelegate и не выдаёт предупреждение. Логика не изменилась.
extension CaptchaWebViewCoordinator {
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
        if host == "sudrf.ru" || host.hasSuffix(".sudrf.ru")
            || SudrfHost.isMSudrfHost(host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
