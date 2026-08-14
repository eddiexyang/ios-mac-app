// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ProtonSocks",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ProtonSocksIPC",
            targets: ["ProtonSocksIPC"]
        ),
        .executable(
            name: "ProtonSocksHelper",
            targets: ["ProtonSocksHelper"]
        ),
    ],
    dependencies: [
        .package(name: "WireGuardKit", path: "../../../external/wireguard-apple"),
    ],
    targets: [
        .target(name: "ProtonSocksIPC"),
        .executableTarget(
            name: "ProtonSocksHelper",
            dependencies: [
                "ProtonSocksIPC",
                .product(name: "WireGuardKitGo", package: "WireGuardKit"),
            ]
        ),
        .testTarget(
            name: "ProtonSocksIPCTests",
            dependencies: ["ProtonSocksIPC"]
        ),
    ]
)
