//  CaseMovementCaptcha.swift — SudrfKit
//  Вклейка карточки, полученной через окно капчи, в собранное движение дела.
//  Общая логика для SearchModel и AppRouter (раньше жила двумя копиями и
//  успела разъехаться: копия поиска теряла категорию и стороны).

import Foundation

public extension CaseMovement {

    /// Заменяет заглушку капчи данного домена реальной инстанцией из разобранной
    /// карточки (HTML считан из окна капчи; сама карточка капчей не защищена).
    /// Все прочие поля движения — категория, стороны, жалобы — сохраняются;
    /// инстанции и акты пересортировываются по хронологии.
    func replacingCaptchaStub(domain: String, courtTitle: String,
                              level: CaseInstance.Level, card: CaseCard) -> CaseMovement {
        var acts = self.acts
        var bodies = self.actBodies
        var actID: String? = nil
        if let body = card.acts.first?.body {
            let id = "act_\(domain)#\(card.caseNumber ?? "—")"
            acts.append(CaseAct(id: id,
                                title: card.acts.first?.label ?? "Судебный акт",
                                date: card.receiptDate ?? "—",
                                courtShort: courtTitle,
                                instanceLevel: level))
            bodies[id] = body
            actID = id
        }

        let inst = CaseInstance(level: level, court: courtTitle,
                                caseNumber: card.caseNumber ?? "—",
                                judge: card.judge, domain: domain,
                                foundByUID: true, result: card.result,
                                sessions: card.sessions, actID: actID)

        var insts = instances.filter { !($0.domain == domain && $0.captchaFormURL != nil) }
        insts.append(inst)
        insts.sort { MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1) }
        acts.sort { MovementService.actOrderKey($0) < MovementService.actOrderKey($1) }

        var out = self
        out.instances = insts
        out.acts = acts
        out.actBodies = bodies
        return out
    }
}
