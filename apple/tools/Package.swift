// swift-tools-version: 6.0
// Build-time tooling only: pins the OpenAPI generator that writes ../api.
import PackageDescription

let package = Package(
    name: "RabbitEarsTools",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.4")
    ]
)
