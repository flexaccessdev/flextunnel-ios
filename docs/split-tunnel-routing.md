# Split-tunnel routing (the tunnel set)

The server pushes domain and CIDR rules during the handshake. For browser
proxy requests, matching targets go through the server and off-list targets
connect from the device. Server-direct port forwards always use the tunnel;
the server rejects their off-list targets.

Domain rules match hostnames; CIDRs match IP literals, including numeric IPs
sent in hostname form. A hostname is not reclassified by its resolved IP.
To route all target types, configure `*` for domains and both `0.0.0.0/0` and
`::/0` for IPs. An empty set still tunnels the reserved `flextunnel.internal`
namespace, including the server's loopback at `localhost.flextunnel.internal`.

## Rust routing and WebKit proxy scoping

The Rust SOCKS5 listener makes the tunnel-or-direct decision for every browser
request that reaches it. The server independently checks tunneled requests
against its routed set, except reserved names.

For hostname-only sets without `*`, the browser also sets
`ProxyConfiguration.matchDomains` through
`WKWebsiteDataStore.proxyConfigurations`. Hostnames outside those suffixes
bypass the SOCKS5 listener entirely. This keeps those requests independent of
proxy health.

`ProxyController.ForwardedRoutes.proxyMatchDomains` converts exact and wildcard
domain rules to bare suffixes and always includes `flextunnel.internal`.
The list must cover everything the core would tunnel; under-matching breaks
private hosts.
WebKit's suffix match can include more hosts than the Rust rule: for example,
an exact `example.com` rule also sends `www.example.com` to the proxy. The
core then applies its precise rule and connects an off-list host directly.
Such overmatched hosts still depend on the local proxy being available.

With `*` or any CIDR rule, hostname scoping is disabled and requests go through
the Rust proxy for classification. A CIDR cannot be expressed as hostname
suffixes. Sending everything to the proxy does not itself make every target
tunneled: domain and IP rules remain independent in the core. WebKit bypasses
proxying for loopback IPs and the device's own addresses, so use
`localhost.flextunnel.internal` to reach the server's loopback. Safari and other
apps never use the browser's proxy; they reach the tunnel only through
[port forwards](port-forwarding.md).

`ProxyConfiguration.loopbackSocks5` sets `allowFailover = false`. A request
assigned to an unavailable proxy fails rather than falling back directly.
Once inside the core, an on-list request waits for tunnel recovery or fails;
it never switches to a direct connection.

## Reconnects and status

The browser retains the last known match list across a session relaunch while
the core relearns its routes. A new unscoped policy is applied when reported.
Hosts outside the retained suffix list can keep browsing directly during that
gap. With scoping disabled, all proxied requests depend on the listener, even
when the core would ultimately connect them directly.

The SOCKS5 listener stays bound across ordinary QUIC reconnects. Suspension
recovery performs a full session relaunch, which briefly closes and rebinds
it. Existing tunneled TCP connections do not survive a dropped tunnel.

**Tunnel status** shows the pushed routes, aliases, DNS forwards and bridges.
**SOCKS listener** reports the local browser listener, separately from tunnel
connectivity. The UI's full-tunnel label recognizes `*` or a default-route
CIDR; consult the individual rules for which target types actually match.

Forwards use core-owned server-direct streams, with no SOCKS5 hop or WebKit
scoping. See [port forwarding](port-forwarding.md).

## Verifying the split

- With a hostname-only scoped set, stop the proxy or observe an outage. A
  fresh request to a host outside every proxy suffix should still load;
  `http://flextunnel.internal` should fail without a working tunnel. If
  everything fails, WebKit scoping is not active: check **Tunnel status** for a
  `*` or CIDR rule. Existing pooled connections and cached pages can obscure
  this check.
- SOCKS5 carries only TCP CONNECT, so QUIC/HTTP-3 cannot use the proxy. An
  off-list HTTP/3 site (for example `https://cloudflare-quic.com`) reporting
  HTTP/3 bypassed it.
- In the iOS Run scheme, set `RUST_LOG=warn,flextunnel_core=debug`. Requests
  reaching the Rust proxy log `Tunneling: …` or
  `Direct (off tunnel set): …`. Hosts bypassing it produce neither line.
- For server-side DNS, add a routed hostname that only resolves on the server
  and load it from the app. Server debug logs (`RUST_LOG=flextunnel=debug`)
  show `Stream target: Domain(…)` after aliasing and before dialing.

`ProxyConfigurationTests` covers scoping and disabled failover.
`ci/e2e.sh` exercises browser routing with hostname, empty and CIDR sets against
real servers; see [local CI](local-ci.md#end-to-end-ui-tests).
