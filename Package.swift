// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Toutu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Toutu", targets: ["Toutu"])],
    targets: [
        .target(name: "QuotaAlerts"),
        .executableTarget(name: "Toutu", dependencies: ["QuotaAlerts"]),
        .testTarget(name: "QuotaAlertsTests", dependencies: ["QuotaAlerts"]),
    ]
)
