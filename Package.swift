// swift-tools-version: 6.0
// Dalnok — open-source DAW.
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "Dalnok",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Dalnok", targets: ["Dalnok"]),
        .executable(name: "dalnok-cli", targets: ["dalnok-cli"]),
    ],
    targets: [
        // Portable C++20 engine. Public surface is the C API in engine/include/dalnok/dalnok.h.
        .target(
            name: "DalnokEngine",
            path: "engine",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-Wall", "-Wextra", "-Wfunction-effects", "-Werror=function-effects"]),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Native macOS front end (AppKit).
        .executableTarget(
            name: "Dalnok",
            dependencies: ["DalnokEngine"],
            path: "app/macos/Dalnok"
        ),
        // Headless driver for smoke tests and benchmarks.
        .executableTarget(
            name: "dalnok-cli",
            dependencies: ["DalnokEngine"],
            path: "tools/dalnok-cli"
        ),
        .testTarget(
            name: "DalnokEngineTests",
            dependencies: ["DalnokEngine"],
            path: "tests/engine"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
