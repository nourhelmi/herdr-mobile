# Herdr Mobile

## v1 setup and use

Requirements: Herdr 0.8.0, Bun, Xcode, and an iPhone simulator (or device).

1. Start the sidecar against the local Herdr session:
   `cd sidecar && bun install && bun run start`
2. Build/install the app on an iPhone 16 simulator:
   `xcodebuild -project ios/HerdrMobile/HerdrMobile.xcodeproj -scheme HerdrMobile -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build`
3. In Settings, set the sidecar base URL (simulator host loopback: `http://127.0.0.1:8787`; a reachable Tailscale address can be used for a device), apply it, and probe `/health`.
4. Home shows live agents/workspaces. Open an agent to type into the pane (HTTP input/keys); bare panes are read-only. Output and state use WebSocket.

The sidecar binds explicit loopback and, when available, Tailscale IPv4 listeners; it never binds `0.0.0.0`. Tailscale is the v1 network boundary.

## v1.1

Additive protocol — see the [v1.1 addendum](PROTOCOL.md#v11-addendum). Home can create a workspace; an expanded workspace can create a tab. Agent detail is live-only: ANSI-colored terminal output, model/repo/cost chips, and a composer that forwards typed text plus quick keys. Bare panes stay read-only.

## v2

Agent Detail shows **Acknowledge** only while the live agent state is `done`. The action POSTs bodyless `/agent/:paneId/acknowledge`, which wraps `herdr agent focus <paneId>` so the completion is marked seen. CLI reads alone do not mark agents seen. Fresh `/state` after success may still report `done`; the visible confirmation is **Acknowledged**.
