import Foundation

/// Уровень военного суда, для которого инструкция закрепляет индекс.
///
/// Это не заменяет `CourtLevel`: последний описывает техническое звено в
/// Sudrf, тогда как здесь важно не смешать одинаковые номера гарнизонного
/// дела и служебной корреспонденции окружного суда.
public enum MilitaryCaseIndexLevel: String, Sendable, Codable, Equatable {
    case garrison
    case circuitOrFleet
    case militaryAppeal
    case militaryCassation
}

/// Процессуальная функция карточки, определяемая индексом номера.
public enum CaseIndexCardRole: String, Sendable, Codable, Equatable {
    case firstInstanceCase
    case appellateCase
    case cassationCase
    case appellateComplaint
    case cassationComplaint
    case preliminaryIntakeMaterial
    case judicialControlMaterial
    case sentenceExecutionMaterial
    case decisionExecutionMaterial
    case proceduralMaterial
    case disciplinaryMaterial
    case operationalSearchMaterial
    case otherMaterial
    case courtCorrespondence
}

/// Насколько номер материала позволяет восстанавливать его основное дело.
///
/// Политика намеренно консервативна: номер материала сам по себе не является
/// ключом для создания или подстановки материнской карточки.
public enum CaseMaterialLinkPolicy: String, Sendable, Codable, Equatable {
    /// Карточка самостоятельна; родителя по номеру не восстанавливаем.
    case standalone
    /// До принятия заявления может появиться новое дело, но связь допустима
    /// только по внешним подтверждённым реквизитам, а не по производному номеру.
    case mayBecomeMainCase
    /// Жалоба относится к уже существующему делу; связь требует внешнего
    /// подтверждения и не выводится только из индекса.
    case requiresVerifiedParent
}

/// Нормализованное описание индекса из инструкций соответствующего звена.
public struct CaseIndexInfo: Sendable, Codable, Equatable {
    public let index: String
    public let processKind: ProcessKind?
    public let cardRole: CaseIndexCardRole
    public let materialLinkPolicy: CaseMaterialLinkPolicy
    public let courtLevel: CourtLevel
    public let branch: CourtBranch

    public init(index: String, processKind: ProcessKind?, cardRole: CaseIndexCardRole,
                materialLinkPolicy: CaseMaterialLinkPolicy = .standalone,
                courtLevel: CourtLevel, branch: CourtBranch) {
        self.index = index
        self.processKind = processKind
        self.cardRole = cardRole
        self.materialLinkPolicy = materialLinkPolicy
        self.courtLevel = courtLevel
        self.branch = branch
    }
}

