import type {
  AudioInputDevice,
  MeetingSession,
} from "../session/session-types.js";
import { LiveTranscriptPanel } from "./LiveTranscriptPanel.js";
import { SessionHeader } from "./SessionHeader.js";
import { SessionSidebar } from "./SessionSidebar.js";

type MeetingSessionShellProps = {
  session: MeetingSession;
  transcriptText: string;
  isTranscriptSyncing: boolean;
  audioDevices: AudioInputDevice[];
  selectedAudioDevice: AudioInputDevice | null;
  onTranscriptTextChange: (nextValue: string) => void;
  onSelectAudioDevice: (deviceIndex: string) => void;
  onStartNormal: () => void;
  onStartImportant: () => void;
  onStopAndProcess: () => void;
  onReprocessLatest: () => void;
  isMutating: boolean;
};

function formatElapsedLabel(session: MeetingSession): string {
  const started = new Date(session.startedAt).getTime();
  const ended = session.endedAt ? new Date(session.endedAt).getTime() : Date.now();
  const diffMs = Math.max(ended - started, 0);
  const totalSeconds = Math.floor(diffMs / 1000);
  const hours = String(Math.floor(totalSeconds / 3600)).padStart(2, "0");
  const minutes = String(Math.floor((totalSeconds % 3600) / 60)).padStart(2, "0");
  const seconds = String(totalSeconds % 60).padStart(2, "0");

  return `${hours}:${minutes}:${seconds}`;
}

function renderList(items: string[], emptyText: string) {
  if (items.length === 0) {
    return <p className="empty-copy">{emptyText}</p>;
  }

  return (
    <ul className="bullet-list">
      {items.map((item) => (
        <li key={item}>{item}</li>
      ))}
    </ul>
  );
}

export function MeetingSessionShell({
  session,
  transcriptText,
  isTranscriptSyncing,
  audioDevices,
  selectedAudioDevice,
  onTranscriptTextChange,
  onSelectAudioDevice,
  onStartNormal,
  onStartImportant,
  onStopAndProcess,
  onReprocessLatest,
  isMutating,
}: MeetingSessionShellProps) {
  return (
    <main className="meeting-shell">
      <SessionHeader session={session} elapsedLabel={formatElapsedLabel(session)} />

      <div className="shell-grid">
        <section className="document-surface">
          <LiveTranscriptPanel
            sessionId={session.id}
            transcriptText={transcriptText}
            editable={session.status === "recording" && session.features.dictationEnabled}
            isSyncing={isTranscriptSyncing}
            onTranscriptTextChange={onTranscriptTextChange}
          />

          <section className="panel">
            <div className="panel-header">
              <div>
                <p className="eyebrow">Agent Workspace</p>
                <h2>临时结论</h2>
              </div>
            </div>
            {renderList(session.artifacts.keyPoints, "Waiting for interim synthesis...")}
          </section>

          <section className="panel panel-split">
            <div>
              <div className="panel-header">
                <div>
                  <p className="eyebrow">Open Loop</p>
                  <h2>待确认问题</h2>
                </div>
              </div>
              <p className="empty-copy">
                当前 harness 还没有 questions 流，下一步可以从 agent 输出里拆出来。
              </p>
            </div>

            <div>
              <div className="panel-header">
                <div>
                  <p className="eyebrow">Action Items</p>
                  <h2>临时 Action Items</h2>
                </div>
              </div>
              {renderList(session.artifacts.actionItems, "No action items yet.")}
            </div>
          </section>

          <section className="panel final-summary-panel">
            <div className="panel-header">
              <div>
                <p className="eyebrow">Post Process</p>
                <h2>最终摘要预览</h2>
              </div>
            </div>
            <p className="summary-copy">{session.artifacts.summary ?? "Summary pending."}</p>
          </section>
        </section>

        <SessionSidebar
          session={session}
          audioDevices={audioDevices}
          selectedAudioDevice={selectedAudioDevice}
          onSelectAudioDevice={onSelectAudioDevice}
          onStartNormal={onStartNormal}
          onStartImportant={onStartImportant}
          onStopAndProcess={onStopAndProcess}
          onReprocessLatest={onReprocessLatest}
          isMutating={isMutating}
        />
      </div>
    </main>
  );
}
