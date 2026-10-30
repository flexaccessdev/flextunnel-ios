# Background keep-alive

The tunnel runs inside the app process, without a Network Extension. When iOS
suspends the app, its tunnel and local listeners cannot serve other apps.

**Forward ports** mode offers an opt-in Core Location session to keep the app
running in the background. Browser sessions never start it; keeping the app
alive would not ensure WebKit's separate processes stay active.

## Setup

Select **Forward ports**, then enable **Keep alive in background** before
starting. It is off by default. Enabling it requests When In Use location
permission; a denial is shown with a link to Settings. While a session runs,
expect iOS's location-in-use indicator. The forwarding screen
reports `off`, `needs location access`, `starts with forwarding`, `active` or
`timed out`. Stop the session to change the setting.

Using location only as a keep-alive suits a personally distributed build; it
is not App Store material, since review expects location to serve a
user-visible location feature.

The **Time limit** choices are 5, 15, 30 and 60 minutes, defaulting to **5
minutes**. The choice persists across launches. It limits inactivity, rather
than total session duration.

## Activity and expiry

`BackgroundKeepAlive.swift` resets the inactivity window when:

- a location fix is at least 500m from the movement anchor; the anchor advances
  only after that threshold is reached;
- a health poll observes any open forward connection, even if it is idle;
- the app is in the foreground, or transitions to or from it.

Expiry is checked against the last activity time every 60s, with timer
coalescing allowed. It can therefore be noticed after the displayed deadline.
At expiry, the app closes local listeners, dismisses the Live Activity and
stops location updates, allowing iOS to suspend it. On return it relaunches
the tunnel and rebinds enabled forwards; other apps must reconnect.

## Location implementation

The location session starts with forwarding and stops with it. A start while
backgrounded is deferred until the app returns to the foreground. The manager
requests coarse accuracy (`desiredAccuracy = 100_000`), enables background
updates and disables automatic pausing. A location fix is retained only as an
in-memory movement anchor; the app does not persist or transmit it.

The app needs `UIBackgroundModes` containing `location` and a
`NSLocationWhenInUseUsageDescription` in `Info.plist`. Preserve these when
[signing an unsigned release](signing-unsigned-ipa.md).

## Polling and traffic

While backgrounded, the app reduces health polling from every 1s to every 60s.
Foreground Low Power Mode uses 2s polling. The Rust core's heartbeat changes
from 10s to 60s, with no separate QUIC keep-alive and a 180s QUIC idle timeout.
On cellular each transmission holds the radio at high power for roughly 10s, so
anything periodic under about 15-20s keeps it there continuously. Returning to
the foreground restores the 10s cadence, sends an overdue heartbeat at once and
ends any reconnect backoff early. Reported network loss parks reconnect retries
until a path returns, then reconnects immediately with a fresh backoff series.

These settings reduce periodic work; they do not guarantee a particular
battery cost or packet count. Connection-path UDP counters include traffic
beyond heartbeats and do not measure radio wakeups or energy use.

## Without keep-alive

Browser mode, forwarding with keep-alive off, and forwarding without location
permission use a short UIKit background task. Its expiration time is controlled
by iOS. When it expires, the app closes local listeners and prepares to recover
on foreground return; there is no guaranteed 30-second service window.

Suspension leaves the process's sockets defunct, and the core cannot recover
them itself: its listeners and QUIC endpoint can wedge while the session still
reads connected. Returning therefore relaunches the session, after keep-alive
expiry as well, and rebinds enabled forwards. Existing TCP
connections are lost, and browser loads may need reloading. A terminated app
cannot recover until it is launched again.

## Live Activity

Only forwarding sessions have a tunnel-status Live Activity. It displays state
but grants no background execution. While keep-alive runs, background health
polls refresh it about once a minute. It is dismissed when forwarding stops,
background grace expires without keep-alive, or the inactivity limit is reached.

The estimated time remaining comes from the last activity deadline and updates
when the widget renders. Open connections or movement can extend that deadline.
The countdown is hidden once expired or stale; it is not a guarantee of when
iOS will suspend the app.
