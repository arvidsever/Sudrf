//  MovementContext.swift — Sudrf · v15
//  Переносимый «снимок поискового контекста» одного дела: всё, что нужно, чтобы
//  ПЕРЕЗАПРОСИТЬ движение по инстанциям с портала позже (из «Моих дел», Обзора,
//  Календаря), не держа в памяти живых объектов поиска.
//
//  Логика подбора доменов вышестоящих судов вынесена СЮДА из SearchModel и
//  используется обоими: и живым поиском (двойной клик), и перезапросом из
//  мониторинга. Это единственный источник правды о подсудности — раньше она
//  жила приватно в SearchModel.makeMovementService и при сопряжении разделов
//  рисковала разъехаться.

import Foundation
import SudrfKit

struct MovementContext: Codable, Equatable, Sendable {

    // Контекст суда/картотеки (как в форме поиска)
    var branchRaw: String          // CourtBranch.rawValue
    var region: String
    var searchDomain: String       // домен для сетевых запросов («--»-вариант)
    var displayDomain: String      // отображаемый («точечный») домен
    var courtTitle: String
    var courtLevelRaw: String      // CourtLevel.rawValue
    var courtCode: String?         // классификационный код (районные/гарнизонные)
    var cartotekaId: String
    var cartotekaLevelRaw: String  // CourtLevel картотеки

    // Базовая строка выдачи (для восстановления CaseSearchResult)
    var caseNumber: String
    var caseID: String?
    var caseUID: String?
    var essence: String?
    var judge: String?
    var receiptDate: String?
    var decisionDate: String?
    var resultText: String?
    var legalForceDate: String?
    var cardURLString: String?

    /// Настоящий судебный УИД (например, 11RS0001-01-...), в отличие от
    /// `caseUID`, который является GUID ссылки на карточку конкретного суда.
    var judicialUID: String? = nil
    /// Фактический процессуальный уровень базовой карточки. Optional сохраняет
    /// декодирование старых контекстов; для них уровень выводится из картотеки.
    var baseInstanceLevelRaw: String? = nil
    /// Точная исходная ссылка базовой карточки. При переякоривании вниз она
    /// становится known card и не теряется.
    var sourceKnownCard: KnownCard? = nil

    /// Известные прямые ссылки на карточки этого дела в других судах/картотеках
    /// (вышестоящие инстанции, материалы) — из импорта выгрузки стороннего
    /// сервиса. Опционально: старые сохранённые контексты декодируются без
    /// миграции. См. `KnownCard` в SudrfKit.
    var knownCards: [KnownCard]? = nil
    /// Точные цели поиска вышестоящих/связанных производств. Нужны мировым
    /// судьям: районная апелляция ищется по живому списку районных судов региона,
    /// а первая кассация зависит от даты вступления в силу.
    var higherCourtTargets: [MovementSearchTarget]? = nil

    // MARK: Производные значения

    var branch: CourtBranch { CourtBranch(rawValue: branchRaw) ?? .general }
    var courtLevel: CourtLevel { CourtLevel(rawValue: courtLevelRaw) ?? .district }
    var cartotekaLevel: CourtLevel { CourtLevel(rawValue: cartotekaLevelRaw) ?? courtLevel }
    var baseInstanceLevel: CaseInstance.Level {
        if let raw = baseInstanceLevelRaw, let level = CaseInstance.Level(rawValue: raw) { return level }
        return Self.instanceLevel(cartotekaID: cartotekaId, courtLevel: courtLevel,
                                  judicialUID: judicialUID)
    }

    static func instanceLevel(cartotekaID: String, courtLevel: CourtLevel,
                              judicialUID: String? = nil,
                              lowerCourtTitle: String? = nil) -> CaseInstance.Level {
        if let level = KoAPProceduralRole.resolve(
            courtLevel: courtLevel, cartotekaID: cartotekaID,
            judicialUID: judicialUID, lowerCourtTitle: lowerCourtTitle).instanceLevel {
            return level
        }
        if cartotekaID == "m" { return .material }
        if cartotekaID == "adm" || cartotekaID == "admj" || cartotekaID.hasSuffix("1") {
            return .first
        }
        if cartotekaID.hasSuffix("33") || cartotekaID.hasSuffix("3") { return .cassation }
        if cartotekaID.hasSuffix("2") { return .appeal }
        switch courtLevel {
        case .magistrate, .district: return .first
        case .subject, .appeal: return .appeal
        case .cassation: return .cassation
        }
    }

    var searchCourt: Court {
        Court(domain: searchDomain, title: courtTitle, level: courtLevel)
    }
    var cartoteka: Cartoteka? {
        CartotekaRegistry.find(level: cartotekaLevel, id: cartotekaId)
    }
    var baseResult: CaseSearchResult {
        CaseSearchResult(caseNumber: caseNumber, receiptDate: receiptDate,
                         essence: essence, judge: judge, decisionDate: decisionDate,
                         result: resultText, legalForceDate: legalForceDate,
                         caseID: caseID, caseUID: caseUID,
                         cardURL: cardURLString.flatMap(URL.init(string:)))
    }

