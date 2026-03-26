import path from "node:path";

import type {
  CreateSessionInput,
  MeetingSession,
  SessionMode,
} from "../session/session-types.js";

function slugifyTitle(title: string): string {
  return title
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9\u4e00-\u9fa5]+/gi, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-+/g, "-");
}

function formatDateParts(now: Date): {
  year: string;
  dateStamp: string;
  timestamp: string;
} {
  const year = String(now.getFullYear());
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  const hours = String(now.getHours()).padStart(2, "0");
  const minutes = String(now.getMinutes()).padStart(2, "0");
  const seconds = String(now.getSeconds()).padStart(2, "0");

  return {
    year,
    dateStamp: `${year}-${month}-${day}`,
    timestamp: `${hours}-${minutes}-${seconds}`,
  };
}

export class SessionLauncher {
  createSession(input: CreateSessionInput): MeetingSession {
    const now = input.now ?? new Date();
    const mode: SessionMode = input.mode ?? "normal";
    const baseDir = input.baseDir ?? process.cwd();
    const { year, dateStamp, timestamp } = formatDateParts(now);
    const slug = slugifyTitle(input.title) || "meeting";
    const fileStem = `${dateStamp} ${input.title}`;
    const sessionId = `${dateStamp}T${timestamp}_${slug}`;
    const sessionDir = path.join(
      baseDir,
      "runtime",
      "WalleBrain",
      "MeetingSessions",
      year,
    );
    const audioDir = path.join(
      baseDir,
      "runtime",
      "WalleBrain",
      "MeetingAudio",
      year,
    );
    const finalNoteDir = path.join(
      baseDir,
      "runtime",
      "Obsidian",
      "Meetings",
      year,
    );

    return {
      id: sessionId,
      title: input.title,
      mode,
      status: "created",
      startedAt: now.toISOString(),
      endedAt: null,
      paths: {
        sessionMarkdown: path.join(sessionDir, `${fileStem}.session.md`),
        sessionJson: path.join(sessionDir, `${fileStem}.session.json`),
        audioFile: path.join(audioDir, `${fileStem}.m4a`),
        finalNote: path.join(finalNoteDir, `${fileStem}.md`),
      },
      features: {
        dictationEnabled: input.dictationEnabled ?? true,
        agentEnabled: input.agentEnabled ?? true,
        recordingEnabled: input.recordingEnabled ?? true,
      },
      capture: {
        recorder: input.recorderType ?? "fake",
        audioDevice: input.audioDevice ?? null,
      },
      processing: {
        transcriptStatus: "pending",
        summaryStatus: "pending",
        exportStatus: "pending",
      },
      artifacts: {
        liveTranscriptChunks: [],
        transcript: null,
        summary: null,
        keyPoints: [],
        actionItems: [],
      },
      errors: [],
    };
  }
}
