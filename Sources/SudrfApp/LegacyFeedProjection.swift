import Foundation
import SudrfKit

struct LegacyFeedRecordInput {
    let recordKey: String
    let caseNumber: String
    let client: String
    let unreadByCase: Bool
    let snapshot: CaseSnapshot?
    let acts: [CaseAct]
    let instances: [CaseInstance]
    let context: MovementContext?
    let enforcementRecords: [EnforcementRecord]
    private let materialInstancesBySourceID: [String: CaseInstance]
    private let previousRegistrationsBySourceID: [String: CaseInstance]

    init(recordKey: String, caseNumber: String, client: String, unreadByCase: Bool,
         snapshot: CaseSnapshot?, movement: CaseMovement?, context: MovementContext?,
         enforcementRecords: [EnforcementRecord]) {
        self.recordKey = recordKey
        self.caseNumber = caseNumber
        self.client = client
        self.unreadByCase = unreadByCase
        self.snapshot = snapshot
        self.context = snapshot == nil ? nil : context
        self.enforcementRecords = enforcementRecords

        let projectedActs: [CaseAct]
        let projectedInstances: [CaseInstance]
        if snapshot != nil, let movement {
            projectedActs = movement.acts.map {
                CaseAct(id: $0.id, title: $0.title, date: $0.date,
                        courtShort: $0.courtShort, instanceLevel: $0.instanceLevel)
            }
            projectedInstances = movement.instances.map { instance in
                // Keep renderer fields without retaining per-instance sessions or linked act files.
                CaseInstance(
                    level: instance.level, court: instance.court,
                    caseNumber: instance.caseNumber, judge: instance.judge,
                    domain: instance.domain, foundByUID: instance.foundByUID,
                    result: instance.result, sessions: [], actID: instance.actID,
                    actIDs: instance.actIDs, captchaFormURL: instance.captchaFormURL,
                    note: instance.note, sourceURL: instance.sourceURL,
                    transientError: instance.transientError)
            }
        } else {
            projectedActs = []
            projectedInstances = []
        }
        acts = projectedActs
        instances = projectedInstances

        if snapshot != nil, let context, !projectedInstances.isEmpty {
            let movement = CaseMovement(
                uid: "", caseNumber: caseNumber, inForce: false,
                instances: projectedInstances, complaints: [:], acts: [])
            materialInstancesBySourceID = AppRouter.materialInstancesBySourceID(
                movement: movement, context: context)
            var grouped = [String: [CaseInstance]]()
            for instance in projectedInstances where instance.note == "Предыдущая регистрация" {
                guard let sourceID = AppRouter.previousRegistrationSourceCardID(
                    for: instance, context: context) else { continue }
                grouped[sourceID, default: []].append(instance)
            }
            previousRegistrationsBySourceID = grouped.compactMapValues {
                $0.count == 1 ? $0[0] : nil
            }
        } else {
            materialInstancesBySourceID = [:]
            previousRegistrationsBySourceID = [:]
        }
    }

    func materialSource(_ session: StoredSession) -> (instance: CaseInstance?, number: String?) {
        guard session.level == .material else { return (nil, nil) }
        let candidate = session.sourceCardID.flatMap { materialInstancesBySourceID[$0] }
        let stored = CaseNumberPresentation.secondary(session.caseNumber, distinctFrom: "")
        let current = candidate.flatMap(MovementDerivation.materialNumber)
        if let stored, let current,
           CaseNumberPresentation.primary(stored) != CaseNumberPresentation.primary(current) {
            return (nil, nil)
        }
        return (candidate, stored ?? current)
    }

    func previousRegistrationSource(_ session: StoredSession)
        -> (instance: CaseInstance, number: String, sourceID: String)? {
        guard let sourceID = session.sourceCardID,
              let instance = previousRegistrationsBySourceID[sourceID] else { return nil }
        let number = CaseNumberPresentation.secondary(
            session.caseNumber, distinctFrom: caseNumber)
            ?? CaseNumberPresentation.secondary(
                instance.caseNumber, distinctFrom: caseNumber)
        guard let number else { return nil }
        return (instance, number, sourceID)
    }

