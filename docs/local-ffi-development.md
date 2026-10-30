# Developing against a local Rust build (FFI)

To iterate on the Rust FFI without cutting a release, build the sibling and set
`FLEXTUNNEL_LOCAL_XCFRAMEWORK=1` — the package's binary target then links the
sibling's `dist/ios` build (reached via the committed symlink
`Packages/Flextunnel/local/libflextunnel.xcframework`) instead of the released zip:

```sh
cd ../flextunnel && ./build-ios.sh release
cd ../flextunnel-ios
FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodegen generate
FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodebuild -project Flextunnel.xcodeproj \
  -scheme FlextunnelApp \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 clean build
```

The var is read when Swift Package Manager evaluates `Package.swift`, so it must
be set for both `xcodegen`/resolution and the build. In the Xcode GUI, export it
before launching (`launchctl setenv FLEXTUNNEL_LOCAL_XCFRAMEWORK 1`, then restart
Xcode) since scheme env vars don't reach package resolution. After rebuilding
the sibling artifact, clean-build the app to avoid reusing cached binary products.

To return to the pinned release:

```sh
unset FLEXTUNNEL_LOCAL_XCFRAMEWORK
xcodegen generate
xcodebuild -project Flextunnel.xcodeproj -scheme FlextunnelApp \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 clean build
```

If you set the variable with `launchctl`, also run
`launchctl unsetenv FLEXTUNNEL_LOCAL_XCFRAMEWORK` and restart Xcode.
