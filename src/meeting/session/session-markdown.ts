import type { MeetingSession } from "./session-types.js";

function renderBulletList(items: string[], emptyText: string): string {
  if (items.length === 0) {
    return `- ${emptyText}`;
  }

  return items.map((item) => `- ${item}`).join("\n");
}

export function renderSessionMarkdown(session: MeetingSession): string {
  return `# ${session.title}

## Session Meta
- Session ID: ${session.id}
- Started At: ${session.startedAt}
- Mode: ${session.mode}
- Status: ${session.status}
- Recorder: ${session.capture.recorder}
- Audio Device: ${session.capture.audioDevice ? `${session.capture.audioDevice.name} (#${session.capture.audioDevice.index})` : "Not selected"}

## Live Transcript (Reference Only)
${renderBulletList(session.artifacts.liveTranscriptChunks, "Waiting for live transcript...")}

## Interim Notes
- Waiting for agent notes...

## Open Questions
- None yet.

## Interim Action Items
${renderBulletList(session.artifacts.actionItems, "None yet.")}
`;
}
