//  MovementCachePolicy.swift — SudrfKit
//  Правила слияния свежего движения дела с кэшированным и очистки перед
//  персистом. Чистая модельная логика — живёт в ядре, чтобы тестироваться
//  вместе с моделями; сами хранилища кэша — на стороне приложения.

import Foundation

public enum MovementCachePolicy {

    /// Слияние свежего движения с кэшированным: заглушка капчи (инстанция с
    /// captchaFormURL) НЕ затирает ранее загруженную реальную инстанцию того же
    /// домена — вместо заглушки остаётся кэшированная инстанция, её акт и текст
    /// переносятся в свежие данные.
    public static func merge(fresh: CaseMovement, cached: CaseMovement?) -> CaseMovement {
        guard let cached else { return fresh }
        var instances = fresh.instances
        var acts = fresh.acts
        var actBodies = fresh.actBodies
        var changed = false

        for (i, inst) in instances.enumerated() where inst.captchaFormURL != nil {
            guard let good = cached.instances.first(where: {
                $0.domain == inst.domain && $0.captchaFormURL == nil
            }) else { continue }
            instances[i] = good
            changed = true
            if let actID = good.actID, !acts.contains(where: { $0.id == actID }),
               let act = cached.acts.first(where: { $0.id == actID }) {
                acts.append(act)
                if let body = cached.actBodies[actID] { actBodies[actID] = body }
            }
        }
        guard changed else { return fresh }

        instances.sort { MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1) }
        acts.sort { MovementService.actOrderKey($0) < MovementService.actOrderKey($1) }
        var out = fresh
        out.instances = instances
        out.acts = acts
        out.actBodies = actBodies
        return out
    }

    /// Версия для персиста: оставшиеся заглушки капчи вырезаются — transient
    /// URL формы хранить бессмысленно, при следующем живом запросе заглушка
    /// восстановится сама. Акты не трогаются (у заглушек actID == nil).
    public static func stripped(forPersist mv: CaseMovement) -> CaseMovement {
        var out = mv
        out.instances = mv.instances.filter { $0.captchaFormURL == nil }
        return out
    }
}
