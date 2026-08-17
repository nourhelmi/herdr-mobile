# Morning verification steps

This is a bounded local runbook for the v1/v1.1 sidecar, v2 acknowledge, and simulator check. It does not upload artifacts.

**Current contract (phase 2, `aed1917+`):** live input only. Agent Detail has no PROMPT/TERM selector. Writes are `POST /pane/:id/input` and `POST /agent/:target/keys`. `POST /agent/:target/prompt` is removed and returns the generic unknown-route 404 `{"ok":false,"error":"Not found"}`. See `PROTOCOL.md` and `verification/sidecar-http-current.md`.

## 1. Start the sidecar

From the repository root:

```sh
cd sidecar
bun install
PORT=8787 bun run start
```

Use the real local Herdr 0.8.0 session. The sidecar prints its topic and binds `127.0.0.1:8787` (and an explicit Tailscale IPv4 address when available); never use `0.0.0.0`.

## 2. ntfy topic

The verifier used the unique non-sensitive topic:

```text
<ntfy-topic>
```

The sidecar prints the configured topic at startup. To publish a bounded health message manually:

```sh
curl -sS -X POST "https://ntfy.sh/<ntfy-topic>" \
  -H 'Title: Herdr Mobile verifier' \
  --data 'Herdr Mobile verifier live publish 202608170607023376'
```

## 3. Boot/build/install the iPhone 16 simulator

```sh
UDID=<simulator-udid>
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b
xcodebuild -project ios/HerdrMobile/HerdrMobile.xcodeproj \
  -scheme HerdrMobile -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$UDID" \
  build CODE_SIGNING_ALLOWED=NO
APP=$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path '*/Build/Products/Debug-iphonesimulator/HerdrMobile.app' -type d -print -quit)
xcrun simctl install "$UDID" "$APP"
```

## 4. Launch and configure the app

```sh
xcrun simctl launch "$UDID" app.herdr.mobile
```

In **Settings**, set and apply this simulator-to-host base URL, then tap **Probe /health**:

```text
http://127.0.0.1:8787
```

Expected result: `ok v1.0.0 · herdr up`, then Home shows the live state. A physical device needs a reachable HTTPS/Tailscale endpoint instead of simulator host loopback.

## 5. Acknowledge a done agent (v2)

Bodyless POST against a real done agent's URL-encoded paneId, then fetch `/state`. Remaining `done` is acceptable when Agent Detail shows **Acknowledged**.

```sh
# Replace with a live done paneId from /state
PANE_ID='w1:pDF'
ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$PANE_ID")
curl -sS -X POST "http://127.0.0.1:8787/agent/${ENCODED}/acknowledge"
curl -sS "http://127.0.0.1:8787/state"
```

## 6. Evidence locations

**Current (release):** `verification/sidecar-http-current.md` — live-only input + explicit prompt-route 404, backed by `sidecar/test/server.integration.test.ts` at `aed1917` (`41 pass / 0 fail`). Protocol: `PROTOCOL.md`.

**Historical (do not treat as current behavior):**
- `verification/sidecar-http-live.md` — 2026-08-17 morning capture; includes a 200 from the removed `POST /agent/:target/prompt` route.
- `verification/sidecar-http.md` — 2026-08-16 capture; missing-target still routed through `cli:agent:prompt`.
- `verification/sidecar-tests-v11.txt` and `sidecar-tests-v11-continuation.txt` — v11-era suite (chrome tests, “prompt text” names). Current names say “input text”; chrome.ts is gone.
- `verification/screenshots/agent-detail-prompt.png` and `agent-detail-terminal.png` — removed PROMPT/TERM selector. Other screenshots in that folder are still valid for home/settings/create/SGR.

Still-current live transcripts: `verification/sidecar-ws-live.md`, `verification/sidecar-ntfy-live.md`. Run evidence manifests stay in the assigned advisor run directory.
