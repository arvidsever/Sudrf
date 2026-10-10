import Foundation

enum JournalFeedComparison {
    static func mismatches(_ legacy: FeedEntry, _ shadow: FeedEntry)
        -> [(String, String?, String?)] {
        var values = [(String, String?, String?)]()
        func compare(_ field: String, _ old: String?, _ new: String?) {
            if old != new { values.append((field, old, new)) }
        }
        compare("dayHead", legacy.dayHead, shadow.dayHead)
        compare("date", String(legacy.date.timeIntervalSinceReferenceDate),
                String(shadow.date.timeIntervalSinceReferenceDate))
        compare("time", legacy.time, shadow.time)
        compare("recordKey", legacy.recordKey, shadow.recordKey)
        compare("caseNumber", legacy.caseNumber, shadow.caseNumber)
        compare("client", legacy.client, shadow.client)
        compare("kind", legacy.kind.rawValue, shadow.kind.rawValue)
        compare("text", legacy.text, shadow.text)
        compare("actID", legacy.actID, shadow.actID)
        compare("isUnread", String(legacy.isUnread), String(shadow.isUnread))
        compare("instanceCaseNumber", legacy.instanceCaseNumber, shadow.instanceCaseNumber)
        compare("instanceLevel", legacy.instanceLevel.rawValue, shadow.instanceLevel.rawValue)
        compare("sourceCardID", legacy.sourceCardID, shadow.sourceCardID)
        compare("sourceInstanceID", legacy.sourceInstanceID, shadow.sourceInstanceID)
        compare("previousRegistrationNumber", legacy.previousRegistrationNumber,
                shadow.previousRegistrationNumber)
        compare("secondaryLabel", legacy.secondaryLabel, shadow.secondaryLabel)
        compare("notificationSubtitle", legacy.notificationSubtitle, shadow.notificationSubtitle)
        return values
    }
}
