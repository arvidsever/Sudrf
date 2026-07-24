import Foundation
import SwiftSoup

/// Судебный участок мирового судьи из справочника ГАС «Правосудие».
public struct MagistrateCourt: Sendable, Equatable, Codable {
    public var title: String
    public var domain: String
    public var code: String
    public var portalSubject: String?

    public var isSupported: Bool {
        let host = domain.lowercased()
        return SudrfHost.isMSudrfHost(host)
    }

    public var court: Court {
        Court(domain: domain, title: title, level: .magistrate)
    }

    public init(title: String, domain: String, code: String, portalSubject: String? = nil) {
        self.title = title
        self.domain = domain
        self.code = code
        self.portalSubject = portalSubject
    }
}

public enum MagistrateCourtParser {

    public static func parse(html: String, portalSubject: String? = nil) -> [MagistrateCourt] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        let anchors = (try? doc.select("table.msSearchResultTbl a[onclick*=listcontrol]").array()) ?? []
        var byCode: [String: MagistrateCourt] = [:]
        for a in anchors {
            let onclick = (try? a.attr("onclick")) ?? ""
            guard let code = captureCode(onclick) else { continue }
            let title = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let domain = officialSite(near: a) ?? "unsupported-ms:\(code)"
            byCode[code] = MagistrateCourt(title: title, domain: domain,
                                           code: code, portalSubject: portalSubject)
        }
        return byCode.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func captureCode(_ onclick: String) -> String? {
        let patterns = [
            #"listcontrol\([^,]+,\s*["']([^"']*MS\d+)["']\)"#,
            #"["'](\d{2}MS\d+)["']"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = onclick as NSString
            if let m = re.firstMatch(in: onclick, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                return ns.substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    private static func officialSite(near anchor: Element) -> String? {
        let containers = anchor.parents().array()
        let scope = containers.first { ((try? $0.attr("class")) ?? "").contains("courtInfoCont") }
            ?? containers.first { $0.tagName() == "tr" }
        guard let scope else { return nil }
        let links = (try? scope.select("a[href]").array()) ?? []
        for link in links {
            guard let host = host(from: (try? link.attr("href")) ?? "") else { continue }
            if SudrfHost.isMSudrfHost(host) { return host }
        }
        return nil
    }

    static func host(from href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return nil }
        return host
    }
}

public actor MagistrateCourtResolver {
    private let client: SudrfClient
    private let cacheURL: URL?
    private var cache: [String: MagistrateCourt] = [:]
    private var loadedSubjects: Set<String> = []
    private var diskLoaded = false

    public init(client: SudrfClient = SudrfClient(),
                cacheURL: URL? = MagistrateCourtResolver.defaultCacheURL()) {
        self.client = client
        self.cacheURL = cacheURL
    }

    public static func defaultCacheURL() -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("SudrfKit-magistrates-v1.json")
    }

    public func courts(forRegion region: String) async throws -> [MagistrateCourt] {
        guard let num = CourtDirectory.subjectNumericCode(forRegion: region) else { return [] }
        return try await courts(forSubjectCode: num)
    }

    /// То же, но по коду субъекта (идентификация региона под капотом — кодом).
    public func courts(forSubjectCode num: String) async throws -> [MagistrateCourt] {
        try await ensureDiskLoaded()
        if !loadedSubjects.contains(num) { _ = try await fetchSubject(num) }
        return subjectCourts(num)
    }

    @discardableResult
    public func refresh(forRegion region: String) async throws -> Int {
        guard let num = CourtDirectory.subjectNumericCode(forRegion: region) else { return 0 }
        return try await fetchSubject(num)
    }

    @discardableResult
    public func refresh(forSubjectCode num: String) async throws -> Int {
        try await fetchSubject(num)
    }

    private func subjectCourts(_ num: String) -> [MagistrateCourt] {
        cache.values
            .filter { ($0.portalSubject ?? CourtDirectory.normalizedSubjectCode($0.code)) == num }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    private func fetchSubject(_ num: String) async throws -> Int {
        let html = try await client.fetchHTML(subjectURL(num))
        let parsed = MagistrateCourtParser.parse(html: html, portalSubject: num)
        for c in parsed { cache[c.code] = c }
        if !parsed.isEmpty { loadedSubjects.insert(num) }
        persist()
        return parsed.count
    }

    private func subjectURL(_ code: String) -> URL {
        URL(string: "https://sudrf.ru/index.php?id=300&act=go_ms_search&searchtype=ms"
                 + "&var=true&ms_type=ms&court_subj=\(code)")!
    }

    private func ensureDiskLoaded() async throws {
        if diskLoaded { return }
        diskLoaded = true
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([MagistrateCourt].self, from: data) else { return }
        for c in arr {
            cache[c.code] = c
            loadedSubjects.insert(c.portalSubject ?? CourtDirectory.normalizedSubjectCode(c.code))
        }
    }

    private func persist() {
        guard let url = cacheURL else { return }
        if let data = try? JSONEncoder().encode(Array(cache.values)) {
            try? data.write(to: url)
        }
    }
}
