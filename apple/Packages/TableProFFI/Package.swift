// swift-tools-version: 6.0

import PackageDescription

// Keep generated bindings and their binary together so their UniFFI checksums agree.
let package = Package(
    name: "TableProFFI",
    // The apps' floors: project.yml and TableProMobile/project.yml, which build-core.sh builds the slices for.
    platforms: [
        .macOS(.v13),
        .iOS(.v18)
    ],
    products: [
        .library(name: "TableProFFI", targets: ["TableProFFI"])
    ],
    targets: [
        .binaryTarget(name: "TableProFFIC", path: "Build/TableProFFIC.xcframework"),
        .target(
            name: "TableProFFI",
            dependencies: ["TableProFFIC"],
            // UniFFI 0.31's Swift for an async foreign trait starts a Task over non-Sendable closures, which Swift 6
            // refuses (mozilla/uniffi-rs#2929). The fix ships in 0.32, which uniffi-bindgen-cs does not support yet, so
            // the generated code alone is checked in Swift 5 mode; the apps stay in Swift 6.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("iconv"),
                // The system's SQLite, the one the app links (core/crates/storage/Cargo.toml).
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(name: "TableProFFITests", dependencies: ["TableProFFI"])
    ]
)
