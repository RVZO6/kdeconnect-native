// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KDEConnectNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KDEConnectNative", targets: ["KDEConnectNative"]),
        .executable(name: "dbus-probe", targets: ["dbus-probe"]),
    ],
    targets: [
        .target(name: "DBusKit"),
        .target(name: "KDEConnectKit", dependencies: ["DBusKit"]),
        .executableTarget(name: "KDEConnectNative", dependencies: ["KDEConnectKit"]),
        .executableTarget(name: "dbus-probe", dependencies: ["DBusKit", "KDEConnectKit"]),
        .testTarget(name: "DBusKitTests", dependencies: ["DBusKit"]),
    ],
    swiftLanguageModes: [.v6]
)
