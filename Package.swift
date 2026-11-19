// swift-tools-version:5.10
import PackageDescription

var targets: [Target] = [
    // Protocol engine: IMAP, SMTP, MIME and sync. Plain Foundation, so it builds and tests on Linux too.
    .target(name: "MailEngine"),
    .testTarget(name: "MailEngineTests", dependencies: ["MailEngine"]),
]
var products: [Product] = [
    .library(name: "MailEngine", targets: ["MailEngine"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "Tern", dependencies: ["MailEngine"]))
products.append(.executable(name: "Tern", targets: ["Tern"]))
#endif

let package = Package(
    name: "Tern",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
