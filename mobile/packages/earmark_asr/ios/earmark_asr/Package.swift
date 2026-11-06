// swift-tools-version: 5.9
// On-device transcription for Earmark: Parakeet TDT (Core ML, Neural Engine) via FluidAudio
// (Apache-2.0), and libopus via swift-opus (BSD-3) to decode the pendant's audio.
import PackageDescription

let package = Package(
    name: "earmark_asr",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .library(name: "earmark-asr", targets: ["earmark_asr"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2"),
        .package(url: "https://github.com/alta/swift-opus.git", revision: "6f3cb6bd3ffed1fe5f06d00a962d5c191a50daf8"),
    ],
    targets: [
        .target(
            name: "earmark_asr",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Copus", package: "swift-opus"),
            ]
        )
    ]
)
