// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpotFast",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SpotFast", targets: ["SpotFast"])],
    targets: [
        .target(name: "SpotFastCore"),
        .executableTarget(name: "SpotFast", dependencies: ["SpotFastCore"]),
        .testTarget(name: "SpotFastCoreTests", dependencies: ["SpotFastCore"])
    ],
    swiftLanguageModes: [.v5]
)
