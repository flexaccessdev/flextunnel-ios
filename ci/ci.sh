#!/usr/bin/env bash
# Run this repo's CI checks natively on this Mac.
#
#   ci/ci.sh                      # the default jobs (see below)
#   ci/ci.sh simulator            # only these
#   ci/ci.sh --list               # what jobs exist
#
# Everything here runs on the machine you type it on and needs no physical
# device — which is the point, because this checkout usually lives in a macOS
# VM. A guest can compile, sign, and run the Simulator (the Simulator is not a
# virtual machine; it is a userspace runtime on this kernel), but it can never
# pair with an iPhone. The half that needs the hardware is scripts/run-device-ios-host.sh, which
# hands the *signed build produced here* to the Mac the phone is attached to.
# docs/local-ci.md draws the line; docs/deploy-from-a-vm.md explains why it is
# where it is.
#
# Jobs:
#   simulator  build for the Simulator (arm64) — the README's verify command
#   smoke      boot a simulator, install the build, launch it, check it stays up
#   unsigned   Release device archive with signing off, plus the bundle
#              assertions from .github/workflows/unsigned-ios.yml
#   device     signed device-slice .app — the artifact scripts/run-device-ios-host.sh installs
#   ffi        rebuild libflextunnel from the sibling ../flextunnel working tree
#              and link against it (.github/workflows/verify-flextunnel-commit.yml)
#
# `ffi` is not in the default set: it compiles the Rust core for iOS, which is
# minutes rather than seconds, and it is only meaningful when you are changing
# ../flextunnel. Ask for it by name.
#
# When a job and the workflow it mirrors disagree, the workflow is right and
# this script is stale. Keep them in step by hand; nothing enforces it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ALL_JOBS=(simulator smoke unsigned device ffi)
DEFAULT_JOBS=(simulator smoke unsigned device)

# A named simulator rather than a UDID: whichever iOS runtime is installed gets
# used, the same way the README's destination leaves OS= off on purpose.
SIM_NAME=${FLEXTUNNEL_CI_SIM:-iPhone 17}
BUNDLE_ID=dev.flexaccess.flextunnel
DERIVED_SIM=build/ci/DerivedData-sim
DERIVED_DEVICE=build/ci/DerivedData-device
DERIVED_FFI=build/ci/DerivedData-ffi
ARCHIVE=build/ci/flextunnel-ios-unsigned.xcarchive

usage() { echo "usage: $0 [--list] [${ALL_JOBS[*]}]" >&2; exit 2; }

jobs=()
while [ $# -gt 0 ]; do
    case $1 in
        --list)
            printf '%s\n' "available: ${ALL_JOBS[*]}" "default:   ${DEFAULT_JOBS[*]}"
            exit 0 ;;
        -h|--help) usage ;;
        *)
            for known in "${ALL_JOBS[@]}"; do
                [ "$1" = "$known" ] && { jobs+=("$1"); shift; continue 2; }
            done
            echo "unknown job: $1" >&2; usage ;;
    esac
