// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MemosPopup",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MemosPopup", targets: ["MemosPopup"])],
    targets: [
        .target(name: "MemosCore"),
        .executableTarget(name: "MemosPopup", dependencies: ["MemosCore"],
                          linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("Security")]),
        .testTarget(name: "MemosCoreTests", dependencies: ["MemosCore"]),
        .testTarget(name: "MemosPopupTests", dependencies: ["MemosPopup"])
    ]
)
