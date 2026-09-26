// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkiPassUI",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "SkiPassUI", targets: ["SkiPassUI"])
    ],
    targets: [
        .target(name: "SkiPassUI"),
        // Named apart from the app project's `SkiPassUITests` (UI test bundle) to avoid a clash.
        .testTarget(name: "SkiPassUIPackageTests", dependencies: ["SkiPassUI"]),
    ]
)
