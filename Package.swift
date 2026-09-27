// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CookieVault",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CookieVault",
            path: "CookieVault/Sources",
            exclude: ["CookieVault.entitlements"],
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
