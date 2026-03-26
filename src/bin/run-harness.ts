import path from "node:path";

import { MeetingOrchestrator } from "../meeting/orchestration/meeting-orchestrator.js";
import { createPostProcessor } from "../meeting/postprocess/post-processor-factory.js";
import type { PostProcessorStrategy } from "../meeting/postprocess/post-processor-factory.js";
import type { SessionMode } from "../meeting/session/session-types.js";

type ParsedArgs = {
  title: string;
  mode: SessionMode;
  baseDir: string;
  processor: PostProcessorStrategy;
};

function parseArgs(argv: string[]): ParsedArgs {
  let title = "Harness Demo Meeting";
  let mode: SessionMode = "normal";
  let baseDir = process.cwd();
  let processor: PostProcessorStrategy = "auto";

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
      continue;
    }

    if (arg === "--processor" && next && (next === "auto" || next === "fake" || next === "real")) {
      processor = next;
      index += 1;
    }
  }

  return { title, mode, baseDir, processor };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const orchestrator = new MeetingOrchestrator(
    undefined,
    undefined,
    undefined,
    undefined,
    createPostProcessor(args.processor),
  );
  const result = await orchestrator.runFakeHarness(args);

  console.log(JSON.stringify({
    id: result.session.id,
    title: result.session.title,
    status: result.session.status,
    sessionMarkdown: result.session.paths.sessionMarkdown,
    sessionJson: result.session.paths.sessionJson,
    audioFile: result.session.paths.audioFile,
    finalNote: result.session.paths.finalNote,
    transcriptLines: result.postProcessResult.transcript.split("\n").length,
    provider: result.postProcessResult.provider,
    model: result.postProcessResult.model,
  }, null, 2));
}

await main();
