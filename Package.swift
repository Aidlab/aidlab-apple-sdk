// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aidlab",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v8),
    ],
    products: [
        .library(
            name: "Aidlab",
            targets: ["Aidlab"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "AidlabSDK",
            path: "AidlabSDK.xcframework"
        ),
        .target(
            name: "Aidlab",
            dependencies: ["AidlabSDK"],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
