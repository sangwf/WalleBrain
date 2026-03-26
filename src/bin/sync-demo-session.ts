import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import { loadLatestSession } from "../meeting/session/latest-session.js";

async function main(): Promise<void> {
  const baseDir = process.cwd();
  const latest = await loadLatestSession(baseDir);
  const outputPath = path.join(baseDir, "src", "ui", "generated", "demo-session.ts");
  const fileContent = `const demoSession = ${JSON.stringify(latest.session, null, 2)};\n\nexport default demoSession;\n`;

  await mkdir(path.dirname(outputPath), { recursive: true });
  await writeFile(outputPath, fileContent, "utf8");

  console.log(JSON.stringify({
    source: latest.sourcePath,
    output: outputPath,
  }, null, 2));
}

await main();
