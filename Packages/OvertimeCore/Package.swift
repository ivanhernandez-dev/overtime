// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "OvertimeCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "OvertimeCore", targets: ["OvertimeCore"])
  ],
  targets: [
    .target(name: "OvertimeCore"),
    .testTarget(name: "OvertimeCoreTests", dependencies: ["OvertimeCore"]),
  ],
  swiftLanguageModes: [.v6]
)
