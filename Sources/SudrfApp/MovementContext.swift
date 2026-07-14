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

    /// Уникальный ключ дела для дедупликации/идентичности в хранилище:
    /// домашний суд (отображаемый домен) + № дела.
    var key: String { displayDomain + "/" + caseNumber }

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
                               vsrf: vsrf, mosgorsud: mosgorsud)
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
