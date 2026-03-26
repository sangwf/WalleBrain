export const SESSION_STATUSES = [
  "created",
  "recording",
  "recorded",
  "transcribing",
  "summarized",
  "exported",
  "failed",
] as const;

export const SESSION_MODES = ["normal", "important"] as const;

export type SessionStatus = (typeof SESSION_STATUSES)[number];
export type SessionMode = (typeof SESSION_MODES)[number];

export type SessionFeatureFlags = {
  dictationEnabled: boolean;
  agentEnabled: boolean;
  recordingEnabled: boolean;
};

export type AudioInputDevice = {
  kind: "avfoundation";
  index: string;
  name: string;
};

export type SessionCaptureConfig = {
  recorder: "fake" | "ffmpeg-avfoundation";
  audioDevice: AudioInputDevice | null;
};

export type SessionPaths = {
  sessionMarkdown: string;
  sessionJson: string;
  audioFile: string | null;
  finalNote: string | null;
};

export type SessionProcessingState = {
  transcriptStatus: "pending" | "running" | "completed" | "failed";
  summaryStatus: "pending" | "running" | "completed" | "failed";
  exportStatus: "pending" | "running" | "completed" | "failed";
};

export type SessionArtifacts = {
  liveTranscriptChunks: string[];
  transcript: string | null;
  summary: string | null;
  keyPoints: string[];
  actionItems: string[];
};

export type SessionError = {
  at: string;
  message: string;
};

export type AudioArtifact = {
  path: string;
  startedAt: string;
  endedAt: string;
};

export type PostProcessResult = {
  provider: "fake" | "deerapi";
  model: string | null;
  transcript: string;
  summary: string;
  keyPoints: string[];
  actionItems: string[];
};

export type ExportResult = {
  path: string;
};

export type MeetingSession = {
  id: string;
  title: string;
  mode: SessionMode;
  status: SessionStatus;
  startedAt: string;
  endedAt: string | null;
  paths: SessionPaths;
  features: SessionFeatureFlags;
  capture: SessionCaptureConfig;
  processing: SessionProcessingState;
  artifacts: SessionArtifacts;
  errors: SessionError[];
};

export type CreateSessionInput = {
  title: string;
  mode?: SessionMode;
  now?: Date;
  baseDir?: string;
  dictationEnabled?: boolean;
  agentEnabled?: boolean;
  recordingEnabled?: boolean;
  recorderType?: SessionCaptureConfig["recorder"];
  audioDevice?: AudioInputDevice | null;
};
