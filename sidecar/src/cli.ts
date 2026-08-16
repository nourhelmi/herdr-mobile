export class CliError extends Error {
  constructor(
    message: string,
    readonly exitCode: number,
  ) {
    super(message);
    this.name = "CliError";
  }
}

export interface HerdrCli {
  json<T>(args: string[]): Promise<T>;
  text(args: string[]): Promise<string>;
}

export class ProcessHerdrCli implements HerdrCli {
  async text(args: string[]): Promise<string> {
    const process = Bun.spawn(["herdr", ...args], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(process.stdout).text(),
      new Response(process.stderr).text(),
      process.exited,
    ]);

    if (exitCode !== 0) {
      throw new CliError((stderr || stdout || `herdr exited ${exitCode}`).trim(), exitCode);
    }
    return stdout;
  }

  async json<T>(args: string[]): Promise<T> {
    const output = await this.text(args);
    try {
      const envelope = JSON.parse(output) as { result?: T };
      if (!("result" in envelope)) {
        throw new Error("missing result envelope");
      }
      return envelope.result as T;
    } catch (error) {
      if (error instanceof CliError) throw error;
      throw new CliError(`Invalid JSON from herdr: ${String(error)}`, 0);
    }
  }
}

export function isUnknownTarget(error: unknown): boolean {
  return error instanceof CliError && /not found|unknown|does not exist|no (?:such )?(?:pane|agent)|could not find/i.test(error.message);
}
