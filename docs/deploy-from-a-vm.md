# Building in a macOS VM, installing from the host

A macOS VM (UTM, [Tart](https://tart.run), Orka…) is a fine build box for this
project, but it can **never install onto a physical iPhone or iPad directly** —
no matter how the network is configured. The fix is not a networking change; it
is to split the work: the **VM builds**, the **host installs**. This is the same
split Tart-based CI and device farms use, and it is why those farms keep the
phones attached to bare metal.

## Why the device is unreachable from the VM

Three independent walls, in the order you hit them:

1. **No USB passthrough.** macOS guests run on Apple's Virtualization.framework
   (this is true of UTM's Apple-virtualization backend and of Tart, which is
   built on it). It has no USB device passthrough at all, so the phone cannot
   appear on the guest's USB bus.
2. **Initial trust requires USB.** iOS 17+ devices advertise `_remotepairing`
   over Bonjour, and a bridged VM *can* see and ping them. That service only
   transports a trust relationship that already exists — it cannot bootstrap
   one. A device will not show a *Trust This Computer?* prompt to a host it has
   never met over USB, which is what stops anyone on your LAN from silently
   pairing with your phone. `xcrun devicectl manage pair --device iPhone.local`
   fails with `CoreDeviceError 1000 (device not found)` because CoreDevice never
   enumerates the device, so no packet reaches the phone and no prompt appears.
3. **Pairing records can't be copied.** The usual workaround — lifting
   `/var/db/lockdown/<UDID>.plist` and `SystemConfiguration.plist` from a Mac
   that *is* paired — does not work on current macOS. That directory is an APFS
   **data vault**: files there `stat` as world-readable `-rw-r--r--`, yet
   `open()` returns `EPERM` even for root with Full Disk Access, because access
   is gated on a private Apple entitlement. It is sealed on the host too, so
   there is nothing to copy *out* either. Only disabling SIP on both machines
   would open it, which is not worth it.

Bridged networking is still worth configuring — not to reach the device, but
because it is the most convenient way to move the built app to the host.

## What this means for `scripts/run-device-ios.sh`

That script normally builds, installs, and launches in one pass, and it
validates the device id against the paired-device list up front — which in a
guest always comes back empty. Pass **`--build-only`** to stop after the build:
it requires no device id, skips the pairing check and the install/launch steps,
and prints the product path.

Use the script unchanged **on the host**; use `--build-only` in the VM.

## 1. In the VM: build the device slice

Prerequisites (see the README for the full list):

```sh
brew install xcodegen jq
cp Developer.local.xcconfig.sample Developer.local.xcconfig
# then edit it and set DEVELOPMENT_TEAM
```

Then generate the project and build:

```sh
scripts/run-device-ios.sh --build-only --pinned
```

`--pinned` matters here. The script defaults to linking a *locally* built
xcframework from the sibling `../flextunnel` Rust repo, which a VM checkout
usually doesn't have — without `--pinned` it stops with `local xcframework not
found`. Passing it lets Swift Package Manager download the pinned release zip
instead, so the build needs network access but no sibling repo.

The equivalent by hand, if you'd rather not use the script:

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

`generic/platform=iOS` builds the device arm64 slice **without needing the
hardware UDID**, which is exactly what makes a device-less build machine work.
The product lands at:

```
build/DerivedData/Build/Products/Debug-iphoneos/Flextunnel.app
```

Note the name: `PRODUCT_NAME` is `Flextunnel` while the scheme is
`FlextunnelApp` (see `project.yml`), and the WidgetKit extension is embedded in
`Flextunnel.app/PlugIns/`. Installing the `.app` carries the widget with it.

### Signing caveat — register the device from the host first

Automatic signing can only produce a build that installs on devices already
listed in the provisioning profile. The VM cannot see your phone, so it cannot
register it, and `-allowProvisioningUpdates` has no UDID to add. If the target
device has never been registered, **connect it to the host once** and let Xcode
register it; the VM then picks up the updated profile from the same Apple ID.

Check which devices the profile you are signing with covers:

```sh
for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision; do
  echo "== $(basename "$p")"
  security cms -D -i "$p" | plutil -extract ProvisionedDevices json -o - - 2>/dev/null \
    | jq -r '.[] | "   " + .' || echo "   (no ProvisionedDevices — enterprise profile)"
done
```

Those are hardware UDIDs, which is what the profile records — not the CoreDevice
identifiers `scripts/list-devices-ios.sh` shows in its `IDENTIFIER` column. Match
them against that script's `UDID` column on the host.

## 2. Move the app to the host over the bridge

Set the VM's network adapter to **Bridged** (not Shared/NAT) so it gets an
address on the same LAN as the host, then serve the build product. In the VM:

```sh
cd build/DerivedData/Build/Products/Debug-iphoneos
mkdir -p Payload && cp -R Flextunnel.app Payload/ && zip -qry Flextunnel.ipa Payload
python3 -m http.server 8080
```

On the host (substitute the VM's LAN address — `ipconfig getifaddr en0` in the
guest):

```sh
curl -O http://<VM_IP>:8080/Flextunnel.ipa
unzip -oq Flextunnel.ipa
```

Any file transport works — a shared folder, `scp`, AirDrop. The bridge is just
the one that needs no extra setup once the adapter is in bridged mode. Stop the
server when you're done; it serves that directory to your whole LAN.

## 3. On the host: install and launch

```sh
scripts/list-devices-ios.sh          # IDENTIFIER column = CoreDevice UUID
xcrun devicectl device install app --device <IDENTIFIER> Payload/Flextunnel.app
xcrun devicectl device process launch --device <IDENTIFIER> dev.flexaccess.flextunnel
```

A locked device refuses the launch with `CoreDeviceError 10002` — the install
still succeeded, so unlock and tap the icon, or re-run the launch.

## Debugging a VM-built app

Installing from the CLI doesn't cost you the debugger. In Xcode on the host,
**Debug → Attach to Process → Flextunnel** under your device gives you
breakpoints and LLDB against the VM-built binary.

If the bug is in startup — `FlextunnelApp.init`, tunnel bring-up, the SOCKS
listener binding — attaching afterwards is too late. Launch suspended and attach
before resuming:

```sh
xcrun devicectl device process launch --device <IDENTIFIER> --start-stopped dev.flexaccess.flextunnel
```

## Checking the tunnel itself from a VM-built install

Nothing about this split changes runtime behavior — the app runs on the device,
so the tunnel, the split-tunnel set, and port forwards behave exactly as in
[Split-tunnel routing](split-tunnel-routing.md) and
[Proxy-only mode & port forwarding](port-forwarding.md). The VM is only a
compiler.

## When to skip all of this

If the host is your own Mac with the phone attached, the lowest-friction setup
is to share the checkout and run `scripts/run-device-ios.sh <DEVICE_ID>` **on
the host**: one command, live debugger, no transfer step. The build-in-VM split
earns its keep when the VM has something the host lacks — a pinned Xcode
version, a clean toolchain, disposable state — which is the reason Tart exists.
Simulator builds have none of these constraints and run fine inside the VM;
see the README for the pinned arm64 iOS 26 Simulator destination.
