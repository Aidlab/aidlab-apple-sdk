import class Foundation.ProcessInfo

// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Aidlab",
    platforms: [
        .iOS(.v15),
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
                .linkedLibrary("z"),
            ]
        ),
    ]
)
