import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

import type {
  ExportResult,
  MeetingSession,
  PostProcessResult,
} from "../session/session-types.js";

function renderSectionList(items: string[]): string {
  if (items.length === 0) {
    return "- None";
  }

  return items.map((item) => `- ${item}`).join("\n");
}

function renderLiveTranscript(items: string[]): string {
  if (items.length === 0) {
    return "_No live dictation captured._";
  }

  return items.join("\n");
}

function renderMeetingNote(
  session: MeetingSession,
  result: PostProcessResult,
): string {
  return `---
type: meeting
title: ${session.title}
date: ${session.startedAt.slice(0, 10)}
mode: ${session.mode}
status: exported
processing_provider: ${result.provider}
processing_model: ${result.model ?? ""}
recorder: ${session.capture.recorder}
audio_device: ${session.capture.audioDevice?.name ?? ""}
audio_file: ${session.paths.audioFile ?? ""}
session_file: ${session.paths.sessionMarkdown}
---

# ${session.title}

## Summary
${result.summary}

## Key Points
${renderSectionList(result.keyPoints)}

## Action Items
${renderSectionList(result.actionItems)}

## Transcript
${result.transcript}

## Live Transcript (Dictation)
${renderLiveTranscript(session.artifacts.liveTranscriptChunks)}
`;
}

export class MarkdownNoteExporter {
  async export(
    session: MeetingSession,
    result: PostProcessResult,
  ): Promise<ExportResult> {
    const targetPath = session.paths.finalNote;

    if (!targetPath) {
      throw new Error("Final note path is not configured for this session.");
    }

    await mkdir(path.dirname(targetPath), { recursive: true });
    await writeFile(targetPath, renderMeetingNote(session, result), "utf8");

    return { path: targetPath };
  }
}
