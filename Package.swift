// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SudrfKit",
    platforms: [
        // Ядро таргетит Apple-платформы: кодек cp1251 берётся из CoreFoundation,
        // которого в таком виде нет на swift-corelibs-foundation (Linux).
        // macOS 26 (Tahoe): интерфейс SudrfApp построен на Liquid Glass
        // (glassEffect, .buttonStyle(.glass)) — без фолбэков на старые версии.
        .macOS("26.0")
    ],
    products: [
        .library(name: "SudrfKit", targets: ["SudrfKit"]),
        .library(name: "CaptchaSolver", targets: ["CaptchaSolver"]),
        .executable(name: "sudrf-cli", targets: ["sudrf-cli"]),
        .executable(name: "SudrfApp", targets: ["SudrfApp"])
    ],
    dependencies: [
        // SwiftSoup запинен точно на 2.7.7: версии 2.8+ (байтовый парсер ByteSlice)
        // роняют оптимизатор Swift 6.4 beta в Release (краш CopyPropagation на
        // Element.appendNormalisedText при Archive). Когда компилятор починят —
        // можно вернуть from: "2.7.0" и обновиться.
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.7.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "SudrfKit",
            dependencies: ["SwiftSoup"],
            resources: [
                // Корень и промежуточные сертификаты Минцифры («Russian Trusted
                // Root/Sub CA») — якоря для проверки TLS-цепочки судов
                // (SudrfTLSDelegate). Источник: gu-st.ru (Госуслуги).
                .copy("Resources/RussianTrustedRootCA.cer"),
                .copy("Resources/RussianTrustedSubCA.cer"),
                .copy("Resources/RussianTrustedSubCA2024.cer"),
                // Суды на «винтажной» версии модуля sud_delo (VNKOD-паттерн) —
                // срез конфигурации tochno-st/sudrfscraper (Scripts/derive-vnkod.py).
                .copy("Resources/VNKODCourts.json"),
            ]
        ),
        .executableTarget(
            name: "sudrf-cli",
            dependencies: [
                "SudrfKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .executableTarget(
            name: "SudrfApp",
            dependencies: ["SudrfKit", "CaptchaSolver"],
            resources: [.process("Resources")]
        ),
        .target(name: "CaptchaSolver"),
        .testTarget(
            name: "SudrfKitTests",
            dependencies: ["SudrfKit"],
            resources: [.copy("Fixtures")]
        ),
        // Тесты прикладной логики (MovementDerivation и др.) — SwiftPM умеет
        // тестировать executable-таргеты начиная с Swift 5.5.
        .testTarget(
            name: "SudrfAppTests",
            dependencies: ["SudrfApp"]
        ),
        .testTarget(
            name: "CaptchaSolverTests",
            dependencies: ["CaptchaSolver", "SudrfKit"],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
