// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CoachKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoachKit", targets: ["CoachKit"]),
    ],
    targets: [
        .target(name: "CoachKit"),
        .executableTarget(name: "coach-eval", dependencies: ["CoachKit"]),
        .testTarget(name: "CoachKitTests", dependencies: ["CoachKit"]),
    ]
)
