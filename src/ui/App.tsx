import { startTransition, useEffect, useEffectEvent, useState } from "react";

import demoSession from "./generated/demo-session.js";
import { MeetingSessionShell } from "../meeting/ui/MeetingSessionShell.js";
import type {
  AudioInputDevice,
  MeetingSession,
  SessionMode,
} from "../meeting/session/session-types.js";

type LiveSessionResponse = {
  ok: boolean;
  sourcePath?: string;
  session?: MeetingSession;
  error?: string;
  provider?: string | null;
  model?: string | null;
};

type AudioDevicesResponse = {
  ok: boolean;
  devices?: AudioInputDevice[];
  activeLiveSessionJsonPath?: string | null;
  error?: string;
};

function pickDefaultDevice(devices: AudioInputDevice[]): AudioInputDevice | null {
  if (devices.length === 0) {
    return null;
  }

  return devices.find((device) => /macbook pro.*麦克风|macbook pro microphone/i.test(device.name))
    ?? devices[0];
}

function ensureSessionShape(session: MeetingSession): MeetingSession {
  return {
    ...session,
    capture: session.capture ?? {
      recorder: "fake",
      audioDevice: null,
    },
  };
}

function sessionTranscriptText(session: MeetingSession): string {
  return session.artifacts.liveTranscriptChunks.join("\n");
}

