# Split-tunnel routing (destinations and their routes)

The client holds **destinations**, each a name (one DNS label, unique among
the destinations) for one flextunnel server.
`<name>.localhost.flextunnel.internal` means that server's loopback
(`office.localhost.flextunnel.internal:8080` is port 8080 on the server
itself), and the bare name is no host at all: every name the client handles by
itself stays under `flextunnel.internal`, so none can shadow a real host. Each
destination may list further domains and IP ranges to send through its server.
Those routes are this app's
configuration, entered on the setup screen: nothing about routing is learned
from a server.

For browser proxy requests, a target a destination routes goes through that
destination's server and everything else connects from the device.
Server-direct port forwards always go through a destination; one whose host no
destination routes can't be switched on.

Precedence, most specific first: `flextunnel.internal` (the client's own
status page); a destination's `<name>.localhost.flextunnel.internal`; the rest
of the reserved `*.flextunnel.internal` namespace (answered by the client
itself with a 404); then the rule
that matches most specifically across all destinations — an exact domain, the
longest `*.suffix`, `*`, and for IP targets the longest network prefix. The
same rule on two destinations is rejected; nested rules are fine.

Domain rules match hostnames; IP ranges match IP literals, including numeric
IPs sent in hostname form. A hostname is not reclassified by its resolved IP.
To route every target type through one destination, give it `*` for domains
and both `0.0.0.0/0` and `::/0` for IPs.

Each server still enforces **its own** routed set and host aliases on what
arrives: a route here only chooses the server, and the server refuses a target
off its list. A destination's loopback name is the exception — the server's loopback is reachable whatever that server routes.

Nothing keeps the two lists in step. A destination's editor can copy the
server's: **Fetch from Server** asks the server named by the node id what it
routes — one connection made for the question, with this device's key and
relays, so the server must authorize the key already — and replaces the two
rule fields with its answer. It works before the destination is saved and with
no session running. Review the result and save; a later change on the server
is not followed.

## Connecting on demand

Starting a session connects nothing. A destination's server is connected when
something is first sent to it — a page, a forwarded connection, its status
page — and disconnected after five minutes with no open stream. A request that
arrives while its destination is connecting is held for up to 45 seconds, then
fails; it never switches to a direct connection. After a failed attempt the
destination rests until it is next used, which tries again with a fresh
endpoint.

## Rust routing and WebKit proxy scoping

The Rust SOCKS5 listener makes the tunnel-or-direct decision for every browser
request that reaches it, and picks the destination.

When the routes are hostnames only, without `*`, the browser also sets
`ProxyConfiguration.matchDomains` through
`WKWebsiteDataStore.proxyConfigurations`. Hostnames outside those suffixes
bypass the SOCKS5 listener entirely. This keeps those requests independent of
proxy health.

`RouteTable.proxyMatchDomains` converts exact and wildcard domain rules to bare
suffixes and always includes `flextunnel.internal`, which covers every
destination's loopback name. The list must cover everything the core would not send
directly; under-matching breaks private hosts.
WebKit's suffix match can include more hosts than the Rust rule: for example,
an exact `example.com` rule also sends `www.example.com` to the proxy. The
core then applies its precise rule and connects an unrouted host directly.
Such overmatched hosts still depend on the local proxy being available.

With `*` or any IP range among the routes, hostname scoping is disabled and
requests go through the Rust proxy for classification. An IP range cannot be
expressed as hostname suffixes. Sending everything to the proxy does not itself
make every target tunneled: domain and IP rules remain independent in the core.
WebKit bypasses proxying for loopback IPs and the device's own addresses, so
use a destination's `<name>.localhost.flextunnel.internal` to reach its
server's loopback. Safari and other
apps never use the browser's proxy; they reach a server only through
[port forwards](port-forwarding.md).

`ProxyConfiguration.loopbackSocks5` sets `allowFailover = false`. A request
assigned to an unavailable proxy fails rather than falling back directly.

The routes are fixed for a session — they are edited on the setup screen, which
a running session covers — so the browser's scoping is set once, when the
session starts, and is known before any server has been contacted.

## Status

**Tunnel status** in the browser, and the port-forwarding screen, list every
destination with its state (idle, connecting, connected, retrying, refused, or
idle after a failed attempt), its routes, and — while it is connected — a
**Connection Path** readout. The header and the browser's tunnel button
summarize them: *Ready* (running, nothing connected yet), *Connected*,
*Connecting*, *Unreachable* (a destination can't be reached) or *Stopped*.
**Restart Session** replaces the session when a destination stays unreachable
or the session ended.

**SOCKS listener** reports the local browser listener, separately from any
server's connection. It stays bound while destinations come and go; suspension
recovery performs a full session relaunch, which briefly closes and rebinds
it. Existing tunneled TCP connections do not survive a dropped server
connection.

Two status pages are served through the in-app proxy:

- `http://flextunnel.internal/` — the client's own: its destinations and their
  state. Reading it connects nothing.
- `http://flextunnel.internal/servers/<name>/` — that destination server's
  page: its routed set and host aliases. Fetching it connects the
  destination.

Both are a tap away under **Tunnel status** (**Client Status Page**, and
**Server Status Page** on each destination). Other `*.flextunnel.internal`
names are reserved and answer 404.

Forwards use core-owned server-direct streams, with no SOCKS5 hop or WebKit
scoping. See [port forwarding](port-forwarding.md).

## Verifying the split

- With hostname-only routes, the direct evidence is what happens when the
  local SOCKS listener alone is gone, with the browser still open and the
  device online — **Tunnel status** then reads *Stopped* with **SOCKS
  listener: Not listening** (the session ended behind the browser; nothing in
  the app stops the listener on its own). In that state make two fresh
  requests: a page you know is reachable on a host outside every proxy suffix
  should still load, and `http://flextunnel.internal`, which only the listener
  answers, should fail. If both fail, WebKit scoping is not active: check
  **Tunnel status** for a `*` or IP-range route. Existing pooled connections
  and cached pages can obscure this check.
  A server being unreachable is not this test, and neither is losing the
  Internet: with the listener up the proxy still sends unrouted hosts out
  directly, so they load whether or not WebKit went around it, and offline
  nothing loads either way. The two checks below work at any time.
- SOCKS5 carries only TCP CONNECT, so QUIC/HTTP-3 cannot use the proxy. An
  unrouted HTTP/3 site (for example `https://cloudflare-quic.com`) reporting
  HTTP/3 bypassed it.
- In the iOS Run scheme, set `RUST_LOG=warn,flextunnel_core=debug`. Requests
  reaching the Rust proxy log `Tunneling via <destination>: …` or
  `Direct (no destination routes it): …`. Hosts bypassing it produce neither
  line.
- For server-side DNS, load a hostname that only resolves on the server. It
  has to be in two places: on a destination's routes in the app, which only
  chooses the server, and in that server's own routed set
  (`routed_domains`), which is what lets the server dial it — adding it in the
  app does not add it there. Add it to both first, or use a hostname the
  server already allows. Server debug logs (`RUST_LOG=flextunnel=debug`) then
  show `Stream target: Domain(…)` after aliasing and before dialing; a name
  the server doesn't allow is refused before any lookup.

`RouteTableTests` covers the routing mirror and the scoping list;
`ProxyConfigurationTests` covers scoping and disabled failover.
`ci/e2e.sh` exercises browser routing with hostname and IP-range destinations
against real servers; see [local CI](local-ci.md#end-to-end-ui-tests).
