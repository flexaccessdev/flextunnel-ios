#!/usr/bin/env bash
set -euo pipefail

# Lists the CoreDevice-paired iOS devices this Mac can build to, resolving the
# two identifiers that matter downstream:
#   - identifier : the CoreDevice UUID `xcrun devicectl device …` wants
#                  (install / launch).
#   - udid       : the hardware UDID `xcodebuild -destination 'platform=iOS,id=…'`
#                  wants. (run-device-ios.sh builds generic and installs by
#                  identifier, so it only needs the former — the udid is emitted
#                  for anyone driving xcodebuild directly.)
#
# Default output is a human table. --tsv emits a stable machine format consumed
# by run-device-ios.sh; --json passes devicectl's raw JSON straight through.

usage() {
  cat <<'USAGE'
Usage:
  scripts/list-devices-ios.sh [options]

Lists paired iOS devices (identifier, udid, name, model, OS, state).

Options:
  --tsv           Machine-readable TSV: identifier<TAB>udid<TAB>platform<TAB>pairingState<TAB>os<TAB>model<TAB>name
  --identifiers   Print only CoreDevice identifiers, one per line.
  --json          Print devicectl's raw JSON unchanged.
  -h, --help      Show this help.

Requires: jq (parsing), python3 (table formatting).
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

MODE="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tsv)         MODE="tsv"; shift ;;
    --identifiers) MODE="identifiers"; shift ;;
    --json)        MODE="json"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage >&2; die "unknown option: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

JSON_FILE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/flextunnel-devices.XXXXXX")"
trap '/bin/rm -f "$JSON_FILE"' EXIT

# devicectl writes JSON to the file and human chatter to stderr; hide the latter.
xcrun devicectl list devices --json-output "$JSON_FILE" >/dev/null 2>&1 \
  || die "xcrun devicectl failed — is Xcode installed and a device paired?"

if [[ "$MODE" == "json" ]]; then
  /bin/cat "$JSON_FILE"
  exit 0
fi

# One TSV row per device. Order is fixed so callers can index it positionally.
tsv() {
  jq -r '
    .result.devices[]
    | [ .identifier,
        (.hardwareProperties.udid // ""),
        (.hardwareProperties.platform // ""),
        (.connectionProperties.pairingState // ""),
        (.deviceProperties.osVersionNumber // ""),
        (.hardwareProperties.marketingName // ""),
        (.deviceProperties.name // "") ]
    | @tsv
  ' "$JSON_FILE"
}

case "$MODE" in
  tsv)
    tsv
    ;;
  identifiers)
    tsv | /usr/bin/cut -f1
    ;;
  table)
    rows="$(tsv)"
    if [[ -z "$rows" ]]; then
      echo "No paired iOS devices found."
      exit 0
    fi
    # python3 aligns the columns; feed it the same fixed-order TSV.
    printf '%s\n' "$rows" | /usr/bin/env python3 -c '
import sys
cols = ["IDENTIFIER", "UDID", "PLATFORM", "PAIRING", "OS", "MODEL", "NAME"]
rows = [line.split("\t") for line in sys.stdin.read().splitlines() if line]
data = [cols] + rows
widths = [max(len(r[i]) for r in data) for i in range(len(cols))]
for r in data:
    print("  ".join(r[i].ljust(widths[i]) for i in range(len(cols))).rstrip())
'
    ;;
esac
