// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BentoZipCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BentoZipCore", targets: ["BentoZipCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
        .package(url: "https://github.com/matteo-pacini/libarchive-for-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "BentoZipCore",
            dependencies: ["ZIPFoundation", .product(name: "libarchive", package: "libarchive-for-swift")],
            path: "Sources/BentoZipCore"
        ),
    ]
)
