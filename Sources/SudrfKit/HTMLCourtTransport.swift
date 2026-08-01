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
