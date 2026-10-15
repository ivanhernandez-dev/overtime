// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "OvertimeRuntime",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "overtimed", targets: ["overtimed"]),
    .executable(name: "overtime-sentinel", targets: ["overtime-sentinel"]),
    .library(name: "OvertimeClamshell", targets: ["OvertimeClamshell"]),
    .library(name: "OvertimeSystem", targets: ["OvertimeSystem"]),
    .library(name: "OvertimeEngine", targets: ["OvertimeEngine"]),
    .library(name: "OvertimeAppSupport", targets: ["OvertimeAppSupport"]),
    .library(name: "OvertimeHelperCore", targets: ["OvertimeHelperCore"]),
    .library(name: "OvertimeHelperClient", targets: ["OvertimeHelperClient"]),
  ],
  dependencies: [
    .package(path: "../OvertimeCore")
  ],
  targets: [
    .target(
      name: "CIOKitShim",
      publicHeadersPath: "include"
    ),
    .target(
      name: "OvertimeClamshell",
      dependencies: ["CIOKitShim"],
      linkerSettings: [.linkedFramework("IOKit")]
    ),
    .executableTarget(
      name: "overtime-sentinel",
      dependencies: ["OvertimeClamshell"]
    ),
    .target(
      name: "OvertimeSystem",
      dependencies: [
        .product(name: "OvertimeCore", package: "OvertimeCore"),
        "OvertimeClamshell",
        "CIOKitShim",
      ],
      linkerSettings: [
        .linkedFramework("IOKit"),
        .linkedFramework("SystemConfiguration"),
        .linkedFramework("CoreWLAN"),
      ]
    ),
    .target(
      name: "OvertimeEngine",
      dependencies: [
        .product(name: "OvertimeCore", package: "OvertimeCore"),
        "OvertimeSystem",
        "OvertimeClamshell",
      ]
    ),
    .target(
      name: "OvertimeAppSupport",
      dependencies: [
        .product(name: "OvertimeCore", package: "OvertimeCore"),
        "OvertimeSystem",
        "OvertimeEngine",
        "OvertimeClamshell",
        "OvertimeHelperCore",
        "OvertimeHelperClient",
      ]
    ),
    .executableTarget(
      name: "overtimed",
      dependencies: [
        "OvertimeEngine",
        "OvertimeSystem",
        .product(name: "OvertimeCore", package: "OvertimeCore"),
      ]
    ),
    .executableTarget(
      name: "SentinelHolderFixture",
      dependencies: [
        "OvertimeEngine",
        "OvertimeSystem",
        "OvertimeClamshell",
        .product(name: "OvertimeCore", package: "OvertimeCore"),
      ]
    ),
    .testTarget(
      name: "OvertimeRuntimeTests",
      dependencies: [
        "OvertimeAppSupport",
        "OvertimeEngine",
        "OvertimeSystem",
        "OvertimeClamshell",
        "OvertimeHelperCore",
        "OvertimeHelperClient",
        "overtime-sentinel",
        "overtime-helper",
        "SentinelHolderFixture",
        .product(name: "OvertimeCore", package: "OvertimeCore"),
      ],
      resources: [.copy("Fixtures/network")]
    ),
    .target(name: "OvertimeHelperCore"),
    .target(name: "OvertimeHelperClient", dependencies: ["OvertimeHelperCore"]),
    .executableTarget(
      name: "overtime-helper",
      dependencies: ["OvertimeHelperCore"],
      linkerSettings: [.linkedFramework("IOKit")]
    ),
    .testTarget(
      name: "OvertimeHelperCoreTests",
      dependencies: ["OvertimeHelperCore", "OvertimeHelperClient"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
