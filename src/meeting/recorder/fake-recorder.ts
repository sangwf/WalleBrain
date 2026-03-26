import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import type { AudioArtifact, MeetingSession } from "../session/session-types.js";
import type { Recorder } from "./recorder.js";

export class FakeRecorder implements Recorder {
  private readonly activeSessions = new Map<string, string>();

  async start(session: MeetingSession): Promise<void> {
    this.activeSessions.set(session.id, new Date().toISOString());
  }

  async stop(session: MeetingSession): Promise<AudioArtifact> {
    const startedAt = this.activeSessions.get(session.id) ?? session.startedAt;
    const endedAt = new Date().toISOString();
    const targetPath = session.paths.audioFile;

    if (!targetPath) {
      throw new Error("Audio file path is not configured for this session.");
    }

    await mkdir(path.dirname(targetPath), { recursive: true });
    await writeFile(
      targetPath,
      [
        "FAKE_M4A_PLACEHOLDER",
        `session=${session.id}`,
        `startedAt=${startedAt}`,
        `endedAt=${endedAt}`,
      ].join("\n"),
      "utf8",
    );

    this.activeSessions.delete(session.id);

    return {
      path: targetPath,
      startedAt,
      endedAt,
    };
  }
}

