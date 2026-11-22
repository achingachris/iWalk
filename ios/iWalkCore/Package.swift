// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iWalkCore",
    platforms: [.iOS(.v18), .watchOS(.v11)],
    products: [
        // Value types, geometry, Valhalla client, sync payloads, Live Activity attributes.
        // Safe to link from the widget extension.
        .library(name: "iWalkCore", targets: ["iWalkCore"]),
        // SwiftData models, used by the iOS app and the Watch app only.
        .library(name: "iWalkStore", targets: ["iWalkStore"]),
    ],
    targets: [
        .target(name: "iWalkCore"),
        .target(name: "iWalkStore", dependencies: ["iWalkCore"]),
    ]
)
