// swift-tools-version:5.10
import PackageDescription

// KRemoteCore is a real local SwiftPM package rather than an XcodeGen-generated
// target on purpose: Xcode does not propagate C module maps (e.g. swift-atomics'
// _AtomicsShims, pulled in by network libraries) into a `library.static` target.
// Building the core through SwiftPM sidesteps that.
// SSH is done by running the system `ssh` on a PTY (see SSHPtySession), so no
// SSH library is needed — only swift-crypto, for the mRemoteNG confCons format.
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
    ],
    targets: [
        .target(
            name: "KRemoteCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
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
