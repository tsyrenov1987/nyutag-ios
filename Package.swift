// swift-tools-version: 6.2
// Нютаг: движок мессенджера без сторонних зависимостей. Только Swift и системные фреймворки Apple.
import PackageDescription

let package = Package(
    name: "Nyutag",
    defaultLocalization: "ru",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NyutagCore", targets: ["NyutagCore"]),
        .library(name: "NyutagCrypto", targets: ["NyutagCrypto"]),
    ],
    targets: [
        // Протокол Matrix: HTTP, вход, /sync, хранилище SQLite, медиа. Без UI и без шифрования.
        .target(
            name: "NyutagCore",
            dependencies: ["NyutagCrypto"],
            path: "Sources/NyutagCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Своя реализация Olm/Megolm на CryptoKit и CommonCrypto.
        .target(
            name: "NyutagCrypto",
            path: "Sources/NyutagCrypto"
        ),
        .testTarget(
            name: "NyutagCoreTests",
            dependencies: ["NyutagCore"],
            path: "Tests/NyutagCoreTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NyutagCryptoTests",
            dependencies: ["NyutagCrypto"],
            path: "Tests/NyutagCryptoTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
