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
        // Offline DSP (time-stretch). Always compiled optimized: the algorithm is
        // ~10x slower unoptimized, which would make debug builds and tests crawl.
        .target(
            name: "DalnokDSP",
            path: "engine/dsp",
            sources: ["src"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../third_party/signalsmith"),
                .define("SIGNALSMITH_USE_ACCELERATE"),
                .unsafeFlags(["-O3", "-Wno-shorten-64-to-32"]),
            ],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        // Portable C++20 engine. Public surface is the C API in engine/include/dalnok/dalnok.h.
        .target(
            name: "DalnokEngine",
            dependencies: ["DalnokDSP"],
            path: "engine",
            exclude: ["dsp", "third_party/signalsmith"],
            sources: ["src", "third_party/pugixml/pugixml.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("third_party/pugixml"),
                .unsafeFlags(["-Wall", "-Wextra", "-Wfunction-effects", "-Werror=function-effects"]),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("z"),
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
