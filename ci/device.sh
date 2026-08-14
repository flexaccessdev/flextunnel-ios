#!/usr/bin/env bash
# Build here, run on the phone over there.
#
#   ci/device.sh                 # build, install and launch on the paired iPhone
#   ci/device.sh install         # same, without launching
#   ci/device.sh devices         # what the host Mac has paired
#   ci/device.sh doctor          # report on the host, change nothing
#   ci/device.sh clean           # drop the staging directory on the host
#
# This checkout normally lives in a macOS VM, which can do everything except
# touch the hardware: it compiles, it signs (the phone's UDID is in the
# provisioning profile — the phone does not have to be on this machine's USB
# bus), and it runs the Simulator. What it can never do is pair with a physical
# device: Virtualization.framework has no USB passthrough, initial trust can
# only be bootstrapped over USB, and the pairing records are sealed in a data
# vault that cannot be copied out. docs/deploy-from-a-vm.md has the long version.
#
# So the split is not build-vs-build. Everything is built and signed *here*, by
# ci/ci.sh's `device` job; the host Mac is only ever handed a finished .app to
# install and launch. That keeps the toolchain in one place — the host needs no
# xcodegen, no Rust, no checkout of this repo.
#
# Overrides:
#   FLEXTUNNEL_IOS_HOST     ssh target        (default: the 'machost' alias)
#   FLEXTUNNEL_IOS_DEVICE   device selector   (default: iPhone) — matched against
#                           the CoreDevice identifier, the hardware UDID, or the
#                           device name, and required to match exactly one
#   FLEXTUNNEL_IOS_STAGING  staging area on the host
#                           (default: codes/staging-area under its login home)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUNDLE_ID=dev.flexaccess.flextunnel
# PRODUCT_NAME, which project.yml keeps deliberately distinct from the target and
# scheme name (FlextunnelApp).
PRODUCT_APP=Flextunnel.app
APP_PATH=build/ci/DerivedData-device/Build/Products/Debug-iphoneos/$PRODUCT_APP

usage() {
    cat >&2 <<'USAGE'
usage: ci/device.sh [options] [run|install|status|devices|doctor|clean]

  run       build, ship, install, launch   (default)
  install   build, ship, install
  status    is the app installed on the phone, and is it running
  devices   list the host's paired devices
  doctor    report on the host, change nothing
  clean     drop the staging directory on the host

options:
  --device SELECTOR   identifier, UDID or name of the target device
  --no-build          ship the existing build instead of rebuilding
  --app PATH          ship this .app instead of the one ci/ci.sh device builds
  --console           launch attached, streaming the app's stdout/stderr here
USAGE
    exit 2
}

target=${FLEXTUNNEL_IOS_HOST:-machost}
selector=${FLEXTUNNEL_IOS_DEVICE:-iPhone}
build=1
console=0
app=$APP_PATH
command=

while [ $# -gt 0 ]; do
    case $1 in
        --device) selector=${2:-}; [ -n "$selector" ] || usage; shift 2 ;;
        --app)    app=${2:-}; [ -n "$app" ] || usage; build=0; shift 2 ;;
        --no-build) build=0; shift ;;
        --console)  console=1; shift ;;
        -h|--help)  usage ;;
        run|install|status|devices|doctor|clean)
            [ -z "$command" ] || usage
            command=$1; shift ;;
        *) usage ;;
    esac
done
command=${command:-run}

info() { echo "[device] $*"; }
die() { echo "[device] error: $*" >&2; exit 1; }

if [ -n "${FLEXTUNNEL_IOS_STAGING:-}" ]; then
    staging=$FLEXTUNNEL_IOS_STAGING
else
    staging="$(ssh "$target" 'printf %s "$HOME"')/codes/staging-area"
fi

# The staging path is spliced into remote command lines, one of which is rm -rf.
# Take only an absolute path of plain characters, at least two components deep,
# so no expansion of it can name a filesystem root — the same stance the sibling
# repo's CI drivers take (../flextunnel/ci/unix/remote.sh).
if ! [[ $staging =~ ^(/[A-Za-z0-9._-]+){2,}$ && $staging != *..* ]]; then
    die "the staging area must be an absolute path of letters, digits, _ . - at least two components deep, with no trailing slash; got: $staging"
