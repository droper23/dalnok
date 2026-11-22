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
        .executable(name: "dalnok-scan", targets: ["dalnok-scan"]),
        .executable(name: "dalnok-plughost", targets: ["dalnok-plughost"]),
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
            exclude: ["dsp", "third_party/signalsmith", "third_party/vst3", "third_party/clap", "src/fx/channel_eq_cuts.inc", "src/generated"],
            sources: ["src", "third_party/pugixml/pugixml.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("third_party/pugixml"),
                .headerSearchPath("third_party/vst3"),
                .headerSearchPath("third_party/clap/include"),
                .unsafeFlags(["-Wall", "-Wextra", "-Wfunction-effects", "-Werror=function-effects"]),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AppKit"), // Audio Unit editor views (au_host.mm)
                .linkedFramework("AVFoundation"), // Audio Unit tags (au_host.mm)
                .linkedLibrary("z"),
            ]
        ),
        // Native macOS front end (AppKit).
        .executableTarget(
            name: "Dalnok",
            dependencies: ["DalnokEngine"],
            path: "app/macos/Dalnok",
            resources: [.copy("Resources/Fonts")] // theme typefaces (SIL OFL; 04 - Research/Licensing.md)
        ),
        // Headless driver for smoke tests and benchmarks.
        .executableTarget(
            name: "dalnok-cli",
            dependencies: ["DalnokEngine"],
            path: "tools/dalnok-cli"
        ),
        // Out-of-process plugin scanner (ADR-0009): loads one plugin per run, so crashes stay contained.
        .executableTarget(
            name: "dalnok-scan",
            path: "tools/dalnok-scan",
            exclude: ["fixtures"], // test plugins, built by scripts/ci/plugin-*.sh
            cxxSettings: [
                .headerSearchPath("../../engine/third_party/vst3"),
                .headerSearchPath("../../engine/third_party/clap/include"),
            ],
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("AudioToolbox")]
        ),
        // Out-of-process plug-in host (ADR-0014): one plug-in instance per process, driven by the engine.
        .executableTarget(
            name: "dalnok-plughost",
            dependencies: ["DalnokEngine"],
            path: "tools/dalnok-plughost"
        ),
        .testTarget(
            name: "DalnokEngineTests",
            dependencies: ["DalnokEngine"],
            path: "tests/engine"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
