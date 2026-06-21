// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "header-tagger",
    platforms: [ .macOS(.v13) ],
    targets: [ .executableTarget(name: "header-tagger") ]
)