    /// Saved movement is also a source of exact, already verified card links.
    /// Keep this enrichment ephemeral: every refresh rebuilds it from the
    /// persisted movement, while the stored context remains backward-compatible.
    func addingKnownCards(from movement: CaseMovement?) -> MovementContext {
        guard let movement else { return self }
        var result = self
        var cards: [KnownCard] = []
        for card in knownCards ?? [] { Self.mergeKnownCard(card, into: &cards) }
        let baseLocator = Self.baseCardLocator(self)

        for instance in movement.instances {
            guard let rawURL = instance.sourceURL,
                  let link = try? SudrfCaseCardLink(url: rawURL),
                  link.moduleHost == SudrfHost.moduleHost(instance.domain.lowercased())
            else { continue }

            let candidate = KnownCard(
                domain: instance.domain,
                courtTitle: instance.court,
                caseID: link.caseID ?? "",
                caseUID: link.caseUID ?? "",
                deloID: link.deloID,
                new: link.resolvedNew,
                caseNumber: instance.caseNumber,
                levelRaw: instance.level.rawValue,
                cartotekaID: instance.sourceEvidence?.cartotekaID,
                sourceURL: link.sanitizedURL)
            if let baseLocator, let candidateLocator = Self.knownCardLocator(candidate),
               Self.sameSourceCard(baseLocator, candidateLocator) {
                continue
            }

            Self.mergeKnownCard(candidate, into: &cards)
        }

        if !cards.isEmpty { result.knownCards = cards }
        return result
    }

    private struct KnownCardLocator {
        var host: String
        var caseID: String?
        var caseUID: String?
        var deloID: String
        var new: String
        var srvNum: String?
    }

    private static func sameSourceCard(_ lhs: KnownCard, _ rhs: KnownCard) -> Bool {
        guard let left = knownCardLocator(lhs), let right = knownCardLocator(rhs),
              sameSourceCard(left, right) else { return false }
        return true
    }

    private static func mergeKnownCard(_ candidate: KnownCard,
                                       into cards: inout [KnownCard]) {
        guard let index = cards.firstIndex(where: { sameSourceCard($0, candidate) }) else {
            cards.append(candidate)
            return
        }
        guard candidate.sourceURL != nil else { return }
        var enriched = cards[index]
        enriched.domain = candidate.domain
        enriched.courtTitle = candidate.courtTitle
        if enriched.caseID.isEmpty { enriched.caseID = candidate.caseID }
        if enriched.caseUID.isEmpty { enriched.caseUID = candidate.caseUID }
        enriched.deloID = candidate.deloID
        enriched.new = candidate.new
        enriched.caseNumber = candidate.caseNumber
        enriched.levelRaw = candidate.levelRaw
        enriched.cartotekaID = candidate.cartotekaID ?? enriched.cartotekaID
        enriched.sourceURL = candidate.sourceURL
        cards[index] = enriched
    }

    private static func sameSourceCard(_ left: KnownCardLocator,
                                       _ right: KnownCardLocator) -> Bool {
        guard left.host == right.host, left.deloID == right.deloID,
              left.new == right.new else { return false }
        if let leftUID = left.caseUID, let rightUID = right.caseUID {
            return leftUID == rightUID
        }
        guard let leftID = left.caseID, let rightID = right.caseID,
              leftID == rightID else { return false }
        return left.srvNum == nil || right.srvNum == nil || left.srvNum == right.srvNum
    }

    private static func knownCardLocator(_ card: KnownCard) -> KnownCardLocator? {
        if let url = card.sourceURL,
           let link = try? SudrfCaseCardLink(url: url),
           link.moduleHost == SudrfHost.moduleHost(card.domain.lowercased()) {
            return KnownCardLocator(
                host: link.moduleHost, caseID: link.caseID, caseUID: link.caseUID,
                deloID: link.deloID, new: link.resolvedNew, srvNum: link.srvNum)
        }
        let caseID = card.caseID.isEmpty ? nil : card.caseID
        let caseUID = card.caseUID.isEmpty ? nil : card.caseUID
        guard caseID != nil || caseUID != nil, !card.deloID.isEmpty else { return nil }
        return KnownCardLocator(
            host: SudrfHost.moduleHost(card.domain.lowercased()),
            caseID: caseID, caseUID: caseUID, deloID: card.deloID,
            new: card.new.isEmpty ? "0" : card.new, srvNum: nil)
    }

