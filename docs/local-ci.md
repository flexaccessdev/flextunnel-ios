# Running CI locally, and running on the phone

This checkout usually lives in a **macOS VM**. That guest can do nearly
everything: compile, run the Simulator, and sign a build the phone will accept.
The one thing it can never do is talk to physical hardware. So the local setup
is split along that line, and only along that line:

| | Where | Entry point |
| --- | --- | --- |
| Build, Simulator, signing, the workflow checks | here, in the VM | `ci/ci.sh` |
| Install and launch on the iPhone | `machost`, over ssh | `scripts/run-device-ios-host.sh` |

```sh
ci/ci.sh                # the default jobs, all local
ci/ci.sh unsigned       # just one
ci/ci.sh --list         # what jobs exist
ci/ci.sh unit           # unit tests (part of the default set)
ci/e2e.sh               # browser UI tests against a real local server (also `ci/ci.sh e2e`)

scripts/run-device-ios-host.sh            # build here, install + launch on the phone
scripts/run-device-ios-host.sh doctor     # report on the host, change nothing
```

Both run against the working tree as it stands, uncommitted changes included —
which is the reason to run them instead of pushing a branch and waiting for
Actions.

## Why only the hardware step is remote

Not because the VM is a weak build box. Three walls stop it from reaching a
device, and none of them is a networking problem — the long version is in
[Building in a macOS VM](deploy-from-a-vm.md), the short one:
Virtualization.framework has no USB passthrough, initial trust can only be
bootstrapped over USB, and the `/var/db/lockdown` pairing records are sealed in
an APFS data vault that cannot be copied out of the host either.

Signing is *not* on that list, which is what keeps the split so narrow. The VM
holds an **Apple Development: Jianchao Chen** certificate and the team's
wildcard provisioning profile, and that profile already lists the iPhone's
hardware UDID. A device slice only needs the UDID to be *in the profile* — not
on this machine's USB bus — so `generic/platform=iOS` produces a fully signed,
installable `.app` here. `machost` is handed a finished bundle and never builds
anything: it needs no `xcodegen`, no Rust, no checkout of this repo.

The Simulator is not a virtual machine — it is a userspace runtime on this
kernel — so it runs in the guest like anywhere else.

## The local jobs

`ci/ci.sh` mirrors the two GitHub workflows, plus the two things the VM can do
that Actions does not bother with:

- **`simulator`** — the README's verify build, `ARCHS=arm64` forced.
  `libflextunnel.xcframework` is arm64-only, and a generic Simulator destination
  without it picks x86_64 and fails to link.
- **`smoke`** — boots a simulator, installs that build, launches it, and checks
  the process is still alive five seconds later. The only check here that proves
  the Rust core actually loads and the app survives launch; everything else
  stops at compile and link.
