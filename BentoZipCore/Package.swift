// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BentoZipCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BentoZipCore", targets: ["BentoZipCore"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BentoZipCore",
            dependencies: [],
            path: "Sources/BentoZipCore",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
