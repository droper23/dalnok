// swift-tools-version: 6.0
// Atrium (working name) — open-source DAW.
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "Atrium",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Atrium", targets: ["Atrium"]),
        .executable(name: "atrium-cli", targets: ["atrium-cli"]),
    ],
    targets: [
        // Portable C++20 engine. Public surface is the C API in engine/include/atrium/atrium.h.
        .target(
            name: "AtriumEngine",
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
            name: "Atrium",
            dependencies: ["AtriumEngine"],
            path: "app/macos/Atrium"
        ),
        // Headless driver for smoke tests and benchmarks.
        .executableTarget(
            name: "atrium-cli",
            dependencies: ["AtriumEngine"],
            path: "tools/atrium-cli"
        ),
        .testTarget(
            name: "AtriumEngineTests",
            dependencies: ["AtriumEngine"],
            path: "tests/engine"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
