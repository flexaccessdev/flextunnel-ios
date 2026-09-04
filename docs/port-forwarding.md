# Proxy-only mode & port forwarding

Besides the browser, the app can run as a plain tunnel endpoint: choose
**Forward ports** on the setup screen and tap **Start Port Forwarding** to
bring up the flextunnel core (the QUIC link to your server — no browser, and no
SOCKS5 listener either; that exists only in browser sessions) with a
status-and-forwards screen. The point is to serve **other apps on the
device**: iOS loopback is shared across processes, so anything you run — an
SSH client, RDP viewer, database GUI, another browser — can reach
`localhost:<port>` endpoints this app provides while it is alive.

On offer in that mode are **port forwards** — plain TCP listeners on
`localhost:<local port>`, owned by the Rust core, that relay every accepted
connection to a fixed `remote host:port` directly over the server connection.

Each forward listens on **both loopback stacks** — `127.0.0.1` and `::1` —
because client apps connecting to `localhost` may try IPv6 first. Each stack
binds and recovers independently, so a forward is usable while either stack is
bound and reports failure only when both are down. Either way nothing is ever
exposed on the LAN.

## Port forwards

A forward is `localhost:<local port> → <remote host>:<remote port>`. Each
accepted connection opens its own data stream on the authenticated server
connection ("server-direct"): the target is sent through unresolved, so DNS
and the dial happen **server-side** — hostnames that only resolve on the
server's network, `[host_aliases]` names, and internal IPs all work. The
server enforces its routed set per connection and **rejects off-list
targets**; unlike the browser (which routes off-list traffic around the proxy
at the WebKit level — see [split-tunnel-routing.md](split-tunnel-routing.md)),
forwards never dial from the device.

Each row shows a **server-direct** (green) or **not routed** (orange) badge
predicting that decision from the pushed tunnel set. The badge is advisory —
the server's own whitelist remains the authority per connection.

To keep a runaway client from exhausting the process's file descriptors, each
forward caps concurrent connections at 128; at the cap it pauses accepting
until a connection closes.

### Managing forwards

Tap **+** to add; tap a row to edit. Fields: optional label, local port, remote
host (hostname or IP — hostnames are passed through unresolved, so DNS happens
on the server), remote port. The sheet rejects a local port that is out of
range or already used by another forward. (iOS apps can't bind ports below
1024 — such a forward fails with a permission error and switches itself off.)

Each row has a **start/stop toggle**, and the toggle is **per-session**: a
fresh session start (either CTA on the setup screen) begins with every forward
off — nothing tunnels until you switch it on:

- **on** — the listeners bind while the session is up and rebind automatically
  when the OS defuncts them, each stack retrying with backoff until its port is
  reclaimed;
- **off** — the listeners close immediately (open connections drop, the local
  port is released).

If starting fails during initial setup (e.g. the local port is in use), the
forward stops and the toggle flips back off, with the reason left on the row
until the next start attempt. A failure *after* the forward was listening
(e.g. iOS reclaiming the listeners around suspension) does not flip it off —
the forward stays enabled and resumes with the session.

The status line under each enabled forward is live: `listening`,
`listening · N active` (open connection count), or a red reason such as
`port 8080 is in use`.

Forward definitions persist across launches (as JSON in the app container,
with the same at-rest protections as bookmarks/history) and belong to the
**connection profile** they were added under — a forward names a host behind
one particular server, so switching profiles swaps the list and deleting a
profile takes its forwards with it. The toggle state is
deliberately **not** part of that — it is runtime-only, so forwards never
auto-start with a session. Once switched on they work in browser-mode sessions
too; the management UI just lives in proxy-only mode.

## Background behavior

The listeners live inside the app process and follow its lifecycle, so whether
forwards survive backgrounding is entirely down to the **keep-alive** — opted
into on the start screen while **Forward ports** is selected, before connecting.
See [background-keep-alive.md](background-keep-alive.md) for the mechanism, the
permission, and the App Store caveat. The proxy screen's Background section
reports its live status read-only.

What matters specifically for forwards:

- **With it on**, every forward stays reachable while you use other apps — until
  the keep-alive's **inactivity limit** (5 minutes by default). A forward
  carrying an open connection counts as activity and keeps
  postponing it, so a session in active use isn't dropped for sitting still;
  reaching the limit falls back to the suspension case below, and returning to
  the app rebinds everything.
- **With it off or location denied**, extended execution keeps serving for
  roughly **30 seconds** after backgrounding, then iOS suspends the process.
  Just before that the app **closes every forward listener**: a suspended
  process's listeners would keep accepting into the kernel backlog and serve
  nothing, so closing turns a client's hang into an immediate
  connection-refused. On return the session is
  **relaunched automatically** — fresh tunnel connect, every enabled forward
  rebound — so expect a brief "connecting", and clients that were connected
  must reconnect.

## What forwards are (and aren't) good for

A forward is a raw TCP pipe. It carries any TCP protocol, but it does not — and
cannot — rewrite what flows through it:

- **great for**: SSH, RDP/VNC, databases (Postgres, MySQL, Redis, …), internal
  dev/admin HTTP services addressed by IP or that accept any `Host`;
- **poor for**: public HTTP(S) sites behind CDNs or name-based virtual hosting.
  A browser pointed at `http://127.0.0.1:9090` sends `Host: 127.0.0.1:9090`,
  and the far end may reject it (e.g. Cloudflare's *error 1003: Direct IP
  access not allowed*). Use the in-app browser — or the SOCKS proxy directly —
  for web browsing; that path preserves hostnames end to end.
- **TCP only.** A forward stream carries one TCP connection; UDP is not relayed.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| red `port N is in use` | Another process owns the local port (in the Simulator this includes Mac processes — loopback is shared with the host). Pick another port. |
| client connects, then immediately drops | Target rejected by the server (not in its routed set) or unreachable from it. Check the badge and the server's `routed_domains`/`routed_cidrs`. |
| every forward stalls | Tunnel link is reconnecting — see the status header. Server-direct forwards always need the link. |
| web page shows a CDN error (e.g. 1003) | Host-header mismatch by design — see "What forwards are good for" above. |
| forward dead after returning to the app | iOS suspended the process — because keep-alive is off or location permission is denied (only the ~30 s grace applied), or the keep-alive hit its inactivity limit while nothing was connected (the Background section reads `timed out`). Either way the session relaunches automatically on return; give the handshake a moment and reconnect the client. To hold sessions across backgrounding, stop and restart with "Keep alive in background" on, and raise its time limit (start screen). |
