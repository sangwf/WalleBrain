import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import { SessionLauncher } from "../meeting/launcher/session-launcher.js";
import { createPostProcessor } from "../meeting/postprocess/post-processor-factory.js";
import type { PostProcessorStrategy } from "../meeting/postprocess/post-processor-factory.js";
import type { MeetingSession, SessionMode } from "../meeting/session/session-types.js";
import {
  computeCharacterErrorRate,
  isNormalizedExactMatch,
  loadDatasetManifest,
  type DatasetEvaluationResult,
} from "../testing/dataset-manifest.js";

type ParsedArgs = {
  manifestPath: string;
  processor: PostProcessorStrategy;
  limit: number | null;
  mode: SessionMode;
  baseDir: string;
};

function parseArgs(argv: string[]): ParsedArgs {
  let manifestPath = path.resolve(process.cwd(), "fixtures", "datasets", "manifest.jsonl");
  let processor: PostProcessorStrategy = "auto";
  let limit: number | null = null;
  let mode: SessionMode = "normal";
  let baseDir = process.cwd();

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    if (arg === "--manifest" && next) {
      manifestPath = path.resolve(next);
      index += 1;
      continue;
    }

    if (arg === "--processor" && next && (next === "auto" || next === "fake" || next === "real")) {
      processor = next;
      index += 1;
      continue;
    }

    if (arg === "--limit" && next) {
      const parsed = Number.parseInt(next, 10);
      if (!Number.isNaN(parsed) && parsed > 0) {
        limit = parsed;
      }
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

  return {
    manifestPath,
    processor,
    limit,
    mode,
    baseDir,
  };
}

function buildEvaluationSession(
  launcher: SessionLauncher,
  baseDir: string,
  mode: SessionMode,
  sampleId: string,
  audioFile: string,
): MeetingSession {
  const session = launcher.createSession({
    title: `Dataset Eval ${sampleId}`,
    mode,
    baseDir,
    dictationEnabled: false,
    agentEnabled: true,
    recordingEnabled: false,
    recorderType: "fake",
  });

  session.paths.audioFile = audioFile;
  session.capture.recorder = "fake";
  session.status = "recorded";
  session.endedAt = session.startedAt;

  return session;
}

function average(values: number[]): number {
  if (values.length === 0) {
    return 0;
  }

  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function ratio(values: boolean[]): number {
  if (values.length === 0) {
    return 0;
  }

  return values.filter(Boolean).length / values.length;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const samples = await loadDatasetManifest(args.manifestPath);
  const selectedSamples = args.limit ? samples.slice(0, args.limit) : samples;
  const launcher = new SessionLauncher();
  const postProcessor = createPostProcessor(args.processor);
  const results: DatasetEvaluationResult[] = [];

  for (const sample of selectedSamples) {
    const session = buildEvaluationSession(
      launcher,
      args.baseDir,
      args.mode,
      sample.id,
      sample.audioFile,
    );
    const output = await postProcessor.run(session);

    results.push({
      id: sample.id,
      source: sample.source,
      audioFile: sample.audioFile,
      expectedTranscript: sample.expectedTranscript,
      actualTranscript: output.transcript,
      charErrorRate: computeCharacterErrorRate(sample.expectedTranscript, output.transcript),
      isExactMatch: isNormalizedExactMatch(sample.expectedTranscript, output.transcript),
      summary: output.summary,
      provider: output.provider,
      model: output.model,
    });
  }

  const generatedAt = new Date().toISOString();
  const targetDir = path.join(args.baseDir, "runtime", "evaluations");
  await mkdir(targetDir, { recursive: true });
  const fileStem = generatedAt.replace(/[:.]/g, "-");
  const outputPath = path.join(targetDir, `${fileStem}.dataset-eval.json`);
  await writeFile(outputPath, `${JSON.stringify({
    generatedAt,
    manifestPath: args.manifestPath,
    processor: args.processor,
    mode: args.mode,
    sampleCount: results.length,
    averageCharacterErrorRate: average(results.map((result) => result.charErrorRate)),
    exactMatchRate: ratio(results.map((result) => result.isExactMatch)),
    results,
  }, null, 2)}\n`, "utf8");

  console.log(JSON.stringify({
    generatedAt,
    manifestPath: args.manifestPath,
    processor: args.processor,
    mode: args.mode,
    sampleCount: results.length,
    averageCharacterErrorRate: average(results.map((result) => result.charErrorRate)),
    exactMatchRate: ratio(results.map((result) => result.isExactMatch)),
    outputPath,
  }, null, 2));
}

await main();
