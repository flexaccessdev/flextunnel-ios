// swift-tools-version:5.9
import Foundation
import PackageDescription

// Delivers the iOS Rust artifact — libflextunnel.xcframework (built by the
// sibling repo's build-ios.sh, released as libflextunnel-ios.xcframework.zip) —
// as a Swift package binary target. The app (this repo) references this package
// by local path, so it always uses this manifest; there is no vendored copy.
//
// Default: download the pinned release zip by URL + checksum (reproducible).
// Bump both when moving to a new release (scripts/bump-xcframework.sh <tag>).
//
// Local FFI dev: set FLEXTUNNEL_LOCAL_XCFRAMEWORK to link a locally built
// xcframework instead of the release. SPM forbids binary-target paths outside
// the package root, so the local build is reached through the committed relative
// symlink local/libflextunnel.xcframework -> ../flextunnel/dist/ios. Set the var
// to "1" to use that symlink, or to another path relative to this package dir:
//   FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodegen generate && ... xcodebuild ...

func localBinaryTarget() -> Target? {
    guard let value = ProcessInfo.processInfo.environment["FLEXTUNNEL_LOCAL_XCFRAMEWORK"],
          !value.isEmpty else { return nil }
    let path = (value == "1" || value == "true") ? "local/libflextunnel.xcframework" : value
    return .binaryTarget(name: "libflextunnel", path: path)
}

let binaryTarget = localBinaryTarget() ?? .binaryTarget(
    name: "libflextunnel",
    url: "https://github.com/flexaccessdev/flextunnel/releases/download/v0.0.67/libflextunnel-ios.xcframework.zip",
    checksum: "b67ed05bf06ffb77d92cee0f09e14016fad2291ea4d05172ff27c35f7e8f8d30"
)

let package = Package(
    name: "Flextunnel",
    products: [
        .library(name: "libflextunnel", targets: ["libflextunnel"]),
    ],
    targets: [binaryTarget]
)
