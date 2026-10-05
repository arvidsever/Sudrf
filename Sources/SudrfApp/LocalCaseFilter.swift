import Foundation
import SudrfKit

/// Search index for the local "My Cases" list. Fields are built with each row
/// projection so keystrokes never decode saved movement or context data.
enum LocalCaseFilter {
    enum Kind: String, CaseIterable {
        case number, uid, judge, party, article, court, region, collection
        case category, production, stage, status

        var label: String {
            switch self {
            case .number: "Номер производства"
            case .uid: "УИД"
            case .judge: "Судья"
            case .party: "Участник"
            case .article: "Статья"
            case .court: "Суд"
            case .region: "Регион"
            case .collection: "Подборка"
            case .category: "Категория"
            case .production: "Вид производства"
            case .stage: "Стадия"
            case .status: "Статус"
            }
        }
    }

    struct Field: Equatable {
        let kind: Kind
        let value: String
        var sourceCourt: String? = nil
        var sourceNumber: String? = nil
        fileprivate let normalizedValue: String
        fileprivate let nameSurname: String?
        fileprivate let nameInitials: String?

        var label: String { kind.label }

        init(kind: Kind, value: String, sourceCourt: String? = nil,
             sourceNumber: String? = nil) {
            self.kind = kind
            self.value = value
            self.sourceCourt = sourceCourt
            self.sourceNumber = sourceNumber
            self.normalizedValue = kind == .uid
                ? JudicialUIDObservation.normalize(value).lowercased()
                : (kind == .number ? LocalCaseFilter.normalizeNumber(value) : LocalCaseFilter.normalize(value))
            let short = (kind == .judge || kind == .party)
                ? LocalCaseFilter.shortName(value) : nil
            self.nameSurname = short?.0
            self.nameInitials = short?.1
        }
    }

    struct Query {
        fileprivate enum Term {
            case token(String, exactReference: Bool)
            case initials(String)
            case surnameInitials(String, String)
            case candidateName(String, String, words: [String])
            case fullName(String)
        }

        fileprivate let terms: [Term]
        var isEmpty: Bool { terms.isEmpty }

        init(_ raw: String) {
            let tokens = normalizeNumber(raw, lowercasing: false)
                .split(whereSeparator: \.isWhitespace).map(String.init)
            var parsed: [Term] = []
            var index = 0
            func initials(at start: Int, undotted: Bool = false) -> (String, Int)? {
                guard start < tokens.count else { return nil }
                if let first = LocalCaseFilter.initialsToken(tokens[start], undotted: undotted) {
                    if first.count == 1, start + 1 < tokens.count,
                       let second = LocalCaseFilter.initialsToken(tokens[start + 1], undotted: undotted), second.count == 1 {
                        return (first + second, 2)
                    }
                    return undotted || tokens[start].contains(".") ? (first, 1) : nil
                }
                return nil
            }
            while index < tokens.count {
                let token = normalize(tokens[index])
                let isWord = token.allSatisfy { $0.isLetter || $0 == "-" }
                if isWord, token.count > 2, let (letters, count) = initials(at: index + 1, undotted: true) {
                    if tokens[index + 1...index + count].contains(where: { $0.contains(".") }) {
                        parsed.append(.surnameInitials(token, letters))
                    } else {
                        parsed.append(.candidateName(token, letters, words: tokens[index...index + count].map { normalize($0) }))
                    }
                    index += count + 1
                } else if index + 2 < tokens.count, isWord,
                          tokens[index + 1].allSatisfy(\.isLetter),
                          ["ич", "вна", "чна"].contains(where: normalize(tokens[index + 2]).hasSuffix) {
                    parsed.append(.fullName(normalize(tokens[index...index + 2].joined(separator: " "))))
                    index += 3
                } else if let (letters, count) = initials(at: index) {
                    parsed.append(.initials(letters))
                    index += count
                } else {
                    if token.contains(where: { $0.isLetter || $0.isNumber }) {
                        let uidValidity = JudicialUIDObservation.validity(of: token)
                        let isUID = uidValidity == .valid || (uidValidity == .partial && JudicialUIDObservation.normalize(token).count >= 4)
                        let completeNumber = token.range(of: #"^[\p{L}\d]+[-/][\p{L}\d./-]*/\d{4}$"#,
                            options: .regularExpression) != nil
                        parsed.append(.token(isUID ? JudicialUIDObservation.normalize(token).lowercased() : token,
                            exactReference: uidValidity == .valid || completeNumber))
                    }
                    index += 1
                }
            }
            terms = parsed
        }
    }

    static func searchText(for fields: [Field]) -> String {
        fields.map(\.normalizedValue).joined(separator: "\n")
    }

