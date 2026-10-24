// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenWisprEngines",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "OpenWisprEngines", targets: ["OpenWisprEngines"]),
    ],
    dependencies: [
        .package(path: "../OpenWisprCore"),
        // No traits: skips the NeMo text-normalization binary, which only FluidAudio's text-to-speech uses.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .target(
            name: "OpenWisprEngines",
            dependencies: [
                .product(name: "OpenWisprCore", package: "OpenWisprCore"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        .executableTarget(
            name: "openwispr-smoke",
            dependencies: ["OpenWisprEngines", .product(name: "OpenWisprCore", package: "OpenWisprCore")]
        ),
    ]
)
