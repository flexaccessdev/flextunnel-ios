#!/usr/bin/env bash
# End-to-end UI tests on the Simulator, against a real flextunnel server running
# on this Mac.
#
#   ci/e2e.sh                                   # every test
#   ci/e2e.sh -only-testing:FlextunnelUITests/BrowserE2ETests/testDisconnectFromTunnelStatusReturnsToSetup
#
# Extra arguments go to `xcodebuild test` as they are; without any, only the
# UI tests run (the unit tests are `ci/ci.sh unit`).
#
# What it stands up, all on loopback and all torn down on exit:
#   - the flextunnel server, built at the tag the app's pinned libflextunnel
#     comes from (Packages/Flextunnel/Package.swift), since client and server
#     speak one protocol version and keep no backward compatibility. With
#     FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 the app links the sibling's local build,
#     so the server is built from the sibling working tree instead;
#   - a fixture site (ci/e2e/fixtures) behind the server's host alias
#     `e2e.flextunnel.test`. Only the server resolves that name, so a page that
#     loads came through the tunnel.
#
# The tests (Sources/FlextunnelUITests) get the server id, a fresh client
# secret and the site URL through TEST_RUNNER_FLEXTUNNEL_E2E_*; the app's
# Debug-only launch hook (E2ELaunchConfig.swift) fills the setup screen from
# them. Needs a Rust toolchain (the first run builds the CLIs into build/e2e),
# uv, and internet access: the simulator finds the server through iroh's n0
# discovery and default relays, as a real client would.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SIM_NAME=${FLEXTUNNEL_CI_SIM:-iPhone 17}
BUNDLE_ID=dev.flexaccess.flextunnel
SIBLING=../flextunnel
WORK=build/e2e
RUN=$WORK/run
DERIVED=build/ci/DerivedData-e2e
TOOLS_ROOT=$PWD/$WORK/tools

info() { echo "[e2e] $*"; }
die() { echo "[e2e] error: $*" >&2; exit 1; }

for tool in xcodebuild xcodegen cargo uv; do
    command -v "$tool" >/dev/null || die "$tool not found"
done

# --- tools -------------------------------------------------------------------

# Builds the flextunnel and flexaccess-keys CLIs into build/e2e/tools, once per
# tag. `cargo install --git file://` clones from the sibling's history into
# cargo's cache, so the sibling checkout itself is never touched.
if [ -n "${FLEXTUNNEL_LOCAL_XCFRAMEWORK:-}" ]; then
    server_src=local
    info "building flextunnel from the $SIBLING working tree"
    CARGO_TARGET_DIR=$PWD/$WORK/cargo-target cargo install --locked --quiet \
        --path "$SIBLING/crates/flextunnel-cli" --root "$TOOLS_ROOT" --force
    flextunnel=$TOOLS_ROOT/bin/flextunnel
    keys_tag=$(sed -n 's/^flexaccess-keys = .*tag = "\([^"]*\)".*/\1/p' "$SIBLING/Cargo.toml")
else
    tag=$(sed -n 's#.*/releases/download/\(v[^/]*\)/.*#\1#p' Packages/Flextunnel/Package.swift)
    [ -n "$tag" ] || die 'no pinned release tag in Packages/Flextunnel/Package.swift'
    server_src=$tag
    flextunnel=$TOOLS_ROOT/flextunnel-$tag/bin/flextunnel
    if [ ! -x "$flextunnel" ]; then
        info "building flextunnel $tag"
        git -C "$SIBLING" rev-parse -q --verify "refs/tags/$tag" >/dev/null \
            || die "$SIBLING has no tag $tag — fetch its tags"
        cargo install --locked --quiet --git "file://$(cd "$SIBLING" && pwd)" --tag "$tag" \
            flextunnel-cli --root "$TOOLS_ROOT/flextunnel-$tag"
    fi
    keys_tag=$(git -C "$SIBLING" show "$tag:Cargo.toml" \
        | sed -n 's/^flexaccess-keys = .*tag = "\([^"]*\)".*/\1/p') \
        || die "could not read Cargo.toml at $tag in $SIBLING"
