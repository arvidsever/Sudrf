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

    /// Известные прямые ссылки на карточки этого дела в других судах/картотеках
    /// (вышестоящие инстанции, материалы) — из импорта выгрузки стороннего
    /// сервиса. Опционально: старые сохранённые контексты декодируются без
    /// миграции. См. `KnownCard` в SudrfKit.
    var knownCards: [KnownCard]? = nil

    // MARK: Производные значения

    var branch: CourtBranch { CourtBranch(rawValue: branchRaw) ?? .general }
    var courtLevel: CourtLevel { CourtLevel(rawValue: courtLevelRaw) ?? .district }
    var cartotekaLevel: CourtLevel { CourtLevel(rawValue: cartotekaLevelRaw) ?? courtLevel }

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
        MovementService(client: client, higherCourtDomains: expandedHigherDomains(),
                        knownCards: knownCards ?? [], vsrf: vsrf, mosgorsud: mosgorsud)
    }

    /// Домены вышестоящих судов с разворотом в оба синонима («vs--X» и «vs.X»):
    /// модуль sud_delo живёт на дефисном варианте, мёртвый молча пропускается.
    func expandedHigherDomains() -> [String] {
        Self.expandedHigherDomains(branch: branch, courtLevel: courtLevel,
                                   courtTitle: courtTitle, courtCode: courtCode,
                                   region: region, displayDomain: displayDomain)
    }

    /// Статическая версия — общая для перезапроса из мониторинга (экземпляр
    /// выше) и живого поиска (SearchModel, где контекст ещё не собран).
    /// Единственный источник правды о подсудности.
    static func expandedHigherDomains(branch: CourtBranch, courtLevel: CourtLevel,
                                      courtTitle: String, courtCode: String?,
                                      region: String, displayDomain: String) -> [String] {
        higherCourtDomains(branch: branch, courtLevel: courtLevel,
                           courtTitle: courtTitle, courtCode: courtCode,
                           region: region, displayDomain: displayDomain)
            .flatMap { d -> [String] in
                if let dash = CourtDirectory.dashVariant(of: d) { return [dash, d] }
                return [d]
            }
    }

    /// Базовые домены вышестоящих судов по подсудности (без разворота синонимов).
    private static func higherCourtDomains(branch: CourtBranch, courtLevel: CourtLevel,
                                           courtTitle: String, courtCode: String?,
                                           region: String, displayDomain: String) -> [String] {
        guard branch == .general else {
            // Военная вертикаль (345-ФЗ / 466-ФЗ): подсудность гарнизонного суда —
            // по НАЗВАНИЮ (код субъекта дислокации врёт о юрисдикции).
            var domains: [String] = []
            switch courtLevel {
            case .district:   // гарнизонный → его окружной (флотский) → КВС
                if let okrug = CourtDirectory.okrugMilitaryCourt(
                        forGarrisonTitle: courtTitle, code: courtCode) {
                    domains.append(okrug.domain)
                }
                domains.append(CourtDirectory.cassationMilitaryCourt.domain)
            case .subject:    // окружной (1-я инстанция) → АВС → КВС
                domains.append(CourtDirectory.appellateMilitaryCourt.domain)
                domains.append(CourtDirectory.cassationMilitaryCourt.domain)
            default:
                break
            }
            return domains
        }
        var domains: [String] = []
        switch courtLevel {
        case .district:
            let code = courtCode.map(CourtDirectory.normalizedSubjectCode)
                ?? CourtDirectory.subjectNumericCode(forRegion: region)
            if let code {
                if let s = CourtDirectory.subjectCourt(forSubjectCode: code), s.isSudrfPlatform {
                    domains.append(s.domain)
                }
                if let k = CourtDirectory.cassationCourt(forSubjectCode: code) {
                    domains.append(k.domain)
                }
            }
        case .subject:
            if let code = CourtDirectory.subjectCode(forDomain: displayDomain) {
                if let a = CourtDirectory.appealCourt(forSubjectCode: code) { domains.append(a.domain) }
                if let k = CourtDirectory.cassationCourt(forSubjectCode: code) { domains.append(k.domain) }
            }
        default:
            break   // апелляция/кассация — выше только ВС РФ (вне проекта)
        }
        return domains
    }
}
