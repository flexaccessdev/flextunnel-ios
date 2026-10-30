# Building in a macOS VM, installing from a paired Mac

The development VM can build, sign and run the Simulator. In this setup the
physical iPhone is paired with `machost`, so device installation and launch run
there over SSH.

## Automated build and install

```sh
scripts/run-device-ios-host.sh
scripts/run-device-ios-host.sh doctor
scripts/run-device-ios-host.sh status
```

The script builds a signed Release app in the VM, transfers it to `machost`,
verifies the signature and installs and launches it on the phone. It defaults
to the pinned core; `--local` selects an existing local xcframework and
`-c Debug` selects a debug build. See [local CI](local-ci.md#running-on-the-phone)
for device selection, overrides and output paths.

The build Mac needs Xcode, `xcodegen`, a signing certificate with its private
key, and provisioning profiles that cover the phone and both app bundles. The
installing Mac needs Xcode's device tools and an existing pairing with the
phone. A signed build can be produced without the phone attached to the build
Mac; development profiles must already include its hardware UDID.

## Why the VM cannot pair

The VM can never pair with the phone, so do not try:

- Virtualization.framework, which UTM's Apple backend and Tart use, has no USB
  passthrough.
- Initial trust can only be established over USB. The VM can see the phone's
  `_remotepairing` Bonjour service, but `xcrun devicectl manage pair` fails with
  `CoreDeviceError 1000`.
- Pairing records in `/var/db/lockdown` sit in an APFS data vault: `open()`
  returns `EPERM` even for root with Full Disk Access, on the host as well, so
  they cannot be copied in.

## Manual build

Use this when installing from another paired Mac or diagnosing a failed step.
The local-device script uses the sibling `../devtools` checkout (or
`DEVTOOLS_DIR`), as configured by `.devtools.conf`.

Set the signing team:

```sh
cp Developer.local.xcconfig.sample Developer.local.xcconfig
# Edit Developer.local.xcconfig and set DEVELOPMENT_TEAM.
```

Build without selecting or contacting a device:

```sh
scripts/run-device-ios.sh --build-only --pinned
```

This script defaults to **Debug** and a **local** Rust artifact; `--pinned`
selects the released xcframework and avoids needing the sibling Rust build.
The product is `build/DerivedData/Build/Products/Debug-iphoneos/Flextunnel.app`,
including its embedded widget. Use `-c Release` for a Release build.

The equivalent Debug build by hand is:

```sh
xcodegen generate
xcodebuild build \
  -project Flextunnel.xcodeproj \
  -scheme FlextunnelApp \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates
```

If the provisioning profiles do not include the phone, register its UDID with
the developer team and refresh the profiles. Xcode on the paired Mac can do
this. `-allowProvisioningUpdates` on a device-less build does not itself select
or register the phone.

## Transfer, install and launch

Archive the signed app on the build Mac:

```sh
ditto -c -k --keepParent \
  build/DerivedData/Build/Products/Debug-iphoneos/Flextunnel.app \
  build/Flextunnel-device.zip
scp build/Flextunnel-device.zip machost:~/Flextunnel-device.zip
```

On the paired Mac, extract it and select the phone's CoreDevice identifier:

```sh
ditto -x -k ~/Flextunnel-device.zip ~/flextunnel-device
codesign --verify --deep --strict ~/flextunnel-device/Flextunnel.app
xcrun devicectl list devices
xcrun devicectl device install app --device <IDENTIFIER> ~/flextunnel-device/Flextunnel.app
xcrun devicectl device process launch --device <IDENTIFIER> dev.flexaccess.flextunnel
```

A locked phone can accept installation but refuse launch. Unlock it and retry.
The CoreDevice identifier used by `devicectl` differs from the hardware UDID
recorded in provisioning profiles.

For debugging, build with Debug and attach from Xcode on the paired Mac. To
pause before startup, launch with `--start-stopped` before attaching.

If building directly on the paired Mac, use
`scripts/run-device-ios.sh <DEVICE_ID> --pinned` to build, install and launch
without a transfer step.
