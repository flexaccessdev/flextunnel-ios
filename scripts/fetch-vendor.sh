#!/usr/bin/env bash
#
# Populate ./vendor with the flextunnel Rust artifacts the Xcode project links:
# libflextunnel.xcframework (device + Simulator arm64 slices, headers embedded)
# and a top-level flextunnel.h for the bridging header.
#
# Two sources:
#   release (default)  Download the pinned GitHub release asset
#                      libflextunnel-ios.xcframework.zip and extract it into
#                      ./vendor. Pinned to a tag for reproducible builds.
#   local  (--local)   Symlink ./vendor entries to the sibling repo's locally
#                      built ../flextunnel/dist/ios. Iterate on the Rust FFI
#                      (run ./build-ios.sh in the sibling) without cutting a
#                      release — each rebuild is picked up with no re-fetch.
#
# Usage:
#   scripts/fetch-vendor.sh                 # release, pinned tag (default)
#   scripts/fetch-vendor.sh --tag v0.0.11   # release, a different tag
#   scripts/fetch-vendor.sh --url <URL>     # release, an explicit asset URL
#   scripts/fetch-vendor.sh --local         # symlink the sibling's dist/ios
#
# Env overrides:
#   FLEXTUNNEL_VENDOR_SOURCE  release|local (default release)
#   FLEXTUNNEL_IOS_TAG        release tag (default below)
#   FLEXTUNNEL_IOS_ASSET_URL  full asset URL (overrides tag)
#   FLEXTUNNEL_SIBLING_DIR    path to the sibling repo (default ../flextunnel)
set -euo pipefail

REPO="andrewtheguy/flextunnel"
DEFAULT_TAG="v0.0.10"
ASSET="libflextunnel-ios.xcframework.zip"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR="$ROOT/vendor"

SOURCE="${FLEXTUNNEL_VENDOR_SOURCE:-release}"
TAG="${FLEXTUNNEL_IOS_TAG:-$DEFAULT_TAG}"
ASSET_URL="${FLEXTUNNEL_IOS_ASSET_URL:-}"
SIBLING_DIR="${FLEXTUNNEL_SIBLING_DIR:-$ROOT/../flextunnel}"

die() { echo "error: $*" >&2; exit 1; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--local)   SOURCE="local"; shift ;;
    --release)    SOURCE="release"; shift ;;
    -t|--tag)     [[ $# -ge 2 ]] || die "$1 requires a value"; TAG="$2"; shift 2 ;;
    -u|--url)     [[ $# -ge 2 ]] || die "$1 requires a value"; ASSET_URL="$2"; shift 2 ;;
    -s|--sibling) [[ $# -ge 2 ]] || die "$1 requires a value"; SIBLING_DIR="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

# Clear whatever is there (real files or symlinks from a previous mode) so
# switching between release and local is clean and never mixes the two.
clean_vendor() {
  rm -rf "$VENDOR/libflextunnel.xcframework" "$VENDOR/flextunnel.h" "$VENDOR/libflextunnel.a"
  mkdir -p "$VENDOR"
}

case "$SOURCE" in
  local)
    SIBLING_DIR="$(cd "$SIBLING_DIR" 2>/dev/null && pwd)" || die "sibling repo not found: $SIBLING_DIR"
    DIST="$SIBLING_DIR/dist/ios"
    [[ -d "$DIST/libflextunnel.xcframework" ]] || \
      die "no local build at $DIST — run './build-ios.sh release' in $SIBLING_DIR first"
    [[ -f "$DIST/flextunnel.h" ]] || die "missing $DIST/flextunnel.h — rebuild the sibling"
    clean_vendor
    ln -s "$DIST/libflextunnel.xcframework" "$VENDOR/libflextunnel.xcframework"
    ln -s "$DIST/flextunnel.h" "$VENDOR/flextunnel.h"
    echo "Linked ./vendor -> $DIST (local sibling build)"
    ;;
  release)
    [[ -n "$ASSET_URL" ]] || \
      ASSET_URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    echo "Downloading $ASSET_URL ..."
    curl -fL --retry 3 -o "$TMP/$ASSET" "$ASSET_URL" || die "download failed: $ASSET_URL"
    unzip -q "$TMP/$ASSET" -d "$TMP/extract" || die "could not unzip $ASSET"
    [[ -d "$TMP/extract/libflextunnel.xcframework" ]] || \
      die "$ASSET did not contain libflextunnel.xcframework"
    [[ -f "$TMP/extract/flextunnel.h" ]] || \
      die "$ASSET did not contain flextunnel.h"
    clean_vendor
    cp -R "$TMP/extract/libflextunnel.xcframework" "$VENDOR/"
    cp "$TMP/extract/flextunnel.h" "$VENDOR/"
    echo "Extracted $ASSET ($TAG) -> ./vendor"
    ;;
  *) die "unknown source '$SOURCE' (use release|local)" ;;
esac

echo "vendor/ now contains:"
ls -la "$VENDOR"
