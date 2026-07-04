import Foundation

/// Кэш «рабочего» варианта поискового URL по суду и картотеке.
///
/// Варианты выдачи перебираются по порядку (SudrfURLBuilder.searchURLVariants);
/// какой из них понимает конкретный суд — выясняется опытным путём и запоминается
/// здесь, чтобы следующие запросы начинались сразу с рабочего. Записи устаревают
/// (суд могут переустановить на другую версию модуля), поэтому хранится дата.
///
/// Синглтон: клиентов SudrfClient в приложении два (поиск и фоновое обновление),
/// кэш у них общий. Персистентность — JSON в Caches, по образцу DistrictCourtResolver.
public actor WorkingVariantStore {

    public static let shared = WorkingVariantStore()

    struct Record: Codable {
        var variantID: String
        var savedAt: Date
    }

    private let cacheURL: URL?
    private let ttl: TimeInterval
    private var records: [String: Record] = [:]
    private var diskLoaded = false

    public init(cacheURL: URL? = WorkingVariantStore.defaultCacheURL(),
                ttl: TimeInterval = 30 * 24 * 3600) {
        self.cacheURL = cacheURL
        self.ttl = ttl
    }

    public static func defaultCacheURL() -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("SudrfKit-working-variants.json")
    }

    /// Ключ: модульный хост + картотека (delo_id/new) — sud_delo различает
    /// поведение по виду производства, поэтому кэшировать на весь суд нельзя.
    private func key(domain: String, cartoteka: Cartoteka) -> String {
        "\(SudrfHost.moduleHost(domain.lowercased()))|\(cartoteka.deloID)|\(cartoteka.new)"
    }

    public func workingVariantID(domain: String, cartoteka: Cartoteka) -> String? {
        loadIfNeeded()
        let k = key(domain: domain, cartoteka: cartoteka)
        guard let rec = records[k] else { return nil }
        guard Date().timeIntervalSince(rec.savedAt) < ttl else {
            records.removeValue(forKey: k)
            return nil
        }
        return rec.variantID
    }

    public func remember(variantID: String, domain: String, cartoteka: Cartoteka) {
        loadIfNeeded()
        records[key(domain: domain, cartoteka: cartoteka)] =
            Record(variantID: variantID, savedAt: Date())
        persist()
    }

    public func forget(domain: String, cartoteka: Cartoteka) {
        loadIfNeeded()
        records.removeValue(forKey: key(domain: domain, cartoteka: cartoteka))
        persist()
    }

    // MARK: - диск

    private func loadIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([String: Record].self, from: data) else { return }
        records = loaded
    }

    private func persist() {
        guard let url = cacheURL,
              let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
