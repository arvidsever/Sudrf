//  DemoMovement.swift — SudrfKitTests
//  Демо-движение дела для тестов (перенесено из Sources/SudrfKit/Movement.swift,
//  чтобы фикстура не попадала в собранное приложение).

import Foundation
@testable import SudrfKit

extension MovementService {

    static func demoMovement(uid: String, caseNumber: String) -> CaseMovement {
        let chzh1 = PrivateComplaint(
            id: "chzh1",
            label: "Частная жалоба на отказ в обеспечительных мерах",
            court: "Верховный суд Республики Коми", caseNumber: "33-1102/2026", foundByUID: true,
            rows: [
                CaseSession(date: "19.03.2026", event: "Подана частная жалоба"),
                CaseSession(date: "02.04.2026", event: "Рассмотрена",
                            result: "определение оставлено без изменения"),
            ])
        let chzh2 = PrivateComplaint(
            id: "chzh2",
            label: "Частная жалоба на оставление без движения",
            court: "Верховный суд Республики Коми", caseNumber: "33-1567/2026", foundByUID: true,
            rows: [
                CaseSession(date: "01.06.2026", event: "Подана частная жалоба"),
                CaseSession(date: "05.06.2026", event: "Возвращена",
                            result: "недостатки устранены добровольно"),
            ])

        let first = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд", caseNumber: "2-3204/2026",
            judge: "Машкалева О. А.", domain: "syktsud.komi.sudrf.ru", foundByUID: false,
            result: "Иск удовлетворён частично",
            sessions: [
                CaseSession(date: "10.03.2026", event: "Регистрация иска"),
                CaseSession(date: "11.03.2026", event: "Принятие к производству (определение)"),
                CaseSession(date: "12.03.2026", event: "Отказ в обеспечительных мерах (определение)",
                            complaintID: "chzh1"),
                CaseSession(date: "15.04.2026", time: "10:30", room: "215",
                            event: "Предварительное судебное заседание", result: "назначено основное заседание"),
                CaseSession(date: "23.04.2026", time: "14:00", room: "215",
                            event: "Судебное заседание", result: "иск удовлетворён частично"),
                CaseSession(date: "25.05.2026", event: "Поступила апелляционная жалоба"),
                CaseSession(date: "28.05.2026", event: "Жалоба оставлена без движения (определение)",
                            complaintID: "chzh2"),
                CaseSession(date: "09.06.2026", event: "Недостатки устранены, дело направлено в ВС Коми"),
            ],
            actID: "a2")
        let appeal = CaseInstance(
            level: .appeal, court: "Верховный суд Республики Коми", caseNumber: "33-2890/2026",
            judge: "Юдин А. В.", domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "Решение оставлено без изменения",
            sessions: [
                CaseSession(date: "16.06.2026", event: "Передача дела судье"),
                CaseSession(date: "30.06.2026", time: "11:00", room: "9",
                            event: "Судебное заседание", result: "решение оставлено без изменения"),
            ],
            actID: "a3")
        let cassation = CaseInstance(
            level: .cassation, court: "Третий кассационный СОЮ", caseNumber: "88-21412/2026",
            judge: "Козлова Е. В.", domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения",
            sessions: [
                CaseSession(date: "10.08.2026", event: "Поступление кассационной жалобы"),
                CaseSession(date: "15.09.2026", time: "12:00", room: "17",
                            event: "Судебное заседание", result: "жалоба оставлена без удовлетворения"),
            ],
            actID: "a4")

        let acts = [
            CaseAct(id: "a1", title: "Определение об отказе в обеспечительных мерах",
                    date: "12.03.2026", courtShort: "1-я инстанция", instanceLevel: .first),
            CaseAct(id: "a2", title: "Решение", date: "23.04.2026",
                    courtShort: "1-я инстанция", instanceLevel: .first),
            CaseAct(id: "a3", title: "Апелляционное определение", date: "30.06.2026",
                    courtShort: "ВС Коми", instanceLevel: .appeal),
            CaseAct(id: "a4", title: "Определение кассационного суда", date: "15.09.2026",
                    courtShort: "3-й КСОЮ", instanceLevel: .cassation),
        ]
        let bodies: [String: String] = [
            "a2": "ПОСТАНОВЛЕНИЕ\nИменем Российской Федерации\n\nСыктывкарский городской суд Республики Коми в составе председательствующей судьи Машкалевой О. А. … РЕШИЛ: иск удовлетворить частично.",
            "a1": "ОПРЕДЕЛЕНИЕ\nоб отказе в принятии мер по обеспечению иска … ОПРЕДЕЛИЛ: в принятии обеспечительных мер отказать.",
            "a3": "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ\nСудебная коллегия … ОПРЕДЕЛИЛА: решение оставить без изменения, апелляционную жалобу — без удовлетворения.",
            "a4": "ОПРЕДЕЛЕНИЕ\nТретий кассационный суд общей юрисдикции … ОПРЕДЕЛИЛ: судебные постановления оставить без изменения, кассационную жалобу — без удовлетворения.",
        ]

        return CaseMovement(
            uid: uid, caseNumber: caseNumber.isEmpty ? "2-3204/2026" : caseNumber,
            inForce: false,
            instances: [first, appeal, cassation],
            complaints: ["chzh1": chzh1, "chzh2": chzh2],
            acts: acts, actBodies: bodies,
            category: "Споры, возникающие из трудовых отношений — о взыскании заработной платы",
            parties: CaseParties(
                plaintiffs: ["Воробьёв В. В."],
                defendants: ["МКУ «Декабрист»"],
                thirdParties: ["ОСФР по Республике Коми"]))
    }
}
