//  HTMLCourtTransport.swift — Sudrf
//
//  Общий транспорт для порталов без капчи, которые отдают HTML в UTF-8.
//  `SudrfClient` намеренно не использует его: там отдельный путь для cp1251,
//  капчи, варианта хоста и строго ограниченного HTTP-фолбэка.

import Foundation

/// Небольшой stateful-транспорт для клиентов, у которых один портал и одна
/// очередь запросов. Сессия внедряется вызывающим клиентом: это сохраняет его
/// TLS-политику и позволяет подменять URLSession в тестах.
actor HTMLCourtTransport {

    struct DownloadedFile: Sendable {
        let data: Data
        let finalURL: URL
        let contentType: String?
    }

    enum DecodingPolicy: Sendable {
        /// Портал Москвы документированно отвечает UTF-8.
        case utf8Only
        /// ВС РФ отвечает UTF-8; cp1251 остаётся только совместимым запасным
        /// вариантом для отдельных старых ответов.
        case utf8ThenWindows1251

        func decode(_ data: Data) -> String? {
            switch self {
            case .utf8Only:
                String(data: data, encoding: .utf8)
            case .utf8ThenWindows1251:
                String(data: data, encoding: .utf8) ?? Cyrillic1251.decode(data)
            }
        }
    }

    enum ThrottleSemantics: Sendable {
        /// Пауза отсчитывается от старта предыдущего запроса. Сохраняет
        /// историческую семантику MosGorSudClient.
        case lastRequestStart
        /// Слот следующего запроса резервируется до первого await. Это не даёт
        /// параллельным поискам ВС РФ проснуться одновременно.
        case reserveSlots
    }

    private let session: URLSession
    private let userAgent: String
    private let minInterval: TimeInterval
    private let decodingPolicy: DecodingPolicy
    private let throttleSemantics: ThrottleSemantics

    private var lastRequestAt: Date?
    private var nextAllowedAt: Date?

    init(session: URLSession,
         userAgent: String,
         minInterval: TimeInterval,
         decodingPolicy: DecodingPolicy,
         throttleSemantics: ThrottleSemantics) {
        self.session = session
        self.userAgent = userAgent
        self.minInterval = minInterval
        self.decodingPolicy = decodingPolicy
        self.throttleSemantics = throttleSemantics
    }

    func fetch(_ url: URL, maxAttempts: Int) async throws -> String {
        var lastError: Error = SudrfError.http(status: 0)
        let attempts = max(1, maxAttempts)

        for attempt in 0..<attempts {
            try await throttle()
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            do {
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                if let http, (500..<600).contains(http.statusCode) {
                    lastError = SudrfError.http(status: http.statusCode)
                    try await backoff(attempt)
                    continue
                }
                if let http, !(200..<300).contains(http.statusCode) {
                    throw SudrfError.http(status: http.statusCode)
                }
                if let html = decodingPolicy.decode(data) { return html }
                throw SudrfError.decodingFailed
            } catch let error as URLError {
                lastError = error
                try await backoff(attempt)
                continue
            }
        }
        throw lastError
    }

    /// Downloads a court attachment through the same session, TLS delegate,
    /// cookies, throttle and retry policy as HTML requests. Unlike
    /// `URLSession.data(for:)`, `bytes(for:)` lets us stop the transfer at a
    /// hard byte limit even when a server lies about Content-Length.
    func fetchFile(_ url: URL, maxAttempts: Int, allowedHosts: Set<String>,
                   maxBytes: Int) async throws -> DownloadedFile {
        guard Self.isAllowedSecureURL(url, hosts: allowedHosts), maxBytes > 0 else {
            throw PublishedActFileError.unsafeSourceURL
        }

        var lastError: Error = SudrfError.http(status: 0)
        let attempts = max(1, maxAttempts)
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            try await throttle()
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(
                "application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/octet-stream;q=0.8,*/*;q=0.1",
                forHTTPHeaderField: "Accept")
            request.setValue("ru,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw PublishedActFileError.unexpectedHTTPStatus(0)
                }
                guard http.statusCode == 200 else {
                    throw PublishedActFileError.unexpectedHTTPStatus(http.statusCode)
                }
                let finalURL = http.url ?? url
                guard Self.isAllowedSecureURL(finalURL, hosts: allowedHosts) else {
                    throw PublishedActFileError.unsafeFinalURL
                }
                if let length = Self.contentLength(http), length > maxBytes {
                    throw PublishedActFileError.downloadTooLarge(limit: maxBytes)
                }

                var data = Data()
                if let length = Self.contentLength(http) {
                    data.reserveCapacity(min(length, maxBytes))
                }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maxBytes else {
                        throw PublishedActFileError.downloadTooLarge(limit: maxBytes)
                    }
                    data.append(byte)
                }
                return DownloadedFile(
                    data: data, finalURL: finalURL,
                    contentType: http.value(forHTTPHeaderField: "Content-Type"))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw error
            } catch let error as PublishedActFileError {
                if case .unexpectedHTTPStatus(let status) = error,
                   (500..<600).contains(status), attempt + 1 < attempts {
                    lastError = error
                    try await backoff(attempt)
                    continue
                }
                throw error
            } catch let error as URLError {
                lastError = error
                guard attempt + 1 < attempts else { throw error }
                try await backoff(attempt)
            }
        }
        throw lastError
    }

    private static func isAllowedSecureURL(_ url: URL, hosts: Set<String>) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else {
            return false
        }
        return hosts.contains(host)
    }

    private static func contentLength(_ response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length"),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
            return nil
        }
        return value
    }

    private func backoff(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double(attempt + 1) * 0.8 * 1_000_000_000))
    }

    private func throttle() async throws {
        switch throttleSemantics {
        case .lastRequestStart:
            if let lastRequestAt {
                let elapsed = Date().timeIntervalSince(lastRequestAt)
                if elapsed < minInterval {
                    try await Task.sleep(
                        nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
                }
            }
            lastRequestAt = Date()

        case .reserveSlots:
            let now = Date()
            let slot = max(now, nextAllowedAt ?? now)
            nextAllowedAt = slot.addingTimeInterval(minInterval)
            let wait = slot.timeIntervalSince(now)
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }
}
