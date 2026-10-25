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
#     The same server also routes `localhost`, a name the simulator reaches
#     directly too, so a tunneled load that fell back to a direct connection
#     would show;
#   - a second server with no routed set, which tunnels only the reserved
#     `flextunnel.internal` namespace. Its built-in loopback name
#     `localhost.flextunnel.internal` reaches the same fixture site;
#   - a third server whose set is a CIDR (TEST-NET-3), which turns off the
#     browser's hostname scoping (every page goes through the in-app proxy);
#   - a control endpoint on loopback (ci/e2e/control.py) that owns the routed
#     and CIDR servers, so a test can stop and restart one to take its tunnel
#     down, and read a server's log.
#
# The tests (Sources/FlextunnelUITests) get the server ids, a fresh client
# secret, the site URL and the control endpoint through
# TEST_RUNNER_FLEXTUNNEL_E2E_*; the app's
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
mkdir -p "$RUN/www" "$RUN/home" "$RUN/empty-home" "$RUN/cidr-home"
cp ci/e2e/fixtures/* "$RUN/www/"
uv run --no-project python -c '
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("hello.txt", "flextunnel e2e\n" * 200)
' "$RUN/www/sample.zip"

json_field() { uv run --no-project python -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }

"$flextunnel" generate-iroh-key -o "$RUN/server.key" >/dev/null
node_id=$("$flextunnel" show-iroh-id -s "$RUN/server.key" --json | json_field endpoint_id)
"$flextunnel" generate-iroh-key -o "$RUN/empty-server.key" >/dev/null
empty_node_id=$("$flextunnel" show-iroh-id -s "$RUN/empty-server.key" --json | json_field endpoint_id)
"$flextunnel" generate-iroh-key -o "$RUN/cidr-server.key" >/dev/null
cidr_node_id=$("$flextunnel" show-iroh-id -s "$RUN/cidr-server.key" --json | json_field endpoint_id)
client=$("$keys" generate-auth-key --json e2e)
secret=$(json_field private_key <<<"$client")
json_field authorized_key <<<"$client" >"$RUN/authorized_keys"

# Three free ports: one for the site, one left closed for the tests' direct
# connection that has to fail, one for the control endpoint.
read -r port closed_port control_port < <(uv run --no-project python -c '
import socket
socks = [socket.socket() for _ in range(3)]
for s in socks: s.bind(("127.0.0.1", 0))
print(*(s.getsockname()[1] for s in socks))')

cat >"$RUN/server.toml" <<EOF
secret_file = "$PWD/$RUN/server.key"
authorized_keys_file = "$PWD/$RUN/authorized_keys"
routed_domains = ["e2e.flextunnel.test", "*.e2e.flextunnel.test", "localhost"]

[host_aliases]
"e2e.flextunnel.test" = "127.0.0.1"
EOF

cat >"$RUN/empty-server.toml" <<EOF
secret_file = "$PWD/$RUN/empty-server.key"
authorized_keys_file = "$PWD/$RUN/authorized_keys"
EOF

cat >"$RUN/cidr-server.toml" <<EOF
secret_file = "$PWD/$RUN/cidr-server.key"
authorized_keys_file = "$PWD/$RUN/authorized_keys"
routed_cidrs = ["203.0.113.0/24"]
EOF

# The servers a test may stop, for the control endpoint to own. The CIDR server
# logs each stream's target, so a test can read off its log that an IP-address
# URL came through the tunnel.
uv run --no-project python -c '
import json, sys
flextunnel, run = sys.argv[1:]
print(json.dumps({
    name: {
        "argv": [flextunnel, "server", "start", "-c", f"{run}/{config}"],
        "home": f"{run}/{home}",
        "log": f"{run}/{log}",
        "env": env,
    }
    for name, config, home, log, env in [
        ("routed", "server.toml", "home", "server.log", {}),
        ("cidr", "cidr-server.toml", "cidr-home", "cidr-server.log",
         {"RUST_LOG": "info,flextunnel_core::proxy::server=debug"}),
    ]
}))' "$flextunnel" "$PWD/$RUN" >"$RUN/servers.json"

pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

uv run --no-project python -m http.server "$port" --bind 127.0.0.1 --directory "$RUN/www" \
    >"$RUN/site.log" 2>&1 &
pids+=($!)
# Each server gets its own HOME, so its lock and duplicate-id blocklist under
# ~/.config/flextunnel are scratch files, not the ones a real server here uses.
# The control endpoint does that for the servers it owns.
uv run --no-project python ci/e2e/control.py "$control_port" "$RUN/servers.json" \
    >"$RUN/control.log" 2>&1 &
pids+=($!)
HOME=$PWD/$RUN/empty-home "$flextunnel" server start -c "$RUN/empty-server.toml" >"$RUN/empty-server.log" 2>&1 &
pids+=($!)

sleep 3
logs=("$RUN/server.log" "$RUN/empty-server.log" "$RUN/cidr-server.log" "$RUN/control.log" "$RUN/site.log")
for pid in "${pids[@]}"; do
    kill -0 "$pid" 2>/dev/null || { tail -20 "${logs[@]}" >&2; die 'a server or the site exited at startup'; }
done
curl -fsS "http://127.0.0.1:$control_port/health" >/dev/null \
    || { tail -20 "${logs[@]}" >&2; die 'a controlled server exited at startup'; }
info "server $node_id ($server_src), site http://e2e.flextunnel.test:$port"
info "empty-set server $empty_node_id"
info "CIDR server $cidr_node_id, control http://127.0.0.1:$control_port"

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
TEST_RUNNER_FLEXTUNNEL_E2E_EMPTY_SERVER_NODE_ID=$empty_node_id \
TEST_RUNNER_FLEXTUNNEL_E2E_CIDR_SERVER_NODE_ID=$cidr_node_id \
TEST_RUNNER_FLEXTUNNEL_E2E_CONTROL=http://127.0.0.1:$control_port \
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
