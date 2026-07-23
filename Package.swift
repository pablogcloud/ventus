// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ventus",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VentusCore", targets: ["VentusCore"]),
        .library(name: "VentusIPC", targets: ["VentusIPC"]),
        .executable(name: "ventusd", targets: ["ventusd"]),
        .executable(name: "ventusctl", targets: ["ventusctl"]),
        .executable(name: "VentusApp", targets: ["VentusApp"]),
    ],
    targets: [
        .target(
            name: "VentusCore",
            dependencies: ["CVentusPrivate"],
            path: "Sources/VentusCore",
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"], .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CVentusPrivate",
            path: "Sources/CVentusPrivate",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VentusIPC",
            dependencies: ["VentusCore"],
            path: "Sources/VentusIPC"
        ),
        .testTarget(
            name: "VentusCoreTests",
            dependencies: ["VentusCore"],
            path: "Tests/VentusCoreTests"
        ),
        .executableTarget(
            name: "ventusd",
            dependencies: ["VentusCore", "VentusIPC"],
            path: "Sources/ventusd"
        ),
        .executableTarget(
            name: "ventusctl",
            dependencies: ["VentusCore", "VentusIPC"],
            path: "Sources/ventusctl"
        ),
        .executableTarget(
            name: "VentusApp",
            dependencies: ["VentusCore", "VentusIPC"],
            path: "Sources/VentusApp"
        ),
    ]
)
