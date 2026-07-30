// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LlamaRuntime",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LlamaFramework", targets: ["LlamaFramework"])
    ],
    targets: [
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9637/llama-b9637-xcframework.zip",
            checksum: "46c7dad871f804d82399ddcfeb54d23b6469888801fc35124d7e33e543a9bef7"
        )
    ]
)
