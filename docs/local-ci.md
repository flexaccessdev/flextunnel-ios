# Running CI locally, and running on the phone

`ci/ci.sh` checks the working tree on a Mac, including a macOS VM. Device
installation uses a separate Mac that is paired with the phone.

```sh
ci/ci.sh                # simulator, smoke, unit, unsigned
ci/ci.sh --list
ci/ci.sh unit
ci/ci.sh ffi            # integrate the sibling Rust working tree
ci/e2e.sh               # browser UI tests through a real tunnel
```

Build jobs need Xcode and `xcodegen`. Simulator jobs default to `iPhone 17`;
set `FLEXTUNNEL_CI_SIM` to another installed simulator name. FFI and e2e jobs
also need Rust; e2e needs `uv` and internet access.

## Jobs and coverage

| Job | What it checks | Default? |
| --- | --- | --- |
| `simulator` | Debug build with `ARCHS=arm64`, using the pinned core | Yes |
| `smoke` | Installs the simulator build, launches it and checks it remains running after 5s | Yes |
| `unit` | App-hosted tests in `Sources/FlextunnelTests` on the simulator | Yes |
| `unsigned` | Unsigned Release archive, widget embedding, absence of signatures/profiles and required location plist keys | Yes |
| `device` | Signed Debug device build and signature verification | No |
| `ffi` | Rebuilds `../flextunnel` in Release and builds the app against that local xcframework | No |
| `e2e` | Browser UI tests; also available directly as `ci/e2e.sh` | No |

Run `simulator` before a standalone `smoke` job: smoke uses its existing build.
The unit suite covers route matching, address resolution and library logic;
keep `RouteMatchTests` aligned with core's `routed_set.rs` tests.

`device` needs a signing identity and profiles for the target phone, with the
team set in `Developer.local.xcconfig` or `FLEXTUNNEL_CI_TEAM`. It does not
install the build.

`ffi` builds the Rust sibling's working tree, then generates and builds with
`FLEXTUNNEL_LOCAL_XCFRAMEWORK=1`. After the app build, including a build failure,
it regenerates the project for the pinned release. This job checks compilation
and linking only: the other jobs regenerate for the pinned core. To exercise
the local build, run `FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 ci/e2e.sh` or
`scripts/run-device-ios-host.sh --local` afterwards.

The archive and FFI jobs mirror checks in
[unsigned-ios.yml](../.github/workflows/unsigned-ios.yml) and
[verify-flextunnel-commit.yml](../.github/workflows/verify-flextunnel-commit.yml).
The GitHub workflows run no tests; they build and package. When a job and the
workflow it mirrors disagree, the workflow is right and the script is stale;
nothing enforces that. Local checks do not cover release tagging, IPA/zip
packaging or publication.

The runners build unsigned from a clean checkout, so working-tree state such as
a stale generated project or a still-linked local xcframework can pass here and
fail there. Conversely, an expired certificate or a profile that no longer
covers the phone fails `device` locally but never on GitHub. Installed Xcode
versions also differ.

## Running on the phone

```sh
scripts/run-device-ios-host.sh                    # build, ship, install, launch
scripts/run-device-ios-host.sh install            # build and install only
scripts/run-device-ios-host.sh status             # installed version and running processes
scripts/run-device-ios-host.sh devices
scripts/run-device-ios-host.sh doctor
scripts/run-device-ios-host.sh -c Debug --console  # attached launch, app output streamed here
scripts/run-device-ios-host.sh --local            # use an existing local xcframework
```

The host script builds its own **Release** device slice by default, using the
pinned core and `build/DerivedData-device`. Debug's `-Onone` changes how
timing-sensitive tunnel code behaves, so test on hardware with Release. It
reads the team from `Developer.local.xcconfig` or `--team`. `--local` requires
a previously built sibling xcframework; it does not rebuild Rust. `--no-build`
uses the existing product and `--app PATH` supplies another signed bundle.

The script transfers the app to `machost`, verifies its signature there, then
installs and launches it with `devicectl`. The remote Mac needs Xcode's device
tools and an existing pairing with the phone; it does not need this checkout
or a Rust toolchain. See [the VM deployment guide](deploy-from-a-vm.md) for
signing setup and a manual transfer.

Device selection defaults to `iPhone` and must match exactly one identifier,
UDID or name. Set `--device` or `FLEXTUNNEL_IOS_DEVICE` to change it. A device
reported unavailable stops the run before building. A launch does not wake
the screen; use `status` to check it. If installation succeeds but launch
fails, the script exits 1; unlock the phone and retry if it was locked.
A phone on a newer iOS than `machost`'s Xcode supports can refuse the install
even though the build succeeded; update Xcode on that host.

| Remote setting | Default / override |
| --- | --- |
| SSH host | `machost` / `FLEXTUNNEL_IOS_HOST` |
| Workspace | `~/codes/staging-area/flextunnel-ios` |
| Lock | `~/codes/staging-area/flextunnel-ios.lock` |
| Staging root | `FLEXTUNNEL_IOS_STAGING` |

Runs replace the remote workspace and lock it during transfer/install. If a
killed run left the lock behind, the next run reports it and prints the `rmdir`
command that clears it.
`scripts/run-device-ios-host.sh clean` removes the workspace under the same
lock. Local CI products live under `build/ci/`, with separate derived data
for simulator, unit, device and FFI jobs.

## End-to-end UI tests

```sh
ci/e2e.sh
ci/e2e.sh -only-testing:FlextunnelUITests/BrowserE2ETests/testDisconnectFromTunnelStatusReturnsToSetup
FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 ci/e2e.sh
```

`ci/e2e.sh` builds a server matching the app's pinned core tag from the sibling
repo's Git history. With `FLEXTUNNEL_LOCAL_XCFRAMEWORK=1`, it builds the server
from the sibling working tree and links the app to the existing local
xcframework; rebuild that artifact first. `flexaccess-keys` uses the dependency
tag from the selected server source. Tool builds are cached in `build/e2e/tools`.

The script starts a fixture HTTP site, routed/empty-set/CIDR servers and a
control endpoint. Each server has a scratch home for its lock and blocklist.
The simulator reaches the servers through iroh discovery and relays, so the
run needs internet access even though the fixtures run locally.

The app is uninstalled before testing. Its Debug-only launch hook seeds an
`E2E` profile and key and clears the browser library. Results and screenshots
are in `build/e2e/run/results.xcresult`, with fixture and server logs alongside.
The script stops its local services on exit.
