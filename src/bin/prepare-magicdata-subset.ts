import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

type ParsedArgs = {
  sourceDir: string;
  targetDir: string;
  limit: number;
};

function parseArgs(argv: string[]): ParsedArgs {
  let sourceDir = path.resolve(process.cwd(), "runtime", "datasets", "magicdata_dev", "dev");
  let targetDir = path.resolve(process.cwd(), "fixtures", "datasets", "magicdata_dev_subset");
  let limit = 12;

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

    if (arg === "--limit" && next) {
      const parsed = Number.parseInt(next, 10);
      if (!Number.isNaN(parsed) && parsed > 0) {
        limit = parsed;
      }
      index += 1;
    }
  }

  return { sourceDir, targetDir, limit };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const transPath = path.join(args.sourceDir, "TRANS.txt");
  const raw = await readFile(transPath, "utf8");
  const lines = raw.split("\n").slice(1).map((line) => line.trim()).filter(Boolean);

  await mkdir(args.targetDir, { recursive: true });

  const manifestLines: string[] = [];
  let copied = 0;

  for (const line of lines) {
    if (copied >= args.limit) {
      break;
    }

    const [fileName, speakerId, ...rest] = line.split("\t");
    const transcript = rest.join("\t").trim();
    const sourceAudio = path.join(args.sourceDir, speakerId, fileName);
    const targetAudio = path.join(args.targetDir, fileName);

    await copyFile(sourceAudio, targetAudio);
    manifestLines.push(JSON.stringify({
      id: fileName.replace(/\.wav$/i, ""),
      source: "magicdata-dev",
      audioFile: path.relative(path.join(args.targetDir, ".."), targetAudio),
      expectedTranscript: transcript,
    }));
    copied += 1;
  }

  const manifestPath = path.join(path.join(args.targetDir, ".."), "manifest.jsonl");
  await writeFile(manifestPath, `${manifestLines.join("\n")}\n`, "utf8");

  console.log(JSON.stringify({
    copied,
    targetDir: args.targetDir,
    manifestPath,
  }, null, 2));
}

await main();
