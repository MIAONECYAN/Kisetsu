// swift-tools-version: 6.0

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
var packageTargets: [Target] = [
  .executableTarget(name: "Kisetsu")
]

if FileManager.default.fileExists(
  atPath: packageDirectory.appendingPathComponent("Tests/KisetsuTests").path
) {
  packageTargets.append(.testTarget(name: "KisetsuTests", dependencies: ["Kisetsu"]))
}

let package = Package(
  name: "KisetsuClient",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .executable(name: "Kisetsu", targets: ["Kisetsu"])
  ],
  targets: packageTargets
)
