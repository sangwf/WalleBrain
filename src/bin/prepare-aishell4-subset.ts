import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import path from "node:path";

type ParsedArgs = {
  sourceDir: string;
  targetDir: string;
  manifestPath: string;
  limit: number;
  minDurationSeconds: number;
  maxDurationSeconds: number;
  sampleRate: number;
};

type Utterance = {
  startSeconds: number;
  endSeconds: number;
  text: string;
};

type Segment = {
  id: string;
  sourceAudio: string;
  targetAudio: string;
  startSeconds: number;
  durationSeconds: number;
  expectedTranscript: string;
};

function parseArgs(argv: string[]): ParsedArgs {
  let sourceDir = path.resolve(process.cwd(), "runtime", "datasets", "aishell4");
  let targetDir = path.resolve(process.cwd(), "fixtures", "datasets", "aishell4_meeting_subset");
  let manifestPath = path.resolve(process.cwd(), "fixtures", "datasets", "aishell4_manifest.jsonl");
  let limit = 20;
  let minDurationSeconds = 60;
  let maxDurationSeconds = 180;
  let sampleRate = 16_000;

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    if (arg === "--source-dir" && next) {
      sourceDir = path.resolve(next);
      index += 1;
      continue;
    }

    if (arg === "--target-dir" && next) {
      targetDir = path.resolve(next);
      index += 1;
      continue;
    }

    if (arg === "--manifest" && next) {
      manifestPath = path.resolve(next);
      index += 1;
      continue;
    }

    if (arg === "--limit" && next) {
      limit = positiveInteger(next, "--limit");
      index += 1;
      continue;
    }

    if (arg === "--min-duration" && next) {
      minDurationSeconds = positiveNumber(next, "--min-duration");
      index += 1;
      continue;
    }

    if (arg === "--max-duration" && next) {
      maxDurationSeconds = positiveNumber(next, "--max-duration");
      index += 1;
      continue;
    }

    if (arg === "--sample-rate" && next) {
      sampleRate = positiveInteger(next, "--sample-rate");
      index += 1;
      continue;
    }

    if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    }
  }

  if (minDurationSeconds > maxDurationSeconds) {
    throw new Error("--min-duration cannot be greater than --max-duration.");
  }

  return {
    sourceDir,
    targetDir,
    manifestPath,
    limit,
    minDurationSeconds,
    maxDurationSeconds,
    sampleRate,
  };
}

function positiveInteger(value: string, name: string): number {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} requires a positive integer.`);
  }
  return parsed;
}

function positiveNumber(value: string, name: string): number {
  const parsed = Number.parseFloat(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} requires a positive number.`);
  }
  return parsed;
}

async function walkFiles(root: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true });
  const files: string[] = [];

  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...await walkFiles(fullPath));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }

  return files;
}

function fileStem(filePath: string): string {
  return path.basename(filePath).replace(/\.[^.]+$/, "");
}

function normalizeTextGridText(raw: string): string {
  return raw
    .replace(/\\"/g, "\"")
    .replace(/""/g, "\"")
    .replace(/<[^>]+>/g, "")
    .replace(/\[[^\]]+\]/g, "")
    .replace(/\s+/g, "")
    .trim();
}

function parseTextGrid(raw: string): Utterance[] {
  const utterances: Utterance[] = [];
  const intervalBlockPattern = /intervals\s*\[\d+\]\s*:\s*([\s\S]*?)(?=\n\s*intervals\s*\[\d+\]\s*:|\n\s*item\s*\[\d+\]\s*:|$)/g;

  for (const match of raw.matchAll(intervalBlockPattern)) {
    const block = match[1] ?? "";
    const xmin = Number.parseFloat(block.match(/xmin\s*=\s*([0-9.]+)/)?.[1] ?? "");
    const xmax = Number.parseFloat(block.match(/xmax\s*=\s*([0-9.]+)/)?.[1] ?? "");
    const text = normalizeTextGridText(block.match(/text\s*=\s*"([\s\S]*?)"/)?.[1] ?? "");

    if (!Number.isFinite(xmin) || !Number.isFinite(xmax) || xmax <= xmin || !text) {
      continue;
    }

    utterances.push({
      startSeconds: xmin,
      endSeconds: xmax,
      text,
    });
  }

  return utterances.sort((left, right) => {
    if (left.startSeconds === right.startSeconds) {
      return left.endSeconds - right.endSeconds;
    }
    return left.startSeconds - right.startSeconds;
  });
}

