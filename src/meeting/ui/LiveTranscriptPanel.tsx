import { useEffect, useRef } from "react";

type LiveTranscriptPanelProps = {
  sessionId: string;
  transcriptText: string;
  editable: boolean;
  isSyncing: boolean;
  onTranscriptTextChange: (nextValue: string) => void;
};

export function LiveTranscriptPanel({
  sessionId,
  transcriptText,
  editable,
  isSyncing,
  onTranscriptTextChange,
}: LiveTranscriptPanelProps) {
  const textareaRef = useRef<HTMLTextAreaElement | null>(null);
  const lastAutoFocusedSessionId = useRef<string | null>(null);

  useEffect(() => {
    if (!editable || lastAutoFocusedSessionId.current === sessionId) {
      return;
    }

    textareaRef.current?.focus();
    lastAutoFocusedSessionId.current = sessionId;
  }, [editable, sessionId]);

  return (
    <section className="panel transcript-panel">
      <div className="panel-header">
        <div>
          <p className="eyebrow">Live Feed</p>
          <h2>实时录写</h2>
        </div>
        <div className="transcript-panel-actions">
          <span className="reference-badge">仅供参考</span>
          <button
            type="button"
            className="transcript-focus-button"
            onClick={() => textareaRef.current?.focus()}
          >
            聚焦录写区
          </button>
        </div>
      </div>

      <p className="transcript-helper">
        把光标放在这里后双击 <kbd>Ctrl</kbd>，macOS Dictation 会开始写字，WalleBrain 会同时开始录音。
      </p>

      <textarea
        ref={textareaRef}
        className="transcript-editor"
        value={transcriptText}
        onChange={(event) => onTranscriptTextChange(event.target.value)}
        readOnly={!editable}
        placeholder={editable ? "等待 Dictation 实时写入..." : "当前会话未处于录音中。"}
        spellCheck={false}
      />

      <div className="transcript-footer">
        <span>{editable ? "实时同步到当前 session" : "只读回看模式"}</span>
        <span>{isSyncing ? "同步中..." : "已同步"}</span>
      </div>
    </section>
  );
}
