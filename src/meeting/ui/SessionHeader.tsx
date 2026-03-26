import type { MeetingSession } from "../session/session-types.js";

type SessionHeaderProps = {
  session: MeetingSession;
  elapsedLabel: string;
};

function formatRecordingLabel(session: MeetingSession): string {
  if (!session.features.recordingEnabled) {
    return "Recording Off";
  }

  return session.status === "recording" ? "Recording Active" : "Recording Ready";
}

function formatStatusLabel(status: MeetingSession["status"]): string {
  switch (status) {
    case "created":
      return "Created";
    case "recording":
      return "Recording";
    case "recorded":
      return "Recorded";
    case "transcribing":
      return "Transcribing";
    case "summarized":
      return "Summarized";
    case "exported":
      return "Exported";
    case "failed":
      return "Failed";
  }
}

export function SessionHeader({
  session,
  elapsedLabel,
}: SessionHeaderProps) {
  return (
    <header className="session-header">
      <div>
        <p className="eyebrow">Meeting Harness</p>
        <h1>{session.title}</h1>
        <p className="session-subtitle">
          {session.startedAt.slice(0, 10)} · Session {session.id}
        </p>
      </div>

      <div className="session-header-actions">
        <div className="timer-card">
          <span className="timer-label">Elapsed</span>
          <strong>{elapsedLabel}</strong>
        </div>

        <div className="pill-row">
          <span className={`pill mode-${session.mode}`}>{session.mode}</span>
          <span className={`pill status-${session.status}`}>
            {formatStatusLabel(session.status)}
          </span>
          <span className={`pill ${session.features.recordingEnabled ? "active" : "muted"}`}>
            {formatRecordingLabel(session)}
          </span>
          <span className={`pill ${session.features.dictationEnabled ? "active" : "muted"}`}>
            Dictation {session.features.dictationEnabled ? "On" : "Off"}
          </span>
          <span className={`pill ${session.features.agentEnabled ? "active" : "muted"}`}>
            Agent {session.features.agentEnabled ? "On" : "Off"}
          </span>
          <span className="pill">
            {session.capture.audioDevice?.name ?? "Audio Device Pending"}
          </span>
        </div>
      </div>
    </header>
  );
}
