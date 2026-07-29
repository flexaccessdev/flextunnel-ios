# Background keep-alive

A session lives inside the app process. There is no VPN / Network Extension, so
the tunnel, the SOCKS listener and every port-forward listener follow the app's
lifecycle: once iOS suspends the process, they stop answering.

To keep a session running while you use other apps, flextunnel uses the same
technique as Termius and Blink: it runs a **continuous Core Location session**,
and iOS does not suspend an app that is actively receiving location updates.

This applies to **both session modes** — browsing and port forwarding. It is one
top-level decision, not a per-mode setting.

## The decision is made before starting

The **"Keep alive in background"** toggle lives in the **Background** section of
the start screen, above the start button — so it applies to whichever mode you
then start, and the location permission prompt is resolved *before* a tunnel
comes up rather than landing mid-connect. It is **off by default** (opt-in,
mirroring Termius's "Location tracking" setting) and the choice persists across
launches.

Once a session is running, the screens report it read-only:

- port forwarding → the **Background** section's `Background keep-alive` row;
- browsing → the same row in the tunnel-status popover (the shield icon).

Values are `off`, `needs location access`, `starts with the session` (opted in,
permitted, session not up yet), `active` (the location session is running) and
`timed out` (the inactivity limit below was reached). To change it, stop the
session and use the start screen.

## Inactivity limit

Directly under the toggle is a **Time limit** picker — 15 minutes, **30 minutes**
(default), 1 hour or 2 hours — capping how long an *inactive* session is held
alive. Without it, an app left in the background holds the location session (and
the battery cost, and the location indicator) until the user comes back.

The window is refilled by any of:

- **movement** — a fix at least 500 m from the last one. Fixes at 100 km desired
  accuracy are tower-grade, so anything smaller is jitter; this is roughly Core
  Location's own significant-change distance. Nothing about the location
  configuration changes for this, so the timeout costs no extra battery;
- **an open port-forward connection** — while any forward is carrying traffic
  (already polled at 1 Hz), the session is in use even if the device is sitting
  still, e.g. SSH from a desk;
- **the app coming to the front, or going away** — so time spent in the app never
  eats the window and the limit caps one stretch of backgrounded time rather than
  the whole session.

The window is checked once a minute against a wall clock (not armed as a one-shot
at the deadline), so a coalesced timer fire can't silently extend it and a
changed limit applies on the next tick.

When it expires, flextunnel **stops the location session and lets iOS suspend the
app by itself** — it does not tear the session down. That is deliberately the
same path as having the keep-alive off: the Live Activity is dismissed while the
app is still alive, iOS suspends the process, and returning to the app relaunches
the session automatically (`recoverFromSuspension`, see below) and refills the
window. So the visible effect of hitting the limit is a brief "connecting" on
return, not a dead screen.

There is deliberately **no unbounded option**: the two activity signals above
already postpone the limit indefinitely for a session that is being used, so an
"off" setting would only serve sessions nobody is using. A stored limit that is
no longer on offer falls back to the default.

## How it works

`BackgroundKeepAlive.swift`:

- toggling it on requests **When In Use** location permission immediately;
  granting it is all the setup there is;
- accuracy is deliberately coarse (100 km, like Blink's `geo track`) so fixes
  come from cell towers rather than the GPS radio — the battery cost is small;
- no fix is stored or sent anywhere: the location session exists purely so iOS
  keeps the process running, and a fix is only compared against the last one (one
  in-memory coordinate) to tell whether the device moved — see the inactivity
  limit above;
- it starts and stops with the session (`setSessionActive`), so the system's
  location indicator never outlives the tunnel — turning the toggle on at the
  start screen starts no location session by itself;
- expect the location-in-use indicator while a session runs — that's iOS
  truthfully reporting the active location session.

Requires the `location` entry in `UIBackgroundModes` plus
`NSLocationWhenInUseUsageDescription` (both in
`Sources/FlextunnelApp/Info.plist`); re-signing must preserve them, see
[signing-unsigned-ipa.md](signing-unsigned-ipa.md).

This is fine for a personally-distributed build, but it is **not App Store
material**: review requires location be used for user-visible location features,
not as a keep-alive vehicle (Termius/Blink dress theirs up with geo-tagging and
geo-fencing features for this reason).

## Without it: the ~30 s fallback

When the keep-alive is off — or location permission is **denied**, which the
start screen flags with a shortcut to Settings — behavior falls back to
best-effort extended execution: the session keeps serving for roughly **30
seconds** after backgrounding, then iOS suspends the process.

- A suspension defuncts the process's sockets — the core's SOCKS listener and
  QUIC endpoint as well as any forward listeners — and the core cannot recover
  that on its own (its accept loop keeps failing while health still reads alive,
  so everything *looks* connected while nothing answers).
- So on return to the app, the session is **relaunched automatically**
  (`recoverFromSuspension` in `ContentView.swift`): the same full stop/start as a
  manual disconnect/connect — fresh tunnel connect, every enabled forward
  rebound — without tearing the screen down. Expect a brief "connecting" while
  the handshake replays.
- Connections that were open when the suspension hit are dead; clients must
  reconnect after you return. In the browser this means an in-flight page load
  fails and needs a reload.

## Live Activity

The tunnel-status Live Activity (lock screen / Dynamic Island) accompanies
sessions in both modes and is **UX only** — it neither grants nor relies on
background execution. Under the keep-alive the 1 Hz health poll keeps refreshing
it while backgrounded; without it, the banner is dismissed when the grace expires
and the app suspends. Reaching the inactivity limit dismisses it the same way,
since the app is about to stop being able to refresh it.

While the keep-alive is holding a session, the banner also shows an **est.
countdown to the limit** (`timer` glyph). The app pushes a *deadline*, not a
rendered number, and the widget counts it down itself — so it stays right between
the app's refreshes (roughly once a minute while backgrounded, driven by
`ProxyController.backgroundRefreshInterval`), and a window refilled by movement or
an open forward connection is reflected on the next refresh. It reads "est."
because expiry is noticed on a periodic check, so the real stop lands at or
shortly after zero. No countdown is shown when nothing is holding the session, or
once the banner has gone stale.
