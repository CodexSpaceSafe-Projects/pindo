// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "PindoCore", targets: ["PindoCore"])]
var targets: [Target] = [
    .target(name: "PindoCore"),
    .testTarget(name: "PindoCoreTests", dependencies: ["PindoCore"])
]
#if os(macOS)
products.append(.executable(name: "Pindo", targets: ["Pindo"]))
targets.append(.executableTarget(name: "Pindo", dependencies: ["PindoCore"]))
targets.append(.testTarget(name: "PindoMacTests", dependencies: ["Pindo", "PindoCore"]))
#endif

let package = Package(name: "Pindo", platforms: [.macOS(.v14)], products: products, targets: targets)
