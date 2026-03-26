import { readdir, stat } from "node:fs/promises";
import path from "node:path";

import type { MeetingSession } from "./session-types.js";
import { SessionStore } from "./session-store.js";

type SessionFileCandidate = {
  path: string;
  mtimeMs: number;
};

async function walkSessionFiles(dirPath: string): Promise<SessionFileCandidate[]> {
  const entries = await readdir(dirPath, { withFileTypes: true });
  const results: SessionFileCandidate[] = [];

  for (const entry of entries) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      results.push(...await walkSessionFiles(fullPath));
      continue;
    }

    if (!entry.isFile() || !entry.name.endsWith(".session.json")) {
      continue;
    }

    const fileStat = await stat(fullPath);
    results.push({
      path: fullPath,
      mtimeMs: fileStat.mtimeMs,
    });
  }

  return results;
}

export async function loadLatestSession(baseDir: string): Promise<{
  sourcePath: string;
  session: MeetingSession;
}> {
  const sessionRoot = path.join(baseDir, "runtime", "WalleBrain", "MeetingSessions");
  const candidates = await walkSessionFiles(sessionRoot);

  if (candidates.length === 0) {
    throw new Error(`No session files found under ${sessionRoot}`);
  }

  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  const latest = candidates[0];
  const sessionStore = new SessionStore();

  return {
    sourcePath: latest.path,
    session: await sessionStore.load(latest.path),
  };
}
