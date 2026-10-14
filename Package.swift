// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MemosPopup",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MemosPopup", targets: ["MemosPopup"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
    targets: [
        .target(name: "MemosCore"),
        .executableTarget(name: "MemosPopup", dependencies: ["MemosCore", .product(name: "Markdown", package: "swift-markdown")],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("Security")]),
        .testTarget(name: "MemosCoreTests", dependencies: ["MemosCore"]),
        .testTarget(name: "MemosPopupTests", dependencies: ["MemosPopup"])
    ]
)
