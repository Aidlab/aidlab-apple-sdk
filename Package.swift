// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aidlab",
    platforms: [
        .iOS(.v14),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Aidlab",
            targets: ["Aidlab"]),
    ],
    targets: [
        .binaryTarget(
            name: "AidlabSDK",
            path: "AidlabSDK.xcframework"
        ),
        .target(
            name: "Aidlab",
            dependencies: ["AidlabSDK"],
            // For macOS
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        )
    ]
)
