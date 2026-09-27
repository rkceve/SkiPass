// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkiPassCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SkiPassModels", targets: ["SkiPassModels"]),
        .library(name: "SkiPassStorage", targets: ["SkiPassStorage"]),
        .library(name: "SkiPassMail", targets: ["SkiPassMail"]),
        .library(name: "SkiPassAuth", targets: ["SkiPassAuth"]),
        .library(name: "SkiPassAuthUI", targets: ["SkiPassAuthUI"]),
        .library(name: "SkiPassExtraction", targets: ["SkiPassExtraction"]),
        .library(name: "SkiPassServerClient", targets: ["SkiPassServerClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Cocoanetics/SwiftMail.git", exact: "1.12.0"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"),
    ],
    targets: [
        .target(name: "SkiPassModels"),
        .target(name: "SkiPassStorage", dependencies: ["SkiPassModels"]),
        .target(name: "SkiPassMail", dependencies: [
            "SkiPassModels", "SkiPassExtraction",
            .product(name: "SwiftMail", package: "SwiftMail"),
        ]),
        // Extension-safe: token refresh only (AppAuthCore). Interactive sign-in lives in SkiPassAuthUI (app only).
        .target(name: "SkiPassAuth", dependencies: [
            "SkiPassModels", "SkiPassStorage", "SkiPassMail",
            .product(name: "AppAuthCore", package: "AppAuth-iOS"),
        ]),
        .target(name: "SkiPassAuthUI", dependencies: [
            "SkiPassAuth", "SkiPassModels",
            .product(name: "AppAuthCore", package: "AppAuth-iOS"),
            .product(name: "AppAuth", package: "AppAuth-iOS"),
        ]),
        .target(name: "SkiPassExtraction", dependencies: ["SkiPassModels"], resources: [.process("Resources")]),
        .target(name: "SkiPassServerClient", dependencies: ["SkiPassModels"]),
        .testTarget(name: "SkiPassStorageTests", dependencies: ["SkiPassStorage"]),
        .testTarget(name: "SkiPassMailTests", dependencies: ["SkiPassMail"]),
        .testTarget(name: "SkiPassExtractionTests", dependencies: ["SkiPassExtraction"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SkiPassServerClientTests", dependencies: ["SkiPassServerClient"]),
        .testTarget(name: "SkiPassAuthTests", dependencies: ["SkiPassAuth", "SkiPassMail", "SkiPassModels", "SkiPassStorage"]),
    ]
)
