//  PackagedResource.swift — SudrfKit · поиск собственных ресурсов
//
//  Почему не просто `Bundle.module`.
//
//  Сгенерированный SwiftPM аксессор ищет бандл строго по
//  `Bundle.main.bundleURL/SudrfKit_SudrfKit.bundle`, а для .app это КОРЕНЬ
//  `SudrfApp.app`. Положить бандл туда нельзя: codesign отвергает бандл с
//  посторонним содержимым в корне («unsealed contents present in the bundle
//  root»), и подпись не проходит вовсе. Штатное место — `Contents/Resources`,
//  куда аксессор не смотрит.
//
//  Хуже того, при ненайденном бандле аксессор не возвращает nil, а зовёт
//  `fatalError`. Поэтому обращаться к `Bundle.module` можно только последним
//  шагом, когда остальные пути уже проверены: иначе собранное приложение
//  падает на первом же обращении к ресурсу (так и было до v0.42.27 —
//  `SearchPatternDirectory.byDomain` роняла процесс при обновлении дела).

import Foundation

enum PackagedResource {

    /// Имя ресурсного бандла SwiftPM для этого модуля.
    private static let bundleName = "SudrfKit_SudrfKit.bundle"

    /// URL ресурса модуля. Порядок: бандл внутри `Contents/Resources`
    /// собранного .app → файл, положенный туда же плоско → `Bundle.module`
    /// для разработки и тестов.
    static func url(_ name: String, withExtension ext: String) -> URL? {
        if let resources = Bundle.main.resourceURL {
            if let nested = Bundle(url: resources.appendingPathComponent(bundleName)),
               let url = nested.url(forResource: name, withExtension: ext) {
                return url
            }
            let flat = resources.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
