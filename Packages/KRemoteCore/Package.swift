// swift-tools-version:5.10
import PackageDescription

// KRemoteCore is a real local SwiftPM package rather than an XcodeGen-generated
// target on purpose. Citadel -> NIOCore -> swift-atomics ships a C module
// (`_AtomicsShims`) whose module map Xcode does not propagate into a
// `library.static` target, which fails with "missing required module
// '_AtomicsShims'". Building the core through SwiftPM resolves it.
let package = Package(
    name: "KRemoteCore",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .library(name: "KRemoteCore", targets: ["KRemoteCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto", exact: "3.15.1"),
        .package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"),
    ],
    targets: [
        .target(
            name: "KRemoteCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        .testTarget(
            name: "KRemoteCoreTests",
            dependencies: ["KRemoteCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
