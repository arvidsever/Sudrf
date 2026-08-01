//  CurrentEntityActivityFactory.swift
//  Sudrf
//
//  Контекст текущего дела для onscreen awareness.

import AppIntents
import Foundation

/// Собирает контекст открытого дела для onscreen awareness. `webpageURL`
/// намеренно не задаётся: Foundation принимает там только web URL и бросает
/// NSInvalidArgumentException для зарегистрированной схемы `sudrf://`.
@MainActor
enum CurrentEntityActivityFactory {
    static func caseActivity(caseNumber: String, identifier: String) -> NSUserActivity {
        make(
            activityType: "ru.sudrf.case",
            title: "Дело № \(caseNumber)",
            entityIdentifier: EntityIdentifier(for: CaseEntity.self, identifier: identifier))
    }

    static func courtActActivity(title: String, caseNumber: String,
                                 identifier: String) -> NSUserActivity {
        make(
            activityType: "ru.sudrf.court-act",
            title: "\(title) по делу № \(caseNumber)",
            entityIdentifier: EntityIdentifier(
                for: CourtActEntity.self, identifier: identifier))
    }

    private static func make(activityType: String, title: String,
                             entityIdentifier: EntityIdentifier) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = title
        activity.appEntityIdentifier = entityIdentifier
        activity.persistentIdentifier = NSUserActivityPersistentIdentifier(
            entityIdentifier.description)
        activity.isEligibleForSearch = true
        return activity
    }
}