    func materialInstance(forSourceCardID sourceCardID: String) -> CaseInstance? {
        materialInstancesBySourceID[sourceCardID]
    }
}

struct LegacyFeedProjectionResult {
    let entries: [FeedEntry]
    let migratedReadIDs: Set<String>
    let migratedKnownIDs: Set<String>
    let migrationState: MaterialFeedMigrationState
}

enum LegacyFeedProjection {
    static func project(records: [LegacyFeedRecordInput], today: Date,
                        readIDs: Set<String>, knownIDs: Set<String>,
                        migrationState: MaterialFeedMigrationState)
        -> LegacyFeedProjectionResult {
        var entries = [FeedEntry]()
        var materialFeedTransitions = [String: Set<String>]()
        var unresolvedMaterialFeedCounts = [String: Int]()
        var materialFeedIDs = Set<String>()
        var normalFeedIDs = Set<String>()

        for record in records {
            for enforcement in record.enforcementRecords where enforcement.source == .treasury {
                for event in enforcement.events {
                    guard let date = event.date ?? event.dateRaw.flatMap(DateUtil.parse) else { continue }
                    guard let guid = event.guid?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !guid.isEmpty else { continue }
                    let diff = DateUtil.daysBetween(date, today)
                    guard diff >= 0 && diff <= 45 else { continue }
                    let id = AppRouter.enforcementFeedID(recordKey: record.recordKey, guid: guid)
                    entries.append(FeedEntry(
                        id: id, dayHead: nil, date: date, time: "—", recordKey: record.recordKey,
                        caseNumber: record.caseNumber, client: record.client, kind: .enforcement,
                        text: event.text, actID: nil, isUnread: !readIDs.contains(id)))
                }
            }

            guard let snapshot = record.snapshot else { continue }
            for session in snapshot.sessions {
                guard let date = session.date else { continue }
                let diff = DateUtil.daysBetween(date, today)
                guard diff >= 0 && diff <= 45 else { continue }
                let text = session.result ?? session.event
                let kind = AppRouter.feedKind(for: session)
                let legacyID = AppRouter.feedID(
                    recordKey: record.recordKey, date: date,
                    time: session.time ?? "—", text: text)
                let material = record.materialSource(session)
                let previousRegistration = record.previousRegistrationSource(session)
                let id: String
                if session.level == .material, let sourceCardID = session.sourceCardID {
                    id = AppRouter.materialFeedID(
                        legacyID: legacyID, sourceCardID: sourceCardID)
                    materialFeedTransitions[legacyID, default: []].insert(id)
                } else {
                    id = legacyID
                    if session.level == .material {
                        unresolvedMaterialFeedCounts[legacyID, default: 0] += 1
                    } else {
                        normalFeedIDs.insert(legacyID)
                    }
                }
                if session.level == .material, !materialFeedIDs.insert(id).inserted { continue }
                entries.append(FeedEntry(
                    id: id, dayHead: nil, date: date, time: session.time ?? "—",
                    recordKey: record.recordKey, caseNumber: record.caseNumber,
                    client: record.client, kind: kind, text: text, actID: nil,
                    isUnread: record.unreadByCase && !readIDs.contains(id),
                    instanceCaseNumber: previousRegistration?.number
                        ?? (session.level == .material ? material.number : session.caseNumber),
                    instanceLevel: session.level, sourceCardID: session.sourceCardID,
                    sourceInstanceID: previousRegistration?.instance.id ?? material.instance?.id,
                    previousRegistrationNumber: previousRegistration?.number))
            }

            if !record.acts.isEmpty {
                for act in record.acts {
                    guard let date = DateUtil.parse(act.date) else { continue }
                    let diff = DateUtil.daysBetween(date, today)
                    guard diff >= 0 && diff <= 45 else { continue }
                    let text = "Опубликован судебный акт: \(act.title)"
                    let legacyID = AppRouter.feedID(
                        recordKey: record.recordKey, date: date, time: "—", text: act.id)
                    let linked = record.instances.filter { $0.linkedActIDs.contains(act.id) }
                    let exactOwner = linked.count == 1 ? linked[0] : nil
                    let sourceLevel = exactOwner?.level ?? act.instanceLevel
                    let previousRegistrationNumber = exactOwner.flatMap { instance -> String? in
                        guard instance.note == "Предыдущая регистрация" else { return nil }
                        return CaseNumberPresentation.secondary(
                            instance.caseNumber, distinctFrom: record.caseNumber)
                    }
                    let linkedMaterial = exactOwner?.level == .material ? exactOwner : nil
                    let sourceCardID = linkedMaterial.flatMap { instance in
                        guard let context = record.context else { return nil }
                        return CaseSnapshotSourceIdentity.sourceCardID(
                            for: instance, context: context)
                    }.flatMap { sourceID in
                        record.materialInstance(forSourceCardID: sourceID) == nil ? nil : sourceID
                    }
                    let material = sourceCardID.flatMap {
                        record.materialInstance(forSourceCardID: $0)
                    }
                    let id: String
                    if sourceLevel == .material, let sourceCardID {
                        id = AppRouter.materialFeedID(
                            legacyID: legacyID, sourceCardID: sourceCardID)
                        materialFeedTransitions[legacyID, default: []].insert(id)
                    } else {
                        id = legacyID
                        if sourceLevel == .material {
                            unresolvedMaterialFeedCounts[legacyID, default: 0] += 1
                        } else {
                            normalFeedIDs.insert(legacyID)
                        }
                    }
                    if sourceLevel == .material, !materialFeedIDs.insert(id).inserted { continue }
                    entries.append(FeedEntry(
                        id: id, dayHead: nil, date: date, time: "—",
                        recordKey: record.recordKey, caseNumber: record.caseNumber,
                        client: record.client, kind: .act, text: text, actID: act.id,
                        isUnread: record.unreadByCase && !readIDs.contains(id),
                        instanceCaseNumber: previousRegistrationNumber
                            ?? (sourceLevel == .material
                                ? material.flatMap(MovementDerivation.materialNumber)
                                : AppRouter.actReviewNumber(
                                    for: act, instances: record.instances,
                                    baseCaseNumber: record.caseNumber)),
                        instanceLevel: sourceLevel, sourceCardID: sourceCardID,
                        sourceInstanceID: exactOwner?.id ?? material?.id,
                        previousRegistrationNumber: previousRegistrationNumber))
                }
            }
        }

        let currentFeedIDs = Set(entries.map(\.id))
        var nextMigrationState = migrationState
        let currentMaterialLegacyIDs = Set(materialFeedTransitions.keys)
            .union(unresolvedMaterialFeedCounts.keys)
        nextMigrationState.consumedLegacyIDs.formUnion(
            normalFeedIDs.subtracting(currentMaterialLegacyIDs).filter {
                readIDs.contains($0) || knownIDs.contains($0)
            })
        let transitionsToMigrate = AppRouter.materialFeedTransitionsToMigrate(
            transitions: materialFeedTransitions,
            unresolvedCounts: unresolvedMaterialFeedCounts,
            readIDs: readIDs, knownIDs: knownIDs, state: &nextMigrationState)
        let migratedReadIDs = AppRouter.migratedFeedIDs(
            readIDs, transitions: transitionsToMigrate, currentIDs: currentFeedIDs)
        let migratedKnownIDs = AppRouter.migratedFeedIDs(
            knownIDs, transitions: transitionsToMigrate, currentIDs: currentFeedIDs)
        for index in entries.indices where migratedReadIDs.contains(entries[index].id) {
            entries[index].isUnread = false
        }
        return LegacyFeedProjectionResult(
            entries: entries, migratedReadIDs: migratedReadIDs,
            migratedKnownIDs: migratedKnownIDs, migrationState: nextMigrationState)
    }
}
