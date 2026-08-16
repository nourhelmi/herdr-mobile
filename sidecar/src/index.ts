import { resolve } from "node:path";
import { assertSafePositional, ProcessHerdrCli } from "./cli";
import { StateEngine } from "./engine";
import {
  loadNotificationTracker,
  loadOrCreateTopic,
  NotificationWatcher,
} from "./notifier";
import { isSafeTailscaleIpv4, startSidecar } from "./server";

async function detectTailscaleIpv4(): Promise<string | null> {
  try {
    const process = Bun.spawn(["tailscale", "ip", "-4"], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const [output, exitCode] = await Promise.all([
      new Response(process.stdout).text(),
      process.exited,
    ]);
    if (exitCode !== 0) return null;
    const address = output.trim().split(/\s+/)[0];
    return address && isSafeTailscaleIpv4(address) ? address : null;
  } catch {
    return null;
  }
}

const stateDirectory = resolve(import.meta.dir, "../state");
const configPath = resolve(stateDirectory, "config.json");
const notificationStatePath = resolve(stateDirectory, "notification-state.json");
const topic = await loadOrCreateTopic(configPath);
console.log(`Herdr sidecar ntfy topic: ${topic}`);

const cli = new ProcessHerdrCli();
const tracker = await loadNotificationTracker(notificationStatePath);
const notifications = new NotificationWatcher(
  tracker,
  notificationStatePath,
  topic,
  (paneId, lines) => {
    assertSafePositional(paneId, "paneId");
    return cli.text([
      "pane",
      "read",
      paneId,
      "--source",
      "recent-unwrapped",
      "--lines",
      String(lines),
      "--format",
      "text",
    ]);
  },
);
const engine = new StateEngine(cli, notifications);
await engine.start();

const configuredPort = Number(Bun.env.PORT ?? 8787);
if (!Number.isSafeInteger(configuredPort) || configuredPort < 1 || configuredPort > 65_535) {
  throw new Error("PORT must be an integer between 1 and 65535");
}
const tailscaleAddress = await detectTailscaleIpv4();
const hosts = ["127.0.0.1", ...(tailscaleAddress ? [tailscaleAddress] : [])];
const sidecar = startSidecar({ engine, cli, hosts, port: configuredPort });

function shutdown(): void {
  sidecar.stop();
  engine.stop();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
