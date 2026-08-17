# Sidecar HTTP verification

Captured against the live read-only Herdr session. Action calls use a deliberately nonexistent target.

## GET health

```http
HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Sun, 16 Aug 2026 21:03:03 GMT
Content-Length: 42

{"ok":true,"version":"1.0.0","herdr":true}
```

## GET state

```http
HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Sun, 16 Aug 2026 21:03:03 GMT
Content-Length: 5245

{"generatedAt":"2026-08-16T21:02:46.292Z","workspaces":[{"id":"w1","label":"sample-api","number":1,"focused":false,"agentStatus":"idle","tabs":[{"id":"w1:t4","label":"server","number":4,"focused":false,"agentStatus":"unknown","panes":[{"id":"w1:p7","label":null,"title":"user@host:~/sample-api","cwd":"/Users/dev/sample-api","isAgent":false,"agent":null},{"id":"w1:p8","label":null,"title":"user@host:~/sample-api","cwd":"/Users/dev/sample-api","isAgent":false,"agent":null},{"id":"w1:p9","label":null,"title":"user@host:~/sample-api","cwd":"/Users/dev/sample-api","isAgent":false,"agent":null}]},{"id":"w1:t5","label":"schema","number":5,"focused":false,"agentStatus":"unknown","panes":[{"id":"w1:pD","label":null,"title":"user@host:~/sample-web","cwd":"/Users/dev/sample-web","isAgent":false,"agent":null}]},{"id":"w1:tN","label":"advisor","number":21,"focused":false,"agentStatus":"idle","panes":[{"id":"w1:pDF","label":"advisor-okay-so-i-have-already-d","title":"π - sample-api","cwd":"/Users/dev/sample-api","isAgent":true,"agent":{"name":"pi","displayName":"π   claude-fable-5   sample-api   main   $0.00","paneId":"w1:pDF","workspaceId":"w1","tabId":"w1:tN","state":"idle","cwd":"/Users/dev/sample-api","paneLabel":"advisor-okay-so-i-have-already-d"}}]}]},{"id":"w2","label":"demo-service","number":2,"focused":false,"agentStatus":"idle","tabs":[{"id":"w2:t1","label":"1","number":1,"focused":false,"agentStatus":"idle","panes":[{"id":"w2:p1","label":null,"title":"π - demo-service","cwd":"/Users/dev/demo-service","isAgent":true,"agent":{"name":"pi","displayName":"π   claude-fable-5   demo-service   design/growth-first-alignment   $0.00","paneId":"w2:p1","workspaceId":"w2","tabId":"w2:t1","state":"idle","cwd":"/Users/dev/demo-service","paneLabel":null}}]},{"id":"w2:t2","label":"git","number":2,"focused":false,"agentStatus":"unknown","panes":[{"id":"w2:p2","label":null,"title":"user@host:~/demo-service","cwd":"/Users/dev/demo-service","isAgent":false,"agent":null}]}]},{"id":"w4","label":"startups","number":3,"focused":true,"agentStatus":"working","tabs":[{"id":"w4:t1","label":"agent","number":1,"focused":true,"agentStatus":"idle","panes":[{"id":"w4:p1","label":null,"title":"π - advisor-herdr-mobile - startups","cwd":"/Users/dev/startups","isAgent":true,"agent":{"name":"pi","displayName":"π   claude-fable-5   startups   $0.00","paneId":"w4:p1","workspaceId":"w4","tabId":"w4:t1","state":"idle","cwd":"/Users/dev/startups","paneLabel":null}},{"id":"w4:p4","label":"▶ wait-sidecar-builder · szzp3x","title":"tail -n +1 -f '/Users/dev/.pi/detach/runs/szzp3x/output.log'","cwd":"/Users/dev/startups","isAgent":false,"agent":null}]},{"id":"w4:t2","label":"terminal","number":2,"focused":false,"agentStatus":"unknown","panes":[{"id":"w4:p2","label":null,"title":"user@host:~/herdr-mobile","cwd":"/Users/dev/herdr-mobile","isAgent":false,"agent":null}]},{"id":"w4:t3","label":"sidecar-builder","number":3,"focused":false,"agentStatus":"working","panes":[{"id":"w4:p3","label":null,"title":"π - sidecar-builder - herdr-mobile","cwd":"/Users/dev/herdr-mobile","isAgent":true,"agent":{"name":"pi","displayName":"π   gpt-5.6-sol   herdr-mobile   main   $2.08","paneId":"w4:p3","workspaceId":"w4","tabId":"w4:t3","state":"working","cwd":"/Users/dev/herdr-mobile","paneLabel":null}},{"id":"w4:p6","label":"✗ Herdr Mobile sidecar verification · fxlpqv","title":"printf '<<pi-detach:fxlpqv:start>>\\n'; ( bun run start; ); printf  $?","cwd":"/Users/dev/herdr-mobile/sidecar","isAgent":false,"agent":null}]}]},{"id":"w3","label":"example-app","number":4,"focused":false,"agentStatus":"unknown","tabs":[{"id":"w3:t1","label":"1","number":1,"focused":false,"agentStatus":"unknown","panes":[{"id":"w3:p1","label":null,"title":"user@host:~/example-app","cwd":"/Users/dev/example-app","isAgent":false,"agent":null}]}]}],"agents":[{"name":"pi","displayName":"π   claude-fable-5   sample-api   main   $0.00","paneId":"w1:pDF","workspaceId":"w1","tabId":"w1:tN","state":"idle","cwd":"/Users/dev/sample-api","paneLabel":"advisor-okay-so-i-have-already-d"},{"name":"pi","displayName":"π   claude-fable-5   demo-service   design/growth-first-alignment   $0.00","paneId":"w2:p1","workspaceId":"w2","tabId":"w2:t1","state":"idle","cwd":"/Users/dev/demo-service","paneLabel":null},{"name":"pi","displayName":"π   claude-fable-5   startups   $0.00","paneId":"w4:p1","workspaceId":"w4","tabId":"w4:t1","state":"idle","cwd":"/Users/dev/startups","paneLabel":null},{"name":"pi","displayName":"π   gpt-5.6-sol   herdr-mobile   main   $2.08","paneId":"w4:p3","workspaceId":"w4","tabId":"w4:t3","state":"working","cwd":"/Users/dev/herdr-mobile","paneLabel":null}]}
```

