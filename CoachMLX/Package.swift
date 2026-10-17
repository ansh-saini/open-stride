// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CoachMLX",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoachMLX", targets: ["CoachMLX"]),
    ],
    dependencies: [
        .package(path: "../CoachKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "CoachMLX", dependencies: [
            "CoachKit",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        // Runs the eval personas through the exact on-device model, on a Mac. Build with xcodebuild (MLX needs Metal shaders).
        .executableTarget(name: "mlx-eval", dependencies: ["CoachMLX", "CoachKit"]),
    ]
)