- **`unit`** — the unit tests in `Sources/FlextunnelTests`, hosted by the app on
  the same simulator: the pure logic behind the browser — route labels
  (`RouteMatch`, kept in step with flextunnel-core's `RoutedSet` tests),
  address-bar URL resolution, the bookmark/history store and history grouping.
  Seconds, so it is in the default set.
- **`unsigned`** — `.github/workflows/unsigned-ios.yml`: the Release archive with
  signing off, then its bundle assertions — widget embedded, nothing signed, no
  profile baked in, and the background-location keys still in `Info.plist`. The
  packaging that workflow does after that (version tag, IPA, archive zip,
  checksums, release) is release plumbing and is deliberately not repeated here.
- **`device`** — the signed device slice, at Debug: a compile-and-sign check, so
  running the job on its own tells you signing still resolves. It is not what
  goes on the phone — `scripts/run-device-ios-host.sh` builds its own Release slice (below).
- **`ffi`** — `.github/workflows/verify-flextunnel-commit.yml`, against the
  sibling `../flextunnel` **working tree** rather than a pinned commit: rebuild
  `libflextunnel.xcframework` with `build-ios.sh release`, regenerate with
  `FLEXTUNNEL_LOCAL_XCFRAMEWORK=1`, and link against it. Not in the default set —
  it compiles the Rust core for iOS, which is minutes rather than seconds, and it
  only means something while you are changing the sibling. It regenerates the
  project against the pinned release again on the way out, so it does not leave
  a project wired to a local build behind.
- **`e2e`** — `ci/e2e.sh`, the browser's end-to-end UI tests (below). Not in
  the default set either: it needs a Rust toolchain and internet access, and
  takes a few minutes.

The GitHub workflows run neither test suite; they build and package. When a
job and the workflow it mirrors disagree, the workflow is right and the script
is stale — nothing enforces that.

## Running on the phone

```sh
scripts/run-device-ios-host.sh                    # build, ship, install, launch
scripts/run-device-ios-host.sh install            # stop after installing
scripts/run-device-ios-host.sh status             # is it installed on the phone, and is it running
scripts/run-device-ios-host.sh --console          # launch attached, app stdout/stderr streamed here
scripts/run-device-ios-host.sh devices            # what machost has paired
scripts/run-device-ios-host.sh clean              # drop the staging directory on machost

scripts/run-device-ios-host.sh -c Debug           # debuggable slice instead of the Release default
scripts/run-device-ios-host.sh --local            # link the local ../flextunnel build (FFI dev)
```

This builds **Release** — the same `xcodebuild` invocation
`scripts/run-device-ios.sh` makes (`generic/platform=iOS`, `-sdk iphoneos`,
automatic signing off `DEVELOPMENT_TEAM`), into its own
`build/DerivedData-device`. What runs on real hardware should be the optimised
build; Debug's `-Onone` changes how anything timing-sensitive in the tunnel
behaves. `--no-build` ships whatever is already there, and `--app PATH` ships a
bundle from somewhere else entirely.

**A successful run is not necessarily visible on the phone.** `devicectl`
launches the process but will not wake a sleeping screen, so over Wi-Fi an
install that worked looks exactly like one that did nothing until you unlock the
device. That is what `status` is for: it reports the installed version and the
running processes — the app and, separately, its widget extension.

`run` builds the slice, packs the `.app` with `ditto`, ships it to
`machost`, re-verifies the signature **on the far end** (a transfer that damaged
the bundle shows up there, not as a cryptic `devicectl` error), then installs and
launches by CoreDevice identifier.

**Device selection.** `machost` has more than one device paired, and this project
targets the **iPhone** only. The selector defaults to `iPhone` and is matched
against the CoreDevice identifier, the hardware UDID, or the device name; it must
match exactly one, and the script prints the list and stops rather than guessing.
Override with `--device` or `FLEXTUNNEL_IOS_DEVICE`.

**A phone that is not attached fails fast.** `transportType` in `devicectl`'s
JSON is the field that says whether a device is reachable right now (`usb` /
`localNetwork`, or absent for one that is merely remembered — what the CLI prints
as `unavailable`). If the phone is not there, the run stops before building or
shipping anything and says to attach it by USB, or wake and unlock it on the
same network. Note that `tunnelState` is *not* that signal: a perfectly reachable
device sits at `disconnected` until a tunnel is actually needed.

A locked phone accepts the install and refuses the launch. The install still
stands, and the message says so — but the run **exits 1**, because the app it was
asked to launch is not running. Unlock the phone and retry, or tap the app.

## Where things land on the host

| | `machost` |
| --- | --- |
| shipped app | `~/codes/staging-area/flextunnel-ios/Flextunnel.app` |
| lock | `~/codes/staging-area/flextunnel-ios.lock` |
| overrides | `FLEXTUNNEL_IOS_HOST`, `FLEXTUNNEL_IOS_DEVICE`, `FLEXTUNNEL_IOS_STAGING` |

The staging area is shared with other repos driven onto that Mac, so everything
under it is named for this one. The workspace is replaced outright on each run
and a lock directory is claimed with `mkdir` (which fails atomically if it
exists), so a second run cannot swap the bundle a first one is mid-install from.
If a run is killed hard enough to skip the release, the next one says so and
prints the command to clear the lock. `clean` takes the same lock.

Local build products live under `build/ci/` (gitignored), one derived-data
directory per job, so the Simulator, device and FFI builds do not evict each
other.

## Where this is not the real runner

- **The Xcode versions differ**, and on purpose nobody keeps them in step: the VM
  builds with its own Xcode, `machost` only installs with its. A device on a
  newer iOS than the host's Xcode knows about can refuse the install even though
  the build here was fine — that failure is on the host side, not in the build.
- **Signing is real here, and it is one certificate and one wildcard profile.**
  If it expires or the profile stops covering the phone, the `device` job fails
  locally in a way GitHub never will, because the workflows build unsigned.
- **`machost` is a shared Mac** with other work and other paired hardware on it.
  That is why the device selector refuses to guess and why the staging path is
  namespaced.
- **The GitHub runners build unsigned, from a clean checkout.** Anything that
  depends on state in this working tree — a stale generated project, a local
  xcframework left linked — passes here and fails there.

## End-to-end UI tests

```sh
ci/e2e.sh                                    # every test
ci/e2e.sh -only-testing:FlextunnelUITests/BrowserE2ETests/testDisconnectFromTunnelStatusReturnsToSetup
FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 ci/e2e.sh     # app and server both from the ../flextunnel working tree
```

`Sources/FlextunnelUITests` drives the browser on a simulator (`iPhone 17`, or
`FLEXTUNNEL_CI_SIM`) through a **real** tunnel. `ci/e2e.sh` stands it all up on
loopback and tears it down on exit:

- **The server** is built from `../flextunnel` at the tag the pinned
  `libflextunnel` release comes from (read from `Packages/Flextunnel/Package.swift`),
  because client and server share one protocol version and keep no backward
  compatibility. With `FLEXTUNNEL_LOCAL_XCFRAMEWORK=1` it is built from the
  sibling working tree instead, to match the local app build. `flexaccess-keys`
  comes from the tag the sibling's `Cargo.toml` pins. Both land in
  `build/e2e/tools`, built once per tag; `cargo install --git file://…` clones
  from the sibling's history, so the sibling checkout is never touched. The
  server runs with its own `HOME`, so its lock and blocklist are scratch files.
- **The fixture site** (`ci/e2e/fixtures`) sits behind the server's host alias
  `e2e.flextunnel.test`. Only the server resolves that name, so a page that
  loads came through the tunnel.
- **The app** gets the server id, a fresh client secret and the site URL through
  `TEST_RUNNER_FLEXTUNNEL_E2E_*`. Its Debug-only launch hook
  (`E2ELaunchConfig.swift`) seeds an `E2E` profile and key and empties the
  library on every launch. The app is uninstalled first, so each run starts
  clean.

The simulator finds the server through iroh's n0 discovery and default relays,
as a real client would, so the run needs internet access. Results, including
screenshots of each screen the tests visit, are in
`build/e2e/run/results.xcresult`; the server and site logs are next to it.

Nothing here is macOS-desktop-specific. A test that needs the desktop client
belongs on `macvm`, not here.