    static func matches(_ row: TrackedCase, query: Query) -> Bool {
        let fields = row.searchFields.isEmpty ? legacyFields(for: row) : row.searchFields
        let text = row.searchText.isEmpty ? searchText(for: fields) : row.searchText
        return resolvedTerms(query, fields: fields).allSatisfy { term in
            if case .token(let value, exactReference: false) = term { return text.range(of: value, options: .literal) != nil }
            return fields.contains { matches(term, in: $0) }
        }
    }

    /// Undotted initials are ambiguous with acronyms. Bind them only to a known
    /// surname in this dossier; otherwise preserve ordinary AND word matching.
    private static func resolvedTerms(_ query: Query, fields: [Field]) -> [Query.Term] {
        query.terms.flatMap { term -> [Query.Term] in
            if case .candidateName(let surname, let initials, let words) = term {
                if fields.contains(where: { $0.nameSurname == surname }) {
                    return [.surnameInitials(surname, initials)]
                }
                return words.map { .token($0, exactReference: false) }
            }
            return [term]
        }
    }

    /// One original field per query term keeps explanations short even for large parties lists.
    static func explanation(for row: TrackedCase, query raw: String) -> String? {
        let query = Query(raw)
        guard !query.isEmpty else { return nil }
        let fields = row.searchFields.isEmpty ? legacyFields(for: row) : row.searchFields
        var shown: [String] = []
        for term in resolvedTerms(query, fields: fields) {
            guard let field = fields.first(where: { $0.sourceCourt != nil && matches(term, in: $0) })
                    ?? fields.first(where: { matches(term, in: $0) }) else { return nil }
            let details = [field.value, field.sourceCourt, field.sourceNumber.map { "№ \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            let line = "\(field.label): \(details)"
            if !shown.contains(line) { shown.append(line) }
        }
        return shown.joined(separator: "\n")
    }

    static func fields(for row: TrackedCase, record: TrackedCaseRecord,
                       context: MovementContext?, movement: CaseMovement?,
                       snapshot: CaseSnapshot?) -> [Field] {
        var fields: [Field] = []
        var seen = Set<String>()
        func add(_ value: String?, _ kind: Kind, court: String? = nil,
                 number: String? = nil) {
            guard let value, shouldIndex(value, kind: kind) else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = [kind.rawValue, normalize(trimmed), normalize(court ?? ""),
                       normalize(number ?? "")].joined(separator: "|")
            guard seen.insert(key).inserted else { return }
            fields.append(Field(kind: kind, value: trimmed, sourceCourt: court,
                                sourceNumber: number))
        }
        func addNumber(_ raw: String?, court: String? = nil) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard shouldIndex(trimmed, kind: .number) else { return }
            add(trimmed, .number, court: court, number: trimmed)
            for token in numberTokens(in: trimmed) where token != trimmed {
                add(token, .number, court: court, number: token)
            }
        }
        func addUID(_ raw: String?) {
            guard let raw, JudicialUIDObservation.validity(of: raw) == .valid else { return }
            add(raw, .uid)
        }
        func addJudge(_ raw: String?, court: String?, number: String?) {
            add(raw, .judge, court: court, number: number)
        }
        func addCourt(_ title: String?, domain: String?, region: String? = nil,
                      number: String? = nil) {
            if let title, !CourtNamePresentation.isTechnicalCourtTitle(title) {
                add(title, .court, number: number)
            }
            if let domain, let official = CourtDirectory.court(forDomain: domain)?.title {
                add(official, .court, number: number)
            }
            add(region, .region, number: number)
        }
        func addParties(_ parties: CaseParties?, court: String?, number: String?) {
            guard let parties else { return }
            for name in parties.plaintiffs + parties.defendants + parties.thirdParties {
                add(name, .party, court: court, number: number)
            }
            for column in parties.columns {
                add(column.title, .party, court: court, number: number)
                add(column.titleMany, .party, court: court, number: number)
                for member in column.members {
                    add(member.name, .party, court: court, number: number)
                    add(member.sub, .party, court: court, number: number)
                    add(member.articles, .article, court: court, number: number)
                }
            }
            for item in parties.roleItems {
                add(item.role, .party, court: court, number: number)
                add(item.name, .party, court: court, number: number)
                add(item.articles, .article, court: court, number: number)
            }
        }

        let rootCourt = context?.courtTitle ?? record.courtTitle
        addNumber(row.caseNumber, court: row.recordCourt)
        row.previousCaseNumbers.forEach { addNumber($0) }
        row.searchCaseNumbers.forEach { addNumber($0) }
        addNumber(row.currentReviewNumber)
        add(row.partiesShort, .party, court: rootCourt, number: row.caseNumber)
        add(row.leadCharges, .article, court: rootCourt, number: row.caseNumber)
        if let second = row.secondPartyLine {
            add(second.name, .party, court: rootCourt, number: row.caseNumber)
            add(second.articles, .article, court: rootCourt, number: row.caseNumber)
        }
        row.collections.forEach { add($0, .collection) }
        add(row.subject, .category)
        add(row.productionLabel, .production)
        add(row.production?.side, .production)
        add(row.stage.label, .stage)
        add(row.stageTag, .stage)
        add(row.statusText, .status)

        addNumber(record.caseNumber, court: row.recordCourt)
        addCourt(row.recordCourt, domain: record.displayDomain, number: record.caseNumber)
        addUID(record.judicialUID)
        if let context {
            addNumber(context.caseNumber, court: context.courtTitle)
            addUID(context.judicialUID)
            addJudge(context.judge, court: context.courtTitle, number: context.caseNumber)
            addCourt(context.courtTitle, domain: context.displayDomain,
                     region: context.region, number: context.caseNumber)
            add(context.cartoteka?.title, .category, number: context.caseNumber)
            let parsed = CaseParties.split(essence: context.essence)
            add(parsed.residual, .category, number: context.caseNumber)
            addParties(parsed.parties, court: context.courtTitle, number: context.caseNumber)
            if let sourceCard = context.sourceKnownCard {
                addNumber(sourceCard.caseNumber, court: sourceCard.courtTitle)
                addCourt(sourceCard.courtTitle, domain: sourceCard.domain,
                         number: sourceCard.caseNumber)
            }
            for card in context.knownCards ?? [] {
                addNumber(card.caseNumber, court: card.courtTitle)
                addCourt(card.courtTitle, domain: card.domain,
                         number: card.caseNumber)
            }
        }

        // The persisted identity graph contains only source-verified bindings.
        if let identity = TrackedCaseIdentity.persistedState(for: record) {
            identity.numberHistory.forEach { addNumber($0.rawValue) }
            identity.cards.compactMap(\.currentCaseNumber).forEach { addNumber($0) }
            identity.judicialUIDs.forEach { addUID($0) }
        }
        if let movement {
            addNumber(movement.caseNumber, court: context?.courtTitle)
            addUID(movement.uid)
            add(movement.category, .category)
            addParties(movement.parties, court: context?.courtTitle,
                       number: movement.caseNumber)
            for instance in movement.instances where instance.captchaFormURL == nil
                    && instance.transientError != true {
                addNumber(instance.caseNumber, court: instance.court)
                addJudge(instance.judge, court: instance.court, number: instance.caseNumber)
                addCourt(instance.court, domain: instance.domain,
                         number: instance.caseNumber)
                if let evidence = instance.sourceEvidence {
                    addUID(evidence.judicialUID)
                    add(evidence.category, .category, court: instance.court,
                        number: instance.caseNumber)
                    evidence.appealKinds?.forEach {
                        add($0, .category, court: instance.court, number: instance.caseNumber)
                    }
                    add(evidence.reviewProcedure, .category, court: instance.court,
                        number: instance.caseNumber)
                    if let lower = evidence.lowerCourt {
                        addNumber(lower.caseNumber, court: lower.courtTitle)
                        addJudge(lower.judge, court: lower.courtTitle,
                                 number: lower.caseNumber)
                        addCourt(lower.courtTitle, domain: nil, region: lower.region,
                                 number: lower.caseNumber)
                    }
                }
                if let previous = instance.previousRegistration {
                    addNumber(previous.caseNumber, court: instance.court)
                }
            }
            for complaint in movement.complaints.values {
                add(complaint.label, .category, court: complaint.court,
                    number: complaint.caseNumber)
                addNumber(complaint.caseNumber, court: complaint.court)
                addCourt(complaint.court, domain: nil, number: complaint.caseNumber)
            }
        }
        if let snapshot {
            addUID(snapshot.uid)
            add(snapshot.category, .category)
            let transientNumbers = Set((movement?.instances ?? []).filter {
                $0.captchaFormURL != nil || $0.transientError == true
            }.map { normalize($0.caseNumber) })
            snapshot.instanceObservations?.filter {
                !transientNumbers.contains(normalize($0.caseNumber))
            }.forEach { observation in
                addNumber(observation.caseNumber, court: observation.court)
                addJudge(observation.judge, court: observation.court,
                         number: observation.caseNumber)
                addCourt(observation.court, domain: nil, number: observation.caseNumber)
            }
            snapshot.complaintObservations?.forEach { observation in
                addNumber(observation.caseNumber, court: observation.court)
                addCourt(observation.court, domain: nil, number: observation.caseNumber)
            }
        }
        return fields
    }

    private static func matches(_ term: Query.Term, in field: Field) -> Bool {
        switch term {
        case .token(let value, let exact):
            if exact {
                return (field.kind == .number || field.kind == .uid) && field.normalizedValue == value
            }
            return field.normalizedValue.range(of: value, options: .literal) != nil
        case .initials(let letters):
            return field.nameInitials == letters
        case .surnameInitials(let surname, let letters):
            return field.nameSurname == surname && field.nameInitials == letters
        case .candidateName:
            return false // Resolved against the dossier before matching.
        case .fullName(let value):
            return (field.kind == .judge || field.kind == .party) && field.normalizedValue.range(of: value, options: .literal) != nil
        }
    }

    private static func legacyFields(for row: TrackedCase) -> [Field] {
        var result: [Field] = []
        for number in [row.caseNumber, row.currentReviewNumber].compactMap({ $0 })
            + row.previousCaseNumbers + row.searchCaseNumbers {
            result.append(Field(kind: .number, value: number))
        }
        for value in [row.partiesShort, row.leadCharges, row.secondPartyLine?.name,
                      row.secondPartyLine?.articles].compactMap({ $0 }) {
            result.append(Field(kind: value == row.leadCharges
                                || value == row.secondPartyLine?.articles ? .article : .party,
                                value: value))
        }
        result += row.collections.map { Field(kind: .collection, value: $0) }
        result += [row.court, row.recordCourt].map { Field(kind: .court, value: $0) }
        result.append(Field(kind: .category, value: row.subject))
        result.append(Field(kind: .production, value: row.productionLabel))
        result.append(Field(kind: .stage, value: row.stage.label))
        result.append(Field(kind: .status, value: row.statusText))
        return result
    }

    private static func numberTokens(in value: String) -> [String] {
        value.split(whereSeparator: {
            $0 == "~" || $0 == "∼" || $0 == "(" || $0 == ")"
                || $0 == "[" || $0 == "]" || $0 == ";" || $0 == ","
        }).compactMap { part in
            let token = CaseNumberPresentation.primary(normalizeNumber(String(part), lowercasing: false))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
    }

    private static func initialsToken(_ raw: String, undotted: Bool = false) -> String? {
        let letters = raw.filter(\.isLetter)
        guard (1...2).contains(letters.count) else { return nil }
        let dotted = raw.range(of: #"^(?:[\p{L}]\.){1,2}$|^[\p{L}]\.[\p{L}]\.?$"#,
            options: .regularExpression) != nil
        let plain = undotted && raw.allSatisfy(\.isLetter)
        guard dotted || plain else { return nil }
        return normalize(letters)
    }

    /// Reuse the existing safe person formatter; accept only its surname/initials form.
    private static func shortName(_ raw: String) -> (String, String)? {
        let source = normalize(raw, lowercasing: false)
        let rawParts = source.split(whereSeparator: \.isWhitespace).map(String.init)
        let plainInitials = rawParts.count == 3 && rawParts.dropFirst().allSatisfy { $0.count == 1 && $0.allSatisfy(\.isLetter) }
        let compactInitials = rawParts.count == 2 && rawParts[1].count == 2
            && rawParts[1].allSatisfy { $0.isLetter && $0.isUppercase }
        let candidate = plainInitials || compactInitials ? source : PartyNamePresentation.level1(source.capitalized)
        let parts = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count >= 2, parts.count <= 3,
              parts[0].allSatisfy({ $0.isLetter || $0 == "-" }),
              parts.dropFirst().allSatisfy({ initialsToken($0, undotted: plainInitials || compactInitials) != nil }) else { return nil }
        let letters = parts.dropFirst().compactMap { initialsToken($0, undotted: plainInitials || compactInitials) }.joined()
        guard (1...2).contains(letters.count) else { return nil }
        return (normalize(parts[0]), letters)
    }

    private static func normalizeNumber(_ raw: String, lowercasing: Bool = true) -> String {
        normalize(raw, lowercasing: lowercasing)
            .replacingOccurrences(of: #"(?<=[\p{L}\d])\s*([-/])\s*(?=[\p{L}\d])"#,
                                  with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\d)\s*\.\s*(?=\d)"#,
                                  with: ".", options: .regularExpression)
    }

    private static func shouldIndex(_ value: String, kind: Kind) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !["—", "–", "-"].contains(clean) else { return false }
        if kind == .court && CourtNamePresentation.isTechnicalCourtTitle(clean) { return false }
        if kind == .status {
            let lower = clean.lowercased()
            return !lower.contains("captcha") && !lower.contains("капч")
                && !lower.contains("введите код")
                && lower != "откройте, чтобы загрузить"
                && lower != "движение ещё не загружено"
        }
        return true
    }

    fileprivate static func normalize(_ raw: String, lowercasing: Bool = true) -> String {
        var value = raw
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{202f}", with: " ")
        for hyphen in ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}",
                       "\u{2014}", "\u{2015}", "\u{2212}", "\u{00ad}"] {
            value = value.replacingOccurrences(of: hyphen, with: "-")
        }
        return (lowercasing ? value.lowercased() : value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