    private static func baseCardLocator(_ context: MovementContext) -> KnownCardLocator? {
        if let rawURL = context.cardURLString.flatMap(URL.init(string:)),
           let link = try? SudrfCaseCardLink(url: rawURL),
           link.moduleHost == SudrfHost.moduleHost(context.searchDomain.lowercased()) {
            return KnownCardLocator(
                host: link.moduleHost, caseID: link.caseID, caseUID: link.caseUID,
                deloID: link.deloID, new: link.resolvedNew, srvNum: link.srvNum)
        }
        if let source = context.sourceKnownCard,
           let locator = knownCardLocator(source) {
            return locator
        }
        let caseID = context.caseID.flatMap { $0.isEmpty ? nil : $0 }
        let caseUID = context.caseUID.flatMap { $0.isEmpty ? nil : $0 }
        guard caseID != nil || caseUID != nil, let cartoteka = context.cartoteka else {
            return nil
        }
        return KnownCardLocator(
            host: SudrfHost.moduleHost(context.searchDomain.lowercased()),
            caseID: caseID, caseUID: caseUID, deloID: cartoteka.deloID,
            new: cartoteka.new, srvNum: nil)
    }

    /// Display-derived legacy locator: домашний суд + номер дела. Он остаётся
    /// совместимым адресом поиска и deep links, но не является identity
    /// логического дела (её задаёт `TrackedCaseRecord.logicalCaseID`).
    var key: String {
        Self.identityKey(displayDomain: displayDomain, courtCode: courtCode,
                         caseNumber: caseNumber)
    }

    /// Формула historical locator, общая для legacy persistence и memory-кэша
    /// движения. V6 хранит это значение как неизменяемый key/alias, а не как
    /// правило сопоставления карточек.
    ///
    /// У ВСЕХ судов Москвы отображаемый домен один (`mos-gorsud.ru`), а номера
    /// дел в райсудах свои у каждого суда — «02-1234/2025» Савёловского и
    /// Тверского иначе схлопнулись бы в один ключ (чужое движение из кэша,
    /// перезатирание отслеживаемого дела). Поэтому для общего портального
    /// домена в ключ добавляется классификационный код суда. Для всех прочих
    /// судов (свой домен на суд) формула остаётся прежней — байт-в-байт, чтобы
    /// сохранённые дела не требовали миграции.
    static func identityKey(displayDomain: String, courtCode: String?,
                            caseNumber: String) -> String {
        if MosGorSudRouting.isMosGorSud(domain: displayDomain),
           let code = courtCode, !code.isEmpty {
            return displayDomain + "#" + code + "/" + caseNumber
        }
        return displayDomain + "/" + caseNumber
    }

    // MARK: Сервис движения (подбор доменов вышестоящих судов)

    func makeService(client: any CaseProviding, vsrf: (any VSRFProviding)? = nil,
                     mosgorsud: (any MosGorSudProviding)? = nil) -> MovementService {
        let exactTargets = higherCourtTargets ?? cartoteka.flatMap {
            MovementTargetBuilder.targets(
                branch: branch, courtLevel: courtLevel, baseCartoteka: $0,
                caseNumber: caseNumber, judicialUID: judicialUID,
                courtTitle: courtTitle, courtCode: courtCode, region: region,
                displayDomain: displayDomain)
        }
        return MovementService(client: client, higherCourtDomains: expandedHigherDomains(),
                               higherCourtTargets: exactTargets,
                               knownCards: knownCards ?? [],
                               baseInstanceLevel: baseInstanceLevel,
                               vsrf: vsrf, mosgorsud: mosgorsud,
                               judicialUID: judicialUID, branch: branch)
    }

    /// Домены вышестоящих судов с разворотом в оба синонима («vs--X» и «vs.X»):
    /// модуль sud_delo живёт на дефисном варианте, мёртвый молча пропускается.
    func expandedHigherDomains() -> [String] {
        Self.expandedHigherDomains(branch: branch, courtLevel: courtLevel,
                                   baseInstanceLevel: baseInstanceLevel,
                                   courtTitle: courtTitle, courtCode: courtCode,
                                   region: region, displayDomain: displayDomain)
    }

    /// Статическая версия — общая для перезапроса из мониторинга (экземпляр
    /// выше) и живого поиска (SearchModel, где контекст ещё не собран).
    /// Единственный источник правды о подсудности.
    static func expandedHigherDomains(branch: CourtBranch, courtLevel: CourtLevel,
                                      baseInstanceLevel: CaseInstance.Level = .first,
                                      courtTitle: String, courtCode: String?,
                                      region: String, displayDomain: String) -> [String] {
        MovementTargetBuilder.higherDomains(branch: branch, courtLevel: courtLevel,
                                            baseInstanceLevel: baseInstanceLevel,
                                            courtTitle: courtTitle, courtCode: courtCode,
                                            region: region, displayDomain: displayDomain)
            .flatMap { d -> [String] in
                if let dash = CourtDirectory.dashVariant(of: d) { return [dash, d] }
                return [d]
            }
    }

}