## GET pane-output

```http
HTTP/1.1 200 OK
Content-Type: application/json;charset=utf-8
Date: Sun, 16 Aug 2026 21:03:03 GMT
Content-Length: 260

{"paneId":"w4:p3","format":"text","text":" pi-lens  ●1E\n   · snapshot.test.ts  · notifier.test.ts  · types.ts  · snapshot.ts  · server.ts\n builder · openai-codex/gpt-5.6-sol · high · 🔀 Orchestrator · repo mode · 0 areas · 3 lanes · LSP ..."}
```

## POST prompt (nonexistent target)

```http
HTTP/1.1 404 Not Found
Content-Type: application/json;charset=utf-8
Date: Sun, 16 Aug 2026 21:03:03 GMT
Content-Length: 175

{"ok":false,"error":"{\"error\":{\"code\":\"agent_not_found\",\"message\":\"agent target sidecar-verification-target-does-not-exist not found\"},\"id\":\"cli:agent:prompt\"}"}
```

## POST keys (nonexistent target)

```http
HTTP/1.1 404 Not Found
Content-Type: application/json;charset=utf-8
Date: Sun, 16 Aug 2026 21:03:03 GMT
Content-Length: 178

{"ok":false,"error":"{\"error\":{\"code\":\"agent_not_found\",\"message\":\"agent target sidecar-verification-target-does-not-exist not found\"},\"id\":\"cli:agent:send-keys\"}"}
```

## Listener binding observed during verification

```text
bun 21549 TCP 127.0.0.1:8787 (LISTEN)
bun 21549 TCP 100.64.0.2:8787 (LISTEN)
```

The same sidecar process owned both explicit listeners; no `0.0.0.0` listener was present.