fi
[ -n "$keys_tag" ] || die 'could not find the flexaccess-keys tag in the sibling Cargo.toml'
keys=$TOOLS_ROOT/flexaccess-keys-$keys_tag/bin/flexaccess-keys
if [ ! -x "$keys" ]; then
    info "building flexaccess-keys $keys_tag"
    cargo install --locked --quiet --git https://github.com/flexaccessdev/flexaccess-keys \
        --tag "$keys_tag" --features cli flexaccess-keys --root "$TOOLS_ROOT/flexaccess-keys-$keys_tag"
fi

# --- server and site ---------------------------------------------------------

rm -rf "$RUN"
mkdir -p "$RUN/www" "$RUN/home"
cp ci/e2e/fixtures/* "$RUN/www/"
uv run --no-project python -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("hello.txt", "flextunnel e2e\n" * 200)
' "$RUN/www/sample.zip"

json_field() { uv run --no-project python -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

"$flextunnel" generate-iroh-key -o "$RUN/server.key" >/dev/null
node_id=$("$flextunnel" show-iroh-id -s "$RUN/server.key" --json | json_field endpoint_id)
client=$("$keys" generate-auth-key --json e2e)
secret=$(json_field private_key <<<"$client")
json_field authorized_key <<<"$client" >"$RUN/authorized_keys"

# Two free ports: one for the site, one left closed for the tests' direct
# connection that has to fail.
read -r port closed_port < <(uv run --no-project python -c '
import socket
socks = [socket.socket() for _ in range(2)]
for s in socks: s.bind(("127.0.0.1", 0))
print(*(s.getsockname()[1] for s in socks))')

cat >"$RUN/server.toml" <<EOF
secret_file = "$PWD/$RUN/server.key"
authorized_keys_file = "$PWD/$RUN/authorized_keys"
routed_domains = ["e2e.flextunnel.test", "*.e2e.flextunnel.test"]

[host_aliases]
"e2e.flextunnel.test" = "127.0.0.1"
EOF

pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

uv run --no-project python -m http.server "$port" --bind 127.0.0.1 --directory "$RUN/www" \
    >"$RUN/site.log" 2>&1 &
pids+=($!)
# Its own HOME, so the server's lock and duplicate-id blocklist under
# ~/.config/flextunnel are scratch files, not the ones a real server here uses.
HOME=$PWD/$RUN/home "$flextunnel" server start -c "$RUN/server.toml" >"$RUN/server.log" 2>&1 &
pids+=($!)

sleep 3
for pid in "${pids[@]}"; do
    kill -0 "$pid" 2>/dev/null || { tail -20 "$RUN/server.log" "$RUN/site.log" >&2; die 'server or site exited at startup'; }
done
info "server $node_id ($server_src), site http://e2e.flextunnel.test:$port"

# --- tests -------------------------------------------------------------------

if [ -n "${FLEXTUNNEL_LOCAL_XCFRAMEWORK:-}" ]; then
    FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodegen generate --quiet
else
    env -u FLEXTUNNEL_LOCAL_XCFRAMEWORK xcodegen generate --quiet
fi

xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_NAME" -b >/dev/null
# A clean install: no profiles, history or bookmarks from an earlier run.
xcrun simctl uninstall "$SIM_NAME" "$BUNDLE_ID" 2>/dev/null || true

rm -rf "$RUN/results.xcresult"
[ $# -gt 0 ] || set -- -only-testing:FlextunnelUITests
TEST_RUNNER_FLEXTUNNEL_E2E_SERVER_NODE_ID=$node_id \
TEST_RUNNER_FLEXTUNNEL_E2E_AUTH_SECRET=$secret \
TEST_RUNNER_FLEXTUNNEL_E2E_SITE=http://e2e.flextunnel.test:$port \
TEST_RUNNER_FLEXTUNNEL_E2E_CLOSED_PORT=$closed_port \
xcodebuild test \
    -project Flextunnel.xcodeproj \
    -scheme FlextunnelApp \
    -configuration Debug \
    -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$RUN/results.xcresult" \
    ARCHS=arm64 \
    "$@"