fi

workspace=$staging/flextunnel-ios
lock=$staging/flextunnel-ios.lock

# One TSV row per paired device: identifier, udid, name, transport. devicectl
# writes JSON to a file and chatter to stderr, so the parsing happens on the far
# end where the JSON is — jq is there; a checkout of this repo is not.
#
# transportType is the field that decides whether the device can be reached right
# now: it is 'usb' or 'localNetwork' for a device devicectl can see, and absent
# for one that is merely remembered — which is what `devicectl list devices`
# renders as "unavailable". (tunnelState is not that signal; a perfectly
# reachable device sits at "disconnected" until a tunnel is actually needed.)
host_devices() {
    ssh "$target" '
        set -e
        json=$(mktemp -t flextunnel-devices)
        trap "rm -f $json" EXIT
        xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
        jq -r ".result.devices[]
               | [ .identifier,
                   (.hardwareProperties.udid // \"\"),
                   (.deviceProperties.name // \"\"),
                   (.connectionProperties.transportType // \"unavailable\") ]
               | @tsv" "$json"
    '
}

# Exactly one match or nothing. Picking silently between a phone and a tablet is
# worse than asking, and the failure mode of guessing wrong is an app installed
# on someone's iPad.
resolve_device() {
    local rows matches count
    rows=$(host_devices) || die "could not list devices on $target"
    [ -n "$rows" ] || die "$target has no paired devices"
    matches=$(printf '%s\n' "$rows" | awk -F'\t' -v sel="$selector" '
        tolower($1) == tolower(sel) || tolower($2) == tolower(sel) || tolower($3) == tolower(sel)')
    count=$(printf '%s' "$matches" | grep -c . || true)
    if [ "$count" -ne 1 ]; then
        {
            [ "$count" -eq 0 ] && echo "no device on $target matches '$selector'. Paired:" \
                                || echo "'$selector' matches $count devices on $target. Paired:"
            printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %-38s %-26s %-14s %s\n", $1, $2, $4, $3 }'
        } >&2
        exit 1
    fi
    printf '%s' "$matches"
}

case $command in
    devices)
        info "paired devices on $target"
        host_devices | awk -F'\t' '
            BEGIN { printf "  %-38s %-26s %-14s %s\n", "IDENTIFIER", "UDID", "TRANSPORT", "NAME" }
            { printf "  %-38s %-26s %-14s %s\n", $1, $2, $4, $3 }'
        exit 0
        ;;
    doctor)
        info "checking $target"
        ssh "$target" '
            sw_vers -productName; sw_vers -productVersion
            xcodebuild -version | head -1
            echo -n "signing identities: "; security find-identity -v -p codesigning | tail -1
            # The only thing this host needs beyond Xcode: the device list is
            # parsed over there, where devicectl writes its JSON.
            echo -n "jq: "; command -v jq || echo "MISSING — device listing will fail"'
        echo
        info "paired devices"
        host_devices | awk -F'\t' '{ printf "  %-38s %-26s %-14s %s\n", $1, $2, $4, $3 }'
        echo
        ssh "$target" "
            echo -n 'staging:  '; ls -d '$staging' 2>/dev/null || echo '$staging (absent — created on the first run)'
            echo -n 'shipped:  '; ls -d '$workspace' 2>/dev/null || echo 'nothing shipped yet'
            [ -d '$lock' ] && echo 'lock:     HELD — a run is in progress, or one died holding it' || echo 'lock:     free'"
        exit 0
        ;;
    clean)
        ssh "$target" "mkdir -p '$staging' && mkdir '$lock'" \
            || die "$target is busy: $lock exists. If no run is in progress, clear it with: ssh $target rmdir '$lock'"
        info "dropping $workspace on $target"
        ssh "$target" "rm -rf '$workspace'; rmdir '$lock'"
        info 'done'
        exit 0
        ;;
esac

# Captured first, and its status checked: resolve_device's failure exits are
# inside a command substitution, so they end that subshell, not this script —
# reading straight from $(resolve_device) would sail on with empty fields.
device_row=$(resolve_device) || exit 1
IFS=$'\t' read -r device_id device_udid device_name device_transport <<<"$device_row"
info "device: $device_name ($device_id, udid $device_udid, over $device_transport)"
if [ "$device_transport" = unavailable ]; then
    hint='Attach it by USB, or wake and unlock it on the same network with Wi-Fi turned on, then retry.'
    [ "$command" = status ] || hint="$hint
       Nothing has been built or shipped."
    die "$device_name is paired with $target but not reachable from it right now.
       $hint"
fi

# Worth its own command because a successful `run` is not visible on the phone:
# devicectl launches the process, but it will not wake a sleeping screen, so an
# install that worked looks exactly like one that did nothing until you unlock.
if [ "$command" = status ]; then
    info "installed on $device_name:"
    ssh "$target" "xcrun devicectl device info apps --device '$device_id' --bundle-id '$BUNDLE_ID' 2>/dev/null | tail -n +4" \
        | sed 's/^/  /'
    info 'running processes:'
    # Matched on the bundle *path*, not the bundle id: this listing is pid +
    # executable path, and the id (dev.flexaccess.flextunnel) appears nowhere in
    # /private/var/containers/Bundle/Application/<uuid>/Flextunnel.app/Flextunnel.
    procs=$(ssh "$target" "xcrun devicectl device info processes --device '$device_id' 2>/dev/null" \
        | grep -F "/$PRODUCT_APP/" || true)
    # The widget extension shows up as its own process; both come from the same
    # installed bundle, so seeing either means the install is live.
    if [ -n "$procs" ]; then
        printf '%s\n' "$procs" | awk '{ printf "  pid %-8s %s\n", $1, $2 }'
    else
        echo '  none — installed but not currently running'
    fi
    exit 0
fi

if [ "$build" = 1 ]; then
    info 'building the signed device slice here'
    ./ci/ci.sh device
fi
[ -d "$app" ] || die "no app at $app — build it, or pass --app"
codesign --verify --strict "$app" >/dev/null 2>&1 || die "$app is not validly signed"

# Claim the staging area: the workspace is single and shared, and a second run
# would replace the .app a first one is mid-install from. mkdir on an existing
# directory fails, atomically, which is all a lock has to do.
ssh "$target" "mkdir -p '$staging' && mkdir '$lock'" \
    || die "$target is busy: $lock exists. Either another run holds it, or one died holding it — clear it with: ssh $target rmdir '$lock'"

archive=$(mktemp -t flextunnel-ios-app).zip
remote_archive="flextunnel-ios-app-$$.zip"
cleanup() {
    rm -f "$archive"
    ssh "$target" "rm -f '$remote_archive'; rmdir '$lock'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

info 'packing the app'
# ditto rather than tar: it is what the release workflow uses on this bundle, and
# the flags drop resource forks, xattrs and quarantine — none of which a device
# install wants. The code signature lives inside the bundle (_CodeSignature and
# the Mach-O), so it survives the round trip; the codesign check on the far end
# is there to prove it did.
rm -f "$archive"
ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$app" "$archive"

info "copying to $target:$workspace"
scp -q "$archive" "$target:$remote_archive"
ssh "$target" "rm -rf '$workspace' && mkdir -p '$workspace' && ditto -x -k '$remote_archive' '$workspace'"

remote_app="$workspace/$(basename "$app")"
ssh "$target" "codesign --verify --strict '$remote_app'" \
    || die "the app failed signature verification on $target — the transfer damaged the bundle"

info "installing on $device_name"
ssh "$target" "xcrun devicectl device install app --device '$device_id' '$remote_app'"

if [ "$command" = install ]; then
    info 'installed (not launched)'
    exit 0
fi

info "launching $BUNDLE_ID"
launch_args="--device '$device_id' '$BUNDLE_ID'"
# A locked phone refuses the launch (CoreDeviceError 10002) while the install
# still stands, so the message below says as much. Note that a *successful*
# launch does not wake a sleeping screen either — `ci/device.sh status` is how
# you tell the two apart.
if [ "$console" = 1 ]; then
    # -t: --console keeps streaming the app's output until interrupted, which
    # needs a terminal on the far end.
    ssh -t "$target" "xcrun devicectl device process launch --console $launch_args"
else
    ssh "$target" "xcrun devicectl device process launch $launch_args" || {
        echo "[device] note: installed OK, but the launch failed — if the phone is locked, unlock it and tap the app." >&2
        exit 1
    }
fi
