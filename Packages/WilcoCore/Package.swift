// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WilcoCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WilcoCore", targets: ["WilcoCore"]),
        .library(name: "WilcoAudio", targets: ["WilcoAudio"]),
        .library(name: "WilcoTranscription", targets: ["WilcoTranscription"]),
        .library(name: "WilcoControl", targets: ["WilcoControl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
        // Parakeet on the Neural Engine. Benchmark only until it's adopted;
        // pinned because the API changes between 0.x releases.
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.3"),
    ],
    targets: [
        .target(name: "WilcoCore"),
        .target(
            name: "WilcoAudio",
            dependencies: ["WilcoCore"],
            linkerSettings: [.linkedFramework("CoreAudio")]
        ),
        .target(
            name: "WilcoTranscription",
            dependencies: [
                "WilcoCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .target(
            name: "WilcoBench",
            dependencies: [
                "WilcoCore",
                "WilcoTranscription",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .executableTarget(
            name: "wilco-bench",
            dependencies: ["WilcoBench", "WilcoTranscription", "WilcoCore"]
        ),
        .target(
            name: "WilcoControl",
            dependencies: ["WilcoCore"],
            linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("Network")]
        ),
        .testTarget(
            name: "WilcoCoreTests",
            dependencies: ["WilcoCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WilcoAudioTests",
            dependencies: ["WilcoAudio"]
        ),
        .testTarget(
            name: "WilcoTranscriptionTests",
            dependencies: ["WilcoTranscription"]
        ),
        .testTarget(
            name: "WilcoBenchTests",
            dependencies: ["WilcoBench", "WilcoTranscription", "WilcoCore"]
        ),
        .testTarget(
            name: "WilcoControlTests",
            dependencies: ["WilcoControl"]
        ),
    ]
)