done
if [ ${#jobs[@]} -eq 0 ]; then jobs=("${DEFAULT_JOBS[@]}"); fi

info() { echo "[ci] $*"; }
step() { echo; echo "=== $* ==="; }
die() { echo "[ci] error: $*" >&2; exit 1; }

command -v xcodebuild >/dev/null || die 'xcodebuild not found — install Xcode and run xcode-select'
command -v xcodegen >/dev/null || die 'xcodegen not found (brew install xcodegen)'

# The .xcodeproj is generated and gitignored, so every job below starts from a
# project regenerated out of project.yml. Which xcframework it points at — the
# pinned release or a local Rust build — is baked in here, at generation time,
# not at build time; that is why `ffi` regenerates rather than just rebuilding.
generate() {
    local mode=$1  # pinned | local
    if [ "$mode" = local ]; then
        [ -e Packages/Flextunnel/local/libflextunnel.xcframework ] \
            || die 'local xcframework not found — run (cd ../flextunnel && ./build-ios.sh release)'
        FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodegen generate
    else
        env -u FLEXTUNNEL_LOCAL_XCFRAMEWORK xcodegen generate
    fi
}

job_simulator() {
    step 'simulator build'
    generate pinned
    # ARCHS=arm64 is not optional: libflextunnel.xcframework is arm64-only, and a
    # generic Simulator destination without it picks x86_64 and fails to link.
    xcodebuild build \
        -project Flextunnel.xcodeproj \
        -scheme FlextunnelApp \
        -configuration Debug \
        -destination "platform=iOS Simulator,name=$SIM_NAME" \
        -derivedDataPath "$DERIVED_SIM" \
        ARCHS=arm64 \
        CODE_SIGNING_ALLOWED=NO
}

# The only check here that proves the Rust core actually loads and the app gets
# past launch — everything else stops at compile and link.
job_smoke() {
    step "smoke run on the $SIM_NAME simulator"
    local app=$DERIVED_SIM/Build/Products/Debug-iphonesimulator/Flextunnel.app
    [ -d "$app" ] || die "no simulator build at $app — run the 'simulator' job first"

    # Unlike the rest of this script, this one changes machine state: it leaves a
    # simulator booted with the app installed. Booting an already-booted device
    # is an error, hence the || true, and bootstatus waits out the first boot of
    # a fresh runtime.
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null
    xcrun simctl install "$SIM_NAME" "$app"
    local pid
    pid=$(xcrun simctl launch "$SIM_NAME" "$BUNDLE_ID" | sed 's/.*: //')
    info "launched $BUNDLE_ID as pid $pid"

    # A crash on launch — a missing symbol in the static lib, a failed FFI init —
    # shows up as a process that is gone a moment later, which a bare `launch`
    # exit code will not tell you.
    sleep 5
    # Captured, not piped into grep -q: -q closes the pipe on the first match,
    # simctl dies of SIGPIPE, and under `set -o pipefail` that turns a live app
    # into a reported crash.
    local running
    running=$(xcrun simctl spawn "$SIM_NAME" launchctl list 2>/dev/null || true)
    case $running in
        *"$BUNDLE_ID"*) ;;
        *) die "$BUNDLE_ID did not survive 5s on the simulator — check the device's CrashReporter logs under ~/Library/Developer/CoreSimulator/Devices" ;;
    esac
    info 'still running after 5s'
    xcrun simctl terminate "$SIM_NAME" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

# .github/workflows/unsigned-ios.yml, minus the packaging: the IPA, the archive
# zip, the checksums and the prerelease are release plumbing, and none of them
# can fail in a way the archive and the assertions below do not already catch.
job_unsigned() {
    step 'unsigned release archive'
    generate pinned
    rm -rf "$ARCHIVE"
    xcodebuild archive \
        -project Flextunnel.xcodeproj \
        -scheme FlextunnelApp \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -archivePath "$ARCHIVE" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= \
        DEVELOPMENT_TEAM=

    step 'unsigned archive assertions'
    local app=$ARCHIVE/Products/Applications/Flextunnel.app
    local widget=$app/PlugIns/FlextunnelWidgets.appex
    [ -d "$app" ] || die "archived app not found at $app"
    [ -d "$widget" ] || die "widget extension not found at $widget"

    while IFS= read -r bundle; do
        ! codesign --display "$bundle" >/dev/null 2>&1 \
            || die "$bundle unexpectedly has a code signature"
    done < <(find "$app" -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' \) -print)

    ! find "$app" -name embedded.mobileprovision -print -quit | grep -q . \
        || die 'the archived app unexpectedly embeds a profile'

    # These two are what let the app hold a forwarding session alive in the
    # background; a dropped Info.plist key compiles and links and then quietly
    # breaks it on device only. See docs/background-keep-alive.md.
    [ "$(plutil -extract UIBackgroundModes.0 raw -o - "$app/Info.plist")" = location ] \
        || die 'the archived app lost its background location mode'
    [ -n "$(plutil -extract NSLocationWhenInUseUsageDescription raw -o - "$app/Info.plist")" ] \
        || die 'the archived app lost its location usage description'
    [ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$widget/Info.plist")" \
        = com.apple.widgetkit-extension ] \
        || die 'the embedded extension is not a WidgetKit extension'
    info 'archive assertions passed'
}

# The signed device slice. `generic/platform=iOS` builds the device arm64 slice
# without the hardware UDID, which is exactly what makes a device-less build
# machine work — the phone's UDID only has to be in the provisioning profile,
# not on this machine's USB bus.
job_device() {
    step 'signed device build'
    local team=${FLEXTUNNEL_CI_TEAM:-}
    if [ -z "$team" ]; then
        team=$(awk -F= '/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
            sub(/\/\/.*$/, "", $2); gsub(/[[:space:]"]/, "", $2); if ($2 != "") { print $2; exit } }' \
            Developer.local.xcconfig 2>/dev/null || true)
    fi
    [ -n "$team" ] || die 'no DEVELOPMENT_TEAM — copy Developer.local.xcconfig.sample to Developer.local.xcconfig and fill it in'
    info "team $team"
    generate pinned
    xcodebuild build \
        -project Flextunnel.xcodeproj \
        -scheme FlextunnelApp \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -derivedDataPath "$DERIVED_DEVICE" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$team"

    local app=$DERIVED_DEVICE/Build/Products/Debug-iphoneos/Flextunnel.app
    [ -d "$app" ] || die "build did not produce an app at $app"
    codesign --verify --strict "$app" || die "$app failed signature verification"
    # Captured whole and parsed after, for the same reason as the smoke check:
    # a `| head -1` closes the pipe early and SIGPIPEs codesign under pipefail.
    local details
    # --verbose=2: the default -dv does not print the Authority chain at all.
    details=$(codesign -dv --verbose=2 "$app" 2>&1)
    info "signed: $(awk -F= '/^Authority=/ { print $2; exit }' <<<"$details") (team $(awk -F= '/^TeamIdentifier=/ { print $2; exit }' <<<"$details"))"
    info "$app"
}

# .github/workflows/verify-flextunnel-commit.yml, against the sibling working
# tree instead of a pinned commit — same reason to exist: prove a not-yet-released
# Rust change still compiles and links into this app before cutting a release.
job_ffi() {
    step 'build libflextunnel from ../flextunnel'
    [ -d ../flextunnel ] || die 'no sibling ../flextunnel checkout'
    ( cd ../flextunnel && ./build-ios.sh release )

    step 'build against the local xcframework'
    generate local
    local status=0
    FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodebuild build \
        -project Flextunnel.xcodeproj \
        -scheme FlextunnelApp \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -sdk iphoneos \
        -derivedDataPath "$DERIVED_FFI" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        DEVELOPMENT_TEAM= \
        COMPILER_INDEX_STORE_ENABLE=NO || status=$?

    # Leave the project pointing at the pinned release again — on the failing path
    # especially, since that is the one you go back to Xcode after: a generated
    # project wired to a local build is a trap for the next plain `xcodebuild`
    # here. The build's status is re-raised after the cleanup, not swallowed.
    generate pinned
    return "$status"
}

info "jobs: ${jobs[*]}"
for job in "${jobs[@]}"; do
    "job_$job"
done

echo
info 'all jobs passed'
