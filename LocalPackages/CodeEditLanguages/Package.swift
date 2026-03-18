// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeEditLanguages",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodeEditLanguages", targets: ["CodeEditLanguages"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "TreeSitterGrammars",
            path: "Sources/TreeSitterGrammars",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("vendored-headers")
            ]
        ),
        .target(
            name: "CodeEditLanguages",
            dependencies: [
                "TreeSitterGrammars",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")
            ],
            resources: [.copy("Resources")],
            linkerSettings: []
        )
    ]
)
