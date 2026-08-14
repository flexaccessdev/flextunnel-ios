# Running CI locally, and running on the phone

This checkout usually lives in a **macOS VM**. That guest can do nearly
everything: compile, run the Simulator, and sign a build the phone will accept.
The one thing it can never do is talk to physical hardware. So the local setup
is split along that line, and only along that line:

| | Where | Entry point |
| --- | --- | --- |
| Build, Simulator, signing, the workflow checks | here, in the VM | `ci/ci.sh` |
| Install and launch on the iPhone | `machost`, over ssh | `ci/device.sh` |

```sh
ci/ci.sh                # the default jobs, all local
ci/ci.sh unsigned       # just one
ci/ci.sh --list         # what jobs exist

ci/device.sh            # build here, install + launch on the phone
ci/device.sh doctor     # report on the host, change nothing
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
- **`unsigned`** — `.github/workflows/unsigned-ios.yml`: the Release archive with
  signing off, then its bundle assertions — widget embedded, nothing signed, no
  profile baked in, and the background-location keys still in `Info.plist`. The
  packaging that workflow does after that (IPA, archive zip, checksums,
  prerelease) is release plumbing and is deliberately not repeated here.
- **`device`** — the signed device slice. This is the artifact `ci/device.sh`
  installs, and running the job on its own is a fast check that signing still
  resolves.
- **`ffi`** — `.github/workflows/verify-flextunnel-commit.yml`, against the
  sibling `../flextunnel` **working tree** rather than a pinned commit: rebuild
  `libflextunnel.xcframework` with `build-ios.sh release`, regenerate with
  `FLEXTUNNEL_LOCAL_XCFRAMEWORK=1`, and link against it. Not in the default set —
  it compiles the Rust core for iOS, which is minutes rather than seconds, and it
  only means something while you are changing the sibling. It regenerates the
  project against the pinned release again on the way out, so it does not leave
  a project wired to a local build behind.

There are **no unit tests to run**: `project.yml` declares no test target, so
"CI" for this repo is builds and bundle assertions. When a job and the workflow
it mirrors disagree, the workflow is right and the script is stale — nothing
enforces that.

## Running on the phone

```sh
ci/device.sh                    # build, ship, install, launch
ci/device.sh install            # stop after installing
ci/device.sh status             # is it installed on the phone, and is it running
ci/device.sh --console          # launch attached, app stdout/stderr streamed here
ci/device.sh devices            # what machost has paired
ci/device.sh clean              # drop the staging directory on machost
```

**A successful run is not necessarily visible on the phone.** `devicectl`
launches the process but will not wake a sleeping screen, so over Wi-Fi an
install that worked looks exactly like one that did nothing until you unlock the
device. That is what `status` is for: it reports the installed version and the
running processes — the app and, separately, its widget extension.

`run` builds via `ci/ci.sh device`, packs the `.app` with `ditto`, ships it to
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
