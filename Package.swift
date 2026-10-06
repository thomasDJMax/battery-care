// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "BatteryCare",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BatteryCare", targets: ["iAdente"])],
    targets: [
        .target(name: "NativeCharge", path: "Native", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(name: "iAdente", dependencies: ["NativeCharge"], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
            .linkedFramework("IOKit"), .linkedFramework("ServiceManagement"),
            .linkedFramework("UserNotifications")
        ])
    ]
)