function buildSegments(
  meetingID: string,
  sourceAudio: string,
  utterances: Utterance[],
  targetDir: string,
  args: ParsedArgs,
): Segment[] {
  const segments: Segment[] = [];
  let index = 0;
  let segmentIndex = 1;

  while (index < utterances.length && segments.length < args.limit) {
    const start = utterances[index].startSeconds;
    const selected: Utterance[] = [];
    let end = start;

    while (index < utterances.length) {
      const utterance = utterances[index];
      const candidateEnd = Math.max(end, utterance.endSeconds);
      const candidateDuration = candidateEnd - start;

      if (selected.length > 0 && candidateDuration > args.maxDurationSeconds) {
        break;
      }

      selected.push(utterance);
      end = candidateEnd;
      index += 1;

      if (end - start >= args.minDurationSeconds) {
        break;
      }
    }

    const duration = end - start;
    if (duration >= args.minDurationSeconds && selected.length > 0) {
      const id = `${meetingID}_${String(segmentIndex).padStart(3, "0")}`;
      segments.push({
        id,
        sourceAudio,
        targetAudio: path.join(targetDir, `${id}.wav`),
        startSeconds: Math.max(0, start),
        durationSeconds: duration,
        expectedTranscript: selected.map((utterance) => utterance.text).join(""),
      });
      segmentIndex += 1;
    }
  }

  return segments;
}

async function cutAudio(segment: Segment, sampleRate: number): Promise<void> {
  await runCommand("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-ss",
    segment.startSeconds.toFixed(3),
    "-t",
    segment.durationSeconds.toFixed(3),
    "-i",
    segment.sourceAudio,
    "-ac",
    "1",
    "-ar",
    String(sampleRate),
    segment.targetAudio,
  ]);
}

function runCommand(command: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "inherit", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`${command} exited with ${code}: ${stderr.trim()}`));
      }
    });
  });
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const files = await walkFiles(args.sourceDir);
  const textGridFiles = files.filter((file) => /\.TextGrid$/i.test(file));
  const audioByStem = new Map(
    files
      .filter((file) => /\.(wav|flac)$/i.test(file))
      .map((file) => [fileStem(file), file]),
  );

  await mkdir(args.targetDir, { recursive: true });
  await mkdir(path.dirname(args.manifestPath), { recursive: true });

  const allSegments: Segment[] = [];
  for (const textGridFile of textGridFiles.sort()) {
    if (allSegments.length >= args.limit) {
      break;
    }

    const stem = fileStem(textGridFile);
    const sourceAudio = audioByStem.get(stem);
    if (!sourceAudio) {
      continue;
    }

    const textGrid = await readFile(textGridFile, "utf8");
    const utterances = parseTextGrid(textGrid);
    const segments = buildSegments(stem, sourceAudio, utterances, args.targetDir, {
      ...args,
      limit: args.limit - allSegments.length,
    });
    allSegments.push(...segments);
  }

  if (allSegments.length === 0) {
    throw new Error(`No AISHELL-4 segments found under ${args.sourceDir}. Expected matching .TextGrid and .wav/.flac file stems.`);
  }

  for (const segment of allSegments) {
    await cutAudio(segment, args.sampleRate);
  }

  const manifestBase = path.dirname(args.manifestPath);
  const manifestLines = allSegments.map((segment) => JSON.stringify({
    id: segment.id,
    source: "aishell4-meeting",
    audioFile: path.relative(manifestBase, segment.targetAudio),
    expectedTranscript: segment.expectedTranscript,
    note: `AISHELL-4 meeting slice start=${segment.startSeconds.toFixed(3)} duration=${segment.durationSeconds.toFixed(3)} source=${path.basename(segment.sourceAudio)}`,
  }));
  await writeFile(args.manifestPath, `${manifestLines.join("\n")}\n`, "utf8");

  console.log(JSON.stringify({
    sourceDir: args.sourceDir,
    targetDir: args.targetDir,
    manifestPath: args.manifestPath,
    segments: allSegments.length,
    minDurationSeconds: args.minDurationSeconds,
    maxDurationSeconds: args.maxDurationSeconds,
  }, null, 2));
}

function printUsage(): void {
  console.log(`
Usage:
  npm run prepare-aishell4-subset -- --source-dir runtime/datasets/aishell4/test --limit 20 --min-duration 60 --max-duration 180

The source directory should be an extracted AISHELL-4 tree containing matching
.TextGrid annotation files and .wav/.flac audio files. The script cuts mono
16 kHz meeting slices and writes fixtures/datasets/aishell4_manifest.jsonl.
`);
}

await main();
