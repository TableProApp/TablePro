// swift-tools-version: 6.0

import PackageDescription

// The shared Rust core as the Apple apps link it. scripts/build-core.sh builds Build/TableProFFIC.xcframework and the
// generated Sources/TableProFFI/TableProFFI.swift, neither in git (core/docs/decisions/0009-macos-on-the-core.md).
// No NonisolatedNonsendingByDefault here: with it the generated async calls poll on the caller's actor, the main one.
let package = Package(
    name: "TableProFFI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TableProFFI", targets: ["TableProFFI"])
    ],
    targets: [
        .binaryTarget(name: "TableProFFIC", path: "Build/TableProFFIC.xcframework"),
        .target(
            name: "TableProFFI",
            dependencies: ["TableProFFIC"],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("iconv")
            ]
        ),
        .testTarget(name: "TableProFFITests", dependencies: ["TableProFFI"])
    ]
)
