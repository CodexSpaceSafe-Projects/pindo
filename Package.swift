// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "PindoCore", targets: ["PindoCore"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
    .target(name: "PindoCore", dependencies: ["CSQLite"]),
    .testTarget(name: "PindoCoreTests", dependencies: ["PindoCore"])
]
#if os(macOS)
dependencies.append(.package(url: "https://github.com/nodes-app/swift-markdown-engine.git", exact: "0.15.0"))
products.append(.executable(name: "Pindo", targets: ["Pindo"]))
targets.append(.executableTarget(name: "Pindo", dependencies: ["PindoCore", .product(name: "MarkdownEngine", package: "swift-markdown-engine")], resources: [.process("Resources")]))
targets.append(.testTarget(name: "PindoMacTests", dependencies: ["Pindo", "PindoCore", .product(name: "MarkdownEngine", package: "swift-markdown-engine")]))
#endif

let package = Package(name: "Pindo", defaultLocalization: "en", platforms: [.macOS(.v14)], products: products, dependencies: dependencies, targets: targets)
