# Background keep-alive

A forwarding session lives inside the app process. There is no VPN / Network
Extension, so the tunnel and every port-forward listener follow the app's
lifecycle: once iOS suspends the process, they stop answering.

To keep port forwards running while you use other apps, flextunnel uses the same
technique as Termius and Blink: it runs a **continuous Core Location session**,
and iOS does not suspend an app that is actively receiving location updates.

This applies only to **Forward ports** mode. Browse mode deliberately uses normal
iOS/WebKit background suspension: keeping the app's tunnel process alive cannot
promise that WebKit's separately managed page and network processes will keep
running in the background, so browser sessions never start a location session.

## The decision is made before starting

The **"Keep alive in background"** toggle appears in the **Background** section
of the start screen only while **Forward ports** is selected. The location
permission prompt is therefore resolved *before* the forwarding tunnel comes up
rather than landing mid-connect. It is **off by default** (opt-in, mirroring
Termius's "Location tracking" setting) and the choice persists across launches.

Once forwarding is running, its **Background** section reports the choice and
live state read-only. Browser setup and the browser's tunnel-status popover do
not expose the setting.

Values are `off`, `needs location access`, `starts with forwarding` (opted in,
permitted, forwarding not up yet), `active` (the location session is running)
and `timed out` (the inactivity limit below was reached). To change it, stop
forwarding and use the start screen.

## Inactivity limit

Directly under the toggle is a **Time limit** picker — under `flextunnel-ios/Sources/FlextunnelApp/BackgroundKeepAlive.swift` — capping how long an *inactive* session is held
alive. Without it, an app left in the background holds the location session (and
the battery cost, and the location indicator) until the user comes back.

The window is refilled by any of:

- **movement** — a fix at least 500 m from the last one. Fixes at 100 km desired
  accuracy are tower-grade, so anything smaller is jitter; this is roughly Core
  Location's own significant-change distance. Nothing about the location
  configuration changes for this, so the timeout costs no extra battery;
- **an open port-forward connection** — while any forward is carrying traffic
  (sampled by the health poll: 1 Hz in the foreground, once a minute while
  backgrounded), the session is in use even if the device is sitting still,
  e.g. SSH from a desk;
- **the app being in front** — the window is refilled on every check while the
  app is in the foreground (and once more on going away), so time spent in the
  app never eats the window and the limit caps one stretch of backgrounded time
  rather than the whole session.

The window is checked once a minute against a wall clock (not armed as a one-shot
at the deadline), so a coalesced timer fire can't silently extend it and a
changed limit applies on the next tick.

When it expires, flextunnel **stops the location session and lets iOS suspend the
app by itself** — it does not tear forwarding down. That is deliberately the
same path as having the keep-alive off: the Live Activity is dismissed while the
app is still alive, iOS suspends the process, and returning to the app relaunches
the forwarding session automatically (`recoverFromSuspension`, see below) and
refills the window. So the visible effect of hitting the limit is a brief
"connecting" on return, not a dead screen.

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
- it starts and stops with the forwarding session (`setSessionActive`), so the
  system's location indicator never outlives forwarding — turning the toggle on
  at the start screen starts no location session by itself;
- with When In Use authorization a location session only holds the process if it
  was started in the foreground, so a start that would land while the app is
  backgrounded is skipped (rather than claiming `active` while holding nothing)
  and retried on the next foreground;
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

## Staying cheap while held alive

The location session itself is nearly free (coarse fixes, no GPS). What costs
battery is the work it protects: on cellular, **every transmission buys ~10
seconds of high-power radio tail**, so anything periodic under ~15–20s keeps
the radio at high power the whole time. While backgrounded the app therefore
quiets everything periodic:

- the core's app-level **heartbeat is the connection's only periodic traffic**
  (there is no QUIC-level keep-alive; the QUIC idle timeout is 180s) and slows
  from 10s to 60s while the app is backgrounded (`flextunnel_set_background`,
  driven from the scene phase). One wake a minute keeps the radio in its
  low-power state almost the whole time; the foreground flip snaps the cadence
  back and sends any overdue beat immediately. Real forward traffic is
  unaffected — when data is flowing the radio is up anyway;
- the **health poll drops from 1 Hz to once a minute** while backgrounded
  (backgrounded, it only feeds the Live Activity re-arm and the keep-alive's
  activity sampling, both minute-granular). In the foreground Low Power Mode
  halves it to every 2s. All periodic timers carry a 10% tolerance so the
  system can coalesce their wakeups;
- **reconnects are gated on the network path**: `NWPathMonitor` verdicts are
  forwarded to the core (`flextunnel_set_network_available`), which parks its
  reconnect loop with no timers at all while no path is usable — backoff
  retries into a dead network detect nothing and wake the radio for nothing —
  and reconnects immediately, with a fresh backoff series, when a path returns.

To gauge the cost, the connection-path sheet shows the session's **UDP
datagrams sent/received**; the sent count across a backgrounded stretch is the
cheap proxy for radio wakes (an idle held-alive hour should be ~60 sends, one
per heartbeat). For real measurements use iOS 26's on-device Power Profiler
(Settings → Developer → Performance Trace) or MetricKit payloads.

## Without it: the ~30 s fallback

For a forwarding session with keep-alive off — or location permission
**denied**, which the start screen flags with a shortcut to Settings — behavior
falls back to best-effort extended execution: the session keeps serving for
roughly **30 seconds** after backgrounding, then iOS suspends the process.

- A suspension defuncts the process's sockets — the core's QUIC endpoint and
  forward listeners — and the core cannot recover that on its own (its accept
  loop keeps failing while health still reads alive, so everything *looks*
  connected while nothing answers).
- So on return to the app, the session is **relaunched automatically**
  (`recoverFromSuspension` in `ContentView.swift`): the same full stop/start as a
  manual disconnect/connect — fresh tunnel connect, every enabled forward
  rebound — without tearing the screen down. Expect a brief "connecting" while
  the handshake replays.
- Connections that were open when the suspension hit are dead; clients must
  reconnect after you return.

Browser mode always takes the fallback path. The same short background task
gives the app process time to finish immediate cleanup, then the SOCKS listener
and tunnel are allowed to suspend along with normal WebKit activity. On return,
`recoverFromSuspension` relaunches the tunnel automatically. An in-flight page
load can fail and need a reload; no location session is started merely to keep
the tunnel warm while WebKit itself is inactive.

## Live Activity

The tunnel-status Live Activity (lock screen / Dynamic Island) accompanies
port-forwarding sessions only and is **UX only** — it neither grants nor relies
on background execution. It exists for a session running behind other apps,
which only forwarding does: a browser session is either on screen or suspended,
so it never starts one. During a held-alive forwarding session the health poll
(once a minute while backgrounded) keeps refreshing it. A forwarding session
without keep-alive dismisses the banner when the grace expires and the app
suspends. Reaching the forwarding inactivity limit dismisses it the same way,
since the app is about to stop being able to refresh it.

While the keep-alive is holding a forwarding session, the banner also shows
**`est. 12m till disconnect`** (`timer` glyph). The app pushes a *deadline*, not a
rendered number, and the widget converts it to whole minutes at render time — so
it can't disagree with the clock even if a refresh is late. It steps with the
app's refreshes (about once a minute while backgrounded — every backgrounded
health poll re-arms it, see `ProxyController.backgroundRefreshInterval`), which
is the right granularity for a
minute-resolution figure, and a window refilled by movement or an open forward
connection is reflected on the next one. It reads "est." because expiry is noticed
on a periodic check, so the real stop lands at or shortly after zero. Nothing is
shown when no keep-alive is holding the session, once the deadline has passed, or
once the banner has gone stale.
