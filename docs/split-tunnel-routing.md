# Split-tunnel routing (the tunnel set)

The server defines a **tunnel set** — the domains/CIDRs it will route — and
pushes it to the client during the handshake. **On-list** destinations are
tunneled through the QUIC connection (resolved and connected server-side);
everything **off-list** is direct-connected from the device. This split-tunnel
behavior is the default; a server whose set matches everything
(`*` / `0.0.0.0/0`) routes all traffic.

## Two layers make the same decision

The split is enforced in two places, and understanding why takes both:

1. **The Rust core (authority).** The on-device SOCKS5 proxy decides
   per-connection from the pushed tunnel set: on-list targets go through the
   tunnel, off-list targets it dials directly itself. This is the ground truth —
   the server also enforces the same set as a **whitelist** (defense in depth),
   rejecting any tunnel request for an off-list target. Anything that reaches
   the proxy gets this decision regardless of what any client did upstream.

2. **WebKit `matchDomains` (browser optimization).** The browser additionally
   scopes its proxy at the connection layer via
   `WKWebsiteDataStore.proxyConfigurations` — `ProxyConfiguration.matchDomains`
   (iOS 17+). WebKit suffix-matches each new connection's hostname against the
   list *before connecting*: matching (tunnel-set) hosts go to the loopback
   SOCKS5 proxy, and **off-list hosts never touch the proxy at all** — the
   network process dials them directly with its own DNS, connection reuse, and
   HTTP/3. This keeps public browsing off the loopback hop and independent of
   proxy/tunnel health.

The match list is derived from the pushed set in
`ProxyController.ForwardedRoutes.proxyMatchDomains`: both exact (`example.com`)
and wildcard (`*.example.com`) rules map to the bare domain, since WebKit's
suffix match already covers the apex and all subdomains — a superset of the
core's rules. The always-tunneled `flextunnel.internal` namespace is always
included. `allowFailover` is explicitly pinned off (`ProxyConfiguration.loopbackSocks5`,
covered by `ProxyConfigurationTests`), so a tunnel-set host **fails rather than
silently leaking direct** when the proxy is down — even when the host also
answers off-tunnel, it never flaps between the tunnel and a direct path across
link blips or relaunch gaps. The core does the same on its side: an on-list
request during an outage holds for the reconnect or is refused, never dialed
directly.

Over-matching is safe: WebKit only decides *whether to send a host to the
proxy*, and the core makes the real tunnel-vs-direct call for whatever arrives.
Under-matching would break private hosts, so the list must cover everything the
core would tunnel.

### When the WebKit layer disables itself

`proxyMatchDomains` returns nil — meaning "send every host to the proxy", the
pre-optimization behavior — when hostname suffixes can't faithfully express the
set:

- **Full tunnel** (`*` / `0.0.0.0/0`): everything is tunneled anyway.
- **Any CIDR rule**: `matchDomains` suffix-matches hostnames and matches an IP
  literal only as an exact string, so a CIDR range can't be expressed and an
  IP-literal URL must still reach the proxy's CIDR check.

In these cases the core alone routes, exactly as before. Unscoped, the system
does send IP-literal URLs to the proxy (private, public and IPv6 alike), with
one exception: **loopback and the device's own addresses are never proxied**,
so a CIDR covering them is reached directly by the browser. Port forwards are
unaffected (they dial through the core). `ProxyConfigurationTests` pins this
behavior, and the e2e CIDR fixture uses TEST-NET-3 rather than a local address
because of it.

## Browser independence

Because off-list hosts bypass the proxy entirely, the browser has **no
"is browsing usable" gate** — there is no `canBrowse` concept. Proxy/tunnel
health only affects tunnel-set hosts, which surface a normal per-tab page error
when the link is down. Across a relaunch gap (when `forwardedRoutes` clears
while the core re-handshakes) the browser **retains its last known match list**
rather than reverting to proxy-everything, so direct browsing continues
seamlessly. A real full-tunnel push (an inner nil) is still applied.

Port forwards, by contrast, have no `matchDomains` equivalent — every accepted
connection is relayed through the SOCKS5 listener and the core makes the call.
See [port-forwarding.md](port-forwarding.md).

## Surfacing in the app

The tunnel set is shown under **Tunnel status** in the browser and on the
port-forwarding screen (tunneled domains/CIDRs, or "Full tunnel (all traffic)"
when the set routes everything). The status popover's **Bound SOCKS** row shows
the loopback address while the listener is serving, or `none — … not listening`
in red whenever the listener is unavailable — startup, a reconnect gap, a bind
failure, or the core stopped — a reminder that only tunnel-set hosts depend
on it (every host, while the set has a CIDR rule).

When the set has CIDR rules, the browser's tunnel-set footer adds a note: IP
ranges cover IP-address URLs and port forwards, never hostnames, and while any
are present every page goes through the in-app proxy (the WebKit layer is off,
see above), except loopback and the device's own addresses, which the system
never proxies. CIDRs exist mostly for port forwards to private IPs; Safari and
other apps never use the browser's proxy, only the forwards.

## Verifying the split

**Off-list bypass.** Stop the core while a session is up (or observe a genuine
tunnel drop). Off-list sites keep loading — proof they connect directly — while
tunnel-set hosts and `http://flextunnel.internal` fail. If instead *everything*
dies, the WebKit layer isn't active: check the Tunnel status set for a
full-tunnel or CIDR rule (both intentionally disable it). Note WebKit pools
connections, so a host already open may reuse its socket briefly — use a fresh
host or force-reload.

**HTTP/3 tell.** SOCKS5 is a TCP CONNECT tunnel, so QUIC/HTTP-3 can't traverse
it. An off-list H3 site (e.g. `https://cloudflare-quic.com`) reporting HTTP/3
provably bypassed the proxy.

**Per-connection log.** The core logs one line per connection that reaches it —
`Tunneling: …` or `Direct (off tunnel set): …` — at `debug`. Set `RUST_LOG` to
`warn,flextunnel_core=debug` in the Run scheme's environment. With the WebKit
layer active, off-list hosts produce **no line** (they never reach the proxy);
`http://flextunnel.internal` is a reliable positive control for a tunneled line.

**Server-side DNS.** Run the flextunnel **server** with `RUST_LOG=info`.
Browsing a tunneled host should log `ATYP_DOMAIN (remote DNS, resolved on
server)` per CONNECT — **not** `ATYP_IP`. For a definitive check, add a hostname
that only resolves on the server's network (e.g. in its `/etc/hosts`) and load
it from the app; if it loads, DNS happened on the server.
