import { execFile } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";

import { MeetingOrchestrator } from "../meeting/orchestration/meeting-orchestrator.js";
import { createPostProcessor } from "../meeting/postprocess/post-processor-factory.js";
import { FfmpegAvfoundationRecorder } from "../meeting/recorder/real-recorder.js";

const execFileAsync = promisify(execFile);

type ParsedArgs = {
  baseDir: string;
  manifestPath: string | null;
};

function parseArgs(argv: string[]): ParsedArgs {
  let baseDir = process.cwd();
  let manifestPath: string | null = null;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    if (arg === "--base-dir" && next) {
      baseDir = path.resolve(next);
      index += 1;
      continue;
    }

    if (arg === "--manifest" && next) {
      manifestPath = path.resolve(next);
      index += 1;
    }
  }

  return { baseDir, manifestPath };
}

async function runCommand(command: string, args: string[], cwd: string): Promise<string> {
  const { stdout, stderr } = await execFileAsync(command, args, {
    cwd,
    env: process.env,
  });

  return [stdout, stderr].filter(Boolean).join("\n").trim();
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const recorder = new FfmpegAvfoundationRecorder();
  const audioDevices = await recorder.listAudioInputDevices();

  if (audioDevices.length === 0) {
    throw new Error("No AVFoundation audio devices were found for acceptance testing.");
  }

  const orchestrator = new MeetingOrchestrator(
    undefined,
    undefined,
    undefined,
    recorder,
    createPostProcessor("auto"),
  );

  const typecheckOutput = await runCommand("npm", ["run", "typecheck"], args.baseDir);
  const buildOutput = await runCommand("npm", ["run", "build"], args.baseDir);

  const liveSession = await orchestrator.startLiveSession({
    title: `Acceptance ${new Date().toLocaleTimeString("zh-CN")}`,
    mode: "normal",
    baseDir: args.baseDir,
    dictationEnabled: true,
  });
  await orchestrator.syncLiveTranscript(
    liveSession.paths.sessionJson,
    "这是验收用的实时录写。\n第二句用于验证实时录写落盘。",
  );
  await sleep(2500);
  const liveResult = await orchestrator.stopLiveSession(liveSession.paths.sessionJson);

  let datasetEvalOutput: string | null = null;

  if (args.manifestPath) {
    datasetEvalOutput = await runCommand(
      "npm",
      [
        "run",
        "eval-dataset",
        "--",
        "--manifest",
        args.manifestPath,
        "--processor",
        "auto",
      ],
      args.baseDir,
    );
  }

  const report = {
    generatedAt: new Date().toISOString(),
    checks: {
      typecheck: typecheckOutput,
      build: buildOutput,
      audioDevices: audioDevices.map((device) => `${device.index}:${device.name}`),
      liveSession: {
        sessionJson: liveResult.session.paths.sessionJson,
        audioFile: liveResult.session.paths.audioFile,
        finalNote: liveResult.session.paths.finalNote,
        liveTranscriptChunks: liveResult.session.artifacts.liveTranscriptChunks,
        transcript: liveResult.postProcessResult.transcript,
        summary: liveResult.postProcessResult.summary,
        provider: liveResult.postProcessResult.provider,
        model: liveResult.postProcessResult.model,
      },
      datasetEval: datasetEvalOutput,
    },
  };

  const targetDir = path.join(args.baseDir, "runtime", "acceptance");
  await mkdir(targetDir, { recursive: true });
  const fileStem = report.generatedAt.replace(/[:.]/g, "-");
  const reportPath = path.join(targetDir, `${fileStem}.acceptance.json`);
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");

  console.log(JSON.stringify({
    reportPath,
    liveSession: report.checks.liveSession,
    datasetEvalIncluded: Boolean(args.manifestPath),
  }, null, 2));
}

await main();
