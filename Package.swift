// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoTerm",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EchoTerm", targets: ["EchoTerm"])],
    // v1.9.0 uses a revision-pinned transitive dependency; SPM requires a revision here too.
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "8840e3596739adfe9599c0e7fff89f4fa88bedcf")],
    targets: [
        .executableTarget(name: "EchoTerm", dependencies: ["SwiftTerm"], resources: [.process("Resources")]),
        .testTarget(name: "EchoTermTests", dependencies: ["EchoTerm"])
    ]
)
