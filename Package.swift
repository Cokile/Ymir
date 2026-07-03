// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ymir",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Ymir", targets: ["Ymir"])
    ],
    targets: [
        .executableTarget(
            name: "Ymir",
            path: "Sources/Ymir"
        )
    ]
)