export function App() {
  const [session, setSession] = useState<MeetingSession>(
    ensureSessionShape(demoSession as unknown as MeetingSession),
  );
  const [dataSource, setDataSource] = useState<"live" | "demo">("demo");
  const [statusText, setStatusText] = useState("Using synced demo session.");
  const [isMutating, setIsMutating] = useState(false);
  const [isTranscriptSyncing, setIsTranscriptSyncing] = useState(false);
  const [audioDevices, setAudioDevices] = useState<AudioInputDevice[]>([]);
  const [selectedAudioDeviceIndex, setSelectedAudioDeviceIndex] = useState<string>("");
  const [transcriptDraft, setTranscriptDraft] = useState(sessionTranscriptText(
    ensureSessionShape(demoSession as unknown as MeetingSession),
  ));
  const [lastSyncedTranscript, setLastSyncedTranscript] = useState(sessionTranscriptText(
    ensureSessionShape(demoSession as unknown as MeetingSession),
  ));
  const [transcriptSessionPath, setTranscriptSessionPath] = useState(
    ensureSessionShape(demoSession as unknown as MeetingSession).paths.sessionJson,
  );

  const applyLiveSession = useEffectEvent((nextSession: MeetingSession, sourcePath?: string | null) => {
    const normalized = ensureSessionShape(nextSession);
    const nextTranscriptText = sessionTranscriptText(normalized);

    startTransition(() => {
      setSession(normalized);
      setDataSource("live");
      setStatusText(sourcePath ? `Live bridge active: ${sourcePath}` : "Live bridge active.");
      if (normalized.capture.audioDevice?.index) {
        setSelectedAudioDeviceIndex(normalized.capture.audioDevice.index);
      }
      setTranscriptSessionPath((current) => {
        const shouldResetDraft = current !== normalized.paths.sessionJson || nextTranscriptText === lastSyncedTranscript;

        if (shouldResetDraft) {
          setTranscriptDraft(nextTranscriptText);
          setLastSyncedTranscript(nextTranscriptText);
        }

        return normalized.paths.sessionJson;
      });
    });
  });

  const applyFallback = useEffectEvent((message: string) => {
    startTransition(() => {
      setDataSource("demo");
      setStatusText(message);
    });
  });

  const runAction = useEffectEvent(async (endpoint: string, payload: Record<string, unknown>) => {
    setIsMutating(true);

    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });
      const result = await response.json() as LiveSessionResponse;

      if (!response.ok || !result.ok || !result.session) {
        throw new Error(result.error ?? `Mutation failed with ${response.status}`);
      }

      applyLiveSession(
        result.session,
        result.sourcePath
          ? `${result.sourcePath}${result.model ? ` · ${result.model}` : ""}`
          : result.model,
      );
    } catch (error) {
      applyFallback(
        `Mutation failed. ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    } finally {
      setIsMutating(false);
    }
  });

  const refreshAudioDevices = useEffectEvent(async () => {
    try {
      const response = await fetch(`/api/audio/devices?ts=${Date.now()}`);
      const payload = await response.json() as AudioDevicesResponse;

      if (!response.ok || !payload.ok || !payload.devices) {
        throw new Error(payload.error ?? `Audio devices API failed with ${response.status}`);
      }

      const devices = payload.devices;

      startTransition(() => {
        setAudioDevices(devices);
        setSelectedAudioDeviceIndex((current) => {
          if (current && devices.some((device) => device.index === current)) {
            return current;
          }

          const defaultDevice = pickDefaultDevice(devices);
          return defaultDevice?.index ?? "";
        });
      });
    } catch {
      startTransition(() => {
        setAudioDevices([]);
        setSelectedAudioDeviceIndex("");
      });
    }
  });

  const startLiveSession = useEffectEvent(async (mode: SessionMode) => {
    const selectedDevice = audioDevices.find((device) => device.index === selectedAudioDeviceIndex);
    const timeLabel = new Date().toLocaleTimeString("zh-CN");

    await runAction("/api/session/start-live", {
      title: mode === "important" ? `重要会议 ${timeLabel}` : `会议记录 ${timeLabel}`,
      mode,
      processor: "auto",
      audioDeviceIndex: selectedDevice?.index,
      audioDeviceName: selectedDevice?.name,
      dictationEnabled: true,
    });
  });

  const stopLiveSession = useEffectEvent(async () => {
    if (transcriptDraft !== lastSyncedTranscript) {
      await syncTranscriptDraft(transcriptDraft, session.paths.sessionJson);
    }

    await runAction("/api/session/stop-live", {
      sessionJsonPath: session.paths.sessionJson,
      processor: "auto",
    });
  });

  const syncTranscriptDraft = useEffectEvent(async (transcriptText: string, targetSessionPath: string) => {
    setIsTranscriptSyncing(true);

    try {
      const response = await fetch("/api/session/sync-transcript", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          sessionJsonPath: targetSessionPath,
          transcriptText,
        }),
      });
      const result = await response.json() as LiveSessionResponse;

      if (!response.ok || !result.ok || !result.session) {
        throw new Error(result.error ?? `Transcript sync failed with ${response.status}`);
      }

      const nextTranscriptText = sessionTranscriptText(result.session);
      startTransition(() => {
        setLastSyncedTranscript(nextTranscriptText);
        setTranscriptDraft(nextTranscriptText);
      });
      applyLiveSession(result.session, result.sourcePath);
    } catch (error) {
      applyFallback(
        `Transcript sync failed. ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      throw error;
    } finally {
      setIsTranscriptSyncing(false);
    }
  });

  useEffect(() => {
    if (session.status !== "recording" || transcriptDraft === lastSyncedTranscript) {
      return;
    }

    const timeoutId = window.setTimeout(() => {
      void syncTranscriptDraft(transcriptDraft, transcriptSessionPath);
    }, 450);

    return () => {
      window.clearTimeout(timeoutId);
    };
  }, [
    lastSyncedTranscript,
    session.status,
    syncTranscriptDraft,
    transcriptDraft,
    transcriptSessionPath,
  ]);

  useEffect(() => {
    let cancelled = false;

    const refresh = async () => {
      try {
        const response = await fetch(`/api/session/latest?ts=${Date.now()}`);
        const payload = await response.json() as LiveSessionResponse;

        if (!response.ok || !payload.ok || !payload.session) {
          throw new Error(payload.error ?? `Live session API failed with ${response.status}`);
        }

        if (!cancelled) {
          applyLiveSession(payload.session, payload.sourcePath);
        }
      } catch (error) {
        if (!cancelled) {
          applyFallback(
            `Live bridge unavailable, using demo session. ${
              error instanceof Error ? error.message : String(error)
            }`,
          );
        }
      }
    };

    void refreshAudioDevices();
    void refresh();
    const intervalId = window.setInterval(() => {
      void refresh();
    }, 2500);
    const audioIntervalId = window.setInterval(() => {
      void refreshAudioDevices();
    }, 10000);

    return () => {
      cancelled = true;
      window.clearInterval(intervalId);
      window.clearInterval(audioIntervalId);
    };
  }, [applyFallback, applyLiveSession, refreshAudioDevices]);

  const selectedAudioDevice = audioDevices.find((device) => device.index === selectedAudioDeviceIndex) ?? null;

  return (
    <div className="app-shell">
      <div className="bridge-banner">
        <span className={`bridge-pill ${dataSource === "live" ? "live" : "demo"}`}>
          {dataSource === "live" ? "Live Session Bridge" : "Demo Fallback"}
        </span>
        <span className="bridge-copy">{statusText}</span>
        <label className="bridge-device-picker">
          <span>音频输入</span>
          <select
            value={selectedAudioDeviceIndex}
            onChange={(event) => setSelectedAudioDeviceIndex(event.target.value)}
            disabled={isMutating || isTranscriptSyncing || session.status === "recording" || audioDevices.length === 0}
          >
            {audioDevices.length === 0 ? <option value="">No device</option> : null}
            {audioDevices.map((device) => (
              <option key={device.index} value={device.index}>
                {device.name}
              </option>
            ))}
          </select>
        </label>
        <div className="bridge-actions">
          {session.status === "recording" ? (
            <button
              type="button"
              className="bridge-action-button accent"
              onClick={() => void stopLiveSession()}
              disabled={isMutating || isTranscriptSyncing}
            >
              结束并整理
            </button>
          ) : (
            <>
              <button
                type="button"
                className="bridge-action-button"
                onClick={() => void startLiveSession("normal")}
                disabled={isMutating || isTranscriptSyncing || audioDevices.length === 0}
              >
                开始普通会议
              </button>
              <button
                type="button"
                className="bridge-action-button accent"
                onClick={() => void startLiveSession("important")}
                disabled={isMutating || isTranscriptSyncing || audioDevices.length === 0}
              >
                开始重要会议
              </button>
              <button
                type="button"
                className="bridge-action-button"
                onClick={() => void runAction("/api/session/reprocess-latest", {
                  processor: "auto",
                })}
                disabled={isMutating || isTranscriptSyncing}
              >
                重跑最新
              </button>
            </>
          )}
        </div>
      </div>

      <MeetingSessionShell
        session={session}
        transcriptText={transcriptDraft}
        isTranscriptSyncing={isTranscriptSyncing}
        audioDevices={audioDevices}
        selectedAudioDevice={selectedAudioDevice}
        onTranscriptTextChange={setTranscriptDraft}
        onSelectAudioDevice={(deviceIndex) => setSelectedAudioDeviceIndex(deviceIndex)}
        onStartNormal={() => void startLiveSession("normal")}
        onStartImportant={() => void startLiveSession("important")}
        onStopAndProcess={() => void stopLiveSession()}
        onReprocessLatest={() => void runAction("/api/session/reprocess-latest", {
          processor: "auto",
        })}
        isMutating={isMutating || isTranscriptSyncing}
      />
    </div>
  );
}
