// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Side",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Side", targets: ["Side"]), .executable(name: "SideChecks", targets: ["SideChecks"])],
    targets: [
        .target(name: "SideCore"),
        .executableTarget(name: "Side", dependencies: ["SideCore"]),
        .executableTarget(name: "SideChecks", dependencies: ["SideCore"])
    ],
    swiftLanguageModes: [.v5]
)
