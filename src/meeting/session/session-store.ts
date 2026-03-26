import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { renderSessionMarkdown } from "./session-markdown.js";
import type { MeetingSession } from "./session-types.js";

async function ensureParentDir(filePath: string): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
}

export class SessionStore {
  async save(session: MeetingSession): Promise<void> {
    await Promise.all([
      this.saveJson(session),
      this.saveMarkdown(session),
    ]);
  }

  async saveJson(session: MeetingSession): Promise<void> {
    await ensureParentDir(session.paths.sessionJson);
    const json = `${JSON.stringify(session, null, 2)}\n`;
    await writeFile(session.paths.sessionJson, json, "utf8");
  }

  async saveMarkdown(session: MeetingSession): Promise<void> {
    await ensureParentDir(session.paths.sessionMarkdown);
    await writeFile(
      session.paths.sessionMarkdown,
      renderSessionMarkdown(session),
      "utf8",
    );
  }

  async load(sessionJsonPath: string): Promise<MeetingSession> {
    const raw = await readFile(sessionJsonPath, "utf8");
    return normalizeMeetingSession(JSON.parse(raw) as Partial<MeetingSession>);
  }
}

function normalizeMeetingSession(raw: Partial<MeetingSession>): MeetingSession {
  return {
    ...raw,
    features: {
      dictationEnabled: raw.features?.dictationEnabled ?? true,
      agentEnabled: raw.features?.agentEnabled ?? true,
      recordingEnabled: raw.features?.recordingEnabled ?? true,
    },
    capture: {
      recorder: raw.capture?.recorder ?? "fake",
      audioDevice: raw.capture?.audioDevice ?? null,
    },
    processing: {
      transcriptStatus: raw.processing?.transcriptStatus ?? "pending",
      summaryStatus: raw.processing?.summaryStatus ?? "pending",
      exportStatus: raw.processing?.exportStatus ?? "pending",
    },
    artifacts: {
      liveTranscriptChunks: raw.artifacts?.liveTranscriptChunks ?? [],
      transcript: raw.artifacts?.transcript ?? null,
      summary: raw.artifacts?.summary ?? null,
      keyPoints: raw.artifacts?.keyPoints ?? [],
      actionItems: raw.artifacts?.actionItems ?? [],
    },
    errors: raw.errors ?? [],
  } as MeetingSession;
}
