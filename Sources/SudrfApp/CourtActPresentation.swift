import Foundation
import SudrfKit

/// Display-only view of published acts. Source IDs and bodies remain in the movement.
struct CourtActDisplay: Identifiable {
    let id: String
    let sourceIDs: [String]
    let title: String
    let date: String
    let stage: String
    let text: String
    let originalURL: URL?
    let instanceLevel: CaseInstance.Level
    var sourceFileURL: URL? = nil
    var productionNumber: String? = nil
    var fileProvenance: PublishedActProvenance? = nil

    func contains(_ sourceID: String) -> Bool { sourceIDs.contains(sourceID) }
}

enum CourtActPresentation {
    private struct Source {
        let act: CaseAct
        let text: String
        let fingerprint: String
        let courtHost: String?
        let courtName: String?
        let linkedLevel: CaseInstance.Level?
        let kind: String?

        var date: String? { knownDate(act.date) }

        var isComplete: Bool {
            date != nil && (courtHost != nil || courtName != nil) && kind != nil
        }
    }

    static func row(for sourceID: String, in movement: CaseMovement) -> CourtActDisplay? {
        rows(in: movement).first { $0.contains(sourceID) }
    }

    static func rows(in movement: CaseMovement) -> [CourtActDisplay] {
        let sources = movement.acts.compactMap { act -> Source? in
            let text = movement.actBodies[act.id] ?? ""
            let fileURL = (act.sourceFileURL ?? act.fileProvenance?.sourceURL)
                .flatMap(PublishedActURLPolicy.safePublishedURL)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || fileURL != nil else { return nil }
            let instance = movement.instances.first { $0.linkedActIDs.contains(act.id) }
            let courtName = instance.flatMap { meaningfulCourt($0.court) }
                ?? meaningfulCourt(act.courtShort)
            let host = instance.map { SudrfHost.moduleHost($0.domain) }
            let title = heading(in: text) ?? act.title
            return Source(act: act, text: text,
                          fingerprint: text.isEmpty ? "published-file:" + act.id : normalizedText(text),
                          courtHost: host, courtName: courtName,
                          linkedLevel: instance?.level,
                          kind: kind(of: title))
        }

        // Complete records establish identity first. A record without court or
        // date cannot bridge two otherwise distinct published acts.
        var groups: [[Source]] = []
        for source in sources.filter(\.isComplete) {
            if let index = groups.firstIndex(where: { compatible(source, with: $0) }) {
                groups[index].append(source)
            } else {
                groups.append([source])
            }
        }
        for source in sources.filter({ !$0.isComplete }) {
            let matches = groups.indices.filter { compatible(source, with: groups[$0]) }
            if matches.count == 1 {
                groups[matches[0]].append(source)
            } else {
                groups.append([source])
            }
        }

        return groups.map { group in
            let representative = group.max { lhs, rhs in
                let left = (lhs.text.count, lhs.text.filter { $0 == "\n" }.count,
                            completeness(lhs), lhs.act.fileProvenance == nil ? 0 : 1)
                let right = (rhs.text.count, rhs.text.filter { $0 == "\n" }.count,
                             completeness(rhs), rhs.act.fileProvenance == nil ? 0 : 1)
                return left < right
            }!
            let date = group.compactMap(\.date).first ?? ""
            let level = group.compactMap(\.linkedLevel).first
                ?? representative.act.instanceLevel
            let title = heading(in: representative.text)
                ?? group.compactMap { humanTitle($0.act.title) }.first
                ?? fallbackTitle(level)
            let sourceIDs = group.map { $0.act.id }
            let fileURL = group.compactMap { $0.act.fileProvenance?.sourceURL ?? $0.act.sourceFileURL }
                .compactMap(PublishedActURLPolicy.safePublishedURL).first
            let cardURL = movement.instances
                .filter { !$0.linkedActIDs.filter(sourceIDs.contains).isEmpty }
                .compactMap { instance -> URL? in
                    guard let url = instance.sourceURL else { return nil }
                    return verifiedCardURL(url, domain: instance.domain)
                }.first
            return CourtActDisplay(id: representative.act.id, sourceIDs: sourceIDs,
                                   title: title, date: date,
                                   stage: stageLabel(level),
                                   text: representative.text,
                                   originalURL: fileURL ?? cardURL,
                                   instanceLevel: level, sourceFileURL: fileURL,
                                   productionNumber: representative.act.productionNumber,
                                   fileProvenance: group.compactMap { $0.act.fileProvenance }.first)
        }.sorted { lhs, rhs in
            let left = sources.firstIndex { lhs.contains($0.act.id) } ?? .max
            let right = sources.firstIndex { rhs.contains($0.act.id) } ?? .max
            return left < right
        }
    }

    private static func completeness(_ source: Source) -> Int {
        (source.date == nil ? 0 : 1) + (source.courtName == nil ? 0 : 1)
            + (source.kind == nil ? 0 : 1)
    }

