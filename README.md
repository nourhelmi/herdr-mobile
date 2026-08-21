# Herdr Mobile

## v1 setup and use

Requirements: Herdr 0.8.0, Bun, Xcode, and an iPhone simulator (or device).

1. Start the sidecar against the local Herdr session:
   `cd sidecar && bun install && bun run start`
2. Build/install the app on an iPhone 16 simulator:
   `xcodebuild -project ios/HerdrMobile/HerdrMobile.xcodeproj -scheme HerdrMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build`
3. In Settings, set the sidecar base URL (simulator host loopback: `http://127.0.0.1:8787`; a reachable Tailscale address can be used for a device), apply it, and probe `/health`.
4. Home shows live agents/workspaces. Open any pane to type into it and send full terminal keys (HTTP input/keys) — agent panes get the dedicated agent experience, bare panes get an ordinary interactive terminal. Output and state use WebSocket.

The sidecar binds explicit loopback and, when available, Tailscale IPv4 listeners; it never binds `0.0.0.0`. Tailscale is the v1 network boundary.

## v1.1

Additive protocol — see the [v1.1 addendum](PROTOCOL.md#v11-addendum). Home can create a workspace; an expanded workspace can create a tab. Agent detail is live-only: ANSI-colored terminal output, model/repo/cost chips, and a composer that forwards typed text plus quick keys.

## v2

Agent Detail shows **Acknowledge** only while the live agent state is `done`. The action POSTs bodyless `/agent/:paneId/acknowledge`, which wraps `herdr agent focus <paneId>` so the completion is marked seen. CLI reads alone do not mark agents seen. Fresh `/state` after success may still report `done`; the visible confirmation is **Acknowledged**.

## Pane-keys addendum

Bare panes are fully interactive, not read-only: they get the same ANSI
terminal output, a composer for printable text, and quick keys for Enter,
Esc, Ctrl-C, Tab, Backspace, and the arrow keys — sent over the pane-scoped
`/pane/:id/keys` route (see the [pane-keys addendum](PROTOCOL.md#pane-keys-addendum)).
While a pane's detail screen is open, it switches live between the bare
terminal view and the dedicated agent view as Pi starts or exits in that
pane, driven by the authoritative snapshot rather than by navigating back.

Agent and bare-pane menus expose **Output History**. Because opening this sheet
is an explicit on-demand action, it loads the full bounded ANSI history once so
the user can scroll continuously to the oldest output Herdr exposes (up to the
2,000-row protocol cap). Dragging to the top of the live terminal opens the
same history screen.
