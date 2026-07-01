#!/usr/bin/env bash
set -euo pipefail

APP_NAME="flextunnel"
PROJECT_NAME="Flextunnel"
SCHEME="FlextunnelApp"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/create-archive-ios.sh [TEAM_ID] [options]
  scripts/create-archive-ios.sh --team-id <TEAM_ID> [options]

Builds an iOS .xcarchive and exports it to a signed .ipa in one step.

Options:
  -t, --team-id TEAM_ID       Developer Team ID.
                              Defaults to DEVELOPMENT_TEAM from Developer.local.xcconfig.
  -a, --archive-path PATH     Output path for the iOS .xcarchive.
                              Defaults to ./build/${APP_NAME}-ios.xcarchive.
  -c, --configuration NAME    Build configuration. Defaults to Release.
  -o, --export-path PATH      Output directory for the exported .ipa.
                              Defaults to ./build/export.
  -m, --method METHOD         Export method. Defaults to debugging.
  --allow-provisioning-updates
                              Let xcodebuild create or update signing assets.
  -h, --help                  Show this help.

Environment overrides:
  TEAM_ID, ARCHIVE_PATH, CONFIGURATION, EXPORT_PATH, METHOD,
  ALLOW_PROVISIONING_UPDATES
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

TEAM_ID="${TEAM_ID:-}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/build/${APP_NAME}-ios.xcarchive}"
CONFIGURATION="${CONFIGURATION:-Release}"
EXPORT_PATH="${EXPORT_PATH:-$PROJECT_ROOT/build/export}"
METHOD="${METHOD:-debugging}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team-id)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TEAM_ID="$2"
      shift 2
      ;;
    -a|--archive-path)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    -c|--configuration)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      CONFIGURATION="$2"
      shift 2
      ;;
    -o|--export-path)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      EXPORT_PATH="$2"
      shift 2
      ;;
    -m|--method)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      METHOD="$2"
      shift 2
      ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
    *)
      if [[ -n "$TEAM_ID" ]]; then
        usage >&2
        die "unexpected argument: $1"
      fi
      TEAM_ID="$1"
      shift
      ;;
  esac
done

detect_project_team_id() {
  local xcconfig="$PROJECT_ROOT/Developer.local.xcconfig"
  [[ -f "$xcconfig" ]] || return 1

  /usr/bin/awk '
    /^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=/ {
      sub(/\/\/.*$/, "")
      sub(/.*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*/, "")
      gsub(/[[:space:]"]+$/, "")
      gsub(/^[[:space:]"]+/, "")
      if ($0 != "") {
        print $0
        found = 1
        exit 0
      }
    }
    END { if (!found) exit 1 }
  ' "$xcconfig"
}

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(detect_project_team_id || true)"
fi

[[ -n "$TEAM_ID" ]] || {
  usage >&2
  die "team ID is required: set DEVELOPMENT_TEAM in Developer.local.xcconfig (copy Developer.local.xcconfig.sample) or pass --team-id"
}

[[ "$ARCHIVE_PATH" == *.xcarchive ]] || die "--archive-path must end in .xcarchive"

[[ -e "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" ]] || \
  die "${PROJECT_NAME}.xcodeproj not found — run 'xcodegen generate' first"

/bin/mkdir -p "$(/usr/bin/dirname "$ARCHIVE_PATH")"

# Clear both outputs up front so a failure mid-flight cannot leave a stale
# .ipa from a previous run sitting next to a new (or missing) .xcarchive.
if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "Replacing existing archive: $ARCHIVE_PATH"
  /bin/rm -rf "$ARCHIVE_PATH"
fi

if [[ -e "$EXPORT_PATH" ]]; then
  echo "Replacing existing export directory: $EXPORT_PATH"
  /bin/rm -rf "$EXPORT_PATH"
fi

provisioning_args=()
if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  provisioning_args=(-allowProvisioningUpdates)
fi

echo "Creating iOS archive:"
printf '  archive:       %s\n' "$ARCHIVE_PATH"
printf '  configuration: %s\n' "$CONFIGURATION"
printf '  team:          %s\n' "$TEAM_ID"

# generic/platform=iOS + -sdk iphoneos selects the device arm64 slice of the
# vendored libflextunnel.xcframework (it is arm64-only — see CLAUDE.md).
xcodebuild archive \
  -project "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -sdk iphoneos \
  -archivePath "$ARCHIVE_PATH" \
  "${provisioning_args[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID"

/bin/mkdir -p "$EXPORT_PATH"

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-export.XXXXXX")"
cleanup() {
  /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

EXPORT_OPTIONS_PLIST="$TEMP_DIR/ExportOptions.plist"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :method string $METHOD" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :destination string export" "$EXPORT_OPTIONS_PLIST"

echo "Exporting archive:"
printf '  archive: %s\n' "$ARCHIVE_PATH"
printf '  export:  %s\n' "$EXPORT_PATH"
printf '  method:  %s\n' "$METHOD"
printf '  team:    %s\n' "$TEAM_ID"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