    private static func compatible(_ source: Source, with group: [Source]) -> Bool {
        group.allSatisfy { other in
            source.fingerprint == other.fingerprint
                && (source.act.productionNumber == nil || other.act.productionNumber == nil
                    || source.act.productionNumber == other.act.productionNumber)
                && (source.linkedLevel == nil || other.linkedLevel == nil
                    || source.linkedLevel == other.linkedLevel)
                && (source.date == nil || other.date == nil || source.date == other.date)
                && (source.kind == nil || other.kind == nil || source.kind == other.kind)
                && sameCourt(source, other)
        }
    }

    private static func sameCourt(_ lhs: Source, _ rhs: Source) -> Bool {
        if let a = lhs.courtHost, let b = rhs.courtHost, a != b { return false }
        if let a = lhs.courtName, let b = rhs.courtName, a != b {
            // A published name may omit its region suffix, but two different
            // courts on a shared portal must never merge by host alone.
            return lhs.courtHost == rhs.courtHost
                && lhs.courtHost != nil
                && (a.hasPrefix(b + " ") || b.hasPrefix(a + " "))
        }
        return true
    }

    private static func verifiedCardURL(_ url: URL, domain: String) -> URL? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host else { return nil }
        let vsHosts = ["vsrf.ru", "www.vsrf.ru"]
        if vsHosts.contains(host.lowercased()), vsHosts.contains(domain.lowercased()),
           url.path.range(of: #"^/lk/practice/(cases|claims|appeals)/[0-9-]+$"#, options: .regularExpression) != nil {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url
        }
        guard SudrfHost.moduleHost(host) == SudrfHost.moduleHost(domain) else { return nil }
        if let link = try? SudrfCaseCardLink(url: url) { return link.sanitizedURL }
        if PublishedActURLPolicy.isAllowedMosGorSud(url),
           MosGorSudRouting.section(fromCardURL: url) != nil {
            return PublishedActURLPolicy.safeMosGorSudURL(url)
        }
        if SudrfHost.isMSudrfHost(host), url.path == "/modules.php",
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.contains(where: { $0.name == "name" && $0.value == "sud_delo" }),
           items.contains(where: { $0.name == "op" && $0.value == "cs" }),
           items.contains(where: { $0.name == "case_id" && !($0.value ?? "").isEmpty }),
           items.contains(where: { $0.name == "delo_id" && !($0.value ?? "").isEmpty }) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url
        }
        return nil
    }

    private static func meaningfulCourt(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.localizedCaseInsensitiveContains("инстанция"),
              value.caseInsensitiveCompare("кассация") != .orderedSame,
              value.caseInsensitiveCompare("апелляция") != .orderedSame else { return nil }
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func normalizedText(_ text: String) -> String {
        ActParagraphizer.normalizedText(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func knownDate(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "—" ? nil : value
    }

    private static func kind(of title: String) -> String? {
        let title = title.lowercased()
        if title.contains("приговор") { return "приговор" }
        if title.contains("постановлен") { return "постановление" }
        if title.contains("определен") || title.contains("определён") { return "определение" }
        if title.contains("решени") { return "решение" }
        return nil
    }

    private static func humanTitle(_ title: String) -> String? {
        guard !title.localizedCaseInsensitiveContains("судебный акт #") else {
            switch kind(of: title) {
            case "решение": return "Решение"
            case "определение": return "Определение"
            case "постановление": return "Постановление"
            case "приговор": return "Приговор"
            default: return nil
            }
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.localizedCaseInsensitiveCompare("Судебный акт") == .orderedSame
            ? nil : trimmed
    }

    static func displayTitle(for title: String) -> String {
        humanTitle(title) ?? "Судебный акт"
    }

    private static func heading(in text: String) -> String? {
        for paragraph in ActParagraphizer.paragraphs(in: String(text.prefix(1_200))).prefix(6) {
            let compact = paragraph.text.uppercased()
                .filter { $0.isLetter }
            switch compact {
            case "ЗАОЧНОЕРЕШЕНИЕ": return "Заочное решение"
            case "АПЕЛЛЯЦИОННОЕОПРЕДЕЛЕНИЕ": return "Апелляционное определение"
            case "КАССАЦИОННОЕОПРЕДЕЛЕНИЕ": return "Кассационное определение"
            case "РЕШЕНИЕ": return "Решение"
            case "ОПРЕДЕЛЕНИЕ": return "Определение"
            case "ПОСТАНОВЛЕНИЕ": return "Постановление"
            case "ПРИГОВОР": return "Приговор"
            default: break
            }
        }
        return nil
    }

    static func stageLabel(_ level: CaseInstance.Level) -> String {
        switch level {
        case .first: "1-я инстанция"
        case .appeal: "апелляция"
        case .cassation, .vsCassation: "кассация"
        case .supervisory: "надзор"
        case .material: "материал"
        }
    }

    private static func fallbackTitle(_ level: CaseInstance.Level) -> String {
        switch level {
        case .first: "Акт первой инстанции"
        case .appeal: "Акт апелляционной инстанции"
        case .cassation, .vsCassation: "Акт кассационной инстанции"
        case .supervisory: "Акт надзорной инстанции"
        case .material: "Акт по материалу"
        }
    }
}
