// swift-tools-version: 6.0
// Generated/ is written by `make generate` from ../../openapi.yaml and
// never edited by hand.
import PackageDescription

let package = Package(
    name: "RabbitEarsAPI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RabbitEarsAPI", type: .dynamic, targets: ["RabbitEarsAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.4"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "RabbitEarsAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        )
    ]
)
