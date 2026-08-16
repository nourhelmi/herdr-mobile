import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import {
  loadNotificationTracker,
  NotificationTracker,
  NotificationWatcher,
} from "../src/notifier";
import type { AgentSnapshot } from "../src/types";

const temporaryDirectories: string[] = [];
afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true })));
});

function agent(state: string): AgentSnapshot {
  return {
    name: "pi",
    displayName: null,
    paneId: "w9:p1",
    workspaceId: "w9",
    tabId: "w9:t1",
    state,
    cwd: "/tmp/project",
    paneLabel: null,
  };
}

describe("NotificationTracker", () => {
  test("notifies transitions into blocked/done and debounces pane+state for 60 seconds", () => {
    const tracker = new NotificationTracker(undefined, 60_000);

    expect(tracker.observe([agent("idle")], 1_000)).toEqual([]);
    expect(tracker.observe([agent("blocked")], 2_000)).toEqual([
      { agent: agent("blocked"), state: "blocked" },
    ]);
    expect(tracker.observe([agent("working")], 3_000)).toEqual([]);
    expect(tracker.observe([agent("blocked")], 61_999)).toEqual([]);
    expect(tracker.observe([agent("working")], 62_000)).toEqual([]);
    expect(tracker.observe([agent("blocked")], 62_000)).toHaveLength(1);
    expect(tracker.observe([agent("done")], 63_000)).toEqual([
      { agent: agent("done"), state: "done" },
    ]);
  });

  test("treats a first blocked observation as a restart baseline", () => {
    const tracker = new NotificationTracker();
    expect(tracker.observe([agent("blocked")], 1_000)).toEqual([]);
  });
});

describe("NotificationWatcher persistence", () => {
  test("persists last-seen state so restart does not re-notify", async () => {
    const directory = await mkdtemp(resolve(tmpdir(), "herdr-sidecar-test-"));
    temporaryDirectories.push(directory);
    const statePath = resolve(directory, "notification-state.json");
    const published: string[] = [];
    const tracker = await loadNotificationTracker(statePath);
    const watcher = new NotificationWatcher(
      tracker,
      statePath,
      "fixture-topic",
      async () => "line 1\nline 2",
      async (_topic, message) => {
        published.push(message);
      },
    );

    await watcher.process([agent("idle")]);
    await watcher.process([agent("done")]);
    expect(published).toHaveLength(1);
    expect(published[0]).toContain("pi: done");
    expect(published[0]).toContain("line 2");

    const restartedTracker = await loadNotificationTracker(statePath);
    const restartedWatcher = new NotificationWatcher(
      restartedTracker,
      statePath,
      "fixture-topic",
      async () => "line 2",
      async (_topic, message) => {
        published.push(message);
      },
    );
    await restartedWatcher.process([agent("done")]);
    expect(published).toHaveLength(1);
  });
});
