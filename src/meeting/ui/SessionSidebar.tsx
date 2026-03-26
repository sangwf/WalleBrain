import type {
  AudioInputDevice,
  MeetingSession,
} from "../session/session-types.js";

type SessionSidebarProps = {
  session: MeetingSession;
  audioDevices: AudioInputDevice[];
  selectedAudioDevice: AudioInputDevice | null;
  onSelectAudioDevice: (deviceIndex: string) => void;
  onStartNormal: () => void;
  onStartImportant: () => void;
  onStopAndProcess: () => void;
  onReprocessLatest: () => void;
  isMutating: boolean;
};

function statusTone(status: string): string {
  if (status === "completed") {
    return "done";
  }
  if (status === "running") {
    return "running";
  }
  if (status === "failed") {
    return "failed";
  }

  return "pending";
}

export function SessionSidebar({
  session,
  audioDevices,
  selectedAudioDevice,
  onSelectAudioDevice,
  onStartNormal,
  onStartImportant,
  onStopAndProcess,
  onReprocessLatest,
  isMutating,
}: SessionSidebarProps) {
  return (
    <aside className="session-sidebar">
      <section className="sidebar-card">
        <p className="eyebrow">Session</p>
        <h3>状态面板</h3>
        <dl className="meta-list">
          <div>
            <dt>Started</dt>
            <dd>{new Date(session.startedAt).toLocaleString("zh-CN")}</dd>
          </div>
          <div>
            <dt>Ended</dt>
            <dd>{session.endedAt ? new Date(session.endedAt).toLocaleString("zh-CN") : "Still running"}</dd>
          </div>
          <div>
            <dt>Recorder</dt>
            <dd>{session.capture.recorder}</dd>
          </div>
          <div>
            <dt>Audio device</dt>
            <dd>{session.capture.audioDevice?.name ?? selectedAudioDevice?.name ?? "Pending"}</dd>
          </div>
          <div>
            <dt>Audio</dt>
            <dd>{session.paths.audioFile ?? "Pending"}</dd>
          </div>
          <div>
            <dt>Final note</dt>
            <dd>{session.paths.finalNote ?? "Pending"}</dd>
          </div>
        </dl>
      </section>

      <section className="sidebar-card">
        <p className="eyebrow">Pipeline</p>
        <h3>后处理进度</h3>
        <div className="status-stack">
          <div className={`status-row ${statusTone(session.processing.transcriptStatus)}`}>
            <span>Transcript</span>
            <strong>{session.processing.transcriptStatus}</strong>
          </div>
          <div className={`status-row ${statusTone(session.processing.summaryStatus)}`}>
            <span>Summary</span>
            <strong>{session.processing.summaryStatus}</strong>
          </div>
          <div className={`status-row ${statusTone(session.processing.exportStatus)}`}>
            <span>Export</span>
            <strong>{session.processing.exportStatus}</strong>
          </div>
        </div>
      </section>

      <section className="sidebar-card">
        <p className="eyebrow">Capture</p>
        <h3>录音设备</h3>
        <label className="device-picker">
          <span>当前输入</span>
          <select
            value={selectedAudioDevice?.index ?? ""}
            onChange={(event) => onSelectAudioDevice(event.target.value)}
            disabled={isMutating || session.status === "recording" || audioDevices.length === 0}
          >
            {audioDevices.length === 0 ? <option value="">No audio device</option> : null}
            {audioDevices.map((device) => (
              <option key={device.index} value={device.index}>
                {device.name}
              </option>
            ))}
          </select>
        </label>
      </section>

      <section className="sidebar-card">
        <p className="eyebrow">Quick Actions</p>
        <h3>下一步</h3>
        <div className="quick-actions">
          {session.status === "recording" ? (
            <button type="button" className="primary" onClick={onStopAndProcess} disabled={isMutating}>
              结束并整理
            </button>
          ) : (
            <>
              <button type="button" onClick={onStartNormal} disabled={isMutating || audioDevices.length === 0}>
                开始普通会议
              </button>
              <button type="button" onClick={onStartImportant} disabled={isMutating || audioDevices.length === 0}>
                开始重要会议
              </button>
              <button type="button" className="primary" onClick={onReprocessLatest} disabled={isMutating}>
                重跑后处理
              </button>
            </>
          )}
        </div>
      </section>
    </aside>
  );
}
