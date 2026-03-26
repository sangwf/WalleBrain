import path from "node:path";

import { MeetingOrchestrator } from "../meeting/orchestration/meeting-orchestrator.js";
import type { SessionMode } from "../meeting/session/session-types.js";

type ParsedArgs = {
  title: string;
  mode: SessionMode;
  baseDir: string;
};

function parseArgs(argv: string[]): ParsedArgs {
  let title = "New Meeting";
  let mode: SessionMode = "normal";
  let baseDir = process.cwd();

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    if (arg === "--title" && next) {
      title = next;
      index += 1;
      continue;
    }

    if (arg === "--mode" && next && (next === "normal" || next === "important")) {
      mode = next;
      index += 1;
      continue;
    }

    if (arg === "--base-dir" && next) {
      baseDir = path.resolve(next);
      index += 1;
    }
  }

  return { title, mode, baseDir };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const orchestrator = new MeetingOrchestrator();
  const session = await orchestrator.createSession(args);

  console.log(JSON.stringify({
    id: session.id,
    title: session.title,
    mode: session.mode,
    status: session.status,
    sessionMarkdown: session.paths.sessionMarkdown,
    sessionJson: session.paths.sessionJson,
  }, null, 2));
}

await main();
