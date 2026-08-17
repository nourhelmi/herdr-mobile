# Live cleanup proof

- Created verifier objects: workspace `w5`, tab `w5:t1`, pane `w5:p1`, agent `hm-check-agent-202608170607`.
- Cleanup command: `herdr workspace close w5`.
- Close result: `{"id":"cli:workspace:close","result":{"type":"ok"}}`.
- Deterministic post-close checks returned zero for `w5` in `herdr workspace list`, `herdr agent list`, and `herdr pane list`.
- Sidecar child PID `16771` received `SIGTERM`; `lsof -nP -iTCP:8787 -sTCP:LISTEN` returned zero listeners and `ps` found zero `bun run src/index.ts` processes.
- Original `sidecar/state/config.json` and `notification-state.json` were restored from the preflight backup.
- App `app.herdr.mobile` was terminated and simulator `<simulator-udid>` was shut down.
- Temporary verifier cwd `/tmp/herdr-mobile-check-202608170607023376` and state backup were removed.

The preflight session had four existing workspaces before verifier creation. One pre-existing workspace ID observed at the first read (`w3`) was absent by the later read before verifier cleanup; the verifier never addressed or closed `w3`.