/// Единый классификатор индексов номеров общих и военных судов.
///
/// Каталог не используется для выбора картотеки и не меняет существующую
/// эвристику `ProcessKind.detect`: он даёт потребителю явную, проверяемую
/// семантику номера, включая материалы и специальные военные звенья.
public enum CaseIndexClassifier {
    /// Нормализованный каталог. Индексы с подвидом (`3/1`, `4/17`) идут перед
    /// базовым индексом, поэтому их можно искать точным совпадением.
    public static let catalog: [CaseIndexInfo] = {
        var out: [CaseIndexInfo] = []
        let g = CourtLevel.district, s = CourtLevel.subject
        let a = CourtLevel.appeal, k = CourtLevel.cassation
        func add(_ index: String, _ kind: ProcessKind?, _ role: CaseIndexCardRole,
                 _ policy: CaseMaterialLinkPolicy = .standalone,
                 _ level: CourtLevel, _ branch: CourtBranch) {
            out.append(CaseIndexInfo(index: index, processKind: kind, cardRole: role,
                                     materialLinkPolicy: policy, courtLevel: level, branch: branch))
        }

        // Обычные районные/городские суды.
        add("1", .upk, .firstInstanceCase, .standalone, g, .general)
        add("2", .civil, .firstInstanceCase, .standalone, g, .general)
        add("2а", .administrative, .firstInstanceCase, .standalone, g, .general)
        for n in 1...17 { add("3/\(n)", .upk, .judicialControlMaterial, .standalone, g, .general) }
        add("3", .upk, .judicialControlMaterial, .standalone, g, .general)
        for n in 1...17 { add("4/\(n)", .upk, .sentenceExecutionMaterial, .standalone, g, .general) }
        add("4", .upk, .sentenceExecutionMaterial, .standalone, g, .general)
        add("5", .koap, .firstInstanceCase, .standalone, g, .general)
        add("6", .upk, .proceduralMaterial, .standalone, g, .general)
        for n in 1...2 { add("8/\(n)", .upk, .proceduralMaterial, .standalone, g, .general) }
        add("8", .upk, .proceduralMaterial, .standalone, g, .general)
        add("9", nil, .preliminaryIntakeMaterial, .mayBecomeMainCase, g, .general)
        add("м", nil, .preliminaryIntakeMaterial, .mayBecomeMainCase, g, .general)
        add("9а", .administrative, .preliminaryIntakeMaterial, .mayBecomeMainCase, g, .general)
        add("9у", .upk, .preliminaryIntakeMaterial, .mayBecomeMainCase, g, .general)
        add("10", .upk, .appellateCase, .requiresVerifiedParent, g, .general)
        add("11", .civil, .appellateCase, .requiresVerifiedParent, g, .general)
        add("11а", .administrative, .appellateCase, .requiresVerifiedParent, g, .general)
        add("12", .koap, .appellateComplaint, .requiresVerifiedParent, g, .general)
        add("13", .civil, .decisionExecutionMaterial, .requiresVerifiedParent, g, .general)
        add("13а", .administrative, .decisionExecutionMaterial, .requiresVerifiedParent, g, .general)
        add("14", .upk, .operationalSearchMaterial, .standalone, g, .general)
        add("15", nil, .otherMaterial, .standalone, g, .general)

        // Обычные суды субъекта.
        add("2", .upk, .firstInstanceCase, .standalone, s, .general)
        add("3", .civil, .firstInstanceCase, .standalone, s, .general)
        add("3а", .administrative, .firstInstanceCase, .standalone, s, .general)
        add("22", .upk, .appellateCase, .requiresVerifiedParent, s, .general)
        add("22к", .upk, .appellateComplaint, .requiresVerifiedParent, s, .general)
        add("33", .civil, .appellateCase, .requiresVerifiedParent, s, .general)
        add("33а", .administrative, .appellateCase, .requiresVerifiedParent, s, .general)
        add("7", .koap, .appellateComplaint, .requiresVerifiedParent, s, .general)
        add("12", .koap, .appellateComplaint, .requiresVerifiedParent, s, .general)

        // АСОЮ и КСОЮ.
        add("55", .upk, .appellateCase, .requiresVerifiedParent, a, .general)
        add("55к", .upk, .judicialControlMaterial, .standalone, a, .general)
        add("66", .civil, .appellateCase, .requiresVerifiedParent, a, .general)
        add("66а", .administrative, .appellateCase, .requiresVerifiedParent, a, .general)
        add("7у", .upk, .cassationComplaint, .requiresVerifiedParent, k, .general)
        add("77", .upk, .cassationCase, .requiresVerifiedParent, k, .general)
        add("8г", .civil, .cassationComplaint, .requiresVerifiedParent, k, .general)
        add("88", .civil, .cassationCase, .requiresVerifiedParent, k, .general)
        add("8а", .administrative, .cassationComplaint, .requiresVerifiedParent, k, .general)
        add("88а", .administrative, .cassationCase, .requiresVerifiedParent, k, .general)
        add("16", .koap, .cassationCase, .requiresVerifiedParent, k, .general)

        // Военные суды: гарнизонное звено использует тот же технический уровень
        // `.district`, но отдельную ветку, поскольку окружной индекс «2» иной.
        let militaryGarrisonExcluded = Set(["10", "11", "11а", "9а", "9у"])
        for entry in out.filter({
            $0.courtLevel == g && $0.branch == .general
                && !militaryGarrisonExcluded.contains($0.index)
        }) {
            var role = entry.cardRole
            var policy = entry.materialLinkPolicy
            var kind = entry.processKind
            if entry.index == "13" || entry.index == "13а" { policy = .requiresVerifiedParent }
            if entry.index == "да" { role = .disciplinaryMaterial; kind = .koap }
            add(entry.index, kind, role, policy, g, .military)
        }
        add("да", .koap, .disciplinaryMaterial, .standalone, g, .military)
        add("1", nil, .courtCorrespondence, .standalone, s, .military)
        add("2", .upk, .firstInstanceCase, .standalone, s, .military)
        add("3", .civil, .firstInstanceCase, .standalone, s, .military)
        add("3а", .administrative, .firstInstanceCase, .standalone, s, .military)
        add("4", nil, .courtCorrespondence, .standalone, s, .military)
        add("5", nil, .courtCorrespondence, .standalone, s, .military)
        add("6", nil, .courtCorrespondence, .standalone, s, .military)
        add("7", .koap, .appellateComplaint, .requiresVerifiedParent, s, .military)
        add("22", .upk, .appellateCase, .requiresVerifiedParent, s, .military)
        add("33", .civil, .appellateCase, .requiresVerifiedParent, s, .military)
        add("33а", .administrative, .appellateCase, .requiresVerifiedParent, s, .military)
        for entry in out.filter({ $0.courtLevel == a && $0.branch == .general }) { add(entry.index, entry.processKind, entry.cardRole, entry.materialLinkPolicy, a, .military) }
        for entry in out.filter({ $0.courtLevel == k && $0.branch == .general }) { add(entry.index, entry.processKind, entry.cardRole, entry.materialLinkPolicy, k, .military) }
        add("55к", .upk, .judicialControlMaterial, .standalone, k, .military)
        return out
    }()

    /// Выделяет индекс из номера (`№ 3/15-44/2026`, латинские двойники и
    /// регистр допускаются). Неизвестный или неполный номер возвращает `nil`.
    public static func normalizedIndex(from caseNumber: String) -> String? {
        let number = CartotekaRegistry.normalizedNumber(caseNumber)
        guard let dash = number.firstIndex(of: "-"), dash > number.startIndex else { return nil }
        let index = String(number[..<dash])
        return index.isEmpty ? nil : index
    }

    public static func classify(caseNumber: String, courtLevel: CourtLevel,
                                branch: CourtBranch = .general) -> CaseIndexInfo? {
        guard let index = normalizedIndex(from: caseNumber) else { return nil }
        return catalog.first { $0.index == index && $0.courtLevel == courtLevel && $0.branch == branch }
    }

    /// Удобный мост для существующих технических звеньев Sudrf. Он нужен только
    /// когда вызывающий уже знает, что суд военный.
    public static func classify(caseNumber: String, level: MilitaryCaseIndexLevel) -> CaseIndexInfo? {
        switch level {
        case .garrison: return classify(caseNumber: caseNumber, courtLevel: .district, branch: .military)
        case .circuitOrFleet: return classify(caseNumber: caseNumber, courtLevel: .subject, branch: .military)
        case .militaryAppeal: return classify(caseNumber: caseNumber, courtLevel: .appeal, branch: .military)
        case .militaryCassation: return classify(caseNumber: caseNumber, courtLevel: .cassation, branch: .military)
        }
    }
}
